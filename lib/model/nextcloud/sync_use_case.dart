import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

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
          final current = row != null && row.etag == item.etag && !missing.contains(item.relativePath) && _holds(row, _wantedTier(account, item));
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
      if (!_holds(row, _wantedTier(account, item))) return false;
      if (row.tier == NextcloudMirrorTier.placeholder) continue;
      if (!await File(_mirror.localPathFor(account, path)).exists()) return false;
    }
    return true;
  }

  // The tier a sync wants for an item; the only place that decides.
  //
  // An image is held as its `grid` derivative (the `x=256` bucket: 192x256 at a measured mean of 18 KB,
  // 0.41 GB for a 22,000-image library). The `view` tier is fetched when an item is opened, never by the
  // sync, and the `original` only on an explicit download. A video is held whole below
  // `videoAutoDownloadLimitBytes`, since the server cannot derive anything from it, and as a `placeholder`
  // above, streamed on demand.
  static NextcloudMirrorTier _wantedTier(NextcloudAccount account, NextcloudRemoteItem item) {
    if (item.isVideo) {
      return item.sizeBytes > account.videoAutoDownloadLimitBytes ? NextcloudMirrorTier.placeholder : NextcloudMirrorTier.original;
    }
    return NextcloudMirrorTier.grid;
  }

  // Whether a row answers for the tier a run wants. Tier order decides it, with one policy on top: a
  // `placeholder` answers for `grid`, because it is what a run records when the server cannot derive the
  // item at all (HEIC under the default providers answers 404), and nothing more can be done for it until
  // the file changes. It does not answer for `original`, which is a video the threshold now admits whole:
  // that row is a gap to be promoted, not an outcome.
  static bool _holds(NextcloudMirrorIndexEntry row, NextcloudMirrorTier wanted) {
    if (row.satisfies(wanted)) return true;
    return row.tier == NextcloudMirrorTier.placeholder && wanted == NextcloudMirrorTier.grid;
  }

  // The tier a run fetches: the wanted one, unless the row already holds more. A `force` run re-fetches
  // every listed item, and it must re-fetch what is held rather than what is wanted, or forcing would
  // silently downgrade every original (every row migrated from v1) to a preview.
  static NextcloudMirrorTier _fetchTier(NextcloudAccount account, NextcloudRemoteItem item, NextcloudMirrorIndexEntry? existing) {
    final wanted = _wantedTier(account, item);
    if (existing != null && existing.tier.index > wanted.index) return existing.tier;
    return wanted;
  }

  // Long edge requested for the grid tier. Fixed, not keyed to the column count, which is a live
  // pinch-to-zoom setting: a tier that followed it would refetch the library on a pinch.
  static const gridEdgePx = 256;

  // Reservation ceilings for derivative tiers. A derivative's byte size is unknowable before the fetch, so
  // the budget reserves a ceiling and then accounts the size the store read back from disk. The ceilings
  // are generous multiples of the measured means (18 KB grid, 135 KB view) and are capped by the original's
  // size, which a derivative never exceeds by more than re-encoding noise.
  static const gridReserveBytes = 64 * 1024;
  static const viewReserveBytes = 512 * 1024;

  static int _reserveFor(NextcloudRemoteItem item, NextcloudMirrorTier tier) => switch (tier) {
    NextcloudMirrorTier.placeholder => 0,
    NextcloudMirrorTier.grid => math.min(item.sizeBytes, gridReserveBytes),
    NextcloudMirrorTier.view => math.min(item.sizeBytes, viewReserveBytes),
    NextcloudMirrorTier.original => item.sizeBytes,
  };

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

    // Partitioned, so that the byte loop below only ever sees items that need bytes. Its two breaks (the
    // budget is spent; an eviction touched this run's own fetch) abandon everything sorted behind them, and
    // a placeholder costs nothing: left in the same list, every above-threshold video behind the break
    // would end the run with no row, no entry and no failure, counted as skipped by a budget that has no
    // bearing on it. Which videos appeared in the gallery would then depend on where the break fell.
    NextcloudMirrorTier tierOf(NextcloudRemoteItem item) => _fetchTier(account, item, rows[item.relativePath]);
    final placeholders = downloads.where((item) => tierOf(item) == NextcloudMirrorTier.placeholder).toList();
    final fetches = downloads.where((item) => tierOf(item) != NextcloudMirrorTier.placeholder).toList();

    for (final item in placeholders) {
      _checkCancelled(cancellation);
      final path = item.relativePath;
      try {
        await _recordPlaceholder(account, item, rows[path], stats);
        // Coupled to the eviction-touched break below, which reads this set: it cannot false-trigger on a
        // placeholder today only because a placeholder is never an eviction candidate.
        fetchedThisRun.add(path);
      } on NextcloudFailure catch (e) {
        if (_isFatal(e)) rethrow;
        stats.itemFailures[path] = e;
      }
      done++;
      emit(NextcloudSyncProgress(phase: NextcloudSyncPhase.downloading, done: done, total: total, bytesDone: bytesDone));
    }

    for (var i = 0; i < fetches.length; i++) {
      _checkCancelled(cancellation);
      final item = fetches[i];
      final path = item.relativePath;
      final existing = rows[path];
      final tier = tierOf(item);
      final reserve = _reserveFor(item, tier);
      try {
        if (reserve > account.cacheLimitBytes) {
          // never empty the whole mirror for a file that cannot fit anyway
          throw NextcloudQuotaFailure(requiredBytes: reserve, availableBytes: account.cacheLimitBytes);
        }
        if (fetchedBytes + reserve > account.cacheLimitBytes) {
          // the budget is full of this run's newest files; the rest are older and would only thrash
          stats.skipped += fetches.length - i;
          break;
        }
        // make room first; whatever goes must leave the collection in the same step
        final eviction = await _mirror.evictToFit(account, reserveBytes: reserve);
        if (!eviction.isEmpty) {
          await _applyEviction(account, eviction, stats);
          // `touched`, not `removed`: a file this run fetched is just as lost to it if the store demoted
          // it to a cheaper tier as if the store deleted it
          if (eviction.touched.any(fetchedThisRun.contains)) {
            // a refreshed file keeps its old LRU position, so the store may still pick one of this run's
            // files: stop here rather than trade the newest files for older ones
            stats.skipped += fetches.length - i;
            break;
          }
        }
        final used = await _mirror.usedBytes(account);
        if (used + reserve > account.cacheLimitBytes) {
          throw NextcloudQuotaFailure(requiredBytes: reserve, availableBytes: account.cacheLimitBytes - used);
        }

        final localPath = _mirror.localPathFor(account, path);
        String? observedEtag;
        int localBytes;
        if (tier == NextcloudMirrorTier.original) {
          var itemBytes = 0;
          observedEtag = await repository.downloadTo(
            item,
            localPath,
            onProgress: (received, _) {
              bytesDone += received - itemBytes;
              itemBytes = received;
              emit(NextcloudSyncProgress(phase: NextcloudSyncPhase.downloading, done: done, total: total, bytesDone: bytesDone));
            },
            cancellation: cancellation,
          );
          localBytes = item.sizeBytes;
        } else {
          final Uint8List bytes;
          try {
            bytes = await repository.fetchPreview(item, width: gridEdgePx, height: gridEdgePx);
          } on NextcloudPreviewUnavailableFailure {
            // the server cannot derive this one (HEIC and HEIF under the default providers): the item is
            // still listed, so it gets a placeholder row, which the completeness rule admits
            await _recordPlaceholder(account, item, existing, stats);
            fetchedThisRun.add(path);
            done++;
            emit(NextcloudSyncProgress(phase: NextcloudSyncPhase.downloading, done: done, total: total, bytesDone: bytesDone));
            continue;
          }
          _checkCancelled(cancellation);
          await _writeThrough(localPath, bytes, modified: item.lastModified);
          localBytes = bytes.length;
          bytesDone += bytes.length;
          emit(NextcloudSyncProgress(phase: NextcloudSyncPhase.downloading, done: done, total: total, bytesDone: bytesDone));
        }
        final now = _now();
        await _mirror.record(
          account,
          NextcloudMirrorIndexEntry(
            relativePath: path,
            // the etag the bytes actually have, which may be newer than the listing's; a derivative carries
            // the listing's, since the preview endpoint answers for the file as listed
            etag: observedEtag ?? item.etag,
            fileId: item.fileId,
            tier: tier,
            remoteSizeBytes: item.sizeBytes,
            // the store reads the local size back from disk either way
            localSizeBytes: localBytes,
            remoteLastModified: item.lastModified,
            downloadedAt: now,
            // a server-side change is not a view: keep the LRU position of a refreshed file
            lastAccessAt: existing?.lastAccessAt ?? now,
          ),
        );
        if (!await _sink.putMirroredFile(account, item, localPath, tier)) {
          // mirrored but invisible would be skipped by etag forever: drop the bytes so the next run retries
          await _mirror.remove(account, path);
          throw NextcloudLocalStorageFailure('could not create an entry for $path');
        }
        fetchedThisRun.add(path);
        // accounted after the fetch, with the bytes that actually landed, not the reservation
        fetchedBytes += localBytes;
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

  // No bytes, so no budget, no eviction and no download: the row and the entry are all there is. A
  // placeholder the sink refuses is removed again, since a row with no entry would be skipped by etag forever.
  Future<void> _recordPlaceholder(NextcloudAccount account, NextcloudRemoteItem item, NextcloudMirrorIndexEntry? existing, _Stats stats) async {
    final path = item.relativePath;
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
      await _mirror.remove(account, path);
      throw NextcloudLocalStorageFailure('could not create a placeholder entry for $path');
    }
    if (existing == null) {
      stats.added++;
    } else {
      stats.updated++;
    }
  }

  // Writes derivative bytes the same way `downloadTo` writes an original: beside, then rename, so a crash
  // leaves a `.part` for the sweep and never a half-written file under a path the index could trust. The
  // mtime is the server's for the same reason as there: a preview carries no Exif, so the file date is the
  // only date the entry has until the catalogue learns it from the properties.
  Future<void> _writeThrough(String localPath, List<int> bytes, {required DateTime modified}) async {
    final target = File(localPath);
    final part = File('$localPath.part');
    await target.parent.create(recursive: true);
    try {
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(localPath);
    } catch (e) {
      if (await part.exists()) await part.delete();
      throw NextcloudLocalStorageFailure('could not write $localPath', cause: e);
    }
    try {
      await target.setLastModified(modified);
    } catch (_) {
      // best effort: the bytes are complete and in place, and a date is not worth an orphan file
    }
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
