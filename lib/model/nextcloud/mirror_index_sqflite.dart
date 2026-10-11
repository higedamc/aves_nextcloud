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
  static const _version = 4;
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
    await _createIndexes(db, table);
  }

  // One source for the schema, used by both the fresh create and the migration's table rebuild: two copies
  // would drift, and the copy a user's upgrade runs is the one nobody looks at.
  static Future<void> _createTable(Database db, String name) => db.execute('''CREATE TABLE $name(
      accountId TEXT NOT NULL
      , relativePath TEXT NOT NULL
      , etag TEXT NOT NULL
      , fileId INTEGER
      , tier TEXT NOT NULL
      , placeholderReason TEXT
      , remoteSizeBytes INTEGER NOT NULL
      , localSizeBytes INTEGER NOT NULL
      , sidecarSizeBytes INTEGER NOT NULL DEFAULT 0
      , pinned INTEGER NOT NULL
      , remoteLastModified INTEGER NOT NULL
      , downloadedAt INTEGER NOT NULL
      , lastAccessAt INTEGER NOT NULL
      , PRIMARY KEY (accountId, relativePath)
      )''');

  // Two eviction orders, two indexes: a user-driven fetch scans the account least-recently-accessed first,
  // the sync scans it oldest `remoteLastModified` first (and on every sync), see `NextcloudEvictionOrder`.
  static Future<void> _createIndexes(Database db, String name) async {
    await db.execute('CREATE INDEX ${name}_lastAccessAt ON $name(accountId, lastAccessAt)');
    await db.execute('CREATE INDEX ${name}_remoteLastModified ON $name(accountId, remoteLastModified)');
  }

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
      // the old index goes with the old table; the new ones are created after the rename so they carry the
      // names the fresh schema uses
      await db.execute('DROP TABLE $table');
      await db.execute('ALTER TABLE $staging RENAME TO $table');
      await _createIndexes(db, table);
    } else if (oldVersion < 3) {
      // v3 adds why a placeholder has no bytes, and the sync's eviction order. A nullable column can be
      // added in place (the v2 lesson was about `NOT NULL` with no default). Every placeholder a v2 binary
      // wrote was a threshold or a 404, so `policy` is a fact about those rows rather than a guess: the
      // only other reason, `unfunded`, did not exist before this version.
      await db.execute('ALTER TABLE $table ADD COLUMN placeholderReason TEXT');
      await db.update(table, {'placeholderReason': NextcloudPlaceholderReason.policy.name}, where: 'tier = ?', whereArgs: [NextcloudMirrorTier.placeholder.name]);
      await db.execute('CREATE INDEX ${table}_remoteLastModified ON $table(accountId, remoteLastModified)');
    }
    if (oldVersion >= 2 && oldVersion < 4) {
      // v4 adds the sidecar's share of a view row's bytes. Defaulted, so an in-place add is fine (the v2
      // lesson was `NOT NULL` with no default), and 0 is a fact about every existing row: no binary
      // before this version wrote a view row.
      await db.execute('ALTER TABLE $table ADD COLUMN sidecarSizeBytes INTEGER NOT NULL DEFAULT 0');
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
  Future<List<NextcloudMirrorIndexEntry>> getLeastRecentlyAccessed(NextcloudAccount account, {required int limit, Set<NextcloudMirrorTier>? tiers}) async {
    // served by the `lastAccessAt` index, so a page costs the page, not the account.
    // `relativePath` breaks ties: a bulk download gives a whole album the same `lastAccessAt`, and
    // without a total order successive pages could repeat or skip rows.
    // Two exclusions, both because the row cannot usefully be evicted and offering it would make a page of
    // candidates that cannot go, which the store reads as "the account has nothing left to evict" while
    // evictable rows sit behind it.
    //
    // `pinned = 0`: the user asked for those bytes.
    // `tier != placeholder`: there are no bytes to reclaim, so removing one frees nothing and only costs
    // the gallery entry. Worse, a placeholder is never viewed, so its `lastAccessAt` never moves and it
    // would sit at the head of this very order — the first eviction would take every above-threshold video
    // and every image without a preview, the next sync would re-list and recreate them, and the cycle
    // would repeat on every eviction.
    //
    // With `tiers`, the placeholder exclusion is kept rather than left to the caller's set, for the same
    // reason as in `getOldestModified`: a caller that passed it would get a page that cannot go.
    final wanted = tiers?.where((tier) => tier != NextcloudMirrorTier.placeholder).toList();
    if (wanted != null && wanted.isEmpty) return const [];
    final tierClause = wanted == null ? 'tier != ?' : 'tier IN (${List.filled(wanted.length, '?').join(', ')})';
    final rows = await _db.query(
      table,
      where: 'accountId = ? AND pinned = 0 AND $tierClause',
      whereArgs: [account.id, if (wanted == null) NextcloudMirrorTier.placeholder.name else ...wanted.map((tier) => tier.name)],
      orderBy: 'lastAccessAt ASC, relativePath ASC',
      limit: limit,
    );
    return rows.map(_toEntry).toList();
  }

  @override
  Future<List<NextcloudMirrorIndexEntry>> getOldestModified(NextcloudAccount account, {required int limit, required Set<NextcloudMirrorTier> tiers, DateTime? modifiedBefore}) async {
    // served by the `remoteLastModified` index; `relativePath` breaks ties for the same reason as above.
    // The same two exclusions as the access order, and `tiers` filtering out `placeholder` would not be
    // enough on its own: a caller that passed it would get a page that cannot go, so it is excluded here
    // regardless of what the caller asks for.
    final wanted = tiers.where((tier) => tier != NextcloudMirrorTier.placeholder).toList();
    if (wanted.isEmpty) return const [];
    final placeholders = List.filled(wanted.length, '?').join(', ');
    final rows = await _db.query(
      table,
      where: 'accountId = ? AND pinned = 0 AND tier IN ($placeholders)${modifiedBefore == null ? '' : ' AND remoteLastModified < ?'}',
      whereArgs: [account.id, ...wanted.map((tier) => tier.name), if (modifiedBefore != null) modifiedBefore.millisecondsSinceEpoch],
      orderBy: 'remoteLastModified ASC, relativePath ASC',
      limit: limit,
    );
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
        'placeholderReason': entry.placeholderReason?.name,
        'remoteSizeBytes': entry.remoteSizeBytes,
        'localSizeBytes': entry.localSizeBytes,
        'sidecarSizeBytes': entry.sidecarSizeBytes,
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
  Future<int> sumLocalSizeBytes(NextcloudAccount account, {NextcloudBudgetClass? of}) async {
    // the same split as `NextcloudMirrorIndexEntry.syncClassBytes` / `viewClassBytes`, in SQL: a view row
    // counts its sidecar for the sync class and the rest for the view class, every other row is sync
    final view = NextcloudMirrorTier.view.name;
    final expression = switch (of) {
      null => 'localSizeBytes',
      NextcloudBudgetClass.sync => "CASE WHEN tier = '$view' THEN sidecarSizeBytes ELSE localSizeBytes END",
      NextcloudBudgetClass.view => "CASE WHEN tier = '$view' THEN localSizeBytes - sidecarSizeBytes ELSE 0 END",
    };
    final rows = await _db.rawQuery('SELECT SUM($expression) AS total FROM $table WHERE accountId = ?', [account.id]);
    // SUM over no rows is null, not 0
    return (rows.isEmpty ? null : rows.first['total'] as int?) ?? 0;
  }

  static NextcloudMirrorIndexEntry _toEntry(Map<String, Object?> row) {
    final tier = _tierFrom(row['tier']);
    return NextcloudMirrorIndexEntry(
      relativePath: row['relativePath'] as String,
      etag: row['etag'] as String,
      fileId: row['fileId'] as int?,
      tier: tier,
      placeholderReason: tier == NextcloudMirrorTier.placeholder ? _reasonFrom(row['placeholderReason']) : null,
      remoteSizeBytes: row['remoteSizeBytes'] as int,
      localSizeBytes: row['localSizeBytes'] as int,
      // only a view row may carry a sidecar; a row from a newer binary read as a placeholder must not
      sidecarSizeBytes: tier == NextcloudMirrorTier.view ? (row['sidecarSizeBytes'] as int? ?? 0) : 0,
      pinned: (row['pinned'] as int? ?? 0) != 0,
      remoteLastModified: DateTime.fromMillisecondsSinceEpoch(row['remoteLastModified'] as int),
      downloadedAt: DateTime.fromMillisecondsSinceEpoch(row['downloadedAt'] as int),
      lastAccessAt: DateTime.fromMillisecondsSinceEpoch(row['lastAccessAt'] as int),
    );
  }

  // an unknown name can only come from a newer binary having written the row, so the safest reading is
  // the tier that promises the least
  static NextcloudMirrorTier _tierFrom(Object? value) => NextcloudMirrorTier.values.firstWhere((v) => v.name == value, orElse: () => NextcloudMirrorTier.placeholder);

  // a missing or unknown reason reads as `policy`: a placeholder that is only ever promoted when the file
  // changes is the pre-v3 behaviour, so a row this binary cannot read behaves as it did before the column
  // existed, rather than being planned as a gap on every relist
  static NextcloudPlaceholderReason _reasonFrom(Object? value) => NextcloudPlaceholderReason.values.firstWhere((v) => v.name == value, orElse: () => NextcloudPlaceholderReason.policy);
}
