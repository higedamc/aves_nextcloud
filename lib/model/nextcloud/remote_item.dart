// A file or collection as reported by the Nextcloud server (WebDAV PROPFIND/SEARCH).
// Immutable snapshot; identity is (relativePath) within one account.
class NextcloudRemoteItem {
  // relative to the account root folder, normalized by `NextcloudPaths.normalize`
  final String relativePath;

  // `oc:fileid`, stable across renames on the server, used for the preview endpoint
  final int? fileId;

  // `d:getetag`, changes when the content changes (for collections: when any descendant changes)
  final String etag;

  // `d:getcontenttype`, null for collections
  final String? mimeType;

  // `oc:size` (`d:getcontentlength` for files)
  final int sizeBytes;

  // `d:getlastmodified`
  final DateTime lastModified;

  final bool isCollection;

  // `nc:has-preview`
  final bool hasPreview;

  // from `nc:metadata-photos-*` when the server (Nextcloud 28+) provides them
  final NextcloudPhotoMetadata? photoMetadata;

  const new({
    required this.relativePath,
    required this.fileId,
    required this.etag,
    required this.mimeType,
    required this.sizeBytes,
    required this.lastModified,
    required this.isCollection,
    this.hasPreview = false,
    this.photoMetadata,
  });

  bool get isImage => mimeType?.startsWith('image/') ?? false;

  bool get isVideo => mimeType?.startsWith('video/') ?? false;

  bool get isMedia => isImage || isVideo;

  @override
  bool operator ==(Object other) => other is NextcloudRemoteItem && other.relativePath == relativePath && other.etag == etag;

  @override
  int get hashCode => Object.hash(relativePath, etag);

  @override
  String toString() => '$runtimeType{path=$relativePath, fileId=$fileId, etag=$etag, mime=$mimeType, size=$sizeBytes, collection=$isCollection}';
}

// Server-side extracted photo metadata (Nextcloud 28+ `nc:metadata-photos-size`, `-original_date_time`, `-gps`).
// Optional hint only: the local catalog pipeline remains the source of truth once the file is mirrored.
class NextcloudPhotoMetadata {
  final int? width, height;
  final DateTime? originalDateTime;
  final double? latitude, longitude;

  const new({
    this.width,
    this.height,
    this.originalDateTime,
    this.latitude,
    this.longitude,
  });

  bool get hasGps => latitude != null && longitude != null;

  @override
  String toString() => '$runtimeType{width=$width, height=$height, date=$originalDateTime, gps=${hasGps ? '$latitude,$longitude' : null}}';
}

// Result of `NextcloudRepository.probe`.
class NextcloudServerInfo {
  // e.g. `31.0.2`, null when the capabilities endpoint is unavailable
  final String? version;

  // whether the WebDAV `SEARCH` method with `depth=infinity` scope is usable (preferred recursive listing)
  final bool supportsSearch;

  // whether `PROPFIND` with `Depth: infinity` is enabled (sabre/dav default: disabled)
  final bool supportsInfiniteDepth;

  // whether the server provides `nc:metadata-photos-*` props
  final bool supportsPhotoMetadata;

  const new({
    required this.version,
    required this.supportsSearch,
    required this.supportsInfiniteDepth,
    required this.supportsPhotoMetadata,
  });

  @override
  String toString() => '$runtimeType{version=$version, search=$supportsSearch, infiniteDepth=$supportsInfiniteDepth, photoMetadata=$supportsPhotoMetadata}';
}
