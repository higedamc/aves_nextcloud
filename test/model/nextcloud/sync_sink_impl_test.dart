import 'dart:io';

import 'package:aves/model/covers.dart';
import 'package:aves/model/db/db.dart';
import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/origins.dart';
import 'package:aves/model/favourites.dart';
import 'package:aves/model/filters/covered/stored_album.dart';
import 'package:aves/model/nextcloud/mirror_store.dart';
import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/placeholder_entries.dart';
import 'package:aves/model/nextcloud/remote_item.dart';
import 'package:aves/model/nextcloud/sync_sink_impl.dart';
import 'package:aves/model/source/collection_source.dart';
import 'package:aves/model/source/media_store_source.dart';
import 'package:aves/ref/mime_types.dart';
import 'package:aves/services/common/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../common.dart';
import '../../fake/db.dart';
import '../../fake/media_fetch_service.dart';
import '../../fake/nextcloud_sync.dart';

// The shared `FakeAvesDb` is a no-op stub (other tests rely on that), so this file records the entry table itself:
// the sink's rules are about which rows exist, with which ids, after a put or a removal.
class RecordingDb extends FakeAvesDb {
  final Map<int, AvesEntry> rows = {};
  final List<Set<AvesEntry>> inserts = [];
  final List<(int, AvesEntry)> updates = [];
  final List<(Set<int>, Set<EntryDataType>?)> removals = [];

  // not `reset()`: `LocalMediaDb.reset()` exists with a different signature
  void clearRecords() {
    rows.clear();
    inserts.clear();
    updates.clear();
    removals.clear();
  }

  @override
  Future<Set<AvesEntry>> loadEntries({int? origin, String? directory}) async {
    return rows.values.where((row) => (origin == null || row.origin == origin) && (directory == null || (row.path?.startsWith(directory) ?? false))).toSet();
  }

  @override
  Future<void> insertEntries(Set<AvesEntry> entries) async {
    if (entries.isEmpty) return;
    inserts.add(entries);
    for (final entry in entries) {
      rows[entry.id] = entry;
    }
  }

  // same shape as `SqfliteLocalMediaDb.updateEntry`: delete the id, then insert the entry
  @override
  Future<void> updateEntry(int id, AvesEntry entry) async {
    updates.add((id, entry));
    rows.remove(id);
    rows[entry.id] = entry;
  }

  // only `basic` (or no filter) drops the row, as in sqflite: `AvesEntry.refresh` removes the id first and
  // `applyNewFields` writes it back with `updateEntry`, so a refresh must not lose the row in between
  @override
  Future<void> removeIds(Set<int> ids, {Set<EntryDataType>? dataTypes}) async {
    if (ids.isEmpty) return;
    removals.add((ids, dataTypes));
    if (dataTypes == null || dataTypes.contains(EntryDataType.basic)) {
      ids.forEach(rows.remove);
    }
  }
}

void main() {
  final db = RecordingDb();
  final mirror = FakeNextcloudMirrorStore('${Directory.systemTemp.path}${Platform.pathSeparator}aves-nextcloud-sink-test');
  final account = NextcloudAccount(
    id: 'acc1',
    serverUrl: Uri.parse('https://cloud.example.com'),
    username: 'alice',
    rootFolder: 'Photos',
    cacheLimitBytes: 1000,
  );
  late MediaStoreSource source;
  late NextcloudCollectionSyncSink sink;

  const relA = '2024/a.jpg', relB = '2023/b.jpg';
  final localA = mirror.localPathFor(account, relA), localB = mirror.localPathFor(account, relB);
  final uriA = Uri.file(localA).toString(), uriB = Uri.file(localB).toString();

  NextcloudRemoteItem itemFor(String relativePath) => NextcloudRemoteItem(
    relativePath: relativePath,
    fileId: null,
    etag: 'e-$relativePath',
    mimeType: MimeTypes.jpeg,
    sizeBytes: 42,
    lastModified: DateTime.utc(2024),
    isCollection: false,
  );

  // the same modification date everywhere: a refresh that sees a changed date calls `clearDecoders()`,
  // which the fake services do not implement, so this is what keeps a refresh on the fake-safe path
  AvesEntry entryAt(String localPath, {required int id, required int origin, int sizeBytes = 42}) => AvesEntry(
    id: id,
    uri: Uri.file(localPath).toString(),
    path: localPath,
    contentId: null,
    pageId: null,
    sourceMimeType: MimeTypes.jpeg,
    width: 360,
    height: 720,
    sourceRotationDegrees: 0,
    sizeBytes: sizeBytes,
    sourceTitle: 'photo',
    dateAddedSecs: 1,
    dateModifiedMillis: 1000,
    sourceDateTakenMillis: 1000,
    durationMillis: null,
    trashed: false,
    origin: origin,
  );

  // what `mediaFetchService.getEntry` answers for a mirrored file
  AvesEntry fetched(String localPath, {int sizeBytes = 42}) => entryAt(localPath, id: 0, origin: EntryOrigins.file, sizeBytes: sizeBytes);

  // a stored `origin = nextcloud` row
  AvesEntry row(String localPath, {required int id}) => entryAt(localPath, id: id, origin: EntryOrigins.nextcloud);

  Future<MediaStoreSource> initSource() async {
    final source = MediaStoreSource();
    await source.init(scope: CollectionSource.fullScope);
    while (!source.isReady) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return source;
  }

  Iterable<AvesEntry> inCollection(String uri) => source.allEntries.where((entry) => entry.uri == uri);

  setUpAll(() async {
    // `refreshEntries` reads `settings.avesLocale`, which falls back to the platform locales via `WidgetsBinding.instance`
    TestWidgetsFlutterBinding.ensureInitialized();
    await setUpAllServices();
    // `localMediaDb` resolves its singleton on first use, which has not happened yet
    getIt.unregister<LocalMediaDb>();
    getIt.registerSingleton<LocalMediaDb>(db);
    expect(identical(localMediaDb, db), isTrue);
  });

  setUp(() async {
    await setUpServices();
    db.clearRecords();
    // favourites and covers are already empty: `MediaStoreSource.init` reloads both from the fake DB (`{}`)
    (mediaFetchService as FakeMediaFetchService).entries = {};
  });

  tearDown(() {
    sink.dispose();
    source.dispose();
  });

  tearDownAll(() async {
    await tearDownAllServices();
  });

  test('a file without a row gets a new entry and a new row, and a second put of it does not', () async {
    source = await initSource();
    sink = NextcloudCollectionSyncSink(source, mirror);
    (mediaFetchService as FakeMediaFetchService).entries = {fetched(localA)};

    expect(await sink.putMirroredFile(account, itemFor(relA), localA, NextcloudMirrorTier.original), isTrue);

    expect(db.inserts.length, 1);
    final inserted = db.inserts.single.single;
    expect(inserted.uri, uriA);
    expect(inserted.origin, EntryOrigins.nextcloud);
    expect(db.rows.keys, {inserted.id});
    expect(inCollection(uriA).map((entry) => entry.id), [inserted.id]);
    expect(db.updates, isEmpty);

    // the index knows the URI now: the same file again is a refresh, not a second row
    expect(await sink.putMirroredFile(account, itemFor(relA), localA, NextcloudMirrorTier.original), isTrue);
    expect(db.inserts.length, 1);
    expect(db.rows.keys, {inserted.id});
    expect(inCollection(uriA).length, 1);
  });

  test('a file whose entry is in the collection is refreshed in place, with its id', () async {
    db.rows[1] = row(localA, id: 1);
    source = await initSource();
    expect(source.getEntryById(1), isNotNull);
    sink = NextcloudCollectionSyncSink(source, mirror);
    (mediaFetchService as FakeMediaFetchService).entries = {fetched(localA, sizeBytes: 99)};

    expect(await sink.putMirroredFile(account, itemFor(relA), localA, NextcloudMirrorTier.original), isTrue);

    expect(db.inserts, isEmpty);
    expect(db.updates.map((update) => update.$1).toSet(), {1});
    expect(db.rows.keys, {1});
    expect(inCollection(uriA).map((entry) => entry.id), [1]);
    expect(source.getEntryById(1)!.sizeBytes, 99);
  });

  test('a file whose row is outside the collection is updated in the DB only', () async {
    source = await initSource();
    sink = NextcloudCollectionSyncSink(source, mirror);
    // a row the source did not load (outside its scope, or a reload in progress)
    db.rows[7] = row(localA, id: 7);
    (mediaFetchService as FakeMediaFetchService).entries = {fetched(localA, sizeBytes: 99)};

    expect(await sink.putMirroredFile(account, itemFor(relA), localA, NextcloudMirrorTier.original), isTrue);

    expect(db.inserts, isEmpty);
    expect(db.updates.length, 1);
    final (updatedId, updated) = db.updates.single;
    expect(updatedId, 7);
    expect(updated.id, 7);
    expect(updated.origin, EntryOrigins.nextcloud);
    expect(updated.sizeBytes, 99);
    expect(db.rows.keys, {7});
    // the old bytes' metadata is dropped so the entry is catalogued again when a full load adds it
    expect(db.removals.length, 1);
    final (removedIds, removedTypes) = db.removals.single;
    expect(removedIds, {7});
    expect(removedTypes, {EntryDataType.catalog, EntryDataType.address});
    expect(source.allEntries, isEmpty);
  });

  test('removing files cleans up rows, favourites and covers in and out of the collection', () async {
    final loaded = row(localA, id: 1);
    db.rows[1] = loaded;
    source = await initSource();
    sink = NextcloudCollectionSyncSink(source, mirror);
    final unloaded = row(localB, id: 2);
    db.rows[2] = unloaded;
    await favourites.add({loaded, unloaded});
    final filterA = StoredAlbumFilter(loaded.directory!, null), filterB = StoredAlbumFilter(unloaded.directory!, null);
    await covers.set(filter: filterA, entryId: 1, packageName: null, color: null);
    await covers.set(filter: filterB, entryId: 2, packageName: null, color: null);
    expect(inCollection(uriA).length, 1);
    expect(inCollection(uriB), isEmpty);

    await sink.removeMirroredFiles(account, {relA, relB});

    expect(db.rows, isEmpty);
    expect(source.allEntries, isEmpty);
    expect(favourites.isFavourite(loaded), isFalse);
    expect(favourites.isFavourite(unloaded), isFalse);
    expect(covers.of(filterA)?.entryId, isNull);
    expect(covers.of(filterB)?.entryId, isNull);
  });

  group('putPlaceholder', () {
    test('delegates to the placeholder builder and inserts at the mirror URI', () async {
      source = await initSource();
      final built = fetched(localA);
      sink = NextcloudCollectionSyncSink(source, mirror, placeholders: _StubPlaceholders(built));

      expect(await sink.putPlaceholder(account, itemFor(relA)), isTrue);

      // the URI is the one a mirrored file for this path *would* have, so a later fetch of real bytes
      // refreshes this entry rather than making a second one for the same photo
      expect(db.inserts.length, 1);
      expect(db.inserts.single.single.uri, Uri.file(localA).toString());
      expect(db.inserts.single.single.origin, EntryOrigins.nextcloud);
      expect(inCollection(Uri.file(localA).toString()).length, 1);
      // never consulted: there are no bytes to read
      expect((mediaFetchService as FakeMediaFetchService).entries, isEmpty);
    });

    test('a builder that cannot make an entry is a refusal, not a failure', () async {
      source = await initSource();
      sink = NextcloudCollectionSyncSink(source, mirror, placeholders: const _StubPlaceholders(null));

      expect(await sink.putPlaceholder(account, itemFor(relA)), isFalse);
      expect(db.inserts, isEmpty);
      expect(inCollection(Uri.file(localA).toString()), isEmpty);
    });

    test('the default builder is unimplemented and says so loudly', () async {
      source = await initSource();
      sink = NextcloudCollectionSyncSink(source, mirror);

      // nothing creates placeholder rows yet; a silent null here would lose every item it was meant to show
      await expectLater(sink.putPlaceholder(account, itemFor(relA)), throwsUnimplementedError);
    });
  });
}

// A stand-in for the leaf that will synthesise entries without local bytes.
class _StubPlaceholders implements NextcloudPlaceholderEntries {
  final AvesEntry? entry;

  const new(this.entry);

  @override
  AvesEntry? build(NextcloudAccount account, NextcloudRemoteItem item) => entry;
}
