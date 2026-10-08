import 'package:aves/model/nextcloud/account.dart';

// One mirrored file, as tracked by the mirror index (layer L3).
// The index is owned by the mirror store (its own small sqflite file or JSON under the mirror root);
// it is deliberately NOT a new table in `localMediaDb`, so no schema migration is needed.
class NextcloudMirrorIndexEntry {
  final String relativePath;
  final String etag;
  final int? fileId;
  final int sizeBytes;
  final DateTime remoteLastModified, downloadedAt;

  // bumped on view; drives LRU eviction
  final DateTime lastAccessAt;

  const NextcloudMirrorIndexEntry({
    required this.relativePath,
    required this.etag,
    required this.fileId,
    required this.sizeBytes,
    required this.remoteLastModified,
    required this.downloadedAt,
    required this.lastAccessAt,
  });

  NextcloudMirrorIndexEntry copyWith({DateTime? lastAccessAt}) {
    return NextcloudMirrorIndexEntry(
      relativePath: relativePath,
      etag: etag,
      fileId: fileId,
      sizeBytes: sizeBytes,
      remoteLastModified: remoteLastModified,
      downloadedAt: downloadedAt,
      lastAccessAt: lastAccessAt ?? this.lastAccessAt,
    );
  }

  @override
  bool operator ==(Object other) => other is NextcloudMirrorIndexEntry && other.relativePath == relativePath;

  @override
  int get hashCode => relativePath.hashCode;

  @override
  String toString() => '$runtimeType{path=$relativePath, etag=$etag, size=$sizeBytes}';
}

// Local mirror contract (layer L3). Layout, fixed by this contract so albums come out right without any new UI:
//
//   <mirrorRoot>/<account.mirrorDirName>/<relativePath>
//
// where `mirrorRoot` comes from `storageService.getNextcloudMirrorRoot()` (app-private `filesDir/nextcloud/`,
// same mechanism as the vault root) and `relativePath` keeps the remote directory tree verbatim.
// Because `AvesEntry.directory` is derived from `path`, each remote sub-folder becomes a nested album for free.
abstract class NextcloudMirrorStore {
  Future<void> init();

  String get mirrorRoot;

  // absolute local path for a remote item; does not touch the filesystem
  String localPathFor(NextcloudAccount account, String relativePath);

  // inverse of `localPathFor`; `null` when `localPath` is not under this account's mirror
  String? relativePathFor(NextcloudAccount account, String localPath);

  Future<NextcloudMirrorIndexEntry?> lookup(NextcloudAccount account, String relativePath);

  Future<Set<NextcloudMirrorIndexEntry>> listAll(NextcloudAccount account);

  // records a completed download; the file at `localPathFor(...)` must already be fully written
  Future<void> record(NextcloudAccount account, NextcloudMirrorIndexEntry entry);

  // deletes the file and its index row; a no-op for unknown paths
  Future<void> remove(NextcloudAccount account, String relativePath);

  Future<void> touch(NextcloudAccount account, String relativePath, DateTime accessedAt);

  Future<int> usedBytes(NextcloudAccount account);

  // Evicts least-recently-accessed files until `usedBytes <= account.cacheLimitBytes - reserveBytes`.
  // Returns the relative paths removed. The caller MUST remove the matching entries from the collection
  // in the same step: an entry whose mirror file is gone would be dropped from the DB on its next refresh.
  Future<Set<String>> evictToFit(NextcloudAccount account, {int reserveBytes = 0});

  // removes everything for the account (used on account removal)
  Future<void> purge(NextcloudAccount account);
}
