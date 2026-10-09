import 'dart:convert';
import 'dart:io';

import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/mirror_store.dart';
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
  //
  // `tier` says what the bytes at `localPath` are. It matters to the entry and not only to the index:
  // below `NextcloudMirrorTier.original` the bytes carry no Exif at all, so date and location have to come
  // from `item.photoMetadata`, and the dimensions have to come from the bytes themselves rather than from
  // `photoMetadata.width/height` — the server reports those **un-rotated** while a preview has the
  // rotation burned in, so a portrait photo would otherwise be recorded as landscape.
  Future<bool> putMirroredFile(NextcloudAccount account, NextcloudRemoteItem item, String localPath, NextcloudMirrorTier tier);

  // Creates or refreshes the entry for an item the mirror holds **no bytes** for, so it appears in the
  // gallery and can be fetched on demand. Returns false when no entry could be made.
  //
  // Deliberately not `putMirroredFile` with a tier of `placeholder`: that signature takes a `localPath`,
  // and there is no path to give for bytes that do not exist. A caller would have to invent one, and the
  // sink would stat it, fail, and report a parse failure for an item that is in fact fine.
  Future<bool> putPlaceholder(NextcloudAccount account, NextcloudRemoteItem item);

  // Removes the entries of mirrored files that are gone (removed on the server, evicted, or missing).
  Future<void> removeMirroredFiles(NextcloudAccount account, Set<String> relativePaths);
}

// What a run knows about the previous one: the collection etags that were fully enumerated, and the cache
// limit they were enumerated under (a raised limit re-lists everything, so evicted files can come back).
//
// A persisted etag promises that the mirror holds every file under that subtree, which only a run that
// actually mirrored them can make. Now that a row can hold less than the whole file, "mirrored" has to name
// a tier, and the rule is:
//
// - an image is satisfied by a row at `NextcloudMirrorTier.grid` or later, with its bytes on disk,
// - a video is satisfied by its poster row, equally at `grid` or later,
// - **any** item whose derivative neither the server nor the device could produce is satisfied by a
//   `placeholder` row, which has no bytes by design. Not only a video above
//   `NextcloudAccount.videoAutoDownloadLimitBytes`: Nextcloud's default `enabledPreviewProviders` excludes
//   HEIC and HEIF, so an image that answers 404 is a real server shape, and if it had no satisfying
//   outcome it would withhold the root etag forever and re-list the whole tree on every sync — the exact
//   hole this rule exists to close. Whether a leaf prefers to fall back to the original for a small image
//   is its own call; the rule only has to admit the outcome.
// - the `view` and `original` tiers never enter the rule. They are fetched on demand, so requiring them
//   would mean no root etag is ever published again.
//
// The tier ordering is what makes this survivable in both directions: a row that holds an explicitly
// downloaded original satisfies a grid requirement, so an upgrade from a tier-less index (where every row
// is an original) does not look like a mirror full of holes.
class NextcloudSyncState {
  final Map<String, String> collectionEtags;

  // The limits the etags were earned under. A raised limit makes items wanted that the promised subtrees
  // skipped, so the next run must list everything; both default to 0 when absent, so a state written
  // before the field existed reads as "lower than whatever is set now" and costs exactly one full listing.
  final int cacheLimitBytes;
  final int videoAutoDownloadLimitBytes;

  const new({this.collectionEtags = const {}, this.cacheLimitBytes = 0, this.videoAutoDownloadLimitBytes = 0});

  static const empty = NextcloudSyncState();

  Map<String, dynamic> toJson() => {'collectionEtags': collectionEtags, 'cacheLimitBytes': cacheLimitBytes, 'videoAutoDownloadLimitBytes': videoAutoDownloadLimitBytes};

  static int _intOrZero(Object? value) => value is int ? value : 0;

  factory fromJson(Map<String, dynamic> json) {
    final etags = json['collectionEtags'];
    return NextcloudSyncState(
      collectionEtags: etags is Map ? etags.map((k, v) => MapEntry(k.toString(), v.toString())) : const {},
      // tolerant of a wrong type, not only a missing key: the file is ours, but a cast that throws here
      // would fail every sync until the file is deleted, and `load` only catches malformed JSON
      cacheLimitBytes: _intOrZero(json['cacheLimitBytes']),
      videoAutoDownloadLimitBytes: _intOrZero(json['videoAutoDownloadLimitBytes']),
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
