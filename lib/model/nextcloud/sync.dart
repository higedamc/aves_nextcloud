import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/errors.dart';
import 'package:aves/model/nextcloud/repository.dart';

// Use case input/output types for synchronizing one account (the integration phase implements the use case).
//
// Algorithm fixed by this contract:
//   1. `probe()`; on `NextcloudAuthFailure` stop and surface it (never retry with the same password).
//   2. `listMediaTree('', knownCollectionEtags: <from last run>)` → remote snapshot (`''` is the account root
//      folder: the repository prefixes `account.rootFolder` itself).
//   3. Diff against `mirrorStore.listAll(account)` by relativePath + etag:
//        added/updated → download (newest `lastModified` first), `record`, then create the `AvesEntry`
//        via `mediaFetchService.getEntry(Uri.file(localPath))` with `origin = EntryOrigins.nextcloud`,
//        removed on server → `mirrorStore.remove` + `source.removeEntries`.
//   4. `evictToFit` → the sink demotes the entries of evicted paths (the rows survive as placeholders).
//   5. Run in the main app isolate only: `localMediaDb.nextId` is process-local.
// v1 is strictly one-way (server → device). No write ever goes to the server.
class NextcloudSyncRequest {
  final NextcloudAccount account;

  // re-download even when etags match
  final bool force;

  final NextcloudCancellation? cancellation;

  const new({required this.account, this.force = false, this.cancellation});
}

enum NextcloudSyncPhase { probing, listing, downloading, evicting, done, failed }

class NextcloudSyncProgress {
  final NextcloudSyncPhase phase;
  final int done, total;
  final int bytesDone;

  const new({required this.phase, this.done = 0, this.total = 0, this.bytesDone = 0});

  @override
  String toString() => '$runtimeType{phase=$phase, done=$done, total=$total, bytes=$bytesDone}';
}

class NextcloudSyncResult {
  final int added, updated, removed, skipped, evicted;

  // rows whose bytes the budget took back: to a placeholder (still in the gallery, streamed on demand) or,
  // for a view row, back to its grid bytes. Not `evicted`, which counts rows that left the mirror
  // altogether; the distinction decides whether the run's etags survive, see the use case.
  final int demoted;

  // rows whose mirror file was missing and that the listing could not refill: dropped with their entries
  final int lost;

  // failures of individual items; the sync keeps going past them
  final Map<String, NextcloudFailure> itemFailures;

  // fatal failure that stopped the sync, if any
  final NextcloudFailure? fatal;

  const new({
    this.added = 0,
    this.updated = 0,
    this.removed = 0,
    this.skipped = 0,
    this.evicted = 0,
    this.demoted = 0,
    this.lost = 0,
    this.itemFailures = const {},
    this.fatal,
  });

  bool get isSuccess => fatal == null;

  @override
  String toString() => '$runtimeType{added=$added, updated=$updated, removed=$removed, skipped=$skipped, evicted=$evicted, demoted=$demoted, lost=$lost, itemFailures=${itemFailures.length}, fatal=$fatal}';
}

abstract class NextcloudSyncUseCase {
  // emits progress, completes with the result; never throws `NextcloudFailure` (it is reported in the result)
  Stream<NextcloudSyncProgress> run(NextcloudSyncRequest request);

  Future<NextcloudSyncResult> get lastResult;

  // Fetches the whole file for one listed item and pins it: never evicted and never downgraded until
  // `releaseOriginal`. This is the explicit action behind "download original" (a wallpaper, a share, the
  // full metadata); the sync never pins anything. Runs under the same per-account serialization as `run`,
  // so no eviction races it. Completes with the failure for that item rather than throwing it; `null` is
  // success. A pinned row can fill the budget: the sync then reports quota failures for what it cannot fit.
  Future<NextcloudFailure?> fetchOriginal(NextcloudAccount account, String relativePath, {NextcloudCancellation? cancellation});

  // Unpins a held original. The bytes stay, evictable like any other row, until the budget wants them.
  Future<NextcloudFailure?> releaseOriginal(NextcloudAccount account, String relativePath);

  // The item was opened. Records the access on its row whatever follows, then, for a row held at `grid`,
  // fetches the screen-sized `view` tier inside `NextcloudAccount.viewAllowanceBytes`, keeping the grid
  // bytes as a sidecar so the budget can give the view bytes back offline. Runs under the same per-account
  // serialization as `run`, so a sync in flight is waited for in full (the viewer shows the grid bytes
  // meanwhile). Completes with the failure rather than throwing it; `null` is success, and also "nothing
  // to do": an item the mirror does not hold, holds at another tier, or that changed on the server since
  // the row was written (the sync owns changes). A `NextcloudQuotaFailure` is the allowance saying no.
  Future<NextcloudFailure?> fetchView(NextcloudAccount account, String relativePath, {NextcloudCancellation? cancellation});
}
