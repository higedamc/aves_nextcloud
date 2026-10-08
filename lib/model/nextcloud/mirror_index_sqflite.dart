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
  static const _version = 1;
  static const table = 'mirrorEntry';

  Future<String> get path async => pContext.join(await getDatabasesPath(), _fileName);

  @override
  Future<void> init() async {
    _db = await openDatabase(
      await path,
      onCreate: (db, version) => _createLatestVersion(db),
      version: _version,
    );
  }

  static Future<void> _createLatestVersion(Database db) async {
    await db.execute('''CREATE TABLE $table(
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
    // eviction scans the account in least-recently-accessed order on every sync
    await db.execute('CREATE INDEX ${table}_lastAccessAt ON $table(accountId, lastAccessAt)');
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
  Future<List<NextcloudMirrorIndexEntry>> getAllByLeastRecentlyAccessed(NextcloudAccount account) async {
    final rows = await _db.query(table, where: 'accountId = ?', whereArgs: [account.id], orderBy: 'lastAccessAt ASC');
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
        'sizeBytes': entry.sizeBytes,
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
  Future<int> sumSizeBytes(NextcloudAccount account) async {
    final rows = await _db.rawQuery('SELECT SUM(sizeBytes) AS total FROM $table WHERE accountId = ?', [account.id]);
    // SUM over no rows is null, not 0
    return (rows.isEmpty ? null : rows.first['total'] as int?) ?? 0;
  }

  static NextcloudMirrorIndexEntry _toEntry(Map<String, Object?> row) => NextcloudMirrorIndexEntry(
    relativePath: row['relativePath'] as String,
    etag: row['etag'] as String,
    fileId: row['fileId'] as int?,
    sizeBytes: row['sizeBytes'] as int,
    remoteLastModified: DateTime.fromMillisecondsSinceEpoch(row['remoteLastModified'] as int),
    downloadedAt: DateTime.fromMillisecondsSinceEpoch(row['downloadedAt'] as int),
    lastAccessAt: DateTime.fromMillisecondsSinceEpoch(row['lastAccessAt'] as int),
  );
}
