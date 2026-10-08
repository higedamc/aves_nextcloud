// Failure types for every Nextcloud layer. Implementations throw these; callers switch on the sealed type.
// Never embed credentials or full authenticated URLs in messages: they end up in reports and logs.
sealed class NextcloudFailure implements Exception {
  final String message;

  const new(this.message);

  @override
  String toString() => '$runtimeType{$message}';
}

// 401/403 from the server: wrong app password, revoked token, or user disabled
class NextcloudAuthFailure extends NextcloudFailure {
  final int statusCode;

  const new(this.statusCode) : super('authentication rejected (HTTP $statusCode)');
}

// DNS, connection refused, timeout, or connection reset
class NextcloudNetworkFailure extends NextcloudFailure {
  final Object? cause;

  const new(super.message, {this.cause});
}

// certificate validation failed; never offer to bypass, surface it to the user
class NextcloudTlsFailure extends NextcloudFailure {
  const new(super.message);
}

// account uses `http://` without the explicit per-account opt-in
class NextcloudInsecureSchemeFailure extends NextcloudFailure {
  const new() : super('http scheme refused without explicit opt-in');
}

// 404 for a path (root folder removed, item deleted between listing and download)
class NextcloudNotFoundFailure extends NextcloudFailure {
  final String relativePath;

  const new(this.relativePath) : super('not found: $relativePath');
}

// server refused the requested listing depth (sabre `propfind-finite-depth`); caller falls back to a `Depth: 1` crawl
class NextcloudDepthRefusedFailure extends NextcloudFailure {
  const new() : super('server refused infinite depth listing');
}

// not enough local space for the mirror, or the account cache limit cannot hold the requested item
class NextcloudQuotaFailure extends NextcloudFailure {
  final int requiredBytes, availableBytes;

  const new({required this.requiredBytes, required this.availableBytes}) : super('insufficient space: need $requiredBytes, have $availableBytes');
}

// malformed multistatus XML, unexpected content type, or missing mandatory props
class NextcloudParseFailure extends NextcloudFailure {
  const new(super.message);
}

// a server-provided `href` resolves outside the account root (or contains unsafe segments)
class NextcloudPathEscapeFailure extends NextcloudFailure {
  final String href;

  const new(this.href) : super('href escapes account root');
}

// any other non-success HTTP status (5xx, 423 locked, 429 throttled, ...)
class NextcloudServerFailure extends NextcloudFailure {
  final int statusCode;

  const new(this.statusCode, [String? detail]) : super('server error (HTTP $statusCode)${detail != null ? ': $detail' : ''}');
}

// the operation was cancelled through its `NextcloudCancellation`
class NextcloudCancelledFailure extends NextcloudFailure {
  const new() : super('cancelled');
}

// the local mirror could not be read or written (mirror root unavailable, a file that would not delete):
// a device-side problem, never a server verdict
class NextcloudLocalStorageFailure extends NextcloudFailure {
  final Object? cause;

  const new(super.message, {this.cause});
}
