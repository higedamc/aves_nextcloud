import 'dart:async';
import 'dart:io';

import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/credential_store.dart';
import 'package:aves/model/nextcloud/errors.dart';
import 'package:aves/model/nextcloud/mirror_store.dart';
import 'package:aves/model/nextcloud/paths.dart';
import 'package:aves/model/nextcloud/remote_item.dart';
import 'package:aves/model/nextcloud/repository.dart';
import 'package:aves/model/nextcloud/sync.dart';
import 'package:aves/model/nextcloud/sync_ports.dart';

// One-way sync of one account (server → device), the algorithm pinned in `sync.dart`.
//
// Invariants this class owns:
// - Runs for the same account are serialized: `evictToFit`/`remove` never interleave with `record`, which is
//   what makes the mirror store's "size read from disk at `record`" trustworthy. The app calls this from the
//   main isolate only (`localMediaDb.nextId` is process-local).
// - The index is accounting, the filesystem is the truth: a row whose file is missing is a cache miss. It is
//   re-downloaded when the listing emits it and dropped (row and entry) otherwise.
// - A path reported through `onItemFailure` was not enumerated. Nothing under it is treated as removed.
// - A persisted collection etag means "the mirror holds every file under this subtree as of this etag". A
//   listing alone cannot make that promise: the budget, a failed download, a sink refusal or an eviction all
//   end the run normally while leaving a listed file without a current row and bytes. So new etags are added
//   only when every listed item ended the run mirrored (derived from the store after eviction, not from the
//   failure sites), and the whole map is forgotten when the run evicted or lost anything, because a local
//   removal under a subtree skipped on an old etag is invisible to every server etag. Nothing is persisted
//   after a fatal failure; `force` and a raised cache limit list everything again. Merging (and the
//   unchanged-root fast path) rests on Nextcloud propagating every etag change to all ancestors: the promise
//   only stays true because any later change under it bumps it. Against a WebDAV server that does not
//   propagate, this is silently stale.
// - Downloads go newest first, within the cache budget. When making room would evict a file downloaded in
//   this run, the remaining (older) files are counted as skipped rather than thrashing the cache.
class NextcloudSyncUseCaseImpl implements NextcloudSyncUseCase {
  final NextcloudRepositoryFactory _repositories;
  final NextcloudCredentialStore _credentials;
  final NextcloudMirrorStore _mirror;
  final NextcloudSyncSink _sink;
  final NextcloudSyncStateStore _states;
  final DateTime Function() _now;

  final Map<String, Future<NextcloudSyncResult>> _running = {};
  Future<NextcloudSyncResult> _lastResult = Future.value(const NextcloudSyncResult());

  new({
    required this._repositories,
    required this._credentials,
    required this._mirror,
    required this._sink,
    required this._states,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  @override
  Future<NextcloudSyncResult> get lastResult => _lastResult;

  @override
  Stream<NextcloudSyncProgress> run(NextcloudSyncRequest request) {
    final controller = StreamController<NextcloudSyncProgress>();
    final accountId = request.account.id;
    // a run for the same account waits for the previous one, whatever its outcome
    final previous = _running[accountId]?.then((_) {}, onError: (_) {}) ?? Future.value();
    final result = previous.then((_) => _run(request, controller.add));
    _running[accountId] = result;
    _lastResult = result;
    // `NextcloudFailure`s end up in the result; anything else is a bug and must not vanish with the stream
    result.then((_) {}, onError: controller.addError).whenComplete(() {
      if (identical(_running[accountId], result)) _running.remove(accountId);
      controller.close();
    });
    return controller.stream;
  }

  Future<NextcloudSyncResult> _run(NextcloudSyncRequest request, void Function(NextcloudSyncProgress) emit) async {
    final account = request.account;
    final cancellation = request.cancellation;
    final stats = _Stats();
    try {
      emit(const NextcloudSyncProgress(phase: NextcloudSyncPhase.probing));
      final credentials = await _credentials.credentialsFor(account);
      if (credentials == null) {
        // no stored app password; 0 marks "nothing to send" as opposed to a server verdict
        throw const NextcloudAuthFailure(0);
      }
      final repository = _repositories.open(account, credentials);
      try {
        await repository.probe();
        _checkCancelled(cancellation);
        await _sweepPartFiles(account);

        final state = await _states.load(account);
        // A raised limit of either kind can turn a skipped item into a wanted one, and an item under a subtree
        // trusted by etag is never listed, so neither could ever be promoted without listing everything.
        final relist = request.force || account.cacheLimitBytes > state.cacheLimitBytes || account.videoAutoDownloadLimitBytes > state.videoAutoDownloadLimitBytes;
        final known = relist ? const <String, String>{} : state.collectionEtags;

        emit(const NextcloudSyncProgress(phase: NextcloudSyncPhase.listing));
        final listing = await _list(repository, known, cancellation, stats);

        final rows = {for (final row in await _mirror.listAll(account)) row.relativePath: row};
        final missing = <String>{};
        for (final row in rows.values) {
          // a `placeholder` row has no file by design, so its absence is not a cache miss
          if (row.tier == NextcloudMirrorTier.placeholder) continue;
          if (!await File(_mirror.localPathFor(account, row.relativePath)).exists()) missing.add(row.relativePath);
        }

        // plan: what to fetch (newest first), what is gone
        final downloads = <NextcloudRemoteItem>[];
        for (final item in listing.items.values) {
          final row = rows[item.relativePath];
          // A row at a later tier than wanted is current (an original answers for a placeholder), so an
          // already-held video is never downgraded when the threshold drops below its size; a row at an
          // earlier tier is not, so raising the threshold promotes a placeholder to an original.
          final current = row != null && row.etag == item.etag && !missing.contains(item.relativePath) && row.satisfies(_wantedTier(account, item));
          if (current && !request.force) {
            stats.skipped++;
          } else {
            downloads.add(item);
          }
        }
        downloads.sort((a, b) {
          final byDate = b.lastModified.compareTo(a.lastModified);
          return byDate != 0 ? byDate : a.relativePath.compareTo(b.relativePath);
        });
        final removed = <String>{};
        final lost = <String>{};
        for (final path in rows.keys) {
          if (listing.items.containsKey(path)) continue;
          if (missing.contains(path)) {
            // a cache miss the listing cannot refill now: the row is a lie, so it goes with its entry
            lost.add(path);
          } else if (listing.isEnumerated(path)) {
            removed.add(path);
          }
        }

        final fetched = await _download(repository, account, downloads, rows, cancellation, stats, emit);
        await _drop(account, removed, stats, countAsRemoved: true);
        await _drop(account, lost, stats, countAsRemoved: false);

        emit(const NextcloudSyncProgress(phase: NextcloudSyncPhase.evicting));
        await _evict(account, stats);

        // The etags are a promise that the mirror reflects those subtrees. Read after `_evict`, since both the
        // download loop and the final sweep evict.
        final Map<String, String> etags;
        if (stats.evicted > 0 || stats.lost > 0) {
          // a file left the mirror without the server knowing: it may sit under a subtree this run skipped on
          // an old etag, and no server etag will ever point at it again, so everything is listed next time
          etags = const {};
        } else if (await _mirrorReflects(account, listing.items.values, fetched)) {
          // `known` rather than the stored map: a relisting run must not resurrect etags it was told to ignore
          etags = {...known, ...listing.published};
        } else {
          // the listing completed but the mirror did not (budget, a failed download, a refused entry): nothing
          // new is promised, and the subtrees this run trusted and never touched stay as they were
          etags = known;
        }
        await _states.save(account, NextcloudSyncState(collectionEtags: etags, cacheLimitBytes: account.cacheLimitBytes, videoAutoDownloadLimitBytes: account.videoAutoDownloadLimitBytes));
        emit(const NextcloudSyncProgress(phase: NextcloudSyncPhase.done));
        return stats.result();
      } finally {
        repository.dispose();
      }
    } on NextcloudFailure catch (e) {
      emit(const NextcloudSyncProgress(phase: NextcloudSyncPhase.failed));
      return stats.result(fatal: e);
    }
  }

  Future<_Listing> _list(NextcloudRepository repository, Map<String, String> known, NextcloudCancellation? cancellation, _Stats stats) async {
    final listing = _Listing(known);
    // `''` is the account root folder: the repository prefixes `account.rootFolder` itself
    final stream = repository.listMediaTree(
      '',
      knownCollectionEtags: known,
      onCollection: listing.publish,
      onItemFailure: (path, failure) {
        stats.itemFailures[path] = failure;
        listing.reported.add(path);
      },
      cancellation: cancellation,
    );
    await for (final item in stream) {
      listing.items[item.relativePath] = item;
    }
    return listing;
  }

  // Whether every listed item ended the run with a row, bytes on disk and the listed etag (or the etag the
  // bytes were observed with, when fetched in this run). Derived from the store so that it holds whatever
  // ended the run short, rather than enumerating the ways it can; stops at the first gap.
  Future<bool> _mirrorReflects(NextcloudAccount account, Iterable<NextcloudRemoteItem> items, Set<String> fetched) async {
    final rows = {for (final row in await _mirror.listAll(account)) row.relativePath: row};
    for (final item in items) {
      final path = item.relativePath;
      final row = rows[path];
      if (row == null) return false;
      if (row.etag != item.etag && !fetched.contains(path)) return false;
      // a row below the wanted tier (a placeholder video whose threshold was raised, left there by the
      // budget) is a gap: promising the subtree would skip it on every later run and never promote it
      if (!row.satisfies(_wantedTier(account, item))) return false;
      if (row.tier == NextcloudMirrorTier.placeholder) continue;
      if (!await File(_mirror.localPathFor(account, path)).exists()) return false;
    }
    return true;
  }

  // The tier this run wants for an item. First cut: everything is mirrored as an original except a video
  // above `videoAutoDownloadLimitBytes`, which gets a `placeholder` row and is streamed on demand instead.
  // The grid and view tiers for images arrive with the budget work; this is the only place that decides.
  static NextcloudMirrorTier _wantedTier(NextcloudAccount account, NextcloudRemoteItem item) {
    if (item.isVideo && item.sizeBytes > account.videoAutoDownloadLimitBytes) return NextcloudMirrorTier.placeholder;
    return NextcloudMirrorTier.original;
  }

  // returns the paths fetched in this run
  Future<Set<String>> _download(
    NextcloudRepository repository,
    NextcloudAccount account,
    List<NextcloudRemoteItem> downloads,
    Map<String, NextcloudMirrorIndexEntry> rows,
    NextcloudCancellation? cancellation,
    _Stats stats,
    void Function(NextcloudSyncProgress) emit,
  ) async {
    final total = downloads.length;
    var done = 0;
    var bytesDone = 0;
    final fetchedThisRun = <String>{};
    var fetchedBytes = 0;
    emit(NextcloudSyncProgress(phase: NextcloudSyncPhase.downloading, done: done, total: total, bytesDone: bytesDone));

    for (var i = 0; i < downloads.length; i++) {
      _checkCancelled(cancellation);
      final item = downloads[i];
      final path = item.relativePath;
      final existing = rows[path];
      try {
        if (_wantedTier(account, item) == NextcloudMirrorTier.placeholder) {
          // no bytes, so no budget, no eviction and no download: the row and the entry are all there is
          await _mirror.record(
            account,
            NextcloudMirrorIndexEntry(
              relativePath: path,
              etag: item.etag,
              fileId: item.fileId,
              tier: NextcloudMirrorTier.placeholder,
              remoteSizeBytes: item.sizeBytes,
              localSizeBytes: 0,
              remoteLastModified: item.lastModified,
              downloadedAt: _now(),
              lastAccessAt: existing?.lastAccessAt ?? _now(),
            ),
          );
          if (!await _sink.putPlaceholder(account, item)) {
            // a row with no entry would be skipped by etag forever: drop it so the next run retries
            await _mirror.remove(account, path);
            throw NextcloudParseFailure('could not create a placeholder entry for $path');
          }
          fetchedThisRun.add(path);
          if (existing == null) {
            stats.added++;
          } else {
            stats.updated++;
          }
          done++;
          emit(NextcloudSyncProgress(phase: NextcloudSyncPhase.downloading, done: done, total: total, bytesDone: bytesDone));
          continue;
        }
        if (item.sizeBytes > account.cacheLimitBytes) {
          // never empty the whole mirror for a file that cannot fit anyway
          throw NextcloudQuotaFailure(requiredBytes: item.sizeBytes, availableBytes: account.cacheLimitBytes);
        }
        if (fetchedBytes + item.sizeBytes > account.cacheLimitBytes) {
          // the budget is full of this run's newest files; the rest are older and would only thrash
          stats.skipped += downloads.length - i;
          break;
        }
        // make room first; whatever goes must leave the collection in the same step
        final eviction = await _mirror.evictToFit(account, reserveBytes: item.sizeBytes);
        if (!eviction.isEmpty) {
          await _applyEviction(account, eviction, stats);
          // `touched`, not `removed`: a file this run fetched is just as lost to it if the store demoted
          // it to a cheaper tier as if the store deleted it
          if (eviction.touched.any(fetchedThisRun.contains)) {
            // a refreshed file keeps its old LRU position, so the store may still pick one of this run's
            // files: stop here rather than trade the newest files for older ones
            stats.skipped += downloads.length - i;
            break;
          }
        }
        final used = await _mirror.usedBytes(account);
        if (used + item.sizeBytes > account.cacheLimitBytes) {
          throw NextcloudQuotaFailure(requiredBytes: item.sizeBytes, availableBytes: account.cacheLimitBytes - used);
        }

        final localPath = _mirror.localPathFor(account, path);
        var itemBytes = 0;
        final observedEtag = await repository.downloadTo(
          item,
          localPath,
          onProgress: (received, _) {
            bytesDone += received - itemBytes;
            itemBytes = received;
            emit(NextcloudSyncProgress(phase: NextcloudSyncPhase.downloading, done: done, total: total, bytesDone: bytesDone));
          },
          cancellation: cancellation,
        );
        final now = _now();
        await _mirror.record(
          account,
          NextcloudMirrorIndexEntry(
            relativePath: path,
            // the etag the bytes actually have, which may be newer than the listing's
            etag: observedEtag ?? item.etag,
            fileId: item.fileId,
            // this run mirrors whole files, so the tier is `original` and the two sizes agree; the store
            // reads the local size back from disk either way
            tier: NextcloudMirrorTier.original,
            remoteSizeBytes: item.sizeBytes,
            localSizeBytes: item.sizeBytes,
            remoteLastModified: item.lastModified,
            downloadedAt: now,
            // a server-side change is not a view: keep the LRU position of a refreshed file
            lastAccessAt: existing?.lastAccessAt ?? now,
          ),
        );
        if (!await _sink.putMirroredFile(account, item, localPath, NextcloudMirrorTier.original)) {
          // mirrored but invisible would be skipped by etag forever: drop the bytes so the next run retries
          await _mirror.remove(account, path);
          throw NextcloudParseFailure('could not create an entry for $path');
        }
        fetchedThisRun.add(path);
        fetchedBytes += item.sizeBytes;
        if (existing == null) {
          stats.added++;
        } else {
          stats.updated++;
        }
      } on NextcloudFailure catch (e) {
        if (_isFatal(e)) rethrow;
        stats.itemFailures[path] = e;
      }
      done++;
      emit(NextcloudSyncProgress(phase: NextcloudSyncPhase.downloading, done: done, total: total, bytesDone: bytesDone));
    }
    return fetchedThisRun;
  }

  Future<void> _drop(NextcloudAccount account, Set<String> paths, _Stats stats, {required bool countAsRemoved}) async {
    if (paths.isEmpty) return;
    final gone = <String>{};
    for (final path in paths) {
      try {
        await _mirror.remove(account, path);
        gone.add(path);
      } on NextcloudFailure catch (e) {
        stats.itemFailures[path] = e;
      } on FileSystemException catch (e) {
        stats.itemFailures[path] = NextcloudLocalStorageFailure('local delete failed: ${e.message}', cause: e);
      }
    }
    if (gone.isEmpty) return;
    await _sink.removeMirroredFiles(account, gone);
    if (countAsRemoved) {
      stats.removed += gone.length;
    } else {
      stats.lost += gone.length;
    }
  }

  Future<void> _evict(NextcloudAccount account, _Stats stats) async {
    final eviction = await _mirror.evictToFit(account);
    if (eviction.isEmpty) return;
    await _applyEviction(account, eviction, stats);
  }

  // Both eviction sites go through here so the two outcomes cannot be handled differently by accident.
  //
  // `demoted` is structurally empty until the view tier exists, which is why there is an `assert` and not
  // a branch: the refresh a demoted entry needs (its bytes and its recorded dimensions both changed) is
  // the leaf that introduces demotion to write, and an empty handler here would let that leaf ship a grid
  // full of entries describing bytes that are no longer there.
  //
  // Read the `assert` as a development tripwire and not as a guarantee: it is compiled out of a release
  // build, so a non-empty `demoted` would be dropped silently there. The leaf that fills the set must
  // replace this line with the refresh rather than rely on it.
  Future<void> _applyEviction(NextcloudAccount account, NextcloudEvictionOutcome eviction, _Stats stats) async {
    assert(eviction.demoted.isEmpty, 'demoted rows need their entries refreshed, which is not implemented');
    if (eviction.removed.isEmpty) return;
    await _sink.removeMirroredFiles(account, eviction.removed);
    stats.evicted += eviction.removed.length;
  }

  // a process that died mid-download leaves `<path>.part` behind: not indexed, not evictable, never reused
  Future<void> _sweepPartFiles(NextcloudAccount account) async {
    final root = Directory(_mirror.localPathFor(account, ''));
    if (!await root.exists()) return;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.endsWith('.part')) {
        try {
          await entity.delete();
        } on FileSystemException {
          // best effort; the next run tries again
        }
      }
    }
  }

  static bool _isFatal(NextcloudFailure failure) => switch (failure) {
    NextcloudAuthFailure() || NextcloudNetworkFailure() || NextcloudTlsFailure() || NextcloudInsecureSchemeFailure() || NextcloudCancelledFailure() => true,
    _ => false,
  };

  static void _checkCancelled(NextcloudCancellation? cancellation) {
    if (cancellation?.isCancelled ?? false) throw const NextcloudCancelledFailure();
  }
}

// what one listing told us, and what it did not
class _Listing {
  final Map<String, String> known;
  final items = <String, NextcloudRemoteItem>{};
  final published = <String, String>{};

  // collections published with the etag we already knew: skipped, nothing under them was enumerated
  final skipped = <String>{};

  // paths reported through `onItemFailure`: not enumerated, nothing under them is known to be gone
  final reported = <String>{};

  new(this.known);

  void publish(NextcloudRemoteItem collection) {
    final path = collection.relativePath;
    published[path] = collection.etag;
    if (known[path] == collection.etag) skipped.add(path);
  }

  // whether the listing would have emitted `path` if it still existed on the server: true unless `path` or
  // one of its ancestors (up to and including the root, '') was skipped or reported. Walks ancestors with set
  // lookups rather than scanning the sets, because on an ordinary incremental run nearly every collection is
  // skipped and nearly every row is not emitted.
  bool isEnumerated(String path) {
    var current = path;
    while (true) {
      if (skipped.contains(current) || reported.contains(current)) return false;
      if (current.isEmpty) return true;
      current = NextcloudPaths.parentOf(current);
    }
  }
}

class _Stats {
  int added = 0, updated = 0, removed = 0, skipped = 0, evicted = 0, lost = 0;
  final itemFailures = <String, NextcloudFailure>{};

  NextcloudSyncResult result({NextcloudFailure? fatal}) => NextcloudSyncResult(
    added: added,
    updated: updated,
    removed: removed,
    skipped: skipped,
    evicted: evicted,
    lost: lost,
    itemFailures: Map.unmodifiable(itemFailures),
    fatal: fatal,
  );
}
