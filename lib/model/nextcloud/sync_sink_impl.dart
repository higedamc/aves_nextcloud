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
  Map<String, AvesEntry>? _byUri;
  final Set<StreamSubscription> _subscriptions = {};

  // cataloguing is batched: a sync puts files one at a time, and `analyze` is sized for sets of entries
  final Set<AvesEntry> _pendingAnalysis = {};
  Timer? _analysisTimer;
  static const analysisBatchSize = 100;
  static const analysisDelay = Duration(seconds: 2);

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
    _analysisTimer?.cancel();
    _pendingAnalysis.clear();
  }

  Map<String, AvesEntry> get _index => _byUri ??= {
    for (final entry in _source.allEntries)
      if (entry.isNextcloud) entry.uri: entry,
  };

  void _onSourceStateChanged() {
    if (_source.state == SourceState.loading) _byUri = null;
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
    _pendingAnalysis.removeAll(event.entries);
  }

  String _uriFor(NextcloudAccount account, String relativePath) => Uri.file(_mirror.localPathFor(account, relativePath)).toString();

  @override
  Future<bool> putMirroredFile(NextcloudAccount account, NextcloudRemoteItem item, String localPath) async {
    final uri = Uri.file(localPath).toString();
    final fetched = await mediaFetchService.getEntry(uri, null, allowUnsized: true);
    if (fetched == null) return false;

    final existing = _index[uri];
    if (existing != null && !identical(_source.getEntryById(existing.id), existing)) {
      // the source dropped it behind our back; treat the file as new
      _index.remove(uri);
    } else if (existing != null) {
      // same path, new bytes: refresh in place, so the entry keeps its id, favourite and cover
      await _source.refreshEntries({existing}, {EntryDataType.basic, EntryDataType.aspectRatio, EntryDataType.catalog, EntryDataType.address});
      return true;
    }

    final entry = fetched.copyWith(id: localMediaDb.nextId, origin: EntryOrigins.nextcloud);
    _source.addEntries({entry});
    await localMediaDb.insertEntries({entry});
    _index[uri] = entry;
    _scheduleAnalysis(entry);
    return true;
  }

  @override
  Future<void> removeMirroredFiles(NextcloudAccount account, Set<String> relativePaths) async {
    if (relativePaths.isEmpty) return;
    final uris = relativePaths.map((path) => _uriFor(account, path)).toSet();
    _pendingAnalysis.removeWhere((entry) => uris.contains(entry.uri));
    await _source.removeEntries(uris, includeTrash: true);
  }

  // every entry under the account's mirror, with or without an index row (used by a purge)
  Future<void> removeAccountEntries(NextcloudAccount account) async {
    final uris = _index.values
        .where((entry) {
          final path = entry.path;
          return path != null && _mirror.relativePathFor(account, path) != null;
        })
        .map((entry) => entry.uri)
        .toSet();
    if (uris.isEmpty) return;
    _pendingAnalysis.removeWhere((entry) => uris.contains(entry.uri));
    await _source.removeEntries(uris, includeTrash: true);
  }

  void _scheduleAnalysis(AvesEntry entry) {
    _pendingAnalysis.add(entry);
    if (_pendingAnalysis.length >= analysisBatchSize) {
      flushAnalysis();
      return;
    }
    _analysisTimer?.cancel();
    _analysisTimer = Timer(analysisDelay, flushAnalysis);
  }

  void flushAnalysis() {
    _analysisTimer?.cancel();
    _analysisTimer = null;
    if (_pendingAnalysis.isEmpty) return;
    final batch = Set.of(_pendingAnalysis);
    _pendingAnalysis.clear();
    unawaited(_source.analyze(null, entries: batch));
  }
}
