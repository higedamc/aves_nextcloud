import 'dart:typed_data';

import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/remote_item.dart';

// Cooperative cancellation handle shared by long operations (listing, downloads, sync).
class NextcloudCancellation {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() => _isCancelled = true;
}

typedef NextcloudProgressCallback = void Function(int receivedBytes, int? totalBytes);

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
  // caller can persist etags for the next `knownCollectionEtags`. The SEARCH strategy returns a full snapshot
  // and never calls it; a caller that gets no collection callbacks must diff against the full snapshot.
  Stream<NextcloudRemoteItem> listMediaTree(
    String relativePath, {
    Map<String, String> knownCollectionEtags = const {},
    void Function(NextcloudRemoteItem collection)? onCollection,
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

  // Server-generated preview (`GET /core/preview?fileId=…&x=…&y=…&a=1`). Not used by v1 (which mirrors originals);
  // reserved for the later Glide-model path that lets the grid work without originals.
  Future<Uint8List> fetchPreview(NextcloudRemoteItem item, {required int width, required int height});

  // Releases connections. The instance must not be used afterwards.
  void dispose();
}

// Creates a repository for an account. Keeping credentials out of `NextcloudAccount` means the factory is the
// only place where the app password meets the network layer.
abstract class NextcloudRepositoryFactory {
  NextcloudRepository open(NextcloudAccount account, NextcloudCredentials credentials);
}
