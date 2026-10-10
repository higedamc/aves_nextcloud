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

  String _accountRoot(NextcloudAccount account) {
    _checkInitialized();
    if (!NextcloudAccount.isValidId(account.mirrorDirName)) {
      // defence in depth: the account store validates this, but this value becomes a filesystem path
      throw NextcloudPathEscapeFailure(account.mirrorDirName);
    }
    return pContext.join(_mirrorRoot, account.mirrorDirName);
  }

  @override
  String localPathFor(NextcloudAccount account, String relativePath) {
    final accountRoot = _accountRoot(account);
    final normalized = NextcloudPaths.normalize(relativePath);
    if (normalized == null) throw NextcloudPathEscapeFailure(relativePath);
    if (normalized.isEmpty) return accountRoot;
    return pContext.joinAll([accountRoot, ...normalized.split(NextcloudPaths.separator)]);
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
      await _index.put(account, entry.copyWith(localSizeBytes: 0));
      return;
    }
    final file = File(localPathFor(account, normalized));
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      // recording a row for a file that is not there would make `usedBytes` lie forever
      throw NextcloudNotFoundFailure(normalized);
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
        localSizeBytes: stat.size,
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
  Future<int> usedBytes(NextcloudAccount account) => _index.sumLocalSizeBytes(account);

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
    final budget = account.cacheLimitBytes - reserveBytes;
    final target = budget < 0 ? 0 : budget;

    var used = await _index.sumLocalSizeBytes(account);
    final demoted = <String>{};

    for (final page in _candidatePages(account, order, funding)) {
      while (used > target) {
        final victims = await page(_evictionPageSize);
        if (victims.isEmpty) break;

        var demotedFromPage = 0;
        for (final victim in victims) {
          if (used <= target) break;
          try {
            await _demote(account, victim);
          } catch (_) {
            // `_demote` deletes the file before rewriting the row, so a failure here means either that
            // nothing went, or that the bytes are already gone and the row still claims them. The second
            // case must still be reported: the caller tells the sink about every path returned here, and
            // an entry left describing bytes that are not there is exactly what the sink must not keep.
            if (await _bytesAreGone(account, victim.relativePath)) {
              demoted.add(victim.relativePath);
            }
            // `used` and `demotedFromPage` deliberately stay put, even in that case: the row is still at
            // the head of its order, so counting this as progress would re-query the same page forever.
            // Leaving the row also keeps its bytes accounted for, which only ever evicts more than needed.
            continue;
          }
          demoted.add(victim.relativePath);
          used -= victim.localSizeBytes;
          demotedFromPage++;
        }
        // nothing on this page could go, so the next page would be the same one
        if (demotedFromPage == 0) break;
      }
    }
    // `used > target` here means even an empty mirror cannot hold the reservation; the caller decides
    // whether that is a `NextcloudQuotaFailure` or an unfunded placeholder. Everything demoted is reported
    // either way. `removed` is never produced: a victim keeps its row, see the contract.
    return NextcloudEvictionOutcome(demoted: demoted);
  }

  // The candidate queries one call takes, in order. Each is paged until it is exhausted or the target is
  // met, then the next one starts; under the access order there is only one.
  List<Future<List<NextcloudMirrorIndexEntry>> Function(int limit)> _candidatePages(NextcloudAccount account, NextcloudEvictionOrder order, NextcloudSyncFunding? funding) {
    switch (order) {
      case NextcloudEvictionOrder.leastRecentlyAccessed:
        return [(limit) => _index.getLeastRecentlyAccessed(account, limit: limit)];
      case NextcloudEvictionOrder.oldestFirst:
        // Originals go first, as a class, then grid rows: a library of thumbnails beats whole copies of a
        // few files. `view` rows are derivative bytes the sync does not rank and go with the originals;
        // the leaf that fetches them decides whether that is where they belong. The bound is the one
        // `NextcloudSyncFunding` documents: an original may only take originals older than itself, and
        // never a grid row; a grid row may take any original and only grid rows older than itself.
        final fundsGrid = funding == null || funding.tier == NextcloudMirrorTier.grid;
        return [
          (limit) => _index.getOldestModified(
            account,
            limit: limit,
            tiers: const {NextcloudMirrorTier.original, NextcloudMirrorTier.view},
            modifiedBefore: fundsGrid ? null : funding.lastModified,
          ),
          if (fundsGrid)
            (limit) => _index.getOldestModified(
              account,
              limit: limit,
              tiers: const {NextcloudMirrorTier.grid},
              modifiedBefore: funding?.lastModified,
            ),
        ];
    }
  }

  // The one transition eviction makes: the file goes, the row stays as an unfunded placeholder. File
  // first, so that a crash in between leaves a row whose file is missing — a cache miss the next sync
  // reconciles — rather than a placeholder row with bytes on disk that nothing accounts for.
  Future<void> _demote(NextcloudAccount account, NextcloudMirrorIndexEntry victim) async {
    await _deleteFile(localPathFor(account, victim.relativePath));
    await _index.put(account, victim.asUnfundedPlaceholder());
  }

  @override
  Future<void> purge(NextcloudAccount account) async {
    final directory = Directory(_accountRoot(account));
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
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

  // after a failed `remove` or `_demote`: are the bytes gone even though the row stayed as it was?
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
