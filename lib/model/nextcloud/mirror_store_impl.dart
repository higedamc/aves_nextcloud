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
      throw const NextcloudParseFailure('could not resolve the Nextcloud mirror root');
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
    // the size is read back from disk rather than trusted from the caller, so that accounting and
    // eviction are driven by the same source as the bytes they are supposed to account for
    await _index.put(
      account,
      NextcloudMirrorIndexEntry(
        relativePath: normalized,
        etag: entry.etag,
        fileId: entry.fileId,
        sizeBytes: stat.size,
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
  Future<int> usedBytes(NextcloudAccount account) => _index.sumSizeBytes(account);

  @override
  Future<Set<String>> evictToFit(NextcloudAccount account, {int reserveBytes = 0}) async {
    final budget = account.cacheLimitBytes - reserveBytes;
    final target = budget < 0 ? 0 : budget;

    var used = await _index.sumSizeBytes(account);
    final evicted = <String>{};
    if (used <= target) return evicted;

    final victims = await _index.getAllByLeastRecentlyAccessed(account);
    for (final victim in victims) {
      if (used <= target) break;
      await remove(account, victim.relativePath);
      evicted.add(victim.relativePath);
      used -= victim.sizeBytes;
    }
    // `used > target` here means even an empty mirror cannot hold the reservation; the caller decides
    // whether that is a `NextcloudQuotaFailure`. Everything evicted is reported either way.
    return evicted;
  }

  @override
  Future<void> purge(NextcloudAccount account) async {
    final directory = Directory(_accountRoot(account));
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
    await _index.deleteAll(account);
  }

  void _checkInitialized() {
    if (_mirrorRoot.isEmpty) throw StateError('$runtimeType used before init()');
  }

  String _requireNormalized(String relativePath) {
    final normalized = NextcloudPaths.normalize(relativePath);
    if (normalized == null) throw NextcloudPathEscapeFailure(relativePath);
    return normalized;
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
