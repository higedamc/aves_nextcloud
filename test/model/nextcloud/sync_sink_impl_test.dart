import 'dart:io';

import 'package:aves/model/covers.dart';
import 'package:aves/model/db/db.dart';
import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/origins.dart';
import 'package:aves/model/favourites.dart';
import 'package:aves/model/filters/covered/stored_album.dart';
import 'package:aves/model/metadata/catalog.dart';
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
  final List<CatalogMetadata> catalogSaves = [];
  final List<(int, CatalogMetadata?)> catalogUpdates = [];

  // not `reset()`: `LocalMediaDb.reset()` exists with a different signature
  void clearRecords() {
    rows.clear();
    inserts.clear();
    updates.clear();
    removals.clear();
    catalogSaves.clear();
    catalogUpdates.clear();
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

  @override
  Future<void> saveCatalogMetadata(Set<CatalogMetadata> metadataEntries) async {
    catalogSaves.addAll(metadataEntries);
  }

  @override
  Future<void> updateCatalogMetadata(int id, CatalogMetadata? metadata) async {
    catalogUpdates.add((id, metadata));
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

  NextcloudRemoteItem itemFor(String relativePath, {NextcloudPhotoMetadata? photoMetadata}) => NextcloudRemoteItem(
    relativePath: relativePath,
    fileId: null,
    etag: 'e-$relativePath',
    mimeType: MimeTypes.jpeg,
    sizeBytes: 42,
    lastModified: DateTime.utc(2024),
    isCollection: false,
    photoMetadata: photoMetadata,
  );

  // the same modification date everywhere: a refresh that sees a changed date calls `clearDecoders()`,
  // which the fake services do not implement, so this is what keeps a refresh on the fake-safe path.
  // `sourceDateTakenMillis`/`dateModifiedMillis` are overridable because one test needs an entry with
  // neither, to match a real preview's bytes (no Exif of its own) rather than this fixture's default.
  AvesEntry entryAt(
    String localPath, {
    required int id,
    required int origin,
    int sizeBytes = 42,
    int? sourceDateTakenMillis = 1000,
    int? dateModifiedMillis = 1000,
  }) => AvesEntry(
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
    dateModifiedMillis: dateModifiedMillis,
    sourceDateTakenMillis: sourceDateTakenMillis,
    durationMillis: null,
    trashed: false,
    origin: origin,
  );

  // what `mediaFetchService.getEntry` answers for a mirrored file
  AvesEntry fetched(String localPath, {int sizeBytes = 42, int? sourceDateTakenMillis = 1000, int? dateModifiedMillis = 1000}) => entryAt(
    localPath,
    id: 0,
    origin: EntryOrigins.file,
    sizeBytes: sizeBytes,
    sourceDateTakenMillis: sourceDateTakenMillis,
    dateModifiedMillis: dateModifiedMillis,
  );

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

  group('catalogue from server metadata', () {
    final serverMetadata = NextcloudPhotoMetadata(
      width: 4032,
      height: 3024,
      originalDateTime: DateTime.utc(2023, 5, 6, 12),
      latitude: 35.6895,
      longitude: 139.6917,
    );

    test('a preview tier put carries the server date and GPS into a new entry, and persists them', () async {
      source = await initSource();
      sink = NextcloudCollectionSyncSink(source, mirror);
      (mediaFetchService as FakeMediaFetchService).entries = {fetched(localA)};

      expect(await sink.putMirroredFile(account, itemFor(relA, photoMetadata: serverMetadata), localA, NextcloudMirrorTier.grid), isTrue);

      final inserted = db.inserts.single.single;
      expect(inserted.isCatalogued, isTrue);
      expect(inserted.catalogMetadata!.dateMillis, serverMetadata.originalDateTime!.millisecondsSinceEpoch);
      expect(inserted.catalogMetadata!.latitude, serverMetadata.latitude);
      expect(inserted.catalogMetadata!.longitude, serverMetadata.longitude);
      // `insertEntries` only writes the entry row, and `analyze()` would skip this entry because it is
      // already catalogued, so without an explicit save the catalog data would never reach the DB
      expect(db.catalogSaves, [inserted.catalogMetadata]);
    });

    test('an original tier put leaves cataloguing to the device, as before', () async {
      source = await initSource();
      sink = NextcloudCollectionSyncSink(source, mirror);
      (mediaFetchService as FakeMediaFetchService).entries = {fetched(localA)};

      expect(await sink.putMirroredFile(account, itemFor(relA, photoMetadata: serverMetadata), localA, NextcloudMirrorTier.original), isTrue);

      final inserted = db.inserts.single.single;
      expect(inserted.isCatalogued, isFalse, reason: 'the original keeps full device-side Exif cataloguing, not just date and GPS');
      expect(db.catalogSaves, isEmpty);
    });

    test('a preview tier refresh overrides stale server date and GPS without forcing a device recatalog', () async {
      db.rows[1] = row(localA, id: 1);
      source = await initSource();
      sink = NextcloudCollectionSyncSink(source, mirror);
      (mediaFetchService as FakeMediaFetchService).entries = {fetched(localA, sizeBytes: 99)};
      // the fake metadata service has nothing set up for this entry, so a forced `entry.catalog()` call
      // here would answer `null` and wipe the entry's catalog metadata entirely: this is the negative
      // control for the fix, reached by deleting the `if (presetCatalog == null) EntryDataType.catalog`
      // guard in `_putEntry`, which turns this assertion into `isCatalogued: false`.

      expect(await sink.putMirroredFile(account, itemFor(relA, photoMetadata: serverMetadata), localA, NextcloudMirrorTier.grid), isTrue);

      final refreshed = source.getEntryById(1)!;
      expect(refreshed.isCatalogued, isTrue);
      expect(refreshed.catalogMetadata!.dateMillis, serverMetadata.originalDateTime!.millisecondsSinceEpoch);
      expect(refreshed.catalogMetadata!.latitude, serverMetadata.latitude);
      expect(refreshed.catalogMetadata!.longitude, serverMetadata.longitude);
      expect(db.catalogUpdates.map((update) => update.$1), contains(1));
    });

    test('a preview tier put to a row outside the collection persists the server date and GPS instead of dropping them', () async {
      source = await initSource();
      sink = NextcloudCollectionSyncSink(source, mirror);
      db.rows[7] = row(localA, id: 7);
      (mediaFetchService as FakeMediaFetchService).entries = {fetched(localA, sizeBytes: 99)};

      expect(await sink.putMirroredFile(account, itemFor(relA, photoMetadata: serverMetadata), localA, NextcloudMirrorTier.grid), isTrue);

      final (updatedId, updated) = db.updates.single;
      expect(updatedId, 7);
      expect(updated.catalogMetadata!.dateMillis, serverMetadata.originalDateTime!.millisecondsSinceEpoch);
      expect(updated.catalogMetadata!.latitude, serverMetadata.latitude);
      expect(db.catalogUpdates.map((update) => update.$1), contains(7));
    });

    test('a preview tier with no server date or GPS leaves the entry visibly unknown, not a zero', () async {
      source = await initSource();
      sink = NextcloudCollectionSyncSink(source, mirror);
      // a real preview carries no Exif of its own (see `catalog_from_metadata.dart`), so this fixture drops
      // the shared fixture's `sourceDateTakenMillis`/`dateModifiedMillis` fallback to match
      (mediaFetchService as FakeMediaFetchService).entries = {fetched(localA, sourceDateTakenMillis: null, dateModifiedMillis: null)};

      expect(await sink.putMirroredFile(account, itemFor(relA), localA, NextcloudMirrorTier.grid), isTrue);

      final inserted = db.inserts.single.single;
      expect(inserted.isCatalogued, isTrue);
      expect(inserted.catalogMetadata!.dateMillis, isNull);
      expect(inserted.bestDate, isNull, reason: 'no catalog, source-taken or modified date is available either, for this fixture');
      expect(inserted.hasGps, isFalse);
    });

    test('dimensions come from the local bytes, never from the server prop', () async {
      source = await initSource();
      sink = NextcloudCollectionSyncSink(source, mirror);
      // the fixture's preview bytes report 360x720 (`entryAt`); the server prop below disagrees on both
      // dimensions and orientation, which is the shape measured on the real server (un-rotated original
      // metadata against a preview with the rotation already burned in)
      (mediaFetchService as FakeMediaFetchService).entries = {fetched(localA)};

      expect(await sink.putMirroredFile(account, itemFor(relA, photoMetadata: serverMetadata), localA, NextcloudMirrorTier.grid), isTrue);

      final inserted = db.inserts.single.single;
      expect(inserted.width, 360);
      expect(inserted.height, 720);
    });
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
    test('stores at the mirror URI even when the builder chose another one', () async {
      source = await initSource();
      // deliberately the *wrong* location: a builder has no reason to know the mirror layout, and if the
      // sink passed its choice through, the row would be keyed under the mirror URI and stored under this
      // one. After a restart `_loadIndex` rebuilds the index from stored URIs, the mirror URI would miss,
      // and the next real fetch would create a second entry for the same photo.
      sink = NextcloudCollectionSyncSink(source, mirror, placeholders: _StubPlaceholders(fetched(localB)));

      expect(await sink.putPlaceholder(account, itemFor(relA)), isTrue);

      expect(db.inserts.length, 1);
      final inserted = db.inserts.single.single;
      expect(inserted.uri, Uri.file(localA).toString(), reason: 'the sink is the only authority on where the entry claims to live');
      expect(inserted.path, localA);
      expect(inserted.origin, EntryOrigins.nextcloud);
      expect(inCollection(Uri.file(localA).toString()).length, 1);
      expect(inCollection(Uri.file(localB).toString()), isEmpty, reason: "the builder's location must not reach the row");
      // never consulted: there are no bytes to read
      expect((mediaFetchService as FakeMediaFetchService).entries, isEmpty);
    });

    test('a later fetch of real bytes refreshes the placeholder instead of adding a second entry', () async {
      source = await initSource();
      sink = NextcloudCollectionSyncSink(source, mirror, placeholders: _StubPlaceholders(fetched(localB)));
      expect(await sink.putPlaceholder(account, itemFor(relA)), isTrue);
      final placeholderId = db.inserts.single.single.id;

      // now the real bytes arrive at the mirror path
      await File(localA).parent.create(recursive: true);
      await File(localA).writeAsBytes(List.filled(42, 0));
      (mediaFetchService as FakeMediaFetchService).entries = {fetched(localA)};

      expect(await sink.putMirroredFile(account, itemFor(relA), localA, NextcloudMirrorTier.grid), isTrue);

      // this is the invariant the URI override exists for: one entry per photo, kept across tiers
      expect(db.inserts.length, 1, reason: 'the placeholder entry is refreshed, not joined by a second one');
      expect(inCollection(Uri.file(localA).toString()).map((v) => v.id), {placeholderId});
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

    test('a placeholder is catalogued from the server metadata, since there are no bytes for the device to read', () async {
      source = await initSource();
      sink = NextcloudCollectionSyncSink(source, mirror, placeholders: _StubPlaceholders(fetched(localB)));
      final serverMetadata = NextcloudPhotoMetadata(
        width: 4032,
        height: 3024,
        originalDateTime: DateTime.utc(2023, 5, 6, 12),
        latitude: 35.6895,
        longitude: 139.6917,
      );

      expect(await sink.putPlaceholder(account, itemFor(relA, photoMetadata: serverMetadata)), isTrue);

      final inserted = db.inserts.single.single;
      expect(inserted.isCatalogued, isTrue, reason: 'an entry with no file has nothing for the device cataloguer to do');
      expect(inserted.catalogMetadata!.dateMillis, serverMetadata.originalDateTime!.millisecondsSinceEpoch);
      expect(inserted.catalogMetadata!.latitude, serverMetadata.latitude);
      expect(inserted.catalogMetadata!.longitude, serverMetadata.longitude);
      // `insertEntries` only writes the entry row; without an explicit save `analyze()` would skip this
      // entry (already catalogued) and the catalog data would never reach the DB
      expect(db.catalogSaves, [inserted.catalogMetadata]);
    });

    test('a placeholder with no server date or GPS is still catalogued, visibly unknown rather than a zero', () async {
      source = await initSource();
      sink = NextcloudCollectionSyncSink(source, mirror, placeholders: _StubPlaceholders(fetched(localB)));

      expect(await sink.putPlaceholder(account, itemFor(relA)), isTrue);

      final inserted = db.inserts.single.single;
      expect(inserted.isCatalogued, isTrue);
      expect(inserted.catalogMetadata!.dateMillis, isNull);
      expect(inserted.hasGps, isFalse);
    });
  });

  group('demoteToPlaceholders', () {
    test('an entry whose bytes the budget took back stays, with its id and its row, and is told its look changed', () async {
      db.rows[1] = row(localA, id: 1);
      source = await initSource();
      sink = NextcloudCollectionSyncSink(source, mirror);
      final entry = source.getEntryById(1)!;
      var visualChanges = 0;
      entry.visualChangeNotifier.addListener(() => visualChanges++);
      // loading the source writes to the DB on its own; only what the demotion adds is the question
      final removalsBefore = db.removals.length, updatesBefore = db.updates.length;

      await sink.demoteToPlaceholders(account, {relA});

      // the whole point of demotion over removal: the photo is still in the gallery, with everything it had
      expect(source.getEntryById(1), same(entry));
      expect(inCollection(uriA).map((e) => e.id), [1]);
      expect(db.rows.keys, {1}, reason: 'the row is untouched: nothing the server could say beats what the device read');
      expect(db.removals.length, removalsBefore);
      expect(db.updates.length, updatesBefore);
      // but the tile and the viewer must look again, since the bytes they decoded are gone
      expect(visualChanges, 1);
      // never consulted: there are no new bytes to read
      expect((mediaFetchService as FakeMediaFetchService).entries, isEmpty);
    });

    test('a path with no entry in the loaded collection is skipped, not an error', () async {
      source = await initSource();
      sink = NextcloudCollectionSyncSink(source, mirror);
      // a row the source did not load, and a path with no row at all
      db.rows[7] = row(localA, id: 7);

      final removalsBefore = db.removals.length, updatesBefore = db.updates.length;

      await sink.demoteToPlaceholders(account, {relA, relB});

      expect(db.rows.keys, {7});
      expect(db.removals.length, removalsBefore);
      expect(db.updates.length, updatesBefore);
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
