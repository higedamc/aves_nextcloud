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

  // Screen-sized derivative, fetched when an item is opened and evictable like any cache entry. A row at
  // this tier keeps its grid bytes as a sidecar (`NextcloudMirrorStore.sidecarPathFor`), so that giving
  // the view bytes back is a local rename to `grid` and works offline, which is when the budget bites.
  // Both files count in `localSizeBytes`, the sidecar's share in `sidecarSizeBytes`: the sidecar is the
  // grid tier the sync funded, the view bytes are what browsing funded, see `NextcloudBudgetClass`.
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

// How `cacheLimitBytes` is split, see `NextcloudAccount.viewAllowanceBytes`. Two classes that never share
// a byte: every byte on disk belongs to exactly one, so neither evictor can take what the other funded.
// The class carries its own limit (`limitFor`) and the store sums its own bytes for it (`usedBytes`,
// `freeBytes`), so that "how full is the sync budget" and "how full is the allowance" are two questions
// with two answers, and a caller cannot pair the allowance with the sync sum: it names a class, not a sum.
enum NextcloudBudgetClass {
  // What the sync holds against `syncBudgetBytes`: grid rows, originals, and the grid sidecar of a view
  // row, which is the grid tier the sync funded and keeps on through a view fetch. **Pinned originals
  // fund against this class too**: a pin is a durable request for whole bytes, machine work and pins on
  // one side, transient views on the other. Were pins to fund against the allowance, one pinned video
  // would eat it whole and the view tier would be dead with the partition in place and looking correct.
  sync,

  // what browsing holds against `viewAllowanceBytes`: the view bytes of view rows, and nothing else
  view;

  int limitFor(NextcloudAccount account) => switch (this) {
    NextcloudBudgetClass.sync => account.syncBudgetBytes,
    NextcloudBudgetClass.view => account.viewAllowanceBytes,
  };
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

  // the share of `localSizeBytes` that is the grid sidecar of a `view` row, read back from disk like the
  // rest; 0 for every other tier. What splits the row between the two budget classes.
  final int sidecarSizeBytes;

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
    this.sidecarSizeBytes = 0,
    this.pinned = false,
    required this.remoteLastModified,
    required this.downloadedAt,
    required this.lastAccessAt,
  }) : assert((tier == NextcloudMirrorTier.placeholder) == (placeholderReason != null), 'a placeholder row carries its reason, and no other tier does'),
       assert(tier == NextcloudMirrorTier.view || sidecarSizeBytes == 0, 'only a view row has a sidecar'),
       assert(sidecarSizeBytes <= localSizeBytes, 'the sidecar is a share of the local bytes');

  // whether this row can answer a requirement for `wanted`; see `NextcloudMirrorTier`
  bool satisfies(NextcloudMirrorTier wanted) => tier.index >= wanted.index;

  // the row's bytes in each budget class, see `NextcloudBudgetClass`
  int get syncClassBytes => tier == NextcloudMirrorTier.view ? sidecarSizeBytes : localSizeBytes;

  int get viewClassBytes => tier == NextcloudMirrorTier.view ? localSizeBytes - sidecarSizeBytes : 0;

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

  // The row a `view` row becomes when the budget takes the view bytes back and the grid sidecar is put in
  // their place: the same identity, `grid`, and the sidecar's size as read back from disk. Not a placeholder:
  // the item still has its thumbnail, so nothing is a gap and no run has anything to come back for.
  NextcloudMirrorIndexEntry asGrid({required int localSizeBytes}) => NextcloudMirrorIndexEntry(
    relativePath: relativePath,
    etag: etag,
    fileId: fileId,
    tier: NextcloudMirrorTier.grid,
    remoteSizeBytes: remoteSizeBytes,
    localSizeBytes: localSizeBytes,
    pinned: pinned,
    remoteLastModified: remoteLastModified,
    downloadedAt: downloadedAt,
    lastAccessAt: lastAccessAt,
  );

  // `tier` and `placeholderReason` are deliberately not here: they change together or not at all, and
  // `asUnfundedPlaceholder` and `asGrid` are the two transitions the store makes.
  NextcloudMirrorIndexEntry copyWith({
    int? remoteSizeBytes,
    int? localSizeBytes,
    int? sidecarSizeBytes,
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
      sidecarSizeBytes: sidecarSizeBytes ?? this.sidecarSizeBytes,
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
  String toString() =>
      '$runtimeType{path=$relativePath, etag=$etag, tier=${tier.name}${placeholderReason == null ? '' : '/${placeholderReason!.name}'}, local=$localSizeBytes${sidecarSizeBytes == 0 ? '' : ' (sidecar $sidecarSizeBytes)'}, remote=$remoteSizeBytes, pinned=$pinned}';
}

// What one eviction pass did. Separate outcomes because the caller has to do different things with them:
// a removed path loses its gallery entry, a demoted one keeps it with no bytes behind it, and one demoted
// to grid keeps it with its thumbnail bytes back in place and must have it read again.
class NextcloudEvictionOutcome {
  // `demoted`: the row survives as an `unfunded` placeholder. `demotedToGrid`: a `view` row survives as a
  // `grid` row, its sidecar renamed back into place. Two sets rather than one with a tier each, so that a
  // caller cannot hand a grid demotion to the placeholder path, which would evict the thumbnail it just kept.
  final Set<String> removed, demoted, demotedToGrid;

  const new({this.removed = const {}, this.demoted = const {}, this.demotedToGrid = const {}});

  static const none = NextcloudEvictionOutcome();

  bool get isEmpty => removed.isEmpty && demoted.isEmpty && demotedToGrid.isEmpty;

  // every path this pass touched, for callers that only need to know whether their own fetch survived
  Set<String> get touched => {...removed, ...demoted, ...demotedToGrid};

  @override
  String toString() => '$runtimeType{removed=${removed.length}, demoted=${demoted.length}, demotedToGrid=${demotedToGrid.length}}';
}

// Which rows `evictToFit` takes first. The two callers want different answers and neither order is right
// for the other, so the choice is explicit rather than a property of the store.
//
// Each order works one budget class (`NextcloudBudgetClass`), and that is what keeps the two evictors
// from ever fighting over a row: they never share one.
//
// - `leastRecentlyAccessed`: the `sync` class, for an explicit download, which the user asked for whole.
//   Any unpinned row can go; what the user looked at last stays.
// - `oldestFirst`: the `sync` class, for the sync, which fetches newest first. An access-ordered evictor
//   can take precisely the file the sync is about to fetch again, which is a treadmill no placeholder rule
//   closes. Taking the oldest `remoteLastModified` first, originals before grid rows, makes the held set a
//   function of (server order, sizes, budget) and so the same on every run. See `NextcloudSyncFunding`
//   for the bound that keeps a fetch from evicting anything it would rank above.
// - `viewRowsLeastRecentlyAccessed`: the `view` class, for a view-tier fetch. Only the view bytes of other
//   `view` rows can go, least recently accessed first, back to their grid bytes; the fetch is refused when
//   they do not make room. Browsing therefore never costs the gallery a thumbnail or an offline video, and
//   a sync that still has something to fund never turns the view tier's room into a held original.
//
// A `view` row sits in both classes: its view bytes are the `view` class and its sidecar is the `sync`
// class. The sync orders see it only as the grid bytes it holds, in the grid page, and take it to a
// placeholder like any grid row; the view order sees only its view bytes.
enum NextcloudEvictionOrder { leastRecentlyAccessed, viewRowsLeastRecentlyAccessed, oldestFirst }

extension NextcloudEvictionOrderClass on NextcloudEvictionOrder {
  NextcloudBudgetClass get budgetClass => switch (this) {
    NextcloudEvictionOrder.leastRecentlyAccessed || NextcloudEvictionOrder.oldestFirst => NextcloudBudgetClass.sync,
    NextcloudEvictionOrder.viewRowsLeastRecentlyAccessed => NextcloudBudgetClass.view,
  };
}

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
  // Where the grid sidecars of `view` rows live: `<mirrorRoot>/<sidecarsDirName>/<account.mirrorDirName>/
  // <relativePath>`, a sibling of the account directories rather than a name beside the file. The server
  // can name a file anything a path segment allows (`notes.grid` is a legal Nextcloud file), and a mirror
  // that refused such a name would report the item as failed, which withholds every ancestor's etag and
  // walks the whole tree on every run for as long as the file exists. A namespace the server cannot reach
  // has no such name. An account whose id is this name is refused, as an unsafe id is.
  static const sidecarsDirName = 'sidecars';

  Future<void> init();

  String get mirrorRoot;

  // absolute local path for a remote item; does not touch the filesystem
  String localPathFor(NextcloudAccount account, String relativePath);

  // absolute local path of the grid sidecar a `view` row keeps for `relativePath`; does not touch the filesystem
  String sidecarPathFor(NextcloudAccount account, String relativePath);

  // inverse of `localPathFor`; `null` when `localPath` is not under this account's mirror
  String? relativePathFor(NextcloudAccount account, String localPath);

  // The id of the account whose mirror `localPath` is under, read from the layout (`mirrorDirName` is the
  // account id), or `null` when it is not under any account's mirror. The layout knowledge stays here, so
  // a caller holding an entry's path need not try every account; it does not check that the account exists.
  String? accountIdFor(String localPath);

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
  // file to stat, so nothing is read back and `localSizeBytes` is written as 0 — and **any file at the path
  // is deleted first**. A placeholder is the tier whose file is absent by design, and the store is what
  // makes that so: written over a row that holds bytes (a changed file the budget cannot fund, or that the
  // server can no longer derive), the bytes go back to the budget; left on disk under a zero-byte row they
  // would be counted by nothing and found by no later run. A caller writing a placeholder over such a row
  // MUST tell the sink the entry's bytes are gone (`NextcloudSyncSink.demoteToPlaceholders`), exactly as it
  // does for `evictToFit`'s `demoted`. Any other tier without its bytes on disk is a
  // `NextcloudNotFoundFailure`, because recording a row for a file that is not there would make `usedBytes`
  // lie forever.
  //
  // A `NextcloudMirrorTier.view` row requires its grid sidecar on disk too (`sidecarPathFor`):
  // `localSizeBytes` is the sum of both files and `sidecarSizeBytes` the sidecar's share, both read back.
  // The sidecar is what makes the row demotable offline, so a view row without one is the same failure as
  // a row without its file. Every other tier deletes a stale sidecar for the path, before the row is
  // written, so bytes a previous view row left behind are never counted by nothing.
  Future<void> record(NextcloudAccount account, NextcloudMirrorIndexEntry entry);

  // deletes the file, its sidecar and its index row; a no-op for unknown paths
  Future<void> remove(NextcloudAccount account, String relativePath);

  Future<void> touch(NextcloudAccount account, String relativePath, DateTime accessedAt);

  // Sum of `localSizeBytes` over the account's rows: bytes on disk, never remote sizes. With `of`, the
  // bytes of that budget class only (`NextcloudMirrorIndexEntry.syncClassBytes` / `viewClassBytes`).
  // Without, the whole mirror, which is what disk reconciliation compares against and **never a budget**:
  // a budget question is asked of `freeBytes`, which binds the class's sum to the class's limit.
  Future<int> usedBytes(NextcloudAccount account, {NextcloudBudgetClass? of});

  // `of.limitFor(account) - usedBytes(account, of: of)`: negative when the class is over its limit (a
  // lowered limit, or the partition landing on a mirror built before it).
  Future<int> freeBytes(NextcloudAccount account, NextcloudBudgetClass of);

  // Gives bytes back until the `order`'s budget class (`NextcloudEvictionOrder.budgetClass`) fits:
  // `freeBytes(of) >= reserveBytes` (and, for `oldestFirst`, within the bound `funding` sets; see both
  // types). The class comes from the order by type and both its limit and its sum from the class, so no
  // call can pair one class's sum with the other's limit.
  //
  // **Eviction never removes a row.** A victim loses its file and keeps its row as an `unfunded`
  // placeholder (`NextcloudMirrorIndexEntry.asUnfundedPlaceholder`), reported in `demoted`. One row and one
  // local path exist per relative path, so if reclaiming bytes deleted the row, the photo would disappear
  // from the grid under budget pressure, the completeness rule would see a listed item with no row, and
  // every later sync would re-list the whole tree and fund the gap by evicting the next row — a treadmill
  // that looks like a working sync. A demotion keeps the row and the item, the item streams on demand,
  // and the mirror still reflects the server. Under the view order a `view` row demotes to `grid` for the
  // same reason: its sidecar is renamed back into place and the row keeps its thumbnail, so nothing is a
  // gap. A view row whose sidecar is missing cannot, and demotes to a placeholder like any other row.
  //
  // A sync order that reaches a `view` row (the grid page, when the grid class alone overflows) takes it
  // in two steps, each inside its own class: first to `grid`, which gives the view bytes back to the
  // allowance and leaves an ordinary grid row, then — if the overflow rule still reaches it on its own
  // terms — to a placeholder. Never straight to a placeholder: that would reclaim allowance bytes to fund
  // sync work, the one leak the partition could have, and it would make an opened photo more likely to
  // lose its thumbnail than one never opened. A path that went both ways in one pass is reported in
  // `demoted` only, since its bytes are gone.
  //
  // - `removed`: the row and its bytes are gone. The caller MUST remove the matching entries from the
  //   collection in the same step, since an entry whose mirror file is gone would be dropped from the DB
  //   on its next refresh. No implementation produces this today; it stays in the contract so that no
  //   caller is written against a return type that can only say "demoted".
  // - `demoted`: the row survives as an `unfunded` placeholder. The caller MUST tell the sink, because the
  //   bytes behind those entries are gone.
  // - `demotedToGrid`: the row survives as a `grid` row with its sidecar bytes in place. The caller MUST
  //   tell the sink, because the bytes behind those entries changed.
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

  // The transition `evictToFit`'s `demotedToGrid` makes, for one row, on request: the view bytes go, the
  // sidecar takes their place, and the row is written back as a `grid` row with the size read from disk.
  // For the caller whose view bytes turned out to be no good after `record` — the sink could not read an
  // entry from them — and that must leave the row as the sync funded it rather than drop it: a row removed
  // outside a run is refilled by nothing, since no etag was withheld and the next run trusts the subtree.
  // The caller MUST tell the sink (`NextcloudSyncSink.demoteToGrid`), exactly as for `demotedToGrid`.
  // A `NextcloudNotFoundFailure` when there is no `view` row for the path or its sidecar is not on disk:
  // there are no grid bytes to go back to, and a row claiming bytes that are not there is the one thing
  // the store never writes.
  Future<void> demoteToGrid(NextcloudAccount account, String relativePath);

  // Deletes every sidecar of the account whose row is not a `view` row: a process that died between the
  // sidecar rename and the row write leaves one behind, and the row it belongs to is then refilled at grid
  // by the next sync (`record` at grid drops the sidecar) or never — this is for the latter.
  Future<void> sweepStraySidecars(NextcloudAccount account);

  // removes everything for the account (used on account removal)
  Future<void> purge(NextcloudAccount account);
}
