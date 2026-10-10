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
// - Downloads go the whole grid class first, then originals, newest first within each, and the budget's
//   eviction may only take rows the sync ranks below the item it is funding (`NextcloudSyncFunding`). An
//   item the budget cannot fund gets an `unfunded` placeholder row — in the gallery, streamed on demand —
//   and so does every row the budget takes back: eviction demotes, it never removes. Both are what let a
//   run that fits less than the server holds still end with the mirror honestly reflecting the server, so
//   that its etags publish and the next run has nothing to do. Without them a sync over budget is a
//   treadmill: it re-lists the whole tree on every run and funds last run's gap by evicting last run's
//   fetch, indefinitely, and it looks like a working sync while doing it (measured, see the leaf briefs).
class NextcloudSyncUseCaseImpl implements NextcloudSyncUseCase {
  final NextcloudRepositoryFactory _repositories;
  final NextcloudCredentialStore _credentials;
  final NextcloudMirrorStore _mirror;
  final NextcloudSyncSink _sink;
  final NextcloudSyncStateStore _states;
  final DateTime Function() _now;

  // the last task queued per account; a sync and a pinned fetch for the same account never overlap
  final Map<String, Future<Object?>> _running = {};
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
    final result = _enqueue(request.account, () => _run(request, controller.add));
    _lastResult = result;
    // `NextcloudFailure`s end up in the result; anything else is a bug and must not vanish with the stream
    result.then((_) {}, onError: controller.addError).whenComplete(controller.close);
    return controller.stream;
  }

  @override
  Future<NextcloudFailure?> fetchOriginal(NextcloudAccount account, String relativePath, {NextcloudCancellation? cancellation}) {
    return _enqueue(account, () => _fetchOriginal(account, relativePath, cancellation));
  }

  @override
  Future<NextcloudFailure?> releaseOriginal(NextcloudAccount account, String relativePath) {
    return _enqueue(account, () async {
      final existing = await _mirror.lookup(account, relativePath);
      if (existing == null) return NextcloudNotFoundFailure(relativePath);
      if (!existing.pinned) return null;
      try {
        await _mirror.record(account, existing.copyWith(pinned: false));
        return null;
      } on NextcloudFailure catch (e) {
        return e;
      }
    });
  }

  // a task for the same account waits for the previous one, whatever its outcome
  Future<T> _enqueue<T>(NextcloudAccount account, Future<T> Function() task) {
    final accountId = account.id;
    final previous = _running[accountId]?.then((_) {}, onError: (_) {}) ?? Future.value();
    final result = previous.then((_) => task());
    _running[accountId] = result;
    result.whenComplete(() {
      if (identical(_running[accountId], result)) _running.remove(accountId);
    });
    return result;
  }

  Future<NextcloudFailure?> _fetchOriginal(NextcloudAccount account, String relativePath, NextcloudCancellation? cancellation) async {
    try {
      _checkCancelled(cancellation);
      final credentials = await _credentials.credentialsFor(account);
      if (credentials == null) throw const NextcloudAuthFailure(0);
      final repository = _repositories.open(account, credentials);
      try {
        final item = await repository.stat(relativePath);
        if (item.isCollection || !item.isMedia) throw NextcloudNotFoundFailure(relativePath);
        final path = item.relativePath;
        final existing = await _mirror.lookup(account, path);
        if (existing != null && existing.tier == NextcloudMirrorTier.original && existing.etag == item.etag) {
          // already whole: only the pin is missing, and the access counts as a view
          if (!existing.pinned) await _mirror.record(account, existing.copyWith(pinned: true, lastAccessAt: _now()));
          return null;
        }
        // net of the bytes already held at this path, which the download replaces (see `_download`)
        final reserve = math.max(0, item.sizeBytes - (existing?.localSizeBytes ?? 0));
        if (item.sizeBytes > account.cacheLimitBytes) {
          throw NextcloudQuotaFailure(requiredBytes: item.sizeBytes, availableBytes: account.cacheLimitBytes);
        }
        final stats = _Stats();
        final eviction = await _mirror.evictToFit(account, reserveBytes: reserve);
        if (!eviction.isEmpty) await _applyEviction(account, eviction, stats);
        final used = await _mirror.usedBytes(account);
        if (used + reserve > account.cacheLimitBytes) {
          throw NextcloudQuotaFailure(requiredBytes: reserve, availableBytes: account.cacheLimitBytes - used);
        }
        final localPath = _mirror.localPathFor(account, path);
        final observedEtag = await repository.downloadTo(item, localPath, cancellation: cancellation);
        final now = _now();
        await _mirror.record(
          account,
          NextcloudMirrorIndexEntry(
            relativePath: path,
            etag: observedEtag ?? item.etag,
            fileId: item.fileId,
            tier: NextcloudMirrorTier.original,
            remoteSizeBytes: item.sizeBytes,
            localSizeBytes: item.sizeBytes,
            pinned: true,
            remoteLastModified: item.lastModified,
            downloadedAt: now,
            // asked for by the user: this is a view
            lastAccessAt: now,
          ),
        );
        if (!await _sink.putMirroredFile(account, item, localPath, NextcloudMirrorTier.original)) {
          await _mirror.remove(account, path);
          throw NextcloudLocalStorageFailure('could not create an entry for $path');
        }
        return null;
      } finally {
        repository.dispose();
      }
    } on NextcloudFailure catch (e) {
      return e;
    }
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
          final current = row != null && row.etag == item.etag && !missing.contains(item.relativePath) && _isCurrent(row, _wantedTier(account, item), relist: relist);
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
          // an old etag, and no server etag will ever point at it again, so everything is listed next time.
          // `evicted` counts rows that left the mirror, never demotions; `_applyEviction` says why that
          // omission is load-bearing.
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
      // a row below the wanted tier for a reason the budget cannot change (a placeholder video whose
      // threshold was raised) is a gap: promising the subtree would skip it on every later run and never
      // promote it. One the budget left there is not, see `_reflects`.
      if (!_reflects(row, _wantedTier(account, item))) return false;
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

  // Whether a row answers for the tier a run wants is two questions, not one, and the budget is where they
  // part. The planning step asks *is there anything left for a sync to do for this item*, which is
  // budget-sensitive; the completeness rule asks *does the mirror honestly reflect the server*, which is
  // not. One shared predicate forced "the budget could not fund this" to be either a gap for both or
  // current for both, and neither is right: as a gap for both it withholds the etags and re-lists the tree
  // on every run, as current for both a raised budget never promotes it. So there are two.
  //
  // Both agree on everything but the `unfunded` placeholder. Tier order decides first, then one policy on
  // top: a `policy` placeholder answers for `grid`, because it is what a run records when the server cannot
  // derive the item at all (HEIC under the default providers answers 404), and nothing more can be done for
  // it until the file changes. It does not answer for `original`, which is a video the threshold now admits
  // whole: that row is a gap to be promoted, not an outcome.

  // Planning. An `unfunded` placeholder is current until the budget changes, and a raised `cacheLimitBytes`
  // is what `relist` means (a forced run too, which re-plans everything regardless), so that is when it is
  // a gap again: planned, sorted with the rest, and funded if the new budget reaches it.
  static bool _isCurrent(NextcloudMirrorIndexEntry row, NextcloudMirrorTier wanted, {required bool relist}) {
    if (row.satisfies(wanted)) return true;
    return switch (row.placeholderReason) {
      null => false,
      NextcloudPlaceholderReason.policy => wanted == NextcloudMirrorTier.grid,
      NextcloudPlaceholderReason.unfunded => !relist,
    };
  }

  // Completeness. An `unfunded` placeholder reflects the server whatever the budget: the item is listed,
  // in the gallery, and nothing the server could tell a later run would change what the mirror holds for
  // it. Promising the subtree is therefore honest, and it is what lets a run over budget stop walking the
  // whole tree.
  static bool _reflects(NextcloudMirrorIndexEntry row, NextcloudMirrorTier wanted) {
    if (row.satisfies(wanted)) return true;
    return switch (row.placeholderReason) {
      null => false,
      NextcloudPlaceholderReason.policy => wanted == NextcloudMirrorTier.grid,
      NextcloudPlaceholderReason.unfunded => true,
    };
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
    emit(NextcloudSyncProgress(phase: NextcloudSyncPhase.downloading, done: done, total: total, bytesDone: bytesDone));

    // Three classes, in the order the budget serves them. Placeholders cost nothing and go first so that no
    // budget decision can abandon one. Then the whole grid class before any original, newest first within
    // each: with one newest-first list, a run of recent video would push every older image's few kilobytes
    // of thumbnail behind the break, and that is a photo library of placeholders with no thumbnails. Where
    // the grid class alone exceeds the budget, this means no original is ever funded, and that is the right
    // degradation — thumbnails for everything beats whole copies of a few.
    NextcloudMirrorTier tierOf(NextcloudRemoteItem item) => _fetchTier(account, item, rows[item.relativePath]);
    final placeholders = downloads.where((item) => tierOf(item) == NextcloudMirrorTier.placeholder).toList();
    final grids = downloads.where((item) => tierOf(item) == NextcloudMirrorTier.grid).toList();
    final originals = downloads.where((item) => tierOf(item).index > NextcloudMirrorTier.grid.index).toList();

    for (final item in placeholders) {
      _checkCancelled(cancellation);
      final path = item.relativePath;
      try {
        await _recordPlaceholder(account, item, rows[path], stats, reason: NextcloudPlaceholderReason.policy);
        fetchedThisRun.add(path);
      } on NextcloudFailure catch (e) {
        if (_isFatal(e)) rethrow;
        stats.itemFailures[path] = e;
      }
      done++;
      emit(NextcloudSyncProgress(phase: NextcloudSyncPhase.downloading, done: done, total: total, bytesDone: bytesDone));
    }

    // The bytes still free once the budget has said no to an item, exact until the next fetch lands; null
    // while the budget has not said no yet. Everything behind that first "no" is decided by this number
    // rather than by another eviction pass, and the arithmetic is sound because of the order: under
    // `NextcloudEvictionOrder.oldestFirst` a pass stops either when the reservation fits or when the rows
    // the item may take run out, so a "no" means the latter — nothing older in its classes is left. Every
    // item behind it in this loop ranks below it (older in the same class, or an original behind a grid
    // row), so its candidates are a subset of that nothing, and only a smaller reservation can still fit.
    int? free;

    for (final item in [...grids, ...originals]) {
      _checkCancelled(cancellation);
      final path = item.relativePath;
      final existing = rows[path];
      final tier = tierOf(item);
      // Net of the bytes already held at this path: a changed file is fetched over its own old bytes, so
      // the budget only has to find the difference. Reserved in full, a changed newest file would demote
      // the next-newest to make room it does not need, and the held set would stop being a function of
      // the server's order. The old bytes stay on disk until the rename, so the mirror can briefly exceed
      // the limit by their size; the index never counts a `.part` file, so nothing is misreported.
      final reserve = math.max(0, _reserveFor(item, tier) - (existing?.localSizeBytes ?? 0));
      try {
        final bool funded;
        if (reserve > account.cacheLimitBytes) {
          // never empty the whole mirror for a file that cannot fit anyway; says nothing about the rest
          funded = false;
        } else if (free != null) {
          funded = reserve <= free;
        } else {
          // make room first; whatever goes must be reported to the sink in the same step
          final eviction = await _mirror.evictToFit(
            account,
            reserveBytes: reserve,
            order: NextcloudEvictionOrder.oldestFirst,
            funding: NextcloudSyncFunding(tier: tier, lastModified: item.lastModified),
          );
          if (!eviction.isEmpty) {
            await _applyEviction(account, eviction, stats);
            // the bound on the victims is what makes this unreachable: anything fetched earlier in this
            // run ranks above this item, and a pass may only take what ranks below it
            assert(!eviction.touched.any(fetchedThisRun.contains), 'the store evicted a row this run fetched: $eviction');
          }
          final used = await _mirror.usedBytes(account);
          funded = used + reserve <= account.cacheLimitBytes;
          if (!funded) free = account.cacheLimitBytes - used;
        }
        if (!funded) {
          // The budget said no: the item is still listed, so it gets a row and an entry, streamed on
          // demand, and the reason is recorded so a raised budget knows to come back for it. Not a quota
          // failure, which it was: a failure ends the run with no row for a listed item, which withholds
          // the etags and walks the whole tree again next run, for a file the budget still cannot hold.
          await _recordPlaceholder(account, item, existing, stats, reason: NextcloudPlaceholderReason.unfunded);
          fetchedThisRun.add(path);
          done++;
          emit(NextcloudSyncProgress(phase: NextcloudSyncPhase.downloading, done: done, total: total, bytesDone: bytesDone));
          continue;
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
            await _recordPlaceholder(account, item, existing, stats, reason: NextcloudPlaceholderReason.policy);
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
            // a refresh (a changed file, a forced run) does not unpin: the user asked for these bytes
            pinned: existing?.pinned ?? false,
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
        // accounted after the fetch, with the bytes that landed as the store read them, not the reservation
        if (free != null) free = account.cacheLimitBytes - await _mirror.usedBytes(account);
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
  Future<void> _recordPlaceholder(NextcloudAccount account, NextcloudRemoteItem item, NextcloudMirrorIndexEntry? existing, _Stats stats, {required NextcloudPlaceholderReason reason}) async {
    final path = item.relativePath;
    await _mirror.record(
      account,
      NextcloudMirrorIndexEntry(
        relativePath: path,
        etag: item.etag,
        fileId: item.fileId,
        tier: NextcloudMirrorTier.placeholder,
        placeholderReason: reason,
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
    } else if (existing.etag != item.etag || existing.tier != NextcloudMirrorTier.placeholder || existing.placeholderReason != reason) {
      // a relist that finds the budget still says no writes the same row again; that is not an update
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

  // The end-of-run sweep: the sync's order, with no item to fund, so nothing is out of bounds. It has work
  // only when the limit was lowered or pinned downloads grew past it, and this run's fetches are the newest
  // rows, so they go last.
  Future<void> _evict(NextcloudAccount account, _Stats stats) async {
    final eviction = await _mirror.evictToFit(account, order: NextcloudEvictionOrder.oldestFirst);
    if (eviction.isEmpty) return;
    await _applyEviction(account, eviction, stats);
  }

  // Every eviction site goes through here so the two outcomes cannot be handled differently by accident.
  Future<void> _applyEviction(NextcloudAccount account, NextcloudEvictionOutcome eviction, _Stats stats) async {
    if (eviction.demoted.isNotEmpty) {
      // the rows survive as unfunded placeholders: the entries stay, and the sink drops what described
      // their bytes
      await _sink.demoteToPlaceholders(account, eviction.demoted);
      stats.demoted += eviction.demoted.length;
    }
    if (eviction.removed.isNotEmpty) {
      await _sink.removeMirroredFiles(account, eviction.removed);
      // `removed` only, never `demoted`, and the omission is the mechanism rather than an oversight. This
      // counter is what forgets every stored etag at the end of the run (`_run`), because a row that left
      // the mirror may sit under a subtree the run trusted and no server etag will ever point at it again.
      // A demoted row has not left: the item is listed, held as a placeholder the completeness rule
      // accepts, and found current by the next run, so nothing under any promised subtree is a lie.
      // Count demotions here and every eviction puts the account back on the treadmill this was written to
      // close — a full tree walk on every run, funding last run's gap by evicting last run's fetch —
      // measured as `evicted=1` on every run after the first, with nothing changed on the server.
      stats.evicted += eviction.removed.length;
    }
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
  int added = 0, updated = 0, removed = 0, skipped = 0, evicted = 0, demoted = 0, lost = 0;
  final itemFailures = <String, NextcloudFailure>{};

  NextcloudSyncResult result({NextcloudFailure? fatal}) => NextcloudSyncResult(
    added: added,
    updated: updated,
    removed: removed,
    skipped: skipped,
    evicted: evicted,
    demoted: demoted,
    lost: lost,
    itemFailures: Map.unmodifiable(itemFailures),
    fatal: fatal,
  );
}
