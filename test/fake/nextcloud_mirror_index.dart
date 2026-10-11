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

  // paths whose row rewrite fails, to exercise a demotion whose file went but whose row could not follow
  final Set<String> failPutFor = {};

  int getLeastRecentlyAccessedCalls = 0;
  int getOldestModifiedCalls = 0;

  @override
  Future<void> init() async => initCount++;

  Map<String, NextcloudMirrorIndexEntry> _rows(NextcloudAccount account) => _byAccount.putIfAbsent(account.id, () => {});

  @override
  Future<NextcloudMirrorIndexEntry?> get(NextcloudAccount account, String relativePath) async => _rows(account)[relativePath];

  @override
  Future<Set<NextcloudMirrorIndexEntry>> getAll(NextcloudAccount account) async => _rows(account).values.toSet();

  @override
  Future<List<NextcloudMirrorIndexEntry>> getLeastRecentlyAccessed(NextcloudAccount account, {required int limit, Set<NextcloudMirrorTier>? tiers}) async {
    getLeastRecentlyAccessedCalls++;
    // same exclusions as the sqflite index: neither a pinned row nor a placeholder can usefully be evicted,
    // whatever `tiers` says
    final entries = _rows(account).values.where((v) => !v.pinned && v.tier != NextcloudMirrorTier.placeholder && (tiers == null || tiers.contains(v.tier))).toList();
    // same total order as the sqflite index: `lastAccessAt`, then `relativePath` to break ties
    entries.sort((a, b) {
      final byAccess = a.lastAccessAt.compareTo(b.lastAccessAt);
      return byAccess != 0 ? byAccess : a.relativePath.compareTo(b.relativePath);
    });
    return entries.take(limit).toList();
  }

  @override
  Future<List<NextcloudMirrorIndexEntry>> getOldestModified(NextcloudAccount account, {required int limit, required Set<NextcloudMirrorTier> tiers, DateTime? modifiedBefore}) async {
    getOldestModifiedCalls++;
    // same exclusions and filter as the sqflite index: unpinned, never a placeholder, in `tiers`, before the bound
    final entries = _rows(account).values.where((v) => !v.pinned && v.tier != NextcloudMirrorTier.placeholder && tiers.contains(v.tier) && (modifiedBefore == null || v.remoteLastModified.isBefore(modifiedBefore))).toList();
    // same total order as the sqflite index: `remoteLastModified`, then `relativePath` to break ties
    entries.sort((a, b) {
      final byDate = a.remoteLastModified.compareTo(b.remoteLastModified);
      return byDate != 0 ? byDate : a.relativePath.compareTo(b.relativePath);
    });
    return entries.take(limit).toList();
  }

  @override
  Future<void> put(NextcloudAccount account, NextcloudMirrorIndexEntry entry) async {
    if (failPutFor.contains(entry.relativePath)) throw const FileSystemException('refused');
    _rows(account)[entry.relativePath] = entry;
  }

  @override
  Future<void> delete(NextcloudAccount account, String relativePath) async {
    if (failDeleteFor.contains(relativePath)) throw const FileSystemException('refused');
    _rows(account).remove(relativePath);
  }

  @override
  Future<void> deleteAll(NextcloudAccount account) async => _rows(account).clear();

  @override
  Future<int> sumLocalSizeBytes(NextcloudAccount account, {NextcloudBudgetClass? of}) async => _rows(account).values.fold<int>(
    0,
    (sum, v) =>
        sum +
        switch (of) {
          null => v.localSizeBytes,
          NextcloudBudgetClass.sync => v.syncClassBytes,
          NextcloudBudgetClass.view => v.viewClassBytes,
        },
  );
}
