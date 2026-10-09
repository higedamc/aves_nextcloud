import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/mirror_index.dart';
import 'package:aves/model/nextcloud/mirror_store.dart';
import 'package:aves/services/common/services.dart';
import 'package:sqflite/sqflite.dart';

// Mirror index rows in their own database file, deliberately not a table in `localMediaDb`:
// the mirror is a cache, so it must be droppable without touching the media database or its
// migration chain. Losing this file costs a re-download, nothing else.
class SqfliteNextcloudMirrorIndex implements NextcloudMirrorIndex {
  late Database _db;

  static const _fileName = 'nextcloud_mirror.db';
  static const _version = 2;
  static const table = 'mirrorEntry';

  Future<String> get path async => pContext.join(await getDatabasesPath(), _fileName);

  @override
  Future<void> init() async {
    _db = await openDatabase(
      await path,
      onCreate: (db, version) => _createLatestVersion(db),
      onUpgrade: _upgrade,
      version: _version,
    );
  }

  static Future<void> _createLatestVersion(Database db) async {
    await _createTable(db, table);
    await _createAccessIndex(db, table);
  }

  // One source for the schema, used by both the fresh create and the migration's table rebuild: two copies
  // would drift, and the copy a user's upgrade runs is the one nobody looks at.
  static Future<void> _createTable(Database db, String name) => db.execute('''CREATE TABLE $name(
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

  // eviction scans the account in least-recently-accessed order on every sync
  static Future<void> _createAccessIndex(Database db, String name) => db.execute('CREATE INDEX ${name}_lastAccessAt ON $name(accountId, lastAccessAt)');

  // v1 had a single `sizeBytes` column and no tiers, because every row it could hold was a full original
  // fetched by the v1 sync. So the values below are facts about the data rather than guesses: the tier is
  // `original`, and v1's `sizeBytes` was already read back from disk, which for an original is also the
  // remote size. `pinned` is false because nobody was ever asked.
  //
  // The rows are copied into a new table rather than patched with `ALTER TABLE ADD COLUMN`. Adding columns
  // leaves v1's `sizeBytes` behind as `NOT NULL` with no default, and sqlite cannot give an existing column
  // a default, so every later insert would fail the constraint. That is measured and not predicted: the
  // first version of this migration added columns, and the test below failed on the first `put` into a
  // migrated database.
  //
  // What must not happen here is dropping the rows and starting empty, even though losing this file is
  // documented as costing only a re-download: the mirrored files would stay on disk with no row, so they
  // would be neither accounted for, nor evictable, nor entries. Being rid of them would mean wiping the
  // mirror directory, which turns a schema change into deleting the user's cache.
  static Future<void> _upgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      const staging = '${table}_v2';
      await _createTable(db, staging);
      await db.execute(
        'INSERT INTO $staging (accountId, relativePath, etag, fileId, tier, remoteSizeBytes, localSizeBytes, pinned, remoteLastModified, downloadedAt, lastAccessAt)'
        " SELECT accountId, relativePath, etag, fileId, '${NextcloudMirrorTier.original.name}', sizeBytes, sizeBytes, 0, remoteLastModified, downloadedAt, lastAccessAt FROM $table",
      );
      // the old index goes with the old table; the new one is created after the rename so it carries the
      // name the fresh schema uses
      await db.execute('DROP TABLE $table');
      await db.execute('ALTER TABLE $staging RENAME TO $table');
      await _createAccessIndex(db, table);
    }
  }

  @override
  Future<NextcloudMirrorIndexEntry?> get(NextcloudAccount account, String relativePath) async {
    final rows = await _db.query(
      table,
      where: 'accountId = ? AND relativePath = ?',
      whereArgs: [account.id, relativePath],
      limit: 1,
    );
    final row = rows.isEmpty ? null : rows.first;
    return row == null ? null : _toEntry(row);
  }

  @override
  Future<Set<NextcloudMirrorIndexEntry>> getAll(NextcloudAccount account) async {
    final rows = await _db.query(table, where: 'accountId = ?', whereArgs: [account.id]);
    return rows.map(_toEntry).toSet();
  }

  @override
  Future<List<NextcloudMirrorIndexEntry>> getLeastRecentlyAccessed(NextcloudAccount account, {required int limit}) async {
    // served by the `lastAccessAt` index, so a page costs the page, not the account.
    // `relativePath` breaks ties: a bulk download gives a whole album the same `lastAccessAt`, and
    // without a total order successive pages could repeat or skip rows.
    // `pinned = 0`: a pinned row is never an eviction victim, so returning it would make a page of
    // candidates that cannot go, and the store would read "nothing on this page could go" as the end of
    // the account while evictable rows sat behind it.
    final rows = await _db.query(table, where: 'accountId = ? AND pinned = 0', whereArgs: [account.id], orderBy: 'lastAccessAt ASC, relativePath ASC', limit: limit);
    return rows.map(_toEntry).toList();
  }

  @override
  Future<void> put(NextcloudAccount account, NextcloudMirrorIndexEntry entry) async {
    await _db.insert(
      table,
      {
        'accountId': account.id,
        'relativePath': entry.relativePath,
        'etag': entry.etag,
        'fileId': entry.fileId,
        'tier': entry.tier.name,
        'remoteSizeBytes': entry.remoteSizeBytes,
        'localSizeBytes': entry.localSizeBytes,
        'pinned': entry.pinned ? 1 : 0,
        'remoteLastModified': entry.remoteLastModified.millisecondsSinceEpoch,
        'downloadedAt': entry.downloadedAt.millisecondsSinceEpoch,
        'lastAccessAt': entry.lastAccessAt.millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> delete(NextcloudAccount account, String relativePath) async {
    await _db.delete(table, where: 'accountId = ? AND relativePath = ?', whereArgs: [account.id, relativePath]);
  }

  @override
  Future<void> deleteAll(NextcloudAccount account) async {
    await _db.delete(table, where: 'accountId = ?', whereArgs: [account.id]);
  }

  @override
  Future<int> sumLocalSizeBytes(NextcloudAccount account) async {
    final rows = await _db.rawQuery('SELECT SUM(localSizeBytes) AS total FROM $table WHERE accountId = ?', [account.id]);
    // SUM over no rows is null, not 0
    return (rows.isEmpty ? null : rows.first['total'] as int?) ?? 0;
  }

  static NextcloudMirrorIndexEntry _toEntry(Map<String, Object?> row) => NextcloudMirrorIndexEntry(
    relativePath: row['relativePath'] as String,
    etag: row['etag'] as String,
    fileId: row['fileId'] as int?,
    tier: _tierFrom(row['tier']),
    remoteSizeBytes: row['remoteSizeBytes'] as int,
    localSizeBytes: row['localSizeBytes'] as int,
    pinned: (row['pinned'] as int? ?? 0) != 0,
    remoteLastModified: DateTime.fromMillisecondsSinceEpoch(row['remoteLastModified'] as int),
    downloadedAt: DateTime.fromMillisecondsSinceEpoch(row['downloadedAt'] as int),
    lastAccessAt: DateTime.fromMillisecondsSinceEpoch(row['lastAccessAt'] as int),
  );

  // an unknown name can only come from a newer binary having written the row, so the safest reading is
  // the tier that promises the least
  static NextcloudMirrorTier _tierFrom(Object? value) => NextcloudMirrorTier.values.firstWhere((v) => v.name == value, orElse: () => NextcloudMirrorTier.placeholder);
}
