import 'dart:io';

import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/errors.dart';
import 'package:aves/model/nextcloud/mirror_index.dart';
import 'package:aves/model/nextcloud/mirror_store.dart';
import 'package:aves/model/nextcloud/paths.dart';
import 'package:aves/services/common/services.dart';
import 'package:flutter/foundation.dart';

// Local mirror of Nextcloud originals (layer L3).
//
// Layout is fixed by `NextcloudMirrorStore`: `<mirrorRoot>/<account.mirrorDirName>/<relativePath>`,
// with `mirrorRoot` provided by the platform (app-private `filesDir/nextcloud/`, the vault mechanism).
// Keeping the remote tree verbatim is what makes each remote sub-folder a nested album with no new UI.
// Grid sidecars of `view` rows live apart, under `<mirrorRoot>/sidecars/<account.mirrorDirName>/`.
class NextcloudMirrorStoreImpl implements NextcloudMirrorStore {
  final NextcloudMirrorIndex _index;

  // Test seam: when null, the root is resolved from the platform in `init`.
  final String? _mirrorRootOverride;

  String _mirrorRoot = '';

  new(this._index, {@visibleForTesting String? mirrorRoot}) : _mirrorRootOverride = mirrorRoot;

  @override
  Future<void> init() async {
    final root = _mirrorRootOverride ?? await storageService.getNextcloudMirrorRoot();
    if (root.isEmpty) {
      // the platform call failed and already reported; every path operation would silently become relative
      throw const NextcloudLocalStorageFailure('could not resolve the Nextcloud mirror root');
    }
    _mirrorRoot = _stripTrailingSeparator(root);
    await _index.init();
  }

  @override
  String get mirrorRoot => _mirrorRoot;

  String get _sidecarsRoot => pContext.join(_mirrorRoot, NextcloudMirrorStore.sidecarsDirName);

  String _accountRoot(NextcloudAccount account) {
    _checkInitialized();
    if (!NextcloudAccount.isValidId(account.mirrorDirName)) {
      // defence in depth: the account store validates this, but this value becomes a filesystem path
      throw NextcloudPathEscapeFailure(account.mirrorDirName);
    }
    final root = pContext.join(_mirrorRoot, account.mirrorDirName);
    if (root == _sidecarsRoot) {
      // unreachable with generated ids; refused here, where it would matter, rather than at load, where
      // refusing would only ever make an account already on disk fail to load
      throw NextcloudPathEscapeFailure(account.mirrorDirName);
    }
    return root;
  }

  String _sidecarAccountRoot(NextcloudAccount account) {
    _accountRoot(account);
    return pContext.join(_sidecarsRoot, account.mirrorDirName);
  }

  @override
  String localPathFor(NextcloudAccount account, String relativePath) {
    final accountRoot = _accountRoot(account);
    final normalized = _requireNormalized(relativePath);
    if (normalized.isEmpty) return accountRoot;
    return pContext.joinAll([accountRoot, ...normalized.split(NextcloudPaths.separator)]);
  }

  @override
  String sidecarPathFor(NextcloudAccount account, String relativePath) {
    final root = _sidecarAccountRoot(account);
    final normalized = _requireNormalized(relativePath);
    if (normalized.isEmpty) throw NextcloudPathEscapeFailure(relativePath);
    return pContext.joinAll([root, ...normalized.split(NextcloudPaths.separator)]);
  }

  @override
  String? relativePathFor(NextcloudAccount account, String localPath) {
    final accountRoot = _accountRoot(account);
    final normalizedLocal = _stripTrailingSeparator(localPath);
    if (normalizedLocal == accountRoot) return '';
    final prefix = '$accountRoot${pContext.separator}';
    if (!normalizedLocal.startsWith(prefix)) return null;
    final tail = normalizedLocal.substring(prefix.length);
    return NextcloudPaths.normalize(tail.split(pContext.separator).join(NextcloudPaths.separator));
  }

  @override
  String? accountIdFor(String localPath) {
    _checkInitialized();
    final prefix = '$_mirrorRoot${pContext.separator}';
    final normalizedLocal = _stripTrailingSeparator(localPath);
    if (!normalizedLocal.startsWith(prefix)) return null;
    final segments = normalizedLocal.substring(prefix.length).split(pContext.separator);
    // the account directory alone is not a mirrored file, and the sidecar tree is not an account
    if (segments.length < 2 || !NextcloudAccount.isValidId(segments.first) || segments.first == NextcloudMirrorStore.sidecarsDirName) return null;
    return segments.first;
  }

  @override
  Future<NextcloudMirrorIndexEntry?> lookup(NextcloudAccount account, String relativePath) {
    final normalized = _requireNormalized(relativePath);
    return _index.get(account, normalized);
  }

  @override
  Future<Set<NextcloudMirrorIndexEntry>> listAll(NextcloudAccount account) => _index.getAll(account);

  @override
  Future<void> record(NextcloudAccount account, NextcloudMirrorIndexEntry entry) async {
    final normalized = _requireNormalized(entry.relativePath);
    if (entry.tier == NextcloudMirrorTier.placeholder) {
      // No bytes by design, and the store is what makes it so: written over a row that holds bytes (a
      // changed file the budget cannot fund, or that the server can no longer derive), the file goes back
      // to the budget here. Left on disk under a row that claims zero bytes, it would be counted by nothing
      // and found by no later run, which is `usedBytes` lying forever by another route. File first, as in
      // `_demote`: a crash in between leaves a cache miss, not bytes nothing accounts for.
      await _deleteFile(localPathFor(account, normalized));
      await _deleteFile(sidecarPathFor(account, normalized));
      await _index.put(account, entry.copyWith(localSizeBytes: 0, sidecarSizeBytes: 0));
      return;
    }
    final file = File(localPathFor(account, normalized));
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      // recording a row for a file that is not there would make `usedBytes` lie forever
      throw NextcloudNotFoundFailure(normalized);
    }
    final int sidecarBytes;
    if (entry.tier == NextcloudMirrorTier.view) {
      // the sidecar is what makes the row demotable offline, so a view row without one is as wrong as a
      // row without its file; its bytes count, since they are on disk under the mirror
      final sidecarStat = await File(sidecarPathFor(account, normalized)).stat();
      if (sidecarStat.type != FileSystemEntityType.file) throw NextcloudNotFoundFailure(normalized);
      sidecarBytes = sidecarStat.size;
    } else {
      // a sidecar a previous view row left behind would be counted by nothing; before the row, so that a
      // crash in between leaves nothing on disk that the row does not claim
      await _deleteFile(sidecarPathFor(account, normalized));
      sidecarBytes = 0;
    }
    // the local size is read back from disk rather than trusted from the caller, so that accounting and
    // eviction are driven by the same source as the bytes they are supposed to account for. The remote
    // size, the tier and the pin cannot be derived from the bytes, so those come from the caller verbatim.
    await _index.put(
      account,
      NextcloudMirrorIndexEntry(
        relativePath: normalized,
        etag: entry.etag,
        fileId: entry.fileId,
        tier: entry.tier,
        remoteSizeBytes: entry.remoteSizeBytes,
        localSizeBytes: stat.size + sidecarBytes,
        sidecarSizeBytes: sidecarBytes,
        pinned: entry.pinned,
        remoteLastModified: entry.remoteLastModified,
        downloadedAt: entry.downloadedAt,
        lastAccessAt: entry.lastAccessAt,
      ),
    );
  }

  @override
  Future<void> remove(NextcloudAccount account, String relativePath) async {
    final normalized = _requireNormalized(relativePath);
    if (normalized.isEmpty) return;
    await _deleteFile(localPathFor(account, normalized));
    await _deleteFile(sidecarPathFor(account, normalized));
    await _index.delete(account, normalized);
  }

  @override
  Future<void> touch(NextcloudAccount account, String relativePath, DateTime accessedAt) async {
    final normalized = _requireNormalized(relativePath);
    final existing = await _index.get(account, normalized);
    if (existing == null) return;
    await _index.put(account, existing.copyWith(lastAccessAt: accessedAt));
  }

  @override
  Future<int> usedBytes(NextcloudAccount account, {NextcloudBudgetClass? of}) => _index.sumLocalSizeBytes(account, of: of);

  @override
  Future<int> freeBytes(NextcloudAccount account, NextcloudBudgetClass of) async => of.limitFor(account) - await _index.sumLocalSizeBytes(account, of: of);

  // one page of eviction candidates; demoting them brings up the next page in the same order, since a
  // demoted row is a placeholder and no candidate query returns those.
  // A page that is entirely undeletable stops eviction, so this is also the number of consecutive
  // undeletable rows at the head of an order that can hide the rest of the queue.
  static const _evictionPageSize = 256;

  @override
  Future<NextcloudEvictionOutcome> evictToFit(
    NextcloudAccount account, {
    int reserveBytes = 0,
    NextcloudEvictionOrder order = NextcloudEvictionOrder.leastRecentlyAccessed,
    NextcloudSyncFunding? funding,
  }) async {
    // the class comes from the order, and both the limit and the sum from the class: the two cannot be
    // paired wrongly here because they are never named separately
    final budgetClass = order.budgetClass;
    final budget = budgetClass.limitFor(account) - reserveBytes;
    final target = budget < 0 ? 0 : budget;

    var used = await _index.sumLocalSizeBytes(account, of: budgetClass);
    final demoted = <String>{};
    final demotedToGrid = <String>{};

    for (final page in _candidatePages(account, order, funding)) {
      requery:
      while (used > target) {
        final victims = await page(_evictionPageSize);
        if (victims.isEmpty) break;

        var demotedFromPage = 0;
        for (final victim in victims) {
          if (used <= target) break;
          final path = victim.relativePath;
          try {
            if (victim.tier == NextcloudMirrorTier.view && await File(sidecarPathFor(account, path)).exists()) {
              // Back to its grid bytes first, whichever class is evicting. For the view class that is the
              // whole demotion and frees the view bytes. For a sync class it frees nothing of its own —
              // the view bytes go back to the allowance, where they belong — and leaves an ordinary grid
              // row, which a fresh page brings up again at its place in the order if the overflow rule
              // still reaches it. Never straight to a placeholder: that would spend allowance bytes on
              // sync work, and make an opened photo likelier to lose its thumbnail than one never opened.
              await _demoteToGrid(account, victim);
              demotedToGrid.add(path);
              switch (budgetClass) {
                case NextcloudBudgetClass.view:
                  used -= victim.viewClassBytes;
                case NextcloudBudgetClass.sync:
                  // Re-query rather than go on down this page: the row is now a grid row at the same
                  // place in the order, and finishing the page first would take every newer row on it
                  // before coming back for its grid bytes — the oldest-first promise broken, and the
                  // opened photo keeping its thumbnail at a never-opened neighbour's expense.
                  continue requery;
              }
            } else {
              await _demote(account, victim);
              demoted.add(path);
              // reported once, as a row whose bytes are gone: the grid refresh the first step asked for
              // would read a file that is no longer there
              demotedToGrid.remove(path);
              used -= switch (budgetClass) {
                NextcloudBudgetClass.view => victim.viewClassBytes,
                NextcloudBudgetClass.sync => victim.syncClassBytes,
              };
            }
          } catch (_) {
            // Both demotions delete the file before rewriting the row, so a failure here means either that
            // nothing went, or that the bytes are already gone and the row still claims them. The second
            // case must still be reported, as a row with no bytes behind it: the caller tells the sink about
            // every path returned here, and an entry left describing bytes that are not there is exactly
            // what the sink must not keep.
            if (await _bytesAreGone(account, path)) {
              demoted.add(path);
              demotedToGrid.remove(path);
            }
            // `used` and `demotedFromPage` deliberately stay put, even in that case: the row is still at
            // the head of its order, so counting this as progress would re-query the same page forever.
            // Leaving the row also keeps its bytes accounted for, which only ever evicts more than needed.
            continue;
          }
          demotedFromPage++;
        }
        // nothing on this page could go, so the next page would be the same one
        if (demotedFromPage == 0) break;
      }
    }
    // `used > target` here means even an empty class cannot hold the reservation; the caller decides
    // whether that is a `NextcloudQuotaFailure` or an unfunded placeholder. Everything demoted is reported
    // either way. `removed` is never produced: a victim keeps its row, see the contract.
    return NextcloudEvictionOutcome(demoted: demoted, demotedToGrid: demotedToGrid);
  }

  // The candidate queries one call takes, in order. Each is paged until it is exhausted or the target is
  // met, then the next one starts; under the two access orders there is only one.
  List<Future<List<NextcloudMirrorIndexEntry>> Function(int limit)> _candidatePages(NextcloudAccount account, NextcloudEvictionOrder order, NextcloudSyncFunding? funding) {
    switch (order) {
      case NextcloudEvictionOrder.leastRecentlyAccessed:
        return [(limit) => _index.getLeastRecentlyAccessed(account, limit: limit)];
      case NextcloudEvictionOrder.viewRowsLeastRecentlyAccessed:
        // only what browsing may spend, see `NextcloudEvictionOrder`
        return [
          (limit) => _index.getLeastRecentlyAccessed(account, limit: limit, tiers: const {NextcloudMirrorTier.view}),
        ];
      case NextcloudEvictionOrder.oldestFirst:
        // Originals go first, as a class, then grid rows: a library of thumbnails beats whole copies of a
        // few files. A view row is a grid row to this order (its sidecar is the grid bytes the sync funded)
        // and sits in the grid page. The bound is the one `NextcloudSyncFunding` documents: an original
        // may only take originals older than itself, and never a grid row; a grid row may take any
        // original and only grid rows older than itself.
        final fundsGrid = funding == null || funding.tier == NextcloudMirrorTier.grid;
        return [
          (limit) => _index.getOldestModified(
            account,
            limit: limit,
            tiers: const {NextcloudMirrorTier.original},
            modifiedBefore: fundsGrid ? null : funding.lastModified,
          ),
          if (fundsGrid)
            (limit) => _index.getOldestModified(
              account,
              limit: limit,
              tiers: const {NextcloudMirrorTier.grid, NextcloudMirrorTier.view},
              modifiedBefore: funding?.lastModified,
            ),
        ];
    }
  }

  // The transition for every row but a view row with its sidecar: the file goes, the row stays as an
  // unfunded placeholder. File first, so that a crash in between leaves a row whose file is missing — a
  // cache miss the next sync reconciles — rather than a placeholder row with bytes on disk that nothing
  // accounts for.
  Future<void> _demote(NextcloudAccount account, NextcloudMirrorIndexEntry victim) async {
    await _deleteFile(localPathFor(account, victim.relativePath));
    await _deleteFile(sidecarPathFor(account, victim.relativePath));
    await _index.put(account, victim.asUnfundedPlaceholder());
  }

  @override
  Future<void> demoteToGrid(NextcloudAccount account, String relativePath) async {
    final normalized = _requireNormalized(relativePath);
    final existing = await _index.get(account, normalized);
    // no grid bytes to go back to: nothing is written, see the contract
    if (existing == null || existing.tier != NextcloudMirrorTier.view) throw NextcloudNotFoundFailure(normalized);
    if (!await File(sidecarPathFor(account, normalized)).exists()) throw NextcloudNotFoundFailure(normalized);
    await _demoteToGrid(account, existing);
  }

  // The transition for a view row: the view bytes go, the sidecar takes their place, and the row becomes a
  // grid row with the size read back from disk. File first, for the same reason as `_demote`: a crash after
  // the delete leaves a cache miss the next sync refills at grid, and `record` at grid drops the sidecar.
  Future<NextcloudMirrorIndexEntry> _demoteToGrid(NextcloudAccount account, NextcloudMirrorIndexEntry victim) async {
    final path = localPathFor(account, victim.relativePath);
    await _deleteFile(path);
    await File(sidecarPathFor(account, victim.relativePath)).rename(path);
    final stat = await File(path).stat();
    final row = victim.asGrid(localSizeBytes: stat.size);
    await _index.put(account, row);
    return row;
  }

  @override
  Future<void> sweepStraySidecars(NextcloudAccount account) async {
    final root = Directory(_sidecarAccountRoot(account));
    if (!await root.exists()) return;
    final prefix = '${root.path}${pContext.separator}';
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.startsWith(prefix)) continue;
      final relativePath = NextcloudPaths.normalize(entity.path.substring(prefix.length).split(pContext.separator).join(NextcloudPaths.separator));
      final row = relativePath == null ? null : await _index.get(account, relativePath);
      if (row?.tier == NextcloudMirrorTier.view) continue;
      try {
        await entity.delete();
      } on FileSystemException {
        // best effort; the next sweep tries again
      }
    }
  }

  @override
  Future<void> purge(NextcloudAccount account) async {
    final directories = [Directory(_accountRoot(account)), Directory(_sidecarAccountRoot(account))];
    try {
      for (final directory in directories) {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    } finally {
      // the rows go even when the directory does not: an account is purged on its way out, and rows
      // claiming files that are gone would make a later account reusing this id skip real downloads
      await _index.deleteAll(account);
    }
  }

  void _checkInitialized() {
    if (_mirrorRoot.isEmpty) throw StateError('$runtimeType used before init()');
  }

  String _requireNormalized(String relativePath) {
    final normalized = NextcloudPaths.normalize(relativePath);
    if (normalized == null) throw NextcloudPathEscapeFailure(relativePath);
    return normalized;
  }

  // after a failed `remove` or demotion: are the bytes gone even though the row stayed as it was?
  Future<bool> _bytesAreGone(NextcloudAccount account, String relativePath) async {
    try {
      return !await File(localPathFor(account, relativePath)).exists();
    } catch (_) {
      // the path does not even resolve, so nothing was deleted under it
      return false;
    }
  }

  Future<void> _deleteFile(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  String _stripTrailingSeparator(String path) {
    final separator = pContext.separator;
    var end = path.length;
    while (end > 1 && path.startsWith(separator, end - separator.length)) {
      end -= separator.length;
    }
    return path.substring(0, end);
  }
}
