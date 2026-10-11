import 'dart:io';

import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/errors.dart';
import 'package:aves/model/nextcloud/mirror_store.dart';
import 'package:aves/model/nextcloud/mirror_store_impl.dart';
import 'package:aves/services/common/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../fake/nextcloud_mirror_index.dart';

void main() {
  late Directory tempDir;
  late FakeNextcloudMirrorIndex index;
  late NextcloudMirrorStoreImpl store;

  final epoch = DateTime.utc(2026, 10, 1);

  // `viewAllowanceBytes` defaults to 0 here so that `cacheLimitBytes` is the sync budget and the eviction
  // arithmetic reads off the one number; the view class tests give the allowance explicitly
  NextcloudAccount accountWith({String id = 'acc1', int cacheLimitBytes = 1000, int viewAllowanceBytes = 0}) => NextcloudAccount(
    id: id,
    serverUrl: Uri.parse('https://cloud.example.com'),
    username: 'alice',
    rootFolder: 'Photos',
    cacheLimitBytes: cacheLimitBytes,
    viewAllowanceBytes: viewAllowanceBytes,
  );

  NextcloudMirrorIndexEntry entryFor(
    String relativePath, {
    int sizeBytes = 0,
    NextcloudMirrorTier tier = NextcloudMirrorTier.original,
    bool pinned = false,
    DateTime? lastAccessAt,
    DateTime? modified,
  }) => NextcloudMirrorIndexEntry(
    relativePath: relativePath,
    etag: '"etag-$relativePath"',
    fileId: 42,
    tier: tier,
    placeholderReason: tier == NextcloudMirrorTier.placeholder ? NextcloudPlaceholderReason.policy : null,
    remoteSizeBytes: sizeBytes,
    localSizeBytes: sizeBytes,
    pinned: pinned,
    remoteLastModified: modified ?? epoch,
    downloadedAt: epoch,
    lastAccessAt: lastAccessAt ?? epoch,
  );

  // writes `size` bytes at the mirror location, as a completed download would
  Future<void> writeMirrorFile(NextcloudAccount account, String relativePath, int size) async {
    final file = File(store.localPathFor(account, relativePath));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.filled(size, 0));
  }

  Future<void> recordWritten(NextcloudAccount account, String relativePath, int size, {DateTime? lastAccessAt, DateTime? modified, NextcloudMirrorTier tier = NextcloudMirrorTier.original, bool pinned = false}) async {
    await writeMirrorFile(account, relativePath, size);
    await store.record(account, entryFor(relativePath, sizeBytes: size, lastAccessAt: lastAccessAt, modified: modified, tier: tier, pinned: pinned));
  }

  // what a demoted row must look like: no bytes, the reason recorded, the identity kept
  Future<void> expectDemoted(NextcloudAccount account, String relativePath, {required int remoteSizeBytes}) async {
    final row = (await store.lookup(account, relativePath))!;
    expect(row.tier, NextcloudMirrorTier.placeholder, reason: 'the row survives eviction');
    expect(row.placeholderReason, NextcloudPlaceholderReason.unfunded, reason: 'the budget took the bytes, so the budget can give them back');
    expect(row.localSizeBytes, 0);
    expect(row.remoteSizeBytes, remoteSizeBytes, reason: 'the identity of the file is kept');
    expect(row.etag, '"etag-$relativePath"');
    expect(await File(store.localPathFor(account, relativePath)).exists(), isFalse);
  }

  setUpAll(() {
    getIt.registerLazySingleton<p.Context>(() => p.Context(style: p.Style.posix));
  });

  tearDownAll(() async {
    await getIt.reset();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('aves_nextcloud_mirror');
    index = FakeNextcloudMirrorIndex();
    store = NextcloudMirrorStoreImpl(index, mirrorRoot: tempDir.path);
    await store.init();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('init', () {
    test('initializes the index and strips a trailing separator from the root', () async {
      final other = NextcloudMirrorStoreImpl(index, mirrorRoot: '${tempDir.path}/');
      await other.init();
      expect(other.mirrorRoot, tempDir.path);
      expect(index.initCount, 2);
    });

    test('fails instead of falling back to a relative root', () async {
      final broken = NextcloudMirrorStoreImpl(index, mirrorRoot: '');
      await expectLater(broken.init(), throwsA(isA<NextcloudLocalStorageFailure>()));
    });

    test('rejects use before init', () {
      final uninitialized = NextcloudMirrorStoreImpl(index, mirrorRoot: tempDir.path);
      expect(() => uninitialized.localPathFor(accountWith(), 'a.jpg'), throwsStateError);
    });
  });

  group('paths', () {
    test('keeps the remote tree verbatim under the account directory', () {
      final account = accountWith();
      expect(store.localPathFor(account, 'trip/day1/a.jpg'), '${tempDir.path}/acc1/trip/day1/a.jpg');
      expect(store.localPathFor(account, ''), '${tempDir.path}/acc1');
    });

    test('normalizes before joining', () {
      expect(store.localPathFor(accountWith(), '/trip/a.jpg/'), '${tempDir.path}/acc1/trip/a.jpg');
    });

    test('refuses a relative path that would escape the account directory', () {
      expect(() => store.localPathFor(accountWith(), '../other/a.jpg'), throwsA(isA<NextcloudPathEscapeFailure>()));
      expect(() => store.localPathFor(accountWith(), 'trip/../../a.jpg'), throwsA(isA<NextcloudPathEscapeFailure>()));
    });

    test('refuses an account whose id is not a safe segment', () {
      // the account store validates this; the mirror store does not trust it, because the value becomes a path
      final hostile = accountWith(id: '../../databases');
      expect(() => store.localPathFor(hostile, 'a.jpg'), throwsA(isA<NextcloudPathEscapeFailure>()));
      expect(() => store.relativePathFor(hostile, '${tempDir.path}/a.jpg'), throwsA(isA<NextcloudPathEscapeFailure>()));
    });

    test('maps a local path back to its relative path', () {
      final account = accountWith();
      expect(store.relativePathFor(account, '${tempDir.path}/acc1/trip/day1/a.jpg'), 'trip/day1/a.jpg');
      expect(store.relativePathFor(account, '${tempDir.path}/acc1'), '');
      expect(store.relativePathFor(account, '${tempDir.path}/acc1/'), '');
    });

    test('maps a local path outside the account mirror to null', () {
      final account = accountWith();
      expect(store.relativePathFor(account, '${tempDir.path}/acc2/a.jpg'), isNull);
      expect(store.relativePathFor(account, '${tempDir.path}/acc1suffix/a.jpg'), isNull);
      expect(store.relativePathFor(account, '/storage/emulated/0/Pictures/a.jpg'), isNull);
    });

    test('round trips every relative path it accepts', () {
      final account = accountWith();
      for (final relativePath in ['a.jpg', 'trip/a.jpg', 'trip/day 1/a b.jpg', 'trip/日本/a.jpg']) {
        expect(store.relativePathFor(account, store.localPathFor(account, relativePath)), relativePath);
      }
    });
  });

  group('record', () {
    test('takes the size from disk rather than from the caller', () async {
      final account = accountWith();
      await writeMirrorFile(account, 'trip/a.jpg', 120);
      // a caller reporting the wrong size must not be able to corrupt the accounting
      await store.record(account, entryFor('trip/a.jpg', sizeBytes: 1));

      expect((await store.lookup(account, 'trip/a.jpg'))!.localSizeBytes, 120);
      expect(await store.usedBytes(account), 120);
    });

    test('refuses to record a row for a file that is not there', () async {
      final account = accountWith();
      await expectLater(
        store.record(account, entryFor('trip/missing.jpg', sizeBytes: 10)),
        throwsA(isA<NextcloudNotFoundFailure>()),
      );
      expect(await store.listAll(account), isEmpty);
    });

    test('refuses to record a directory', () async {
      final account = accountWith();
      await Directory(store.localPathFor(account, 'trip')).create(recursive: true);
      await expectLater(store.record(account, entryFor('trip')), throwsA(isA<NextcloudNotFoundFailure>()));
    });

    test('normalizes the recorded path', () async {
      final account = accountWith();
      await writeMirrorFile(account, 'trip/a.jpg', 5);
      await store.record(account, entryFor('/trip/a.jpg'));
      expect(await store.lookup(account, 'trip/a.jpg'), isNotNull);
    });

    test('keeps accounts separate', () async {
      final a = accountWith(id: 'acc1');
      final b = accountWith(id: 'acc2');
      await recordWritten(a, 'a.jpg', 10);
      await recordWritten(b, 'a.jpg', 20);

      expect(await store.usedBytes(a), 10);
      expect(await store.usedBytes(b), 20);
      expect(File(store.localPathFor(a, 'a.jpg')).parent.path, isNot(File(store.localPathFor(b, 'a.jpg')).parent.path));
    });
  });

  group('remove', () {
    test('deletes the file and the row', () async {
      final account = accountWith();
      await recordWritten(account, 'trip/a.jpg', 10);

      await store.remove(account, 'trip/a.jpg');

      expect(await File(store.localPathFor(account, 'trip/a.jpg')).exists(), isFalse);
      expect(await store.lookup(account, 'trip/a.jpg'), isNull);
      expect(await store.usedBytes(account), 0);
    });

    test('is a no-op for an unknown path', () async {
      final account = accountWith();
      await expectLater(store.remove(account, 'trip/unknown.jpg'), completes);
    });

    test('never deletes the account directory itself', () async {
      final account = accountWith();
      await recordWritten(account, 'a.jpg', 10);

      await store.remove(account, '');

      expect(await Directory(store.localPathFor(account, '')).exists(), isTrue);
      expect(await store.lookup(account, 'a.jpg'), isNotNull);
    });
  });

  group('touch', () {
    test('moves the item to the back of the eviction queue', () async {
      final account = accountWith();
      final accessedAt = epoch.add(const Duration(days: 1));
      await recordWritten(account, 'a.jpg', 10);

      await store.touch(account, 'a.jpg', accessedAt);

      expect((await store.lookup(account, 'a.jpg'))!.lastAccessAt, accessedAt);
    });

    test('does not create a row for an unknown path', () async {
      final account = accountWith();
      await store.touch(account, 'unknown.jpg', epoch);
      expect(await store.listAll(account), isEmpty);
    });
  });

  // `evictToFit` reports removals and demotions separately; these cases are about removals, and the
  // outcome's own shape is asserted in its own test below.
  // eviction never removes a row: everything it reports is a demotion
  Future<Set<String>> evict(NextcloudAccount account, {int reserveBytes = 0}) async {
    final outcome = await store.evictToFit(account, reserveBytes: reserveBytes);
    expect(outcome.removed, isEmpty, reason: 'eviction demotes, it never removes');
    return outcome.demoted;
  }

  Future<NextcloudEvictionOutcome> evictOldestFirstOutcome(NextcloudAccount account, {int reserveBytes = 0, NextcloudSyncFunding? funding}) async {
    final outcome = await store.evictToFit(account, reserveBytes: reserveBytes, order: NextcloudEvictionOrder.oldestFirst, funding: funding);
    expect(outcome.removed, isEmpty, reason: 'eviction demotes, it never removes');
    return outcome;
  }

  Future<Set<String>> evictOldestFirst(NextcloudAccount account, {int reserveBytes = 0, NextcloudSyncFunding? funding}) async {
    final outcome = await store.evictToFit(account, reserveBytes: reserveBytes, order: NextcloudEvictionOrder.oldestFirst, funding: funding);
    expect(outcome.removed, isEmpty, reason: 'eviction demotes, it never removes');
    return outcome.demoted;
  }

  group('evictToFit', () {
    test('does nothing while the account is within its limit', () async {
      final account = accountWith(cacheLimitBytes: 100);
      await recordWritten(account, 'a.jpg', 40);

      expect(await evict(account), isEmpty);
      expect(await store.usedBytes(account), 40);
    });

    test('evicts least recently accessed first and stops as soon as it fits', () async {
      final account = accountWith(cacheLimitBytes: 100);
      await recordWritten(account, 'old.jpg', 50, lastAccessAt: epoch);
      await recordWritten(account, 'mid.jpg', 50, lastAccessAt: epoch.add(const Duration(days: 1)));
      await recordWritten(account, 'new.jpg', 50, lastAccessAt: epoch.add(const Duration(days: 2)));

      final evicted = await evict(account);

      expect(evicted, {'old.jpg'});
      expect(await store.usedBytes(account), 100);
      await expectDemoted(account, 'old.jpg', remoteSizeBytes: 50);
      expect(await File(store.localPathFor(account, 'mid.jpg')).exists(), isTrue);
    });

    test('makes room for the reservation of an incoming download', () async {
      final account = accountWith(cacheLimitBytes: 100);
      await recordWritten(account, 'old.jpg', 40, lastAccessAt: epoch);
      await recordWritten(account, 'new.jpg', 40, lastAccessAt: epoch.add(const Duration(days: 1)));

      final evicted = await evict(account, reserveBytes: 30);

      expect(evicted, {'old.jpg'});
      expect(await store.usedBytes(account), 40);
    });

    test('reports every eviction even when the reservation can never fit', () async {
      final account = accountWith(cacheLimitBytes: 100);
      await recordWritten(account, 'a.jpg', 40, lastAccessAt: epoch);
      await recordWritten(account, 'b.jpg', 40, lastAccessAt: epoch.add(const Duration(days: 1)));

      // the caller decides what to do about it; the mirror must still not under-report what it took
      final evicted = await evict(account, reserveBytes: 500);

      expect(evicted, {'a.jpg', 'b.jpg'});
      expect(await store.usedBytes(account), 0);
      expect((await store.listAll(account)).map((row) => row.tier), everyElement(NextcloudMirrorTier.placeholder), reason: 'the rows stay');
    });

    test('treats a limit of zero as "mirror nothing"', () async {
      final account = accountWith(cacheLimitBytes: 0);
      await recordWritten(account, 'a.jpg', 10);

      expect(await evict(account), {'a.jpg'});
    });

    test('leaves other accounts untouched', () async {
      final a = accountWith(id: 'acc1', cacheLimitBytes: 0);
      final b = accountWith(id: 'acc2', cacheLimitBytes: 1000);
      await recordWritten(a, 'a.jpg', 10);
      await recordWritten(b, 'b.jpg', 10);

      await evict(a);

      expect(await store.listAll(b), isNotEmpty);
      expect(await File(store.localPathFor(b, 'b.jpg')).exists(), isTrue);
    });

    test('still reports what it evicted when one row rewrite fails', () async {
      final account = accountWith(cacheLimitBytes: 0);
      await recordWritten(account, 'stuck.jpg', 10, lastAccessAt: epoch);
      await recordWritten(account, 'ok.jpg', 10, lastAccessAt: epoch.add(const Duration(days: 1)));
      // the oldest item is the one whose row cannot be rewritten, so a propagating failure would hide both
      index.failPutFor.add('stuck.jpg');

      final evicted = await evict(account);

      // a demotion deletes the file before rewriting the row, so `stuck.jpg`'s bytes went even though its
      // row still says `original`. It has to be reported: the caller tells the sink about this set, and an
      // entry still describing bytes that are gone is exactly what the sink must not keep.
      expect(evicted, {'ok.jpg', 'stuck.jpg'});
      expect(await File(store.localPathFor(account, 'stuck.jpg')).exists(), isFalse);
      // the row stays as it was, so the bytes stay accounted for: over-reporting only ever evicts more
      expect((await store.lookup(account, 'stuck.jpg'))?.tier, NextcloudMirrorTier.original);
      expect(await store.usedBytes(account), 10);
    });

    test('reports a row whose file was already missing', () async {
      final account = accountWith(cacheLimitBytes: 0);
      // a row with no file on disk: nothing to delete, and the row rewrite then fails
      await writeMirrorFile(account, 'ghost.jpg', 10);
      await store.record(account, entryFor('ghost.jpg', sizeBytes: 10));
      await File(store.localPathFor(account, 'ghost.jpg')).delete();
      index.failPutFor.add('ghost.jpg');

      expect(await evict(account), {'ghost.jpg'});
    });

    test('stops instead of looping when nothing on the page can go', () async {
      final account = accountWith(cacheLimitBytes: 0);
      await recordWritten(account, 'stuck.jpg', 10);
      index.failPutFor.add('stuck.jpg');

      // the path is still reported (its bytes went), but the row left at the head of the LRU order
      // must not count as progress, or the next round would query the same page forever
      expect(await evict(account), {'stuck.jpg'});
      expect(index.getLeastRecentlyAccessedCalls, 1);
      expect(await store.usedBytes(account), 10);
    });

    test('pages through more candidates than one query returns', () async {
      // 300 rows against a 256-row page: a single page cannot bring the account under the limit
      final account = accountWith(cacheLimitBytes: 0);
      for (var i = 0; i < 300; i++) {
        await recordWritten(account, 'photo$i.jpg', 1, lastAccessAt: epoch.add(Duration(minutes: i)));
      }

      final evicted = await evict(account);

      expect(evicted.length, 300);
      expect(await store.usedBytes(account), 0);
      expect(index.getLeastRecentlyAccessedCalls, greaterThan(1));
    });
  });

  group('view rows', () {
    // a view row as a view fetch leaves it: the view bytes at the path, the grid bytes as the sidecar
    Future<void> recordView(NextcloudAccount account, String relativePath, {required int viewBytes, required int gridBytes, DateTime? lastAccessAt, DateTime? modified}) async {
      await writeMirrorFile(account, relativePath, viewBytes);
      final sidecar = File(store.sidecarPathFor(account, relativePath));
      await sidecar.parent.create(recursive: true);
      await sidecar.writeAsBytes(List.filled(gridBytes, 0));
      await store.record(account, entryFor(relativePath, sizeBytes: viewBytes + gridBytes, tier: NextcloudMirrorTier.view, lastAccessAt: lastAccessAt, modified: modified));
    }

    Future<NextcloudEvictionOutcome> evictViews(NextcloudAccount account, {int reserveBytes = 0}) async {
      final outcome = await store.evictToFit(account, reserveBytes: reserveBytes, order: NextcloudEvictionOrder.viewRowsLeastRecentlyAccessed);
      expect(outcome.removed, isEmpty, reason: 'eviction demotes, it never removes');
      return outcome;
    }

    Future<void> expectGrid(NextcloudAccount account, String relativePath, {required int gridBytes}) async {
      final row = (await store.lookup(account, relativePath))!;
      expect(row.tier, NextcloudMirrorTier.grid);
      expect(row.localSizeBytes, gridBytes, reason: 'read back from the sidecar now in place');
      expect(row.sidecarSizeBytes, 0);
      expect(await File(store.localPathFor(account, relativePath)).length(), gridBytes);
      expect(await File(store.sidecarPathFor(account, relativePath)).exists(), isFalse);
    }

    test('the sidecar lives apart from the mirror tree, where no server name can reach it', () {
      final account = accountWith();
      expect(store.sidecarPathFor(account, 'trip/a.jpg'), '${tempDir.path}/sidecars/acc1/trip/a.jpg');
      // a legal Nextcloud file name, and nothing beside it is a sidecar
      expect(store.localPathFor(account, 'notes.grid'), '${tempDir.path}/acc1/notes.grid');
      expect(store.localPathFor(account, 'a.jpg.grid'), '${tempDir.path}/acc1/a.jpg.grid');
      expect(() => store.sidecarPathFor(account, ''), throwsA(isA<NextcloudPathEscapeFailure>()));
      expect(() => store.sidecarPathFor(account, '../a.jpg'), throwsA(isA<NextcloudPathEscapeFailure>()));
    });

    test('the sidecar tree is no account, and the one id that would collide with it is refused where it would matter', () {
      expect(store.accountIdFor('${tempDir.path}/acc1/trip/a.jpg'), 'acc1');
      expect(store.accountIdFor('${tempDir.path}/acc1'), isNull);
      expect(store.accountIdFor('${tempDir.path}/sidecars/acc1/trip/a.jpg'), isNull);
      expect(store.accountIdFor('/storage/emulated/0/Pictures/a.jpg'), isNull);
      // not at load, which could only make an account already on disk fail to load
      final collides = accountWith(id: NextcloudMirrorStore.sidecarsDirName);
      expect(() => store.localPathFor(collides, 'a.jpg'), throwsA(isA<NextcloudPathEscapeFailure>()));
    });

    test('a view row counts both files, with the sidecar as its sync-class share', () async {
      final account = accountWith(cacheLimitBytes: 100, viewAllowanceBytes: 40);
      await recordView(account, 'a.jpg', viewBytes: 30, gridBytes: 4);
      await recordWritten(account, 'b.jpg', 10, tier: NextcloudMirrorTier.grid);

      final row = (await store.lookup(account, 'a.jpg'))!;
      expect(row.localSizeBytes, 34);
      expect(row.sidecarSizeBytes, 4);
      expect(row.syncClassBytes, 4);
      expect(row.viewClassBytes, 30);
      expect(await store.usedBytes(account), 44, reason: 'the whole mirror: what disk reconciliation compares against');
      expect(await store.usedBytes(account, of: NextcloudBudgetClass.sync), 14);
      expect(await store.usedBytes(account, of: NextcloudBudgetClass.view), 30);
      expect(await store.freeBytes(account, NextcloudBudgetClass.sync), 60 - 14);
      expect(await store.freeBytes(account, NextcloudBudgetClass.view), 40 - 30);
    });

    test('a view row without its sidecar is a failure, like a row without its file', () async {
      final account = accountWith(cacheLimitBytes: 100);
      await writeMirrorFile(account, 'a.jpg', 30);

      await expectLater(store.record(account, entryFor('a.jpg', sizeBytes: 30, tier: NextcloudMirrorTier.view)), throwsA(isA<NextcloudNotFoundFailure>()));
      expect(await store.lookup(account, 'a.jpg'), isNull);
    });

    test('a row at any other tier drops a stale sidecar, so nothing on disk is claimed by no row', () async {
      final account = accountWith(cacheLimitBytes: 100, viewAllowanceBytes: 40);
      await recordView(account, 'a.jpg', viewBytes: 30, gridBytes: 4);

      // the sync re-fetched the file at grid over the view bytes
      await writeMirrorFile(account, 'a.jpg', 5);
      await store.record(account, entryFor('a.jpg', sizeBytes: 5, tier: NextcloudMirrorTier.grid));

      final row = (await store.lookup(account, 'a.jpg'))!;
      expect(row.localSizeBytes, 5);
      expect(row.sidecarSizeBytes, 0);
      expect(await File(store.sidecarPathFor(account, 'a.jpg')).exists(), isFalse);
      expect(await store.usedBytes(account, of: NextcloudBudgetClass.view), 0);

      // and a placeholder written over a view row takes both files
      await recordView(account, 'b.jpg', viewBytes: 30, gridBytes: 4);
      await store.record(account, entryFor('b.jpg', sizeBytes: 34, tier: NextcloudMirrorTier.placeholder));
      expect(await File(store.localPathFor(account, 'b.jpg')).exists(), isFalse);
      expect(await File(store.sidecarPathFor(account, 'b.jpg')).exists(), isFalse);
      expect(await store.usedBytes(account), 5);
    });

    test('remove and purge take the sidecar with them', () async {
      final account = accountWith(cacheLimitBytes: 100, viewAllowanceBytes: 40);
      await recordView(account, 'a.jpg', viewBytes: 30, gridBytes: 4);
      await recordView(account, 'b.jpg', viewBytes: 30, gridBytes: 4);

      await store.remove(account, 'a.jpg');
      expect(await File(store.sidecarPathFor(account, 'a.jpg')).exists(), isFalse);
      expect(await File(store.sidecarPathFor(account, 'b.jpg')).exists(), isTrue);

      await store.purge(account);
      expect(await Directory('${tempDir.path}/sidecars/acc1').exists(), isFalse);
    });

    test('the view order gives up the least recently opened view row, back to its grid bytes, and nothing else', () async {
      final account = accountWith(cacheLimitBytes: 1000, viewAllowanceBytes: 60);
      await recordView(account, 'old.jpg', viewBytes: 30, gridBytes: 4, lastAccessAt: epoch);
      await recordView(account, 'new.jpg', viewBytes: 30, gridBytes: 4, lastAccessAt: epoch.add(const Duration(days: 1)));
      await recordWritten(account, 'never.jpg', 10, tier: NextcloudMirrorTier.grid, lastAccessAt: epoch.subtract(const Duration(days: 1)));
      await recordWritten(account, 'v.mp4', 10, lastAccessAt: epoch.subtract(const Duration(days: 1)));
      final syncBytes = await store.usedBytes(account, of: NextcloudBudgetClass.sync);

      final outcome = await evictViews(account, reserveBytes: 30);

      expect(outcome.demotedToGrid, {'old.jpg'});
      expect(outcome.demoted, isEmpty, reason: 'nothing lost its bytes');
      await expectGrid(account, 'old.jpg', gridBytes: 4);
      expect((await store.lookup(account, 'new.jpg'))!.tier, NextcloudMirrorTier.view);
      expect(await store.usedBytes(account, of: NextcloudBudgetClass.view), 30);
      expect(await store.usedBytes(account, of: NextcloudBudgetClass.sync), syncBytes, reason: 'the grid bytes moved from the sidecar to the path: same class, same count');

      // a reservation no view row can make room for takes the last view row and stops: the sync-held
      // rows are not browsing's to spend, however old, and the caller is told it does not fit
      final hopeless = await evictViews(account, reserveBytes: 500);
      expect(hopeless.demotedToGrid, {'new.jpg'});
      expect(hopeless.demoted, isEmpty);
      expect((await store.lookup(account, 'never.jpg'))!.tier, NextcloudMirrorTier.grid);
      expect((await store.lookup(account, 'v.mp4'))!.tier, NextcloudMirrorTier.original);
      expect(await store.freeBytes(account, NextcloudBudgetClass.view), 60);
    });

    test('demoteToGrid makes the view order\'s transition for one row on request, and refuses when there are no grid bytes to go back to', () async {
      final account = accountWith(cacheLimitBytes: 1000, viewAllowanceBytes: 60);
      await recordView(account, 'a.jpg', viewBytes: 30, gridBytes: 4);
      await recordView(account, 'b.jpg', viewBytes: 30, gridBytes: 4);
      await recordWritten(account, 'c.jpg', 10, tier: NextcloudMirrorTier.grid);

      await store.demoteToGrid(account, 'a.jpg');

      await expectGrid(account, 'a.jpg', gridBytes: 4);
      expect((await store.lookup(account, 'b.jpg'))!.tier, NextcloudMirrorTier.view, reason: 'one row, the one asked for');
      expect(await store.usedBytes(account, of: NextcloudBudgetClass.view), 30);

      // a grid row, an unknown path, a view row whose sidecar is gone: nothing to put in the view bytes' place
      await expectLater(store.demoteToGrid(account, 'c.jpg'), throwsA(isA<NextcloudNotFoundFailure>()));
      await expectLater(store.demoteToGrid(account, 'never.jpg'), throwsA(isA<NextcloudNotFoundFailure>()));
      await File(store.sidecarPathFor(account, 'b.jpg')).delete();
      await expectLater(store.demoteToGrid(account, 'b.jpg'), throwsA(isA<NextcloudNotFoundFailure>()));
      expect((await store.lookup(account, 'b.jpg'))!.tier, NextcloudMirrorTier.view, reason: 'refused before anything is written');
      expect(await File(store.localPathFor(account, 'b.jpg')).length(), 30, reason: 'the view bytes stay: deleted with no grid bytes to put back, the row would claim a file that is not there');
    });

    test('a sync order reaching a view row takes its grid bytes at the row\'s own place in the order, not after the newer rows on the page', () async {
      // the sync budget is `cacheLimitBytes` here (allowance 0); the view row sits in it as its 4 sidecar bytes
      final account = accountWith(cacheLimitBytes: 10, viewAllowanceBytes: 0);
      await recordView(account, 'old.jpg', viewBytes: 30, gridBytes: 4, modified: epoch);
      await recordWritten(account, 'new.jpg', 4, tier: NextcloudMirrorTier.grid, modified: epoch.add(const Duration(days: 1)));
      expect(await store.usedBytes(account, of: NextcloudBudgetClass.sync), 8);

      final outcome = await evictOldestFirstOutcome(account, reserveBytes: 6);

      // oldest first: the opened photo loses its thumbnail before the never-opened newer one, as it would
      // have unopened, and the row that went both ways in one pass is reported once, as bytes gone
      expect(outcome.demoted, {'old.jpg'});
      expect(outcome.demotedToGrid, isEmpty);
      await expectDemoted(account, 'old.jpg', remoteSizeBytes: 34);
      expect(await File(store.sidecarPathFor(account, 'old.jpg')).exists(), isFalse);
      expect((await store.lookup(account, 'new.jpg'))!.tier, NextcloudMirrorTier.grid);
      expect(await store.usedBytes(account, of: NextcloudBudgetClass.sync), 4);
      expect(await store.usedBytes(account, of: NextcloudBudgetClass.view), 0);
    });

    test('a sync class within its budget leaves a view row alone, however many view bytes it holds', () async {
      // 34 bytes on disk against a 10-byte sync budget, 4 of them sync-class: nothing is over
      final account = accountWith(cacheLimitBytes: 10, viewAllowanceBytes: 0);
      await recordView(account, 'old.jpg', viewBytes: 30, gridBytes: 4, modified: epoch);
      await recordWritten(account, 'new.jpg', 4, tier: NextcloudMirrorTier.grid, modified: epoch.add(const Duration(days: 1)));

      expect((await evictOldestFirstOutcome(account)).isEmpty, isTrue, reason: 'the view bytes are not the sync\'s concern');
      expect((await store.lookup(account, 'old.jpg'))!.tier, NextcloudMirrorTier.view);
      expect(await File(store.sidecarPathFor(account, 'old.jpg')).exists(), isTrue);
    });

    test('a view row whose sidecar is missing demotes to a placeholder like any other row', () async {
      final account = accountWith(cacheLimitBytes: 1000, viewAllowanceBytes: 20);
      await recordView(account, 'a.jpg', viewBytes: 30, gridBytes: 4);
      await File(store.sidecarPathFor(account, 'a.jpg')).delete();

      final outcome = await evictViews(account);

      expect(outcome.demoted, {'a.jpg'});
      expect(outcome.demotedToGrid, isEmpty);
      await expectDemoted(account, 'a.jpg', remoteSizeBytes: 34);
    });

    test('sweepStraySidecars deletes a sidecar whose row is not a view row and keeps one whose row is', () async {
      final account = accountWith(cacheLimitBytes: 1000, viewAllowanceBytes: 40);
      await recordView(account, 'kept.jpg', viewBytes: 30, gridBytes: 4);
      await recordWritten(account, 'grid.jpg', 4, tier: NextcloudMirrorTier.grid);
      for (final stray in ['grid.jpg', 'unknown/x.jpg']) {
        final file = File(store.sidecarPathFor(account, stray));
        await file.parent.create(recursive: true);
        await file.writeAsBytes([0]);
      }
      final other = accountWith(id: 'acc2');
      await recordView(other, 'theirs.jpg', viewBytes: 30, gridBytes: 4);

      await store.sweepStraySidecars(account);

      expect(await File(store.sidecarPathFor(account, 'kept.jpg')).exists(), isTrue);
      expect(await File(store.sidecarPathFor(account, 'grid.jpg')).exists(), isFalse);
      expect(await File(store.sidecarPathFor(account, 'unknown/x.jpg')).exists(), isFalse);
      expect(await File(store.sidecarPathFor(other, 'theirs.jpg')).exists(), isTrue);
    });
  });

  group('purge', () {
    test('removes the account directory and all of its rows', () async {
      final account = accountWith();
      await recordWritten(account, 'trip/day1/a.jpg', 10);

      await store.purge(account);

      expect(await Directory(store.localPathFor(account, '')).exists(), isFalse);
      expect(await store.listAll(account), isEmpty);
      expect(await store.usedBytes(account), 0);
    });

    test('leaves other accounts untouched', () async {
      final a = accountWith(id: 'acc1');
      final b = accountWith(id: 'acc2');
      await recordWritten(a, 'a.jpg', 10);
      await recordWritten(b, 'b.jpg', 10);

      await store.purge(a);

      expect(await File(store.localPathFor(b, 'b.jpg')).exists(), isTrue);
      expect(await store.listAll(b), isNotEmpty);
    });

    test('succeeds for an account that never mirrored anything', () async {
      await expectLater(store.purge(accountWith(id: 'acc3')), completes);
    });

    test('drops the rows even when the directory cannot be deleted', () async {
      final account = accountWith();
      await recordWritten(account, 'a.jpg', 10);
      // make the mirror root unwritable so the account directory cannot be unlinked
      await Process.run('chmod', ['500', tempDir.path]);
      addTearDown(() => Process.run('chmod', ['700', tempDir.path]));

      var deleteFailed = false;
      try {
        await store.purge(account);
      } on FileSystemException {
        deleteFailed = true;
      }

      if (!deleteFailed) {
        // running as a user that ignores the mode bits; the premise of this test does not hold here
        markTestSkipped('the directory delete succeeded despite mode 500');
        return;
      }
      // rows claiming files that may be gone must not outlive the account
      expect(await store.listAll(account), isEmpty);
      expect(await store.usedBytes(account), 0);
    });
  });

  group('placeholder rows', () {
    test('a placeholder is recorded with no file and no local bytes', () async {
      final account = accountWith(cacheLimitBytes: 100);

      // deliberately no `writeMirrorFile`: a placeholder exists so the item can appear in the gallery,
      // and the whole point is that it has no bytes
      await store.record(account, entryFor('remote-only.mp4', sizeBytes: 3000000000, tier: NextcloudMirrorTier.placeholder));

      final row = await store.lookup(account, 'remote-only.mp4');
      expect(row!.tier, NextcloudMirrorTier.placeholder);
      expect(row.localSizeBytes, 0, reason: 'nothing is on disk, so nothing may count against the budget');
      expect(row.remoteSizeBytes, 3000000000, reason: 'the remote size is what a threshold compares, and it comes from the caller');
      expect(await store.usedBytes(account), 0);
    });

    test('any other tier without its bytes is still a failure', () async {
      final account = accountWith(cacheLimitBytes: 100);

      // the placeholder branch must not become a way to record a row for bytes that were supposed to be
      // there and are not: that is the case that makes `usedBytes` lie forever
      await expectLater(
        store.record(account, entryFor('missing.jpg', sizeBytes: 40, tier: NextcloudMirrorTier.grid)),
        throwsA(isA<NextcloudNotFoundFailure>()),
      );
      expect(await store.lookup(account, 'missing.jpg'), isNull);
    });

    test('a placeholder written over a row that holds bytes deletes them, so the accounting stays honest', () async {
      final account = accountWith(cacheLimitBytes: 100);
      await recordWritten(account, 'changed.jpg', 40, tier: NextcloudMirrorTier.grid);
      expect(await store.usedBytes(account), 40);

      // a changed file the budget cannot fund, or that the server can no longer derive: the row becomes a
      // placeholder, and the bytes it held must not stay on disk under a row that claims none
      await store.record(account, entryFor('changed.jpg', sizeBytes: 90, tier: NextcloudMirrorTier.placeholder));

      final row = await store.lookup(account, 'changed.jpg');
      expect(row!.tier, NextcloudMirrorTier.placeholder);
      expect(row.localSizeBytes, 0);
      expect(await File(store.localPathFor(account, 'changed.jpg')).exists(), isFalse, reason: 'the bytes went back to the budget');
      expect(await store.usedBytes(account), 0);
    });

    test('a placeholder is never a victim and does not stall the rows behind it', () async {
      final account = accountWith(cacheLimitBytes: 100);
      // `aaa` so it sorts ahead of the row with bytes: a placeholder is never viewed, so its `lastAccessAt`
      // never moves and it really does sit at the head of the eviction order in practice
      await store.record(account, entryFor('aaa-remote-only.mp4', sizeBytes: 3000000000, tier: NextcloudMirrorTier.placeholder));
      await recordWritten(account, 'zzz-big.jpg', 140);

      final demoted = await evict(account);

      // taking the placeholder would reclaim nothing and cost the gallery entry, and the next sync would
      // re-list and recreate it, every single time the budget bites
      expect(demoted, {'zzz-big.jpg'});
      expect(await store.lookup(account, 'aaa-remote-only.mp4'), isNotNull, reason: 'a placeholder holds no bytes, so evicting it frees nothing and only makes a hole');
      expect(await store.usedBytes(account), 0);
    });

    test('a mirror of nothing but placeholders stops eviction instead of looping', () async {
      final account = accountWith(cacheLimitBytes: 0);
      await store.record(account, entryFor('a.mp4', sizeBytes: 3000000000, tier: NextcloudMirrorTier.placeholder));
      await store.record(account, entryFor('b.mp4', sizeBytes: 3000000000, tier: NextcloudMirrorTier.placeholder));

      // `used` is already 0 so there is nothing to do; the point is that excluding placeholders from the
      // candidate query cannot turn into an empty-page loop
      expect(await evict(account), isEmpty);
      expect((await store.listAll(account)).length, 2);
    });
  });

  group('eviction outcome', () {
    test('reports demotions and never removals: a victim keeps its row as an unfunded placeholder', () async {
      final account = accountWith(cacheLimitBytes: 100);
      await recordWritten(account, 'a.jpg', 140);

      final outcome = await store.evictToFit(account);

      expect(outcome.demoted, {'a.jpg'});
      // a removed row is a listed item with no row: the next sync re-lists the whole tree and funds the
      // gap by evicting the next row, forever. A demoted row is still in the gallery and still reflects
      // the server, so the sync has nothing to do about it.
      expect(outcome.removed, isEmpty);
      expect(outcome.touched, {'a.jpg'});
      expect(outcome.isEmpty, isFalse);
      expect(NextcloudEvictionOutcome.none.isEmpty, isTrue);
      await expectDemoted(account, 'a.jpg', remoteSizeBytes: 140);
      expect(await store.usedBytes(account), 0, reason: 'the demoted bytes no longer count');
    });

    test('a demoted row keeps its pin out of the question: a pinned row is never a victim in either order', () async {
      final account = accountWith(cacheLimitBytes: 0);
      await recordWritten(account, 'kept.jpg', 10, pinned: true);
      await recordWritten(account, 'goes.jpg', 10);

      expect(await evictOldestFirst(account), {'goes.jpg'});
      expect((await store.lookup(account, 'kept.jpg'))?.tier, NextcloudMirrorTier.original);
      expect(await store.usedBytes(account), 10);
    });
  });

  group('sync order', () {
    final day1 = epoch, day2 = epoch.add(const Duration(days: 1)), day3 = epoch.add(const Duration(days: 2));

    test('takes the oldest remoteLastModified first, whatever was viewed last', () async {
      final account = accountWith(cacheLimitBytes: 100);
      // the oldest file is the one viewed most recently: under the access order it would be the last to go
      await recordWritten(account, 'old.jpg', 50, modified: day1, lastAccessAt: day3);
      await recordWritten(account, 'mid.jpg', 50, modified: day2, lastAccessAt: day2);
      await recordWritten(account, 'new.jpg', 50, modified: day3, lastAccessAt: day1);

      expect(await evictOldestFirst(account), {'old.jpg'});
      expect(await store.usedBytes(account), 100);
    });

    test('takes every original before any grid row, however old the grid row is', () async {
      final account = accountWith(cacheLimitBytes: 60);
      await recordWritten(account, 'thumb.jpg', 10, modified: day1, tier: NextcloudMirrorTier.grid);
      await recordWritten(account, 'v1.mp4', 50, modified: day2);
      await recordWritten(account, 'v2.mp4', 50, modified: day3);

      // 110 against 60: one original is enough, and it is the older one, not the oldest row
      expect(await evictOldestFirst(account), {'v1.mp4'});
      expect((await store.lookup(account, 'thumb.jpg'))?.tier, NextcloudMirrorTier.grid, reason: 'a library of thumbnails beats whole copies of a few files');
    });

    test('funding an original may only take originals older than it, never a newer one and never a grid row', () async {
      final account = accountWith(cacheLimitBytes: 100);
      await recordWritten(account, 'thumb.jpg', 10, modified: day1, tier: NextcloudMirrorTier.grid);
      await recordWritten(account, 'older.mp4', 40, modified: day1);
      await recordWritten(account, 'newer.mp4', 40, modified: day3);

      // 90 held, 95 reserved: a target of 5 that every row together could meet. The bound leaves only
      // `older.mp4` to take, so the pass stops at 50 with the reservation unmet, rather than taking the
      // newer original (which the sync ranks above the item) or the grid row (which outranks every original).
      final funding = NextcloudSyncFunding(tier: NextcloudMirrorTier.original, lastModified: day2);
      expect(await evictOldestFirst(account, reserveBytes: 95, funding: funding), {'older.mp4'});
      expect((await store.lookup(account, 'newer.mp4'))?.tier, NextcloudMirrorTier.original, reason: 'a fetch never evicts what the sync ranks above it');
      expect((await store.lookup(account, 'thumb.jpg'))?.tier, NextcloudMirrorTier.grid);
      // the caller sees that it did not fit and records the item unfunded
      expect(await store.usedBytes(account), 50);
    });

    test('funding a grid row may take any original, and only grid rows older than it', () async {
      final account = accountWith(cacheLimitBytes: 100);
      await recordWritten(account, 'older-thumb.jpg', 10, modified: day1, tier: NextcloudMirrorTier.grid);
      await recordWritten(account, 'newer-thumb.jpg', 10, modified: day3, tier: NextcloudMirrorTier.grid);
      await recordWritten(account, 'newer.mp4', 80, modified: day3);

      // 100 held, 40 reserved: the newer original goes first (the whole class ranks below grid rows), then
      // the older thumbnail; the newer thumbnail is out of bounds
      final funding = NextcloudSyncFunding(tier: NextcloudMirrorTier.grid, lastModified: day2);
      expect(await evictOldestFirst(account, reserveBytes: 40, funding: funding), {'newer.mp4'});
      expect(await store.usedBytes(account), 20);

      // and with more to reclaim than the originals hold, the bound on grid rows is what stops it
      expect(await evictOldestFirst(account, reserveBytes: 95, funding: funding), {'older-thumb.jpg'});
      expect((await store.lookup(account, 'newer-thumb.jpg'))?.tier, NextcloudMirrorTier.grid);
      expect(await store.usedBytes(account), 10);
    });

    test('a sweep with nothing to fund is unbounded: originals oldest first, then grid rows oldest first', () async {
      final account = accountWith(cacheLimitBytes: 0);
      await recordWritten(account, 'thumb-old.jpg', 10, modified: day1, tier: NextcloudMirrorTier.grid);
      await recordWritten(account, 'thumb-new.jpg', 10, modified: day3, tier: NextcloudMirrorTier.grid);
      await recordWritten(account, 'v.mp4', 10, modified: day2);

      expect(await evictOldestFirst(account), {'thumb-old.jpg', 'thumb-new.jpg', 'v.mp4'});
      expect(await store.usedBytes(account), 0);
      // the order is visible in which rows went first when the target is met part way
      await recordWritten(account, 'a.jpg', 10, modified: day1, tier: NextcloudMirrorTier.grid);
      await recordWritten(account, 'b.mp4', 10, modified: day3);
      final partial = accountWith(cacheLimitBytes: 10);
      expect(await evictOldestFirst(partial), {'b.mp4'}, reason: 'the original goes before the older grid row');
    });

    test('pages through the originals and then the grid rows', () async {
      // 300 originals and 300 grid rows against a 256-row page, so each class takes more than one page
      final account = accountWith(cacheLimitBytes: 0);
      for (var i = 0; i < 300; i++) {
        await recordWritten(
          account,
          'photo$i.jpg',
          1,
          modified: epoch.add(Duration(minutes: i)),
          tier: NextcloudMirrorTier.grid,
        );
        await recordWritten(account, 'video$i.mp4', 1, modified: epoch.add(Duration(minutes: i)));
      }

      final demoted = await evictOldestFirst(account);

      expect(demoted.length, 600);
      expect(await store.usedBytes(account), 0);
      expect(index.getOldestModifiedCalls, greaterThan(2));
      expect(index.getLeastRecentlyAccessedCalls, 0, reason: 'the sync order never consults the access order');
    });
  });
}
