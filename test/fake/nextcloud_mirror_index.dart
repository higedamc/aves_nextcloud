import 'dart:io';

import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/mirror_index.dart';
import 'package:aves/model/nextcloud/mirror_store.dart';

// In-memory `NextcloudMirrorIndex`, so the accounting and eviction policy in
// `NextcloudMirrorStoreImpl` can be tested without a platform database.
class FakeNextcloudMirrorIndex implements NextcloudMirrorIndex {
  final Map<String, Map<String, NextcloudMirrorIndexEntry>> _byAccount = {};

  int initCount = 0;

  // paths whose row deletion fails, to exercise a platform that refuses to drop an entry
  final Set<String> failDeleteFor = {};

  int getLeastRecentlyAccessedCalls = 0;

  @override
  Future<void> init() async => initCount++;

  Map<String, NextcloudMirrorIndexEntry> _rows(NextcloudAccount account) => _byAccount.putIfAbsent(account.id, () => {});

  @override
  Future<NextcloudMirrorIndexEntry?> get(NextcloudAccount account, String relativePath) async => _rows(account)[relativePath];

  @override
  Future<Set<NextcloudMirrorIndexEntry>> getAll(NextcloudAccount account) async => _rows(account).values.toSet();

  @override
  Future<List<NextcloudMirrorIndexEntry>> getLeastRecentlyAccessed(NextcloudAccount account, {required int limit}) async {
    getLeastRecentlyAccessedCalls++;
    final entries = _rows(account).values.toList();
    // same total order as the sqflite index: `lastAccessAt`, then `relativePath` to break ties
    entries.sort((a, b) {
      final byAccess = a.lastAccessAt.compareTo(b.lastAccessAt);
      return byAccess != 0 ? byAccess : a.relativePath.compareTo(b.relativePath);
    });
    return entries.take(limit).toList();
  }

  @override
  Future<void> put(NextcloudAccount account, NextcloudMirrorIndexEntry entry) async => _rows(account)[entry.relativePath] = entry;

  @override
  Future<void> delete(NextcloudAccount account, String relativePath) async {
    if (failDeleteFor.contains(relativePath)) throw const FileSystemException('refused');
    _rows(account).remove(relativePath);
  }

  @override
  Future<void> deleteAll(NextcloudAccount account) async => _rows(account).clear();

  @override
  Future<int> sumSizeBytes(NextcloudAccount account) async => _rows(account).values.fold<int>(0, (sum, v) => sum + v.sizeBytes);
}
