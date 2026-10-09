import 'dart:typed_data';

import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/errors.dart';
import 'package:aves/model/nextcloud/remote_item.dart';

// Cooperative cancellation handle shared by long operations (listing, downloads, sync).
class NextcloudCancellation {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() => _isCancelled = true;
}

typedef NextcloudProgressCallback = void Function(int receivedBytes, int? totalBytes);

// Reports one item (or one sub-collection) that could not be listed, so a listing keeps going past it.
// `path` is the relative path when it is known (a sub-collection that could not be listed), otherwise the
// raw server href (an href that could not be mapped inside the account root).
typedef NextcloudItemFailureCallback = void Function(String path, NextcloudFailure failure);

// Remote access contract (layer L1: WebDAV client). One instance is bound to one account + credentials.
// Implementations:
// - build URLs from `account.serverUrl` + `account.filesRootDavPath` + `NextcloudPaths.encodeForUrl(...)`,
// - send `Authorization: Basic` on every request, and nothing else identifying,
// - refuse `http://` unless `account.isSchemeAllowed`,
// - validate every `href` with `NextcloudPaths.relativePathFromHref` and throw `NextcloudPathEscapeFailure` otherwise,
// - throw only `NextcloudFailure` subtypes.
abstract class NextcloudRepository {
  NextcloudAccount get account;

  // Verifies credentials and detects server capabilities. Cheap; safe to call on every app start.
  Future<NextcloudServerInfo> probe();

  // Lists the direct children of `relativePath` (PROPFIND `Depth: 1`). The collection itself is not included.
  Future<List<NextcloudRemoteItem>> listCollection(String relativePath);

  // Properties of a single item (PROPFIND `Depth: 0`). Used for cheap etag comparisons before re-listing a subtree.
  Future<NextcloudRemoteItem> stat(String relativePath);

  // Recursively lists every media file under `relativePath` (`''` = account root folder).
  // Emits files only, never collections. Nested sub-directories at any depth are included: this is the
  // requirement other clients miss. Implementation strategy, in order of preference:
  //   1. WebDAV `SEARCH` on `/remote.php/dav/` with scope depth `infinity` and a mimetype `where` clause
  //      (what the official Photos web app uses; unaffected by the PROPFIND finite-depth restriction),
  //   2. PROPFIND `Depth: 1` crawl, skipping subtrees whose collection etag matches `knownCollectionEtags`.
  // Emission order is unspecified. Cancellation stops emission with `NextcloudCancelledFailure`.
  // `onCollection` is called for every collection the crawl visits or skips (with its current etag), so the
  // caller can persist etags for the next `knownCollectionEtags`. The SEARCH strategy enumerates the whole
  // scope in one query and has no subtrees to skip, so it consumes and publishes only the root's etag: an
  // unchanged root (Nextcloud propagates etag changes to every ancestor) ends the listing without a query, and
  // a complete query publishes the root. Sub-collection etags are consumed and published by the crawl only.
  // Either way, the root is stat'd first and a root that cannot be listed fails the whole listing.
  // `onItemFailure` receives item-level failures (an href that cannot be mapped inside the root, a sub-collection
  // that answers 403/404/5xx or with a body that is not a multistatus) and the listing continues without that
  // item; the sync records them as `NextcloudSyncResult.itemFailures`. Without it, the first such failure is
  // thrown. Failures that concern the whole listing (auth, network, TLS, cancellation, quota, and anything the
  // root collection itself answers) are always thrown.
  // A collection's etag is published through `onCollection` only after its whole subtree was listed or skipped
  // as unchanged, with nothing reported through `onItemFailure` anywhere under it; a reported item or
  // sub-collection keeps every ancestor unpublished, so the next crawl descends there again. A reported
  // collection was not enumerated at all: the caller must not treat its subtree as deleted.
  Stream<NextcloudRemoteItem> listMediaTree(
    String relativePath, {
    Map<String, String> knownCollectionEtags = const {},
    void Function(NextcloudRemoteItem collection)? onCollection,
    NextcloudItemFailureCallback? onItemFailure,
    NextcloudCancellation? cancellation,
  });

  // Downloads the original bytes of a file to `localPath`, writing to a temporary sibling first and renaming
  // on completion so a partial file is never visible to the gallery. Overwrites an existing file.
  // Returns the etag observed in the response (may differ from `item.etag` if the file changed meanwhile).
  Future<String?> downloadTo(
    NextcloudRemoteItem item,
    String localPath, {
    NextcloudProgressCallback? onProgress,
    NextcloudCancellation? cancellation,
  });

  // Server-generated preview of an image (`GET /core/preview?fileId=…&x=…&y=…&a=1`).
  //
  // Measured against Nextcloud 32.0.11, and binding on any implementation because callers size their
  // caches from it:
  // - the request is rounded **up** to a bucket and never upscaled past the original. The long-edge ladder
  //   observed is 64 / 256 / 341 / 1024 / 2048, so `width`/`height` are an upper bound and not a promise:
  //   a request for 512 is answered with the 1024 bucket, and a request for 320 with 256x341.
  // - `a=1` is mandatory. Without it the server crops to a square (`x=y=512` answered 1024x1024).
  // - the Exif orientation is **burned into the pixels** and the response carries no Exif at all, so the
  //   bytes display the right way up and carry no date, camera, lens or GPS. Those have to come from
  //   `NextcloudRemoteItem.photoMetadata`, which makes that field load-bearing rather than a hint.
  // - a 404 means "no preview for this item", not "no such item", and must be thrown as
  //   `NextcloudPreviewUnavailableFailure`. Every video on a server without ffmpeg answers 404 here while
  //   `nc:has-preview` still reports true.
  Future<Uint8List> fetchPreview(NextcloudRemoteItem item, {required int width, required int height});

  // Poster frame of a video, sized like `fetchPreview`, for a grid tile.
  //
  // Separate from `fetchPreview` because no Nextcloud server reached so far can produce one: the preview
  // endpoint answers 404 for every video unless `OC\Preview\Movie` is enabled with ffmpeg.
  //
  // Nothing calls this in the first cut. A video the mirror does not hold as an original gets a
  // `placeholder` row, and its poster comes from the device's own video thumbnail path against the remote
  // URL with headers, held by the image cache rather than the mirror. This port goes live only if the
  // measured wire cost of that path forces poster rows into the mirror, and the on-disk layout of such a
  // row goes into the contract before that happens. A caller that cannot obtain a frame throws
  // `NextcloudPreviewUnavailableFailure` and gets a `placeholder` row in answer.
  //
  // Implementations must not download the whole file to do this. An MP4 written by a phone is not
  // faststart (`ftyp` + `free` + `mdat`, with `moov` at the tail: measured at 147,691 bytes on a 1.91 GB
  // file), and the server supports `Range` (206), so the index and one keyframe are all that is needed.
  // Note that an extractor reading the file as a stream will fetch more than that through its read-ahead
  // cache; the cost has to be measured on the wire rather than assumed from the index size.
  Future<Uint8List> fetchPoster(NextcloudRemoteItem item, {required int width, required int height});

  // Releases connections. The instance must not be used afterwards.
  void dispose();
}

// Creates a repository for an account. Keeping credentials out of `NextcloudAccount` means the factory is the
// only place where the app password meets the network layer.
abstract class NextcloudRepositoryFactory {
  NextcloudRepository open(NextcloudAccount account, NextcloudCredentials credentials);
}
