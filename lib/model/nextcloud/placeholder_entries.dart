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
// placeholders and streaming playback owns this file without touching the sink.
//
// An implementation must be total over the items the sync hands it: it reports "no entry for this one" by
// returning null, and must not throw. A throw from here is not a `NextcloudFailure`, so the per-item
// `on NextcloudFailure catch` in `NextcloudSyncUseCaseImpl._run` does not catch it, and one unmirrorable
// item would abort the run for the whole account with no etags saved. That is measured, not hypothetical:
// the Phase 0 stub that threw did exactly this on a 1.27 GB mp4 on 2026-10-11.
abstract class NextcloudPlaceholderEntries {
  // `null` when no entry can be made for this item, which the sink reports as a refusal rather than a
  // failure: an item with no obtainable derivative is a normal outcome, not an error.
  AvesEntry? build(NextcloudAccount account, NextcloudRemoteItem item);
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
// library, which looks like data loss rather than a missing property. `NextcloudRemoteItem.lastModified`
// is not nullable, and `MultistatusParser` answers the epoch for a header it cannot read, so "unknown"
// arrives here as 0 and is turned back into null below.
//
// Every number here is the server's claim about a file this device has never read, and this is the first
// entry in the source whose shape comes from a claim rather than from bytes a decoder measured. So the two
// fields the UI divides by are taken only when they are usable: `displayAspectRatio` guards `== 0` alone,
// and a negative width reaches `AspectRatio` in the viewer, which asserts a positive ratio.
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
    // both or neither: one usable side is not an aspect ratio, and 0 is what `displayAspectRatio` reads
    // as unknown (it answers 1, so the tile is square instead of dividing by zero or going negative)
    final width = photo?.width, height = photo?.height;
    final sized = width != null && height != null && width > 0 && height > 0;
    // the parser's "unknown" for a date it could not read; 1970 is not a date this item has
    final modifiedMillis = item.lastModified.millisecondsSinceEpoch;
    return AvesEntry(
      id: null,
      uri: '',
      path: null,
      contentId: null,
      pageId: null,
      sourceMimeType: mimeType,
      // the server gives real dimensions only for items it could extract them from
      width: sized ? width : 0,
      height: sized ? height : 0,
      sourceRotationDegrees: 0,
      // the original's size on the server, which is what an info page should show; nothing is held locally
      sizeBytes: item.sizeBytes,
      // null, not the file name: `sourceTitle` is for a title that differs from the path, and the sink
      // sets the path
      sourceTitle: null,
      // when it was added to *this device*, which is not something the server knows
      dateAddedSecs: null,
      dateModifiedMillis: modifiedMillis == 0 ? null : modifiedMillis,
      sourceDateTakenMillis: photo?.originalDateTime?.millisecondsSinceEpoch,
      durationMillis: null,
      trashed: false,
      origin: EntryOrigins.nextcloud,
    );
  }
}
