import 'dart:convert';
import 'dart:io';

import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/remote_item.dart';

// Ports of the sync use case towards the app; the integration phase implements them.
// Keeping them abstract keeps `sync_use_case.dart` free of Flutter and app types, so the sync algorithm
// is tested on its own and the integration leaf only wires.

// Where mirrored files become (and stop being) gallery entries.
abstract class NextcloudSyncSink {
  // Creates or refreshes the entry for a file that is fully written at `localPath`
  // (`origin = EntryOrigins.nextcloud`). Returns false when the file could not be turned into an entry;
  // the sync then drops the mirror file again, so a file that is mirrored but invisible never survives
  // into the next run (its etag would match and it would be skipped forever).
  Future<bool> putMirroredFile(NextcloudAccount account, NextcloudRemoteItem item, String localPath);

  // Removes the entries of mirrored files that are gone (removed on the server, evicted, or missing).
  Future<void> removeMirroredFiles(NextcloudAccount account, Set<String> relativePaths);
}

// What a run knows about the previous one: the collection etags that were fully enumerated, and the cache
// limit they were enumerated under (a raised limit re-lists everything, so evicted files can come back).
class NextcloudSyncState {
  final Map<String, String> collectionEtags;
  final int cacheLimitBytes;

  const new({this.collectionEtags = const {}, this.cacheLimitBytes = 0});

  static const empty = NextcloudSyncState();

  Map<String, dynamic> toJson() => {'collectionEtags': collectionEtags, 'cacheLimitBytes': cacheLimitBytes};

  factory fromJson(Map<String, dynamic> json) {
    final etags = json['collectionEtags'];
    return NextcloudSyncState(
      collectionEtags: etags is Map ? etags.map((k, v) => MapEntry(k.toString(), v.toString())) : const {},
      cacheLimitBytes: json['cacheLimitBytes'] as int? ?? 0,
    );
  }
}

abstract class NextcloudSyncStateStore {
  Future<NextcloudSyncState> load(NextcloudAccount account);

  Future<void> save(NextcloudAccount account, NextcloudSyncState state);

  // forgets the account; the counterpart of `NextcloudMirrorStore.purge`
  Future<void> clear(NextcloudAccount account);
}

// One JSON file per account under `directory` (the mirror root, beside the account's mirror directory).
// Losing it costs one full listing, nothing else.
class FileNextcloudSyncStateStore implements NextcloudSyncStateStore {
  final String directory;

  const new(this.directory);

  File _fileFor(NextcloudAccount account) {
    if (!NextcloudAccount.isValidId(account.id)) {
      // defence in depth: the account store validates this, but this value becomes a file name
      throw ArgumentError.value(account.id, 'account.id', 'not a safe segment');
    }
    return File('$directory${Platform.pathSeparator}${account.id}.sync.json');
  }

  @override
  Future<NextcloudSyncState> load(NextcloudAccount account) async {
    final file = _fileFor(account);
    if (!await file.exists()) return NextcloudSyncState.empty;
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic> ? NextcloudSyncState.fromJson(decoded) : NextcloudSyncState.empty;
    } on FormatException {
      // a corrupt state file costs a full listing, not a failure
      return NextcloudSyncState.empty;
    }
  }

  @override
  Future<void> save(NextcloudAccount account, NextcloudSyncState state) async {
    final file = _fileFor(account);
    await file.parent.create(recursive: true);
    // write beside, then rename, so a crash never leaves a half-written state file
    final part = File('${file.path}.part');
    await part.writeAsString(jsonEncode(state.toJson()), flush: true);
    await part.rename(file.path);
  }

  @override
  Future<void> clear(NextcloudAccount account) async {
    final file = _fileFor(account);
    if (await file.exists()) await file.delete();
  }
}
