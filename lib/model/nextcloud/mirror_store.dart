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

// Why a `placeholder` row holds no bytes. The two reasons are told apart by **what would change them**,
// not by what the row would otherwise have held: an unfunded sub-threshold video wants `original` both
// before and after the budget rises, so a "wanted tier" on the row could never tell a sync that the rise
// is what it was waiting for.
enum NextcloudPlaceholderReason {
  // Above the video threshold, or the server cannot derive the item at all (HEIC under the default
  // providers answers 404). Final until the file changes on the server.
  policy,

  // The budget said no in the run that wrote the row, or took the bytes back later to fund something it
  // ranks higher. Final until the budget changes: a raised `cacheLimitBytes` lists everything again and
  // the planning step then treats this row as a gap to fill, while the completeness rule accepts it as
  // is, since the mirror reflects the server honestly in both states.
  unfunded,
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

  // why a `placeholder` row has no bytes; null for every other tier, see `NextcloudPlaceholderReason`
  final NextcloudPlaceholderReason? placeholderReason;

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

  // bumped on view; drives the eviction order of user-driven fetches (`NextcloudEvictionOrder.leastRecentlyAccessed`)
  final DateTime lastAccessAt;

  const new({
    required this.relativePath,
    required this.etag,
    required this.fileId,
    required this.tier,
    this.placeholderReason,
    required this.remoteSizeBytes,
    required this.localSizeBytes,
    this.pinned = false,
    required this.remoteLastModified,
    required this.downloadedAt,
    required this.lastAccessAt,
  }) : assert((tier == NextcloudMirrorTier.placeholder) == (placeholderReason != null), 'a placeholder row carries its reason, and no other tier does');

  // whether this row can answer a requirement for `wanted`; see `NextcloudMirrorTier`
  bool satisfies(NextcloudMirrorTier wanted) => tier.index >= wanted.index;

  // The row this one becomes when the budget takes its bytes back: no file, no local bytes, the same
  // identity (path, etag, file id, remote size and date), and the reason recorded so a later run knows
  // what it is waiting for. A pin is never demoted, so the pin does not carry over; a caller that demotes
  // a pinned row has already broken the contract.
  NextcloudMirrorIndexEntry asUnfundedPlaceholder() => NextcloudMirrorIndexEntry(
    relativePath: relativePath,
    etag: etag,
    fileId: fileId,
    tier: NextcloudMirrorTier.placeholder,
    placeholderReason: NextcloudPlaceholderReason.unfunded,
    remoteSizeBytes: remoteSizeBytes,
    localSizeBytes: 0,
    remoteLastModified: remoteLastModified,
    downloadedAt: downloadedAt,
    lastAccessAt: lastAccessAt,
  );

  // `tier` and `placeholderReason` are deliberately not here: they change together or not at all, and
  // `asUnfundedPlaceholder` is the one transition the store makes.
  NextcloudMirrorIndexEntry copyWith({
    int? remoteSizeBytes,
    int? localSizeBytes,
    bool? pinned,
    DateTime? lastAccessAt,
  }) {
    return NextcloudMirrorIndexEntry(
      relativePath: relativePath,
      etag: etag,
      fileId: fileId,
      tier: tier,
      placeholderReason: placeholderReason,
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
  String toString() => '$runtimeType{path=$relativePath, etag=$etag, tier=${tier.name}${placeholderReason == null ? '' : '/${placeholderReason!.name}'}, local=$localSizeBytes, remote=$remoteSizeBytes, pinned=$pinned}';
}

// What one eviction pass did. Separate outcomes because the caller has to do opposite things with them:
// a removed path loses its gallery entry, a demoted one keeps it and has it refreshed.
class NextcloudEvictionOutcome {
  final Set<String> removed, demoted;

  const new({this.removed = const {}, this.demoted = const {}});

  static const none = NextcloudEvictionOutcome();

  bool get isEmpty => removed.isEmpty && demoted.isEmpty;

  // every path this pass touched, for callers that only need to know whether their own fetch survived
  Set<String> get touched => {...removed, ...demoted};

  @override
  String toString() => '$runtimeType{removed=${removed.length}, demoted=${demoted.length}}';
}

// Which rows `evictToFit` takes first. The two callers want different answers and neither order is right
// for the other, so the choice is explicit rather than a property of the store.
//
// - `leastRecentlyAccessed`: for a user-driven fetch (an explicit download, a view-tier fetch). What the
//   user looked at last stays.
// - `oldestFirst`: for the sync, which fetches newest first. An access-ordered evictor can take precisely
//   the file the sync is about to fetch again, which is a treadmill no placeholder rule closes. Taking
//   the oldest `remoteLastModified` first, originals before grid rows, makes the held set a function of
//   (server order, sizes, budget) and so the same on every run. See `NextcloudSyncFunding` for the bound
//   that keeps a fetch from evicting anything it would rank above.
enum NextcloudEvictionOrder { leastRecentlyAccessed, oldestFirst }

// The item a sync is making room for, under `NextcloudEvictionOrder.oldestFirst`. It bounds the victims:
//
// - funding an `original` may only take unpinned originals (and view rows, which are derivative bytes
//   the sync does not rank) **older** than the item;
// - funding a `grid` row may take any unpinned original or view row, and grid rows older than the item.
//
// Without the bound, funding the oldest wanted item could evict a newer one the sync ranks above it, and
// the next run would fund that one by evicting this one. With it, a run can only ever evict what it would
// not have fetched in the first place, so "newest first" holds across runs and not only within one. The
// grid class outranks originals as a whole (a library of thumbnails beats whole copies of a few files),
// which is why an original can never take a grid row. A sweep with no item to fund (`null`) is unbounded.
class NextcloudSyncFunding {
  final NextcloudMirrorTier tier;
  final DateTime lastModified;

  const new({required this.tier, required this.lastModified});

  @override
  String toString() => '$runtimeType{tier=${tier.name}, lastModified=$lastModified}';
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

  // Records a completed fetch; the file at `localPathFor(...)` must already be fully written.
  //
  // `entry.localSizeBytes` is ignored and read back from disk, so that accounting and eviction are driven
  // by the same source as the bytes they account for. Everything else is taken from the caller, including
  // `remoteSizeBytes`, `tier` and `pinned`: the store cannot know from the bytes alone which version of
  // the file they are, how large the original is, or whether anyone asked for it.
  //
  // A `NextcloudMirrorTier.placeholder` row is the one exception and takes a separate branch: there is no
  // file to stat, so nothing is read back and `localSizeBytes` is written as 0. Any other tier without its
  // bytes on disk is a `NextcloudNotFoundFailure`, because recording a row for a file that is not there
  // would make `usedBytes` lie forever.
  Future<void> record(NextcloudAccount account, NextcloudMirrorIndexEntry entry);

  // deletes the file and its index row; a no-op for unknown paths
  Future<void> remove(NextcloudAccount account, String relativePath);

  Future<void> touch(NextcloudAccount account, String relativePath, DateTime accessedAt);

  // Sum of `localSizeBytes` over the account's rows: bytes on disk, never remote sizes.
  Future<int> usedBytes(NextcloudAccount account);

  // Gives bytes back until `usedBytes <= account.cacheLimitBytes - reserveBytes`, in the given `order`
  // (and, for `oldestFirst`, within the bound `funding` sets; see both types).
  //
  // **Eviction never removes a row.** A victim loses its file and keeps its row as an `unfunded`
  // placeholder (`NextcloudMirrorIndexEntry.asUnfundedPlaceholder`), reported in `demoted`. One row and one
  // local path exist per relative path, so if reclaiming bytes deleted the row, the photo would disappear
  // from the grid under budget pressure, the completeness rule would see a listed item with no row, and
  // every later sync would re-list the whole tree and fund the gap by evicting the next row — a treadmill
  // that looks like a working sync. A demotion keeps the row and the item, the item streams on demand,
  // and the mirror still reflects the server. The `view` tier, when it exists, demotes to `grid` for the
  // same reason.
  //
  // - `removed`: the row and its bytes are gone. The caller MUST remove the matching entries from the
  //   collection in the same step, since an entry whose mirror file is gone would be dropped from the DB
  //   on its next refresh. No implementation produces this today; it stays in the contract so that no
  //   caller is written against a return type that can only say "demoted".
  // - `demoted`: the row survives at a cheaper tier. The caller MUST tell the sink, because the bytes
  //   behind those entries are gone or changed.
  //
  // A `pinned` row is never either: the user asked for those bytes, so dropping or shrinking them silently
  // would make an explicit download a lie. Neither is a `placeholder` row: it holds no bytes, so taking it
  // reclaims nothing. That makes the reservation refusable — pinned rows can fill the budget — and the
  // caller decides, exactly as it already does when an empty mirror cannot hold a file.
  Future<NextcloudEvictionOutcome> evictToFit(
    NextcloudAccount account, {
    int reserveBytes = 0,
    NextcloudEvictionOrder order = NextcloudEvictionOrder.leastRecentlyAccessed,
    NextcloudSyncFunding? funding,
  });

  // removes everything for the account (used on account removal)
  Future<void> purge(NextcloudAccount account);
}
