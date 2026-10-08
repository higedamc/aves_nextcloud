import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/errors.dart';
import 'package:aves/model/nextcloud/repository.dart';

// Use case input/output types for synchronizing one account (the integration phase implements the use case).
//
// Algorithm fixed by this contract:
//   1. `probe()`; on `NextcloudAuthFailure` stop and surface it (never retry with the same password).
//   2. `listMediaTree(account.rootFolder, knownCollectionEtags: <from last run>)` → remote snapshot.
//   3. Diff against `mirrorStore.listAll(account)` by relativePath + etag:
//        added/updated → download (newest `lastModified` first), `record`, then create the `AvesEntry`
//        via `mediaFetchService.getEntry(Uri.file(localPath))` with `origin = EntryOrigins.nextcloud`,
//        removed on server → `mirrorStore.remove` + `source.removeEntries`.
//   4. `evictToFit` → `source.removeEntries` for evicted paths.
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
    this.itemFailures = const {},
    this.fatal,
  });

  bool get isSuccess => fatal == null;

  @override
  String toString() => '$runtimeType{added=$added, updated=$updated, removed=$removed, skipped=$skipped, evicted=$evicted, itemFailures=${itemFailures.length}, fatal=$fatal}';
}

abstract class NextcloudSyncUseCase {
  // emits progress, completes with the result; never throws `NextcloudFailure` (it is reported in the result)
  Stream<NextcloudSyncProgress> run(NextcloudSyncRequest request);

  Future<NextcloudSyncResult> get lastResult;
}
