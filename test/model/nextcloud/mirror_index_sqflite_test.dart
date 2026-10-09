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
      expect(names, containsAll(<String>['tier', 'remoteSizeBytes', 'localSizeBytes', 'pinned']));

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
}
