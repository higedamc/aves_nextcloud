import 'dart:async';

import 'package:aves/model/covers.dart';
import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/origins.dart';
import 'package:aves/model/favourites.dart';
import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/mirror_store.dart';
import 'package:aves/model/nextcloud/remote_item.dart';
import 'package:aves/model/nextcloud/sync_ports.dart';
import 'package:aves/model/source/collection_source.dart';
import 'package:aves/model/source/events.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves_model/aves_model.dart';

// `NextcloudSyncSink` over the app collection (integration). A mirrored file becomes an entry the way a recovered
// vault item does: `mediaFetchService.getEntry` on its `file://` URI, `origin = nextcloud`, inserted in the DB and
// added to the source. It leaves through `removeEntries`, which also drops its DB row, favourite and cover.
class NextcloudCollectionSyncSink implements NextcloudSyncSink {
  final CollectionSource _source;
  final NextcloudMirrorStore _mirror;

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

  new(this._source, this._mirror) {
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
    final rows = await localMediaDb.loadEntries(origin: EntryOrigins.nextcloud);
    return {for (final row in rows) row.uri: row.id};
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
  Future<bool> putMirroredFile(NextcloudAccount account, NextcloudRemoteItem item, String localPath) async {
    final uri = Uri.file(localPath).toString();
    final fetched = await mediaFetchService.getEntry(uri, null, allowUnsized: true);
    if (fetched == null) return false;

    final index = await _idByUri;
    final id = index[uri];
    if (id != null) {
      final existing = _source.getEntryById(id);
      if (existing != null) {
        // same path, new bytes: refresh in place, so the entry keeps its id, favourite and cover
        await _source.refreshEntries({existing}, {EntryDataType.basic, EntryDataType.aspectRatio, EntryDataType.catalog, EntryDataType.address});
      } else {
        // a row outside the loaded scope, or a reload in progress: update the row, and drop the metadata of the
        // old bytes so the entry is catalogued again when a full load adds it. The collection is not touched.
        await localMediaDb.updateEntry(id, fetched.copyWith(id: id, origin: EntryOrigins.nextcloud));
        await localMediaDb.removeIds({id}, dataTypes: {EntryDataType.catalog, EntryDataType.address});
      }
      return true;
    }

    final entry = fetched.copyWith(id: localMediaDb.nextId, origin: EntryOrigins.nextcloud);
    // added silently, and announced in batches by `flush`
    _source.addEntries({entry}, notify: false);
    // the row is written per file: a batched write would leave a mirrored file with an index row and no entry
    // after a crash, which no later sync can see (its etag matches)
    await localMediaDb.insertEntries({entry});
    index[uri] = entry.id;
    _schedule(entry);
    return true;
  }

  @override
  Future<void> removeMirroredFiles(NextcloudAccount account, Set<String> relativePaths) async {
    if (relativePaths.isEmpty) return;
    await _removeUris(relativePaths.map((path) => _uriFor(account, path)).toSet());
  }

  // every entry under the account's mirror, with or without an index row (used by a purge)
  Future<void> removeAccountEntries(NextcloudAccount account) async {
    final index = await _idByUri;
    final uris = index.keys.where((uri) => _mirror.relativePathFor(account, Uri.parse(uri).toFilePath()) != null).toSet();
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
