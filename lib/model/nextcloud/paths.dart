// Remote path rules shared by every Nextcloud layer (WebDAV client, mirror store, sync).
//
// A "relative path" is relative to the account root folder, uses `/` as separator,
// has no leading or trailing `/`, and `''` denotes the root itself.
// Normalization rejects anything that could escape the root on either side:
// `.`/`..` segments, empty segments, backslashes, and control characters.
class NextcloudPaths {
  static const separator = '/';

  /// Returns the normalized relative path, or `null` when the input is unsafe.
  static String? normalize(String raw) {
    final trimmed = raw.replaceAll(RegExp(r'^/+|/+$'), '');
    if (trimmed.isEmpty) return '';

    final segments = trimmed.split(separator);
    for (final segment in segments) {
      if (!isSafeSegment(segment)) return null;
    }
    return segments.join(separator);
  }

  static bool isSafeSegment(String segment) {
    if (segment.isEmpty || segment == '.' || segment == '..') return false;
    if (segment.contains(separator) || segment.contains('\\')) return false;
    for (final codeUnit in segment.codeUnits) {
      if (codeUnit < 0x20 || codeUnit == 0x7f) return false;
    }
    return true;
  }

  static String join(String parent, String child) => parent.isEmpty
      ? child
      : child.isEmpty
      ? parent
      : '$parent$separator$child';

  static String parentOf(String relativePath) {
    final index = relativePath.lastIndexOf(separator);
    return index < 0 ? '' : relativePath.substring(0, index);
  }

  static String nameOf(String relativePath) {
    final index = relativePath.lastIndexOf(separator);
    return index < 0 ? relativePath : relativePath.substring(index + 1);
  }

  /// Percent-encodes each segment for use in a WebDAV URL, keeping `/` as separator.
  static String encodeForUrl(String relativePath) => relativePath.split(separator).where((v) => v.isNotEmpty).map(Uri.encodeComponent).join(separator);

  /// Converts a server-provided `href` back to a relative path, given the files root
  /// as it appears in hrefs (e.g. `/remote.php/dav/files/alice/Photos`, unencoded).
  /// Accepts both path-only hrefs and absolute ones (`https://host/remote.php/dav/...`),
  /// as sabre/dav emits either depending on its base URI / reverse proxy setup.
  /// Returns `null` when the href is outside that root, unsafe, or not decodable:
  /// this function never throws, so callers can map `null` to `NextcloudPathEscapeFailure`.
  static String? relativePathFromHref(String href, String rootHref) {
    final String decoded;
    try {
      final parsed = Uri.parse(href);
      final rawPath = parsed.hasScheme || parsed.hasAuthority ? parsed.path : href;
      decoded = _stripTrailingSeparators(Uri.decodeFull(rawPath));
    } catch (_) {
      // `Uri.parse` / `Uri.decodeFull` report malformed input with different error types
      // (`FormatException`, `ArgumentError` for invalid UTF-8); all mean "not a usable href"
      return null;
    }
    final decodedRoot = _stripTrailingSeparators(rootHref);
    if (decoded == decodedRoot) return '';
    if (!decoded.startsWith('$decodedRoot$separator')) return null;
    return normalize(decoded.substring(decodedRoot.length + 1));
  }

  static String _stripTrailingSeparators(String path) => path.replaceAll(RegExp(r'/+$'), '');
}
