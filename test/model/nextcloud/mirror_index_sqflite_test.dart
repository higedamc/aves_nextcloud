import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/mirror_index_sqflite.dart';
import 'package:aves/model/nextcloud/mirror_store.dart';
import 'package:aves/services/common/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// The index is a cache, but it is a cache in a file on a user's device, so the upgrade from the tier-less
// v1 schema is a write to data we did not create. These tests open a v1 file written by hand and assert
// what the rows read back as.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // `SqfliteNextcloudMirrorIndex.path` joins through `pContext`
    if (!getIt.isRegistered<p.Context>()) {
      getIt.registerLazySingleton<p.Context>(() => p.Context(style: p.Style.posix));
    }
  });

  final account = NextcloudAccount(
    id: 'acc1',
    serverUrl: Uri.parse('https://cloud.example.com'),
    username: 'alice',
    rootFolder: '',
    cacheLimitBytes: 1000,
  );

  group('v1 to v2 upgrade', () {
    late String dbPath;

    setUp(() async {
      dbPath = '${await databaseFactory.getDatabasesPath()}/nextcloud_mirror.db';
      // `deleteDatabase` and not `File.delete`: the factory keeps single-instance handles, so deleting the
      // file behind its back leaves the previous test's open database answering queries
      await databaseFactory.deleteDatabase(dbPath);
    });

    // exactly the v1 schema, so the test fails if the real `onUpgrade` is written against a shape that
    // was never shipped
    Future<void> writeV1(List<Map<String, Object?>> rows) async {
      final db = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async {
            await db.execute('''CREATE TABLE ${SqfliteNextcloudMirrorIndex.table}(
              accountId TEXT NOT NULL
              , relativePath TEXT NOT NULL
              , etag TEXT NOT NULL
              , fileId INTEGER
              , sizeBytes INTEGER NOT NULL
              , remoteLastModified INTEGER NOT NULL
              , downloadedAt INTEGER NOT NULL
              , lastAccessAt INTEGER NOT NULL
              , PRIMARY KEY (accountId, relativePath)
              )''');
            await db.execute('CREATE INDEX ${SqfliteNextcloudMirrorIndex.table}_lastAccessAt ON ${SqfliteNextcloudMirrorIndex.table}(accountId, lastAccessAt)');
          },
        ),
      );
      for (final row in rows) {
        await db.insert(SqfliteNextcloudMirrorIndex.table, row);
      }
      await db.close();
    }

    Map<String, Object?> v1Row(String relativePath, int sizeBytes) => {
      'accountId': account.id,
      'relativePath': relativePath,
      'etag': 'etag-$relativePath',
      'fileId': 7,
      'sizeBytes': sizeBytes,
      'remoteLastModified': 1000,
      'downloadedAt': 2000,
      'lastAccessAt': 3000,
    };

    test('a v1 row becomes an unpinned original whose two sizes are the size it had', () async {
      await writeV1([v1Row('trip/a.jpg', 120), v1Row('trip/b.jpg', 880)]);

      final index = SqfliteNextcloudMirrorIndex();
      await index.init();
      final row = await index.get(account, 'trip/a.jpg');

      // every row v1 could hold was a whole file fetched by the v1 sync, so `original` is a fact about the
      // data. Read as the enum's first value instead, these rows would be placeholders and the app would
      // offer to download files it already holds.
      expect(row!.tier, NextcloudMirrorTier.original, reason: 'a v1 row is an original, not the first enum value');
      expect(row.remoteSizeBytes, 120, reason: "v1's sizeBytes was the remote size of an original");
      expect(row.localSizeBytes, 120, reason: "v1's sizeBytes was read back from disk, so it is also the local size");
      expect(row.pinned, isFalse, reason: 'nobody was ever asked, so nothing is pinned');
      expect(row.etag, 'etag-trip/a.jpg');
      expect(row.fileId, 7);
      expect(row.lastAccessAt.millisecondsSinceEpoch, 3000);
    });

    test('the budget sums the local sizes of migrated rows, not zero', () async {
      await writeV1([v1Row('trip/a.jpg', 120), v1Row('trip/b.jpg', 880)]);

      final index = SqfliteNextcloudMirrorIndex();
      await index.init();

      // a migration that adds the column with its default and forgets to backfill leaves this at 0, which
      // reads as an empty mirror: the budget would then accept every new fetch and the files would pile up
      expect(await index.sumLocalSizeBytes(account), 1000);
    });

    test('a migrated row is an eviction candidate, and a pinned row is not', () async {
      await writeV1([v1Row('trip/a.jpg', 120)]);

      final index = SqfliteNextcloudMirrorIndex();
      await index.init();
      expect((await index.getLeastRecentlyAccessed(account, limit: 10)).map((v) => v.relativePath), ['trip/a.jpg']);

      final pinned = (await index.get(account, 'trip/a.jpg'))!.copyWith(pinned: true);
      await index.put(account, pinned);

      expect(await index.getLeastRecentlyAccessed(account, limit: 10), isEmpty, reason: 'a pinned row can never be evicted, so it must not be offered as a candidate');
      expect(await index.sumLocalSizeBytes(account), 120, reason: 'pinning does not stop the bytes counting against the budget');
    });

    test('a placeholder row is not an eviction candidate in the real query', () async {
      final index = SqfliteNextcloudMirrorIndex();
      await index.init();
      await index.put(
        account,
        NextcloudMirrorIndexEntry(
          relativePath: 'aaa-remote-only.mp4',
          etag: 'e1',
          fileId: 1,
          tier: NextcloudMirrorTier.placeholder,
          placeholderReason: NextcloudPlaceholderReason.policy,
          remoteSizeBytes: 3000000000,
          localSizeBytes: 0,
          remoteLastModified: DateTime.fromMillisecondsSinceEpoch(1000),
          downloadedAt: DateTime.fromMillisecondsSinceEpoch(1000),
          // oldest access, so it heads the eviction order: a placeholder is never viewed, so this is the
          // realistic state rather than a contrived one
          lastAccessAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      );
      await index.put(
        account,
        NextcloudMirrorIndexEntry(
          relativePath: 'zzz-held.jpg',
          etag: 'e2',
          fileId: 2,
          tier: NextcloudMirrorTier.grid,
          remoteSizeBytes: 10000000,
          localSizeBytes: 18062,
          remoteLastModified: DateTime.fromMillisecondsSinceEpoch(2000),
          downloadedAt: DateTime.fromMillisecondsSinceEpoch(2000),
          lastAccessAt: DateTime.fromMillisecondsSinceEpoch(2000),
        ),
      );

      // the exclusion lives in the SQL, so the fake index agreeing with the contract proves nothing here
      final candidates = await index.getLeastRecentlyAccessed(account, limit: 10);
      expect(candidates.map((v) => v.relativePath), ['zzz-held.jpg'], reason: 'evicting a placeholder frees nothing and only costs the gallery entry');
    });

    test('the rebuild keeps the access index and leaves no stale column behind', () async {
      await writeV1([v1Row('trip/a.jpg', 120)]);

      final index = SqfliteNextcloudMirrorIndex();
      await index.init();
      final db = await databaseFactory.openDatabase(dbPath, options: OpenDatabaseOptions(singleInstance: true));

      // the old index is dropped with the old table, and a lost index is silent: nothing fails, eviction
      // just degrades to a full scan, which only shows up at six figures of rows
      final indexes = await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?", [SqfliteNextcloudMirrorIndex.table]);
      expect(indexes.map((v) => v['name']), contains('${SqfliteNextcloudMirrorIndex.table}_lastAccessAt'));

      // v1's `sizeBytes` is gone rather than left behind unmaintained; leaving it was the first attempt and
      // it broke every insert, since it is NOT NULL with no default
      final columns = await db.rawQuery('PRAGMA table_info(${SqfliteNextcloudMirrorIndex.table})');
      final names = columns.map((v) => v['name']).toSet();
      expect(names, isNot(contains('sizeBytes')));
      expect(names, containsAll(<String>['tier', 'placeholderReason', 'remoteSizeBytes', 'localSizeBytes', 'pinned']));
      // a v1 file upgrades straight to the latest schema: the sync's eviction order is indexed too
      expect(indexes.map((v) => v['name']), contains('${SqfliteNextcloudMirrorIndex.table}_remoteLastModified'));

      // and the staging table did not survive the rename
      final tables = await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'");
      expect(tables.map((v) => v['name']), isNot(contains('${SqfliteNextcloudMirrorIndex.table}_v2')));
    });

    test('a fresh v2 database round trips every new field', () async {
      final index = SqfliteNextcloudMirrorIndex();
      await index.init();
      await index.put(
        account,
        NextcloudMirrorIndexEntry(
          relativePath: 'trip/c.jpg',
          etag: 'e',
          fileId: null,
          tier: NextcloudMirrorTier.grid,
          remoteSizeBytes: 10485760,
          localSizeBytes: 18062,
          pinned: true,
          remoteLastModified: DateTime.fromMillisecondsSinceEpoch(1000),
          downloadedAt: DateTime.fromMillisecondsSinceEpoch(2000),
          lastAccessAt: DateTime.fromMillisecondsSinceEpoch(3000),
        ),
      );

      final row = await index.get(account, 'trip/c.jpg');
      expect(row!.tier, NextcloudMirrorTier.grid);
      expect(row.remoteSizeBytes, 10485760);
      expect(row.localSizeBytes, 18062);
      expect(row.pinned, isTrue);
      // the two sizes must not collapse into one another: this is the pair that, confused, reports a
      // few hundred megabytes of previews as the size of the whole remote library
      expect(row.localSizeBytes, isNot(row.remoteSizeBytes));
    });
  });

  group('v2 to v3 upgrade', () {
    late String dbPath;

    setUp(() async {
      dbPath = '${await databaseFactory.getDatabasesPath()}/nextcloud_mirror.db';
      await databaseFactory.deleteDatabase(dbPath);
    });

    // exactly the v2 schema as shipped, so the test fails if the real `onUpgrade` is written against a
    // shape that was never on a device
    Future<void> writeV2(List<Map<String, Object?>> rows) async {
      final db = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, version) async {
            await db.execute('''CREATE TABLE ${SqfliteNextcloudMirrorIndex.table}(
              accountId TEXT NOT NULL
              , relativePath TEXT NOT NULL
              , etag TEXT NOT NULL
              , fileId INTEGER
              , tier TEXT NOT NULL
              , remoteSizeBytes INTEGER NOT NULL
              , localSizeBytes INTEGER NOT NULL
              , pinned INTEGER NOT NULL
              , remoteLastModified INTEGER NOT NULL
              , downloadedAt INTEGER NOT NULL
              , lastAccessAt INTEGER NOT NULL
              , PRIMARY KEY (accountId, relativePath)
              )''');
            await db.execute('CREATE INDEX ${SqfliteNextcloudMirrorIndex.table}_lastAccessAt ON ${SqfliteNextcloudMirrorIndex.table}(accountId, lastAccessAt)');
          },
        ),
      );
      for (final row in rows) {
        await db.insert(SqfliteNextcloudMirrorIndex.table, row);
      }
      await db.close();
    }

    Map<String, Object?> v2Row(String relativePath, {required NextcloudMirrorTier tier, int localSizeBytes = 0, int remoteLastModified = 1000}) => {
      'accountId': account.id,
      'relativePath': relativePath,
      'etag': 'etag-$relativePath',
      'fileId': 7,
      'tier': tier.name,
      'remoteSizeBytes': 500,
      'localSizeBytes': localSizeBytes,
      'pinned': 0,
      'remoteLastModified': remoteLastModified,
      'downloadedAt': 2000,
      'lastAccessAt': 3000,
    };

    test('a v2 placeholder reads as a policy placeholder, and every other row carries no reason', () async {
      await writeV2([v2Row('above.mp4', tier: NextcloudMirrorTier.placeholder), v2Row('a.jpg', tier: NextcloudMirrorTier.grid, localSizeBytes: 18062)]);

      final index = SqfliteNextcloudMirrorIndex();
      await index.init();

      // every placeholder a v2 binary wrote was a threshold or a 404, so this is a fact about the rows,
      // not a default. Read as `unfunded`, every such row would be planned as a gap on the next relist and
      // the preview endpoint asked again for files it already answered 404 for.
      final placeholder = await index.get(account, 'above.mp4');
      expect(placeholder!.tier, NextcloudMirrorTier.placeholder);
      expect(placeholder.placeholderReason, NextcloudPlaceholderReason.policy);
      final grid = await index.get(account, 'a.jpg');
      expect(grid!.tier, NextcloudMirrorTier.grid);
      expect(grid.placeholderReason, isNull);
      expect(grid.localSizeBytes, 18062, reason: 'an in-place column add touches nothing else');
    });

    test('the upgrade adds the sync order index and leaves the access index in place', () async {
      await writeV2([v2Row('a.jpg', tier: NextcloudMirrorTier.grid)]);

      final index = SqfliteNextcloudMirrorIndex();
      await index.init();
      final db = await databaseFactory.openDatabase(dbPath, options: OpenDatabaseOptions(singleInstance: true));

      final indexes = await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?", [SqfliteNextcloudMirrorIndex.table]);
      expect(indexes.map((v) => v['name']), containsAll(<String>['${SqfliteNextcloudMirrorIndex.table}_lastAccessAt', '${SqfliteNextcloudMirrorIndex.table}_remoteLastModified']));
      final columns = await db.rawQuery('PRAGMA table_info(${SqfliteNextcloudMirrorIndex.table})');
      expect(columns.map((v) => v['name']), contains('placeholderReason'));
    });

    test('a migrated database accepts a put of every tier, with and without a reason', () async {
      await writeV2([v2Row('a.jpg', tier: NextcloudMirrorTier.grid)]);

      final index = SqfliteNextcloudMirrorIndex();
      await index.init();
      // the v2 lesson, in the other direction: an added column must not break the next insert
      await index.put(
        account,
        NextcloudMirrorIndexEntry(
          relativePath: 'b.jpg',
          etag: 'e',
          fileId: 2,
          tier: NextcloudMirrorTier.grid,
          remoteSizeBytes: 10,
          localSizeBytes: 2,
          remoteLastModified: DateTime.fromMillisecondsSinceEpoch(1),
          downloadedAt: DateTime.fromMillisecondsSinceEpoch(1),
          lastAccessAt: DateTime.fromMillisecondsSinceEpoch(1),
        ),
      );
      await index.put(
        account,
        NextcloudMirrorIndexEntry(
          relativePath: 'v.mp4',
          etag: 'e',
          fileId: 3,
          tier: NextcloudMirrorTier.placeholder,
          placeholderReason: NextcloudPlaceholderReason.unfunded,
          remoteSizeBytes: 10,
          localSizeBytes: 0,
          remoteLastModified: DateTime.fromMillisecondsSinceEpoch(1),
          downloadedAt: DateTime.fromMillisecondsSinceEpoch(1),
          lastAccessAt: DateTime.fromMillisecondsSinceEpoch(1),
        ),
      );

      expect((await index.get(account, 'b.jpg'))?.placeholderReason, isNull);
      expect((await index.get(account, 'v.mp4'))?.placeholderReason, NextcloudPlaceholderReason.unfunded);
    });

    test('a reason this binary cannot read is a policy placeholder, as before the column existed', () async {
      await writeV2([v2Row('x.mp4', tier: NextcloudMirrorTier.placeholder)]);
      final index = SqfliteNextcloudMirrorIndex();
      await index.init();
      final db = await databaseFactory.openDatabase(dbPath, options: OpenDatabaseOptions(singleInstance: true));
      await db.update(SqfliteNextcloudMirrorIndex.table, {'placeholderReason': 'from-the-future'}, where: 'relativePath = ?', whereArgs: ['x.mp4']);

      expect((await index.get(account, 'x.mp4'))?.placeholderReason, NextcloudPlaceholderReason.policy);
    });
  });

  group('oldest modified query', () {
    late SqfliteNextcloudMirrorIndex index;
    final epoch = DateTime.fromMillisecondsSinceEpoch(1000);

    NextcloudMirrorIndexEntry rowFor(String relativePath, {required NextcloudMirrorTier tier, required int modified, bool pinned = false, int lastAccess = 0}) => NextcloudMirrorIndexEntry(
      relativePath: relativePath,
      etag: 'e',
      fileId: 1,
      tier: tier,
      placeholderReason: tier == NextcloudMirrorTier.placeholder ? NextcloudPlaceholderReason.unfunded : null,
      remoteSizeBytes: 10,
      localSizeBytes: tier == NextcloudMirrorTier.placeholder ? 0 : 10,
      pinned: pinned,
      remoteLastModified: epoch.add(Duration(days: modified)),
      downloadedAt: epoch,
      lastAccessAt: epoch.add(Duration(days: lastAccess)),
    );

    setUp(() async {
      await databaseFactory.deleteDatabase('${await databaseFactory.getDatabasesPath()}/nextcloud_mirror.db');
      index = SqfliteNextcloudMirrorIndex();
      await index.init();
    });

    // the order and the bound live in the SQL, so the fake index agreeing with the contract proves nothing here
    test('orders by remoteLastModified then path, ignoring the access order', () async {
      await index.put(account, rowFor('b.mp4', tier: NextcloudMirrorTier.original, modified: 2, lastAccess: 0));
      await index.put(account, rowFor('a.mp4', tier: NextcloudMirrorTier.original, modified: 2, lastAccess: 9));
      await index.put(account, rowFor('z.mp4', tier: NextcloudMirrorTier.original, modified: 1, lastAccess: 5));

      final rows = await index.getOldestModified(account, limit: 10, tiers: {NextcloudMirrorTier.original});
      expect(rows.map((v) => v.relativePath), ['z.mp4', 'a.mp4', 'b.mp4']);
    });

    test('filters by tier and by a strict bound on remoteLastModified', () async {
      await index.put(account, rowFor('old.mp4', tier: NextcloudMirrorTier.original, modified: 1));
      await index.put(account, rowFor('same.mp4', tier: NextcloudMirrorTier.original, modified: 2));
      await index.put(account, rowFor('new.mp4', tier: NextcloudMirrorTier.original, modified: 3));
      await index.put(account, rowFor('old.jpg', tier: NextcloudMirrorTier.grid, modified: 1));

      final before = epoch.add(const Duration(days: 2));
      final originals = await index.getOldestModified(account, limit: 10, tiers: {NextcloudMirrorTier.original}, modifiedBefore: before);
      // strictly before: an item with the same date as the one being funded is not older than it
      expect(originals.map((v) => v.relativePath), ['old.mp4']);
      final grids = await index.getOldestModified(account, limit: 10, tiers: {NextcloudMirrorTier.grid}, modifiedBefore: before);
      expect(grids.map((v) => v.relativePath), ['old.jpg']);
      final both = await index.getOldestModified(account, limit: 10, tiers: {NextcloudMirrorTier.original, NextcloudMirrorTier.grid});
      expect(both.map((v) => v.relativePath), ['old.jpg', 'old.mp4', 'same.mp4', 'new.mp4']);
    });

    test('never offers a pinned row or a placeholder, whatever tiers it is asked for', () async {
      await index.put(account, rowFor('pinned.mp4', tier: NextcloudMirrorTier.original, modified: 1, pinned: true));
      await index.put(account, rowFor('aaa.mp4', tier: NextcloudMirrorTier.placeholder, modified: 0));
      await index.put(account, rowFor('free.mp4', tier: NextcloudMirrorTier.original, modified: 2));

      final rows = await index.getOldestModified(account, limit: 10, tiers: NextcloudMirrorTier.values.toSet());
      expect(rows.map((v) => v.relativePath), ['free.mp4']);
      expect(await index.getOldestModified(account, limit: 10, tiers: {NextcloudMirrorTier.placeholder}), isEmpty);
    });

    test('pages and stays within the account', () async {
      final other = NextcloudAccount(id: 'acc2', serverUrl: account.serverUrl, username: 'bob', rootFolder: '', cacheLimitBytes: 1000);
      for (var i = 0; i < 5; i++) {
        await index.put(account, rowFor('v$i.mp4', tier: NextcloudMirrorTier.original, modified: i));
      }
      await index.put(other, rowFor('theirs.mp4', tier: NextcloudMirrorTier.original, modified: 0));

      final page = await index.getOldestModified(account, limit: 2, tiers: {NextcloudMirrorTier.original});
      expect(page.map((v) => v.relativePath), ['v0.mp4', 'v1.mp4']);
    });
  });
}
