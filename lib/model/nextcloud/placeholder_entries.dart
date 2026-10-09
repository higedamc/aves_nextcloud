import 'package:aves/model/entry/entry.dart';
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
class UnimplementedNextcloudPlaceholderEntries implements NextcloudPlaceholderEntries {
  const new();

  @override
  AvesEntry? build(NextcloudAccount account, NextcloudRemoteItem item) {
    throw UnimplementedError('synthesising an entry without local bytes is not implemented yet');
  }
}
