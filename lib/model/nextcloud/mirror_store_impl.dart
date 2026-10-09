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

  // one page of eviction candidates; removing them brings up the next page in the same order.
  // A page that is entirely undeletable stops eviction, so this is also the number of consecutive
  // undeletable rows at the head of the LRU order that can hide the rest of the queue.
  static const _evictionPageSize = 256;

  @override
  Future<Set<String>> evictToFit(NextcloudAccount account, {int reserveBytes = 0}) async {
    final budget = account.cacheLimitBytes - reserveBytes;
    final target = budget < 0 ? 0 : budget;

    var used = await _index.sumLocalSizeBytes(account);
    final evicted = <String>{};

    while (used > target) {
      final victims = await _index.getLeastRecentlyAccessed(account, limit: _evictionPageSize);
      if (victims.isEmpty) break;

      var removedFromPage = 0;
      for (final victim in victims) {
        if (used <= target) break;
        try {
          await remove(account, victim.relativePath);
        } catch (_) {
          // `remove` deletes the file before the row, so a failure here means either that nothing went,
          // or that the bytes are already gone and only the row stayed. The second case must still be
          // reported: the caller drops the collection entry for every path returned here, and an entry
          // left pointing at a deleted file is exactly the `entry.refresh` trap the contract warns about.
          if (await _bytesAreGone(account, victim.relativePath)) {
            evicted.add(victim.relativePath);
          }
          // `used` and `removedFromPage` deliberately stay put, even in that case: the row is still at
          // the head of the LRU order, so counting this as progress would re-query the same page forever.
          // Leaving the row also keeps its bytes accounted for, which only ever evicts more than needed.
          continue;
        }
        evicted.add(victim.relativePath);
        used -= victim.localSizeBytes;
        removedFromPage++;
      }
      // nothing on this page could go, so the next page would be the same one
      if (removedFromPage == 0) break;
    }
    // `used > target` here means even an empty mirror cannot hold the reservation; the caller decides
    // whether that is a `NextcloudQuotaFailure`. Everything evicted is reported either way.
    return evicted;
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

  // after a failed `remove`: are the bytes gone even though the row stayed?
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
