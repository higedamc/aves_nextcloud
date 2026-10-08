import 'dart:async';

import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/extensions/nextcloud.dart';
import 'package:aves/model/entry/origins.dart';
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

  // Nextcloud entries by URI, so a put does not scan `allEntries` (a copy of the whole collection) per file.
  // Rebuilt whenever the source reloads (`clearEntries` happens under `SourceState.loading`), and kept in step
  // with adds and removals through the event bus: the sink is the only writer of these entries, but the source
  // may drop one on its own (a refresh of an entry whose file is gone).
  //
  // The index is only read once the source is out of `loading`: a full reload (`MediaStoreSource._loadEntries`,
  // reached from startup, a widened scope and the album/tag pickers) clears the collection first and adds the
  // `origin = nextcloud` rows last, so an index built in between would answer "no entry" for a URI that has a DB
  // row, and the put would insert a second row for it. The source leaves `loading` only after those rows are in.
  Map<String, AvesEntry>? _byUri;
  Completer<void>? _loaded;
  final Set<StreamSubscription> _subscriptions = {};

  // Cataloguing and collection notification are batched: a sync puts files one at a time, `analyze` is sized for
  // sets of entries, and a notified `addEntries` makes every open grid re-sort the whole collection.
  final Set<AvesEntry> _pending = {};
  Timer? _flushTimer;
  static const batchSize = 100;
  static const flushDelay = Duration(seconds: 2);

  new(this._source, this._mirror) {
    _source.stateNotifier.addListener(_onSourceStateChanged);
    _subscriptions.add(_source.eventBus.on<EntryAddedEvent>().listen(_onEntriesAdded));
    _subscriptions.add(_source.eventBus.on<EntryRemovedEvent>().listen(_onEntriesRemoved));
  }

  void dispose() {
    _source.stateNotifier.removeListener(_onSourceStateChanged);
    _subscriptions
      ..forEach((sub) => sub.cancel())
      ..clear();
    _flushTimer?.cancel();
    _pending.clear();
  }

  Map<String, AvesEntry> get _index => _byUri ??= {
    for (final entry in _source.allEntries)
      if (entry.isNextcloud) entry.uri: entry,
  };

  // completes once the source is not loading, i.e. once every stored entry is in the collection
  Future<void> _whenLoaded() {
    if (_source.state != SourceState.loading) return Future.value();
    return (_loaded ??= Completer<void>()).future;
  }

  void _onSourceStateChanged() {
    if (_source.state == SourceState.loading) {
      _byUri = null;
    } else {
      _loaded?.complete();
      _loaded = null;
    }
  }

  void _onEntriesAdded(EntryAddedEvent event) {
    final index = _byUri;
    if (index == null) return;
    event.entries?.where((entry) => entry.isNextcloud).forEach((entry) => index[entry.uri] = entry);
  }

  void _onEntriesRemoved(EntryRemovedEvent event) {
    final index = _byUri;
    if (index != null) {
      final uris = event.entries.map((entry) => entry.uri).toSet();
      index.removeWhere((uri, _) => uris.contains(uri));
    }
    _pending.removeAll(event.entries);
  }

  String _uriFor(NextcloudAccount account, String relativePath) => Uri.file(_mirror.localPathFor(account, relativePath)).toString();

  @override
  Future<bool> putMirroredFile(NextcloudAccount account, NextcloudRemoteItem item, String localPath) async {
    final uri = Uri.file(localPath).toString();
    final fetched = await mediaFetchService.getEntry(uri, null, allowUnsized: true);
    if (fetched == null) return false;

    // from here to `addEntries` nothing yields, so the index and the collection cannot change under the lookup
    await _whenLoaded();
    final existing = _index[uri];
    if (existing != null && !identical(_source.getEntryById(existing.id), existing)) {
      // the source dropped it behind our back; treat the file as new, without leaving a row for the old entry
      _index.remove(uri);
      await localMediaDb.removeIds({existing.id});
    } else if (existing != null) {
      // same path, new bytes: refresh in place, so the entry keeps its id, favourite and cover
      await _source.refreshEntries({existing}, {EntryDataType.basic, EntryDataType.aspectRatio, EntryDataType.catalog, EntryDataType.address});
      return true;
    }

    final entry = fetched.copyWith(id: localMediaDb.nextId, origin: EntryOrigins.nextcloud);
    // added silently, and announced in batches by `flush`
    _source.addEntries({entry}, notify: false);
    // the row is written per file: a batched write would leave a mirrored file with an index row and no entry
    // after a crash, which no later sync can see (its etag matches)
    await localMediaDb.insertEntries({entry});
    _index[uri] = entry;
    _schedule(entry);
    return true;
  }

  @override
  Future<void> removeMirroredFiles(NextcloudAccount account, Set<String> relativePaths) async {
    if (relativePaths.isEmpty) return;
    final uris = relativePaths.map((path) => _uriFor(account, path)).toSet();
    _pending.removeWhere((entry) => uris.contains(entry.uri));
    await _source.removeEntries(uris, includeTrash: true);
  }

  // every entry under the account's mirror, with or without an index row (used by a purge)
  Future<void> removeAccountEntries(NextcloudAccount account) async {
    await _whenLoaded();
    final uris = _index.values
        .where((entry) {
          final path = entry.path;
          return path != null && _mirror.relativePathFor(account, path) != null;
        })
        .map((entry) => entry.uri)
        .toSet();
    if (uris.isEmpty) return;
    _pending.removeWhere((entry) => uris.contains(entry.uri));
    await _source.removeEntries(uris, includeTrash: true);
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
