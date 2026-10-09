import 'package:aves/model/nextcloud/account.dart';

// Which version of a remote file the local mirror holds, from least to most complete.
//
// The order is meaningful: a row satisfies a requirement for tier T when its own tier is T or later,
// because a later tier can always answer what an earlier one could. That is what keeps an explicitly
// downloaded original from being treated as a missing grid thumbnail, and what lets rows written before
// tiers existed (all originals) satisfy a grid requirement without re-fetching anything.
enum NextcloudMirrorTier {
  // No local bytes at all: the row exists only so the item can appear in the gallery. The sole tier
  // whose `localSizeBytes` is 0 and whose local file is absent by design, so the mirror's "a row whose
  // file is missing is a cache miss" rule must exempt it.
  placeholder,

  // Grid-sized derivative: a server preview for an image, a device-extracted frame for a video.
  // Cheap enough to hold for every listed item.
  grid,

  // Screen-sized derivative, fetched when an item is opened and evictable like any cache entry.
  view,

  // The file's own bytes, byte for byte. The only tier that carries the original metadata, and the
  // only one an export, a wallpaper or a share can use.
  original,
}

// One mirrored file, as tracked by the mirror index (layer L3).
// The index is owned by the mirror store (its own small sqflite file or JSON under the mirror root);
// it is deliberately NOT a new table in `localMediaDb`, so no `localMediaDb` migration is needed.
class NextcloudMirrorIndexEntry {
  final String relativePath;
  final String etag;
  final int? fileId;

  // which version of the file is on disk; see `NextcloudMirrorTier`
  final NextcloudMirrorTier tier;

  // the file's size on the server, from the listing. Never read back from disk: for every tier other
  // than `original` the local bytes are a different, smaller artefact. This is what a size threshold
  // compares and what an info page should show as the original's size.
  final int remoteSizeBytes;

  // bytes actually on disk, read back from disk by `NextcloudMirrorStore.record`. This, and never
  // `remoteSizeBytes`, is what the cache budget sums: summing remote sizes over preview rows would
  // report a mirror of a few hundred megabytes as hundreds of gigabytes and evict everything forever.
  final int localSizeBytes;

  // the user asked for these bytes explicitly (a download, a wallpaper, an export), so eviction must
  // not take them and a sync must not replace them with a cheaper tier. Distinct from `tier`:
  // `original` describes what is held, `pinned` describes whether anyone asked for it.
  final bool pinned;

  final DateTime remoteLastModified, downloadedAt;

  // bumped on view; drives LRU eviction
  final DateTime lastAccessAt;

  const new({
    required this.relativePath,
    required this.etag,
    required this.fileId,
    required this.tier,
    required this.remoteSizeBytes,
    required this.localSizeBytes,
    this.pinned = false,
    required this.remoteLastModified,
    required this.downloadedAt,
    required this.lastAccessAt,
  });

  // whether this row can answer a requirement for `wanted`; see `NextcloudMirrorTier`
  bool satisfies(NextcloudMirrorTier wanted) => tier.index >= wanted.index;

  NextcloudMirrorIndexEntry copyWith({
    NextcloudMirrorTier? tier,
    int? remoteSizeBytes,
    int? localSizeBytes,
    bool? pinned,
    DateTime? lastAccessAt,
  }) {
    return NextcloudMirrorIndexEntry(
      relativePath: relativePath,
      etag: etag,
      fileId: fileId,
      tier: tier ?? this.tier,
      remoteSizeBytes: remoteSizeBytes ?? this.remoteSizeBytes,
      localSizeBytes: localSizeBytes ?? this.localSizeBytes,
      pinned: pinned ?? this.pinned,
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
  String toString() => '$runtimeType{path=$relativePath, etag=$etag, tier=${tier.name}, local=$localSizeBytes, remote=$remoteSizeBytes, pinned=$pinned}';
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

  // Records a completed fetch; the file at `localPathFor(...)` must already be fully written, except for
  // a `placeholder` row, which has no file by design.
  //
  // `entry.localSizeBytes` is ignored and read back from disk, so that accounting and eviction are driven
  // by the same source as the bytes they account for. Everything else is taken from the caller, including
  // `remoteSizeBytes`, `tier` and `pinned`: the store cannot know from the bytes alone which version of
  // the file they are, how large the original is, or whether anyone asked for it.
  Future<void> record(NextcloudAccount account, NextcloudMirrorIndexEntry entry);

  // deletes the file and its index row; a no-op for unknown paths
  Future<void> remove(NextcloudAccount account, String relativePath);

  Future<void> touch(NextcloudAccount account, String relativePath, DateTime accessedAt);

  // Sum of `localSizeBytes` over the account's rows: bytes on disk, never remote sizes.
  Future<int> usedBytes(NextcloudAccount account);

  // Evicts least-recently-accessed files until `usedBytes <= account.cacheLimitBytes - reserveBytes`.
  // Returns the relative paths removed. The caller MUST remove the matching entries from the collection
  // in the same step: an entry whose mirror file is gone would be dropped from the DB on its next refresh.
  //
  // A `pinned` row is never a victim: the user asked for those bytes, so dropping them silently would
  // make an explicit download a lie. That makes the reservation refusable — pinned rows can fill the
  // budget — and the caller decides, exactly as it already does when an empty mirror cannot hold a file.
  Future<Set<String>> evictToFit(NextcloudAccount account, {int reserveBytes = 0});

  // removes everything for the account (used on account removal)
  Future<void> purge(NextcloudAccount account);
}
