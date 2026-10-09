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

  NextcloudAccount accountWith({String id = 'acc1', int cacheLimitBytes = 1000}) => NextcloudAccount(
    id: id,
    serverUrl: Uri.parse('https://cloud.example.com'),
    username: 'alice',
    rootFolder: 'Photos',
    cacheLimitBytes: cacheLimitBytes,
  );

  NextcloudMirrorIndexEntry entryFor(
    String relativePath, {
    int sizeBytes = 0,
    NextcloudMirrorTier tier = NextcloudMirrorTier.original,
    bool pinned = false,
    DateTime? lastAccessAt,
  }) => NextcloudMirrorIndexEntry(
    relativePath: relativePath,
    etag: '"etag-$relativePath"',
    fileId: 42,
    tier: tier,
    remoteSizeBytes: sizeBytes,
    localSizeBytes: sizeBytes,
    pinned: pinned,
    remoteLastModified: epoch,
    downloadedAt: epoch,
    lastAccessAt: lastAccessAt ?? epoch,
  );

  // writes `size` bytes at the mirror location, as a completed download would
  Future<void> writeMirrorFile(NextcloudAccount account, String relativePath, int size) async {
    final file = File(store.localPathFor(account, relativePath));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.filled(size, 0));
  }

  Future<void> recordWritten(NextcloudAccount account, String relativePath, int size, {DateTime? lastAccessAt}) async {
    await writeMirrorFile(account, relativePath, size);
    await store.record(account, entryFor(relativePath, sizeBytes: size, lastAccessAt: lastAccessAt));
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
  Future<Set<String>> evict(NextcloudAccount account, {int reserveBytes = 0}) async => (await store.evictToFit(account, reserveBytes: reserveBytes)).removed;

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
      expect(await File(store.localPathFor(account, 'old.jpg')).exists(), isFalse);
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

      // the caller decides this is a quota failure; the mirror must still not under-report what it deleted
      final evicted = await evict(account, reserveBytes: 500);

      expect(evicted, {'a.jpg', 'b.jpg'});
      expect(await store.usedBytes(account), 0);
      expect(await store.listAll(account), isEmpty);
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

    test('still reports what it evicted when one row deletion fails', () async {
      final account = accountWith(cacheLimitBytes: 0);
      await recordWritten(account, 'stuck.jpg', 10, lastAccessAt: epoch);
      await recordWritten(account, 'ok.jpg', 10, lastAccessAt: epoch.add(const Duration(days: 1)));
      // the oldest item is the one whose row cannot go, so a propagating failure would hide both
      index.failDeleteFor.add('stuck.jpg');

      final evicted = await evict(account);

      // `remove` deletes the file before the row, so `stuck.jpg`'s bytes went even though its row
      // stayed. It has to be reported: the caller drops its collection entry from this set, and an
      // entry pointing at a file that is gone is the `entry.refresh` trap.
      expect(evicted, {'ok.jpg', 'stuck.jpg'});
      expect(await File(store.localPathFor(account, 'stuck.jpg')).exists(), isFalse);
      // the row stays, so the bytes stay accounted for: over-reporting only ever evicts more
      expect(await store.lookup(account, 'stuck.jpg'), isNotNull);
      expect(await store.usedBytes(account), 10);
    });

    test('reports a row whose file was already missing', () async {
      final account = accountWith(cacheLimitBytes: 0);
      // a row with no file on disk: nothing to delete, and the row deletion then fails
      await writeMirrorFile(account, 'ghost.jpg', 10);
      await store.record(account, entryFor('ghost.jpg', sizeBytes: 10));
      await File(store.localPathFor(account, 'ghost.jpg')).delete();
      index.failDeleteFor.add('ghost.jpg');

      expect(await evict(account), {'ghost.jpg'});
    });

    test('stops instead of looping when nothing on the page can go', () async {
      final account = accountWith(cacheLimitBytes: 0);
      await recordWritten(account, 'stuck.jpg', 10);
      index.failDeleteFor.add('stuck.jpg');

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

    test('a placeholder is still an eviction candidate but frees nothing', () async {
      final account = accountWith(cacheLimitBytes: 100);
      await store.record(account, entryFor('remote-only.mp4', sizeBytes: 3000000000, tier: NextcloudMirrorTier.placeholder));
      await recordWritten(account, 'big.jpg', 140);

      // the placeholder is older in LRU order, so it is offered first; removing it cannot reduce `used`,
      // and eviction must still reach the row that actually holds bytes rather than stalling on it
      final removed = await evict(account);
      expect(removed, contains('big.jpg'));
      expect(await store.usedBytes(account), 0);
    });
  });

  group('eviction outcome', () {
    test('reports removals and, for now, never demotions', () async {
      final account = accountWith(cacheLimitBytes: 100);
      await recordWritten(account, 'a.jpg', 140);

      final outcome = await store.evictToFit(account);

      expect(outcome.removed, {'a.jpg'});
      // structurally empty until a cheaper tier exists to fall back to; asserted so that the leaf adding
      // the view tier has to come back here and say what demotion means
      expect(outcome.demoted, isEmpty);
      expect(outcome.touched, {'a.jpg'});
      expect(outcome.isEmpty, isFalse);
      expect(NextcloudEvictionOutcome.none.isEmpty, isTrue);
    });
  });
}
