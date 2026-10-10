import 'dart:async';

import 'package:aves/model/covers.dart';
import 'package:aves/model/entry/cache.dart';
import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/origins.dart';
import 'package:aves/model/favourites.dart';
import 'package:aves/model/metadata/catalog.dart';
import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/catalog_from_metadata.dart';
import 'package:aves/model/nextcloud/mirror_store.dart';
import 'package:aves/model/nextcloud/placeholder_entries.dart';
import 'package:aves/model/nextcloud/remote_item.dart';
import 'package:aves/model/nextcloud/sync_ports.dart';
import 'package:aves/model/source/collection_source.dart';
import 'package:aves/model/source/events.dart';
import 'package:aves/services/common/services.dart';

// `NextcloudSyncSink` over the app collection (integration). A mirrored file becomes an entry the way a recovered
// vault item does: `mediaFetchService.getEntry` on its `file://` URI, `origin = nextcloud`, inserted in the DB and
// added to the source. It leaves through `removeEntries`, which also drops its DB row, favourite and cover.
class NextcloudCollectionSyncSink implements NextcloudSyncSink {
  final CollectionSource _source;
  final NextcloudMirrorStore _mirror;

  // how an entry is made for an item with no local bytes; see `NextcloudPlaceholderEntries`
  final NextcloudPlaceholderEntries _placeholders;

  // Entry ids by URI for every `origin = nextcloud` DB row, built once from the DB and kept in step by the sink,
  // which is the only writer of those rows (the source removes one on its own only when a refresh finds the file
  // gone, which the `EntryRemovedEvent` below reflects).
  //
  // The DB is the authority on "does this URI already have a row", and this index must not be derived from the
  // collection: the source holds only the rows of its loaded scope (a single directory, without sub-folders,
  // in view and screen saver modes), and during a full reload it is cleared before the Nextcloud rows are added
  // back. `SourceState` cannot tell those windows apart either, since `analyze` (which `flush` calls) writes it.
  // A URI with a row but no entry in the collection is a row outside the loaded scope or mid-reload: the put
  // updates the row only, and the next full load picks the entry up.
  Future<Map<String, int>>? _index;
  final Set<StreamSubscription> _subscriptions = {};

  // Cataloguing and collection notification are batched: a sync puts files one at a time, `analyze` is sized for
  // sets of entries, and a notified `addEntries` makes every open grid re-sort the whole collection.
  final Set<AvesEntry> _pending = {};
  Timer? _flushTimer;
  static const batchSize = 100;
  static const flushDelay = Duration(seconds: 2);

  new(this._source, this._mirror, {this._placeholders = const UnimplementedNextcloudPlaceholderEntries()}) {
    _subscriptions.add(_source.eventBus.on<EntryRemovedEvent>().listen(_onEntriesRemoved));
  }

  void dispose() {
    _subscriptions
      ..forEach((sub) => sub.cancel())
      ..clear();
    _flushTimer?.cancel();
    _pending.clear();
  }

  Future<Map<String, int>> get _idByUri => _index ??= _loadIndex();

  Future<Map<String, int>> _loadIndex() async {
    try {
      final rows = await localMediaDb.loadEntries(origin: EntryOrigins.nextcloud);
      return {for (final row in rows) row.uri: row.id};
    } catch (_) {
      // not cached, so the next call retries instead of failing every put for the rest of the session
      _index = null;
      rethrow;
    }
  }

  void _onEntriesRemoved(EntryRemovedEvent event) {
    _pending.removeAll(event.entries);
    final index = _index;
    if (index == null) return;
    unawaited(
      index.then((index) {
        // the event is delivered asynchronously: a URI put again in the meantime has a new id, which stays
        for (final entry in event.entries) {
          if (index[entry.uri] == entry.id) index.remove(entry.uri);
        }
      }),
    );
  }

  String _uriFor(NextcloudAccount account, String relativePath) => Uri.file(_mirror.localPathFor(account, relativePath)).toString();

  @override
  Future<bool> putMirroredFile(NextcloudAccount account, NextcloudRemoteItem item, String localPath, NextcloudMirrorTier tier) async {
    final uri = Uri.file(localPath).toString();
    final fetched = await mediaFetchService.getEntry(uri, null, allowUnsized: true);
    if (fetched == null) return false;
    // Below `original`, the local bytes are a preview with no Exif of their own, so the device-side
    // cataloguer is skipped entirely in favour of the server's date and GPS: `presetCatalog` makes the
    // entry already `isCatalogued`, which is what `TagMixin.catalogEntriesTest` reads to decide whether
    // `analyze()` still has work to do for it. `original` keeps today's behaviour unchanged.
    final presetCatalog = tier == NextcloudMirrorTier.original ? null : catalogMetadataFromPhotoMetadata(fetched.id, item.photoMetadata);
    return _putEntry(uri, fetched, presetCatalog: presetCatalog);
  }

  @override
  Future<bool> putPlaceholder(NextcloudAccount account, NextcloudRemoteItem item) async {
    final localPath = _mirror.localPathFor(account, item.relativePath);
    // the URI a mirrored file for this path *would* have, so that a later fetch of real bytes refreshes
    // this entry in place instead of creating a second one for the same photo
    final uri = Uri.file(localPath).toString();
    final synthesised = _placeholders.build(account, item);
    if (synthesised == null) return false;
    // The location is overridden here rather than asked of the builder. `_putEntry` uses `uri` only as the
    // index key and stores `entry.uri`, so a builder that chose any other location would be keyed under
    // the mirror URI and stored under its own: after a restart `_loadIndex` rebuilds the index from the
    // stored URIs, the mirror URI would miss, and the next real fetch would create the second entry the
    // comment above says it prevents. Making the sink the only authority on where the entry claims to live
    // means a builder cannot get this wrong, and Leaf C never needs to know the mirror layout.
    //
    // There are no bytes behind a placeholder at all, so unlike the preview tier above, the server's
    // metadata is not merely the best source, it is the only one. An all-null `CatalogMetadata` still sets
    // `isCatalogued`, which is correct here rather than regrettable: an entry with no file has nothing for
    // the device cataloguer to do, and promotion recovers everything once an `original` put arrives with
    // `presetCatalog: null` and takes the forced-catalog branch.
    final presetCatalog = catalogMetadataFromPhotoMetadata(synthesised.id, item.photoMetadata);
    return _putEntry(
      uri,
      synthesised.copyWith(uri: uri, path: localPath),
      presetCatalog: presetCatalog,
    );
  }

  // insert-or-refresh for one URI, shared by both puts: everything below is about reconciling the DB row,
  // the loaded collection and the id index, none of which cares where the entry came from.
  //
  // `presetCatalog` is the server-sourced date and GPS for a preview-tier put (null for an original, which
  // keeps the device-side cataloguer as the sole source, as before). It is applied *instead of* the forced
  // re-catalog below, not alongside it: the local bytes behind a preview-tier entry have no Exif, so forcing
  // `entry.catalog()` on them would wipe exactly what the caller just supplied with nothing to replace it.
  Future<bool> _putEntry(String uri, AvesEntry fetched, {CatalogMetadata? presetCatalog}) async {
    final index = await _idByUri;
    final id = index[uri];
    if (id != null) {
      final existing = _source.getEntryById(id);
      if (existing != null) {
        // set before the refresh below, not after: `refreshEntries`' address step reads `existing`'s GPS
        // to geocode it, and it must see this put's coordinates, not the ones left by the previous one
        if (presetCatalog != null) {
          existing.catalogMetadata = presetCatalog.copyWith(id: existing.id);
          await localMediaDb.updateCatalogMetadata(existing.id, existing.catalogMetadata);
        }
        // same path, new bytes: refresh in place, so the entry keeps its id, favourite and cover
        await _source.refreshEntries(
          {existing},
          {
            EntryDataType.basic,
            EntryDataType.aspectRatio,
            EntryDataType.address,
            if (presetCatalog == null) EntryDataType.catalog,
          },
        );
      } else {
        // a row outside the loaded scope, or a reload in progress: update the row, and drop the metadata of
        // the old bytes so the entry is catalogued again when a full load adds it. The collection is not
        // touched. A preset catalog is written back right away instead of being dropped with the rest,
        // since nothing will ever re-derive it from these bytes.
        final updated = fetched.copyWith(id: id, origin: EntryOrigins.nextcloud);
        if (presetCatalog != null) updated.catalogMetadata = presetCatalog.copyWith(id: id);
        await localMediaDb.updateEntry(id, updated);
        await localMediaDb.removeIds({id}, dataTypes: {EntryDataType.catalog, EntryDataType.address});
        if (presetCatalog != null) await localMediaDb.updateCatalogMetadata(id, updated.catalogMetadata);
      }
      return true;
    }

    final entry = fetched.copyWith(id: localMediaDb.nextId, origin: EntryOrigins.nextcloud);
    if (presetCatalog != null) entry.catalogMetadata = presetCatalog.copyWith(id: entry.id);
    // added silently, and announced in batches by `flush`
    _source.addEntries({entry}, notify: false);
    // the row is written per file: a batched write would leave a mirrored file with an index row and no entry
    // after a crash, which no later sync can see (its etag matches)
    await localMediaDb.insertEntries({entry});
    // `insertEntries` writes the entry row only; `analyze()` would normally catalogue and persist this, but
    // it skips any entry that is already `isCatalogued`, which setting `presetCatalog` just made this one
    if (presetCatalog != null) await localMediaDb.saveCatalogMetadata({entry.catalogMetadata!});
    index[uri] = entry.id;
    _schedule(entry);
    return true;
  }

  @override
  Future<void> removeMirroredFiles(NextcloudAccount account, Set<String> relativePaths) async {
    if (relativePaths.isEmpty) return;
    await _removeUris(relativePaths.map((path) => _uriFor(account, path)).toSet());
  }

  @override
  Future<void> demoteToPlaceholders(NextcloudAccount account, Set<String> relativePaths) async {
    if (relativePaths.isEmpty) return;
    final index = await _idByUri;
    for (final path in relativePaths) {
      final uri = _uriFor(account, path);
      final id = index[uri];
      final entry = id == null ? null : _source.getEntryById(id);
      // a row outside the loaded scope (or none): nothing cached describes its bytes, and the next full
      // load reads the entry as it is, which is still the right entry
      if (entry == null) continue;
      // the decoded thumbnails and full images for this URI are of bytes that are no longer there; the
      // notifier is what the thumbnail and viewer widgets listen to, and it is announced after the
      // eviction so a listener that reloads does not find the stale image again
      EntryCache.evict(uri);
      entry.visualChangeNotifier.notify();
    }
  }

  // every entry under the account's mirror, with or without an index row (used by a purge)
  Future<void> removeAccountEntries(NextcloudAccount account) async {
    final index = await _idByUri;
    final uris = index.keys.where((uri) {
      final parsed = Uri.parse(uri);
      return parsed.isScheme('file') && _mirror.relativePathFor(account, parsed.toFilePath()) != null;
    }).toSet();
    await _removeUris(uris);
  }

  // Removes the rows, favourites and covers of `uris`, in and out of the collection. `source.removeEntries` only
  // knows the entries it holds, so rows outside the loaded scope are cleaned up directly; otherwise they would
  // come back as entries without a file on the next full load.
  Future<void> _removeUris(Set<String> uris) async {
    if (uris.isEmpty) return;
    final index = await _idByUri;
    _pending.removeWhere((entry) => uris.contains(entry.uri));
    final unloadedIds = <int>{};
    for (final uri in uris) {
      final id = index[uri];
      if (id != null && _source.getEntryById(id) == null) unloadedIds.add(id);
    }
    await _source.removeEntries(uris, includeTrash: true);
    if (unloadedIds.isNotEmpty) {
      await favourites.removeIds(unloadedIds);
      await covers.removeIds(unloadedIds);
      await localMediaDb.removeIds(unloadedIds);
    }
    uris.forEach(index.remove);
  }

  void _schedule(AvesEntry entry) {
    _pending.add(entry);
    if (_pending.length >= batchSize) {
      flush();
      return;
    }
    _flushTimer?.cancel();
    _flushTimer = Timer(flushDelay, flush);
  }

  // Announces the entries added since the last flush to the collection once, then catalogues them.
  // Called by the batch size, the delay, and the end of a sync.
  void flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_pending.isEmpty) return;
    final batch = Set.of(_pending);
    _pending.clear();
    _source
      ..updateDerivedFilters(batch)
      ..notifyAlbumsChanged()
      ..eventBus.fire(EntryAddedEvent(batch));
    unawaited(_source.analyze(null, entries: batch));
  }
}
