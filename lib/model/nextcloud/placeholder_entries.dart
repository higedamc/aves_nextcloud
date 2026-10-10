import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/origins.dart';
import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/remote_item.dart';

// Builds the gallery entry for an item the mirror holds no bytes for.
//
// Its own file, and its own seam, for one reason: every other entry in this source is built by handing a
// real `file://` path to `mediaFetchService.getEntry`, which reads the bytes to learn the dimensions, the
// mime type and the rotation. An entry with no bytes has to be synthesised from the WebDAV properties
// instead, and that is a different job from the sink's.
//
// Keeping it here keeps two leaves orthogonal: the sink (which owns cataloguing from properties) delegates
// to this interface and never needs to know how a path-less entry is made, while the leaf that adds video
// placeholders and streaming playback fills this file in without touching the sink.
abstract class NextcloudPlaceholderEntries {
  // `null` when no entry can be made for this item, which the sink reports as a refusal rather than a
  // failure: an item with no obtainable derivative is a normal outcome, not an error.
  AvesEntry? build(NextcloudAccount account, NextcloudRemoteItem item);
}

// Phase 0 placeholder for the implementation. Nothing creates placeholder rows yet, so this is unreachable;
// it throws rather than returning null so that the first caller gets a loud, locatable failure instead of
// silently losing every item it was supposed to show.
//
// Retired by the commit that wires `NextcloudPlaceholderEntriesImpl` into the sink's default. It is kept
// until then because the sink's constructor default still names it, and that file belongs to another leaf.
class UnimplementedNextcloudPlaceholderEntries implements NextcloudPlaceholderEntries {
  const new();

  @override
  AvesEntry? build(NextcloudAccount account, NextcloudRemoteItem item) {
    throw UnimplementedError('synthesising an entry without local bytes is not implemented yet');
  }
}

// The entry for a listed media item with no local bytes, built from the WebDAV properties alone.
//
// Who gets one: **every** media item the mirror does not hold bytes for, not only the videos above
// `videoAutoDownloadLimitBytes`. A video over the threshold is the case this was written for, but an image
// the server cannot derive a preview from (HEIC and HEIF under the default providers answer 404) takes the
// same path, so nothing here may assume a mime class. Both are items the server has listed and the gallery
// must show; the only thing they lack is bytes.
//
// What is deliberately absent, and why absence rather than a guess:
//
// - **the location.** `uri` is empty and `path` is null, because the sink is the single authority on where
//   the entry claims to live and overrides both (`NextcloudCollectionSyncSink.putPlaceholder`). Returning
//   empty rather than a plausible-looking path means an entry that somehow escaped the override is
//   obviously broken instead of subtly misfiled under a URI the id index does not key on.
// - **the id.** `_putEntry` owns it; whatever is passed here is re-stamped.
// - **the rotation.** It lives in the bytes, and for a portrait video shot on a phone it is the difference
//   between right-side-up and sideways. `0` is the only honest default, and it is why the poster that
//   arrives later from the device path (which does read the bytes) is what corrects the aspect.
// - **the duration.** WebDAV reports no duration, and `nc:metadata-photos-*` carries none, so it stays
//   null and the tile shows no badge rather than `0:00`.
//
// Dates follow the rule the preview tier settled: the server's `d:getlastmodified` becomes
// `dateModifiedMillis` so the entry sorts by when the file was written rather than when it was seen, and
// the capture date comes from `nc:metadata-photos-original_date_time` when the server has it. Both are
// **null when unknown, never 0** — a zero reads back as 1970 and sorts the item to the start of the
// library, which looks like data loss rather than a missing property.
class NextcloudPlaceholderEntriesImpl implements NextcloudPlaceholderEntries {
  const new();

  @override
  AvesEntry? build(NextcloudAccount account, NextcloudRemoteItem item) {
    // A collection is not an entry, and an item with no `d:getcontenttype` cannot be given a mime type
    // from anywhere else: `sourceMimeType` is non-nullable and every downstream decision (which decoder,
    // which tile, whether it plays) reads it. Refusing is the documented outcome, not an error.
    final mimeType = item.mimeType;
    if (item.isCollection || mimeType == null || !item.isMedia) return null;

    final photo = item.photoMetadata;
    return AvesEntry(
      id: null,
      uri: '',
      path: null,
      contentId: null,
      pageId: null,
      sourceMimeType: mimeType,
      // 0 means unknown to `displayAspectRatio`, which answers 1 for it, so an unsized tile is square
      // rather than a division by zero. The server gives real dimensions only for items it could
      // extract them from.
      width: photo?.width ?? 0,
      height: photo?.height ?? 0,
      sourceRotationDegrees: 0,
      // the original's size on the server, which is what an info page should show; nothing is held locally
      sizeBytes: item.sizeBytes,
      // null, not the file name: `sourceTitle` is for a title that differs from the path, and the sink
      // sets the path
      sourceTitle: null,
      // when it was added to *this device*, which is not something the server knows
      dateAddedSecs: null,
      dateModifiedMillis: item.lastModified.millisecondsSinceEpoch,
      sourceDateTakenMillis: photo?.originalDateTime?.millisecondsSinceEpoch,
      durationMillis: null,
      trashed: false,
      origin: EntryOrigins.nextcloud,
    );
  }
}
