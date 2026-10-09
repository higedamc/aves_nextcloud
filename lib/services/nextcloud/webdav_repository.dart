import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/errors.dart';
import 'package:aves/model/nextcloud/paths.dart';
import 'package:aves/model/nextcloud/remote_item.dart';
import 'package:aves/model/nextcloud/repository.dart';
import 'package:aves/services/nextcloud/dav_requests.dart';
import 'package:aves/services/nextcloud/multistatus_parser.dart';
import 'package:http/http.dart' as http;

// `NextcloudRepository` over plain HTTP(S) + WebDAV, built on `package:http` and `package:xml` only.
//
// Security properties, in one place:
// - credentials travel only as `Authorization: Basic` on requests to `account.serverUrl`; redirects are never
//   followed, so the header cannot leak to another host (a 3xx is reported as a server failure instead),
// - `http://` is refused unless the account opted in,
// - TLS validation is the platform default; there is no hook to weaken it,
// - every server-provided href is mapped through `NextcloudPaths.relativePathFromHref` and rejected if it
//   leaves the account root,
// - nothing from the credentials or request headers is ever put in a failure message.
class WebDavNextcloudRepository implements NextcloudRepository {
  static const requestTimeout = Duration(seconds: 30);
  static const searchPageSize = 500;
  static const _maxSearchPages = 10000;

  // nesting depth below the crawl root at which a collection is reported and not descended into
  static const maxCrawlDepth = 64;

  @override
  final NextcloudAccount account;

  final NextcloudCredentials _credentials;
  final http.Client _client;
  NextcloudServerInfo? _serverInfo;

  new(this.account, this._credentials, {http.Client? client}) : _client = client ?? http.Client();

  // last probe result, if any
  NextcloudServerInfo? get serverInfo => _serverInfo;

  @override
  Future<NextcloudServerInfo> probe() async {
    _checkScheme();

    // OPTIONS on the DAV root: verifies credentials (401 without them) and advertises the supported methods
    final options = await _send('OPTIONS', _davRootUrl());
    final allow = (_header(options.headers, 'allow') ?? '').toUpperCase().split(',').map((v) => v.trim()).toSet();
    final supportsSearch = allow.contains('SEARCH');

    String? version;
    try {
      final capabilities = await _send(
        'GET',
        _serverUrl('/ocs/v2.php/cloud/capabilities', query: {'format': 'json'}),
        headers: {'ocs-apirequest': 'true', 'accept': 'application/json'},
      );
      final decoded = jsonDecode(capabilities.body);
      if (decoded is Map) {
        final ocs = decoded['ocs'];
        final data = ocs is Map ? ocs['data'] : null;
        final versionMap = data is Map ? data['version'] : null;
        final string = versionMap is Map ? versionMap['string'] : null;
        if (string is String && string.isNotEmpty) version = string;
      }
    } on NextcloudAuthFailure {
      rethrow;
    } on NextcloudFailure {
      // capabilities are informational; a server that hides them is still usable
    } on FormatException {
      // non-JSON body, same as above
    }

    final major = int.tryParse(version?.split('.').first ?? '');
    final info = NextcloudServerInfo(
      version: version,
      supportsSearch: supportsSearch,
      // `Depth: infinity` is disabled on stock Nextcloud (sabre `propfind-finite-depth`) and cannot be detected
      // without a trial request, which this client never issues; the crawl does not need it
      supportsInfiniteDepth: false,
      supportsPhotoMetadata: major != null && major >= 28,
    );
    _serverInfo = info;
    return info;
  }

  @override
  Future<List<NextcloudRemoteItem>> listCollection(String relativePath) async => _listCollection(_normalize(relativePath), null);

  Future<List<NextcloudRemoteItem>> _listCollection(String path, NextcloudItemFailureCallback? onItemFailure) async {
    final items = await _propfind(path, depth: 1, onItemFailure: onItemFailure);
    return items.where((item) => item.relativePath != path).toList();
  }

  @override
  Future<NextcloudRemoteItem> stat(String relativePath) async {
    final path = _normalize(relativePath);
    final items = await _propfind(path, depth: 0);
    final self = items.where((item) => item.relativePath == path).firstOrNull;
    if (self == null) {
      throw NextcloudNotFoundFailure(path);
    }
    return self;
  }

  @override
  Stream<NextcloudRemoteItem> listMediaTree(
    String relativePath, {
    Map<String, String> knownCollectionEtags = const {},
    void Function(NextcloudRemoteItem collection)? onCollection,
    NextcloudItemFailureCallback? onItemFailure,
    NextcloudCancellation? cancellation,
  }) async* {
    final root = _normalize(relativePath);
    final info = _serverInfo ?? await probe();
    _checkCancelled(cancellation);

    // the root is listed strictly: if it cannot be listed, there is no tree to sync
    final rootItem = await stat(root);
    if (!rootItem.isCollection) {
      throw NextcloudNotFoundFailure(root);
    }
    if (knownCollectionEtags[root] == rootItem.etag) {
      // Nextcloud propagates etag changes up to every ancestor, so an unchanged root means an unchanged tree,
      // whichever strategy enumerated it last time
      onCollection?.call(rootItem);
      return;
    }

    if (info.supportsSearch) {
      _SearchSnapshot? snapshot;
      try {
        snapshot = await _searchMediaTree(root, onItemFailure, cancellation);
      } on NextcloudAuthFailure {
        rethrow;
      } on NextcloudCancelledFailure {
        rethrow;
      } on NextcloudNetworkFailure {
        rethrow;
      } on NextcloudTlsFailure {
        rethrow;
      } on NextcloudFailure {
        // server rejected or garbled the SEARCH: fall back to the crawl, which uses only PROPFIND
        snapshot = null;
      }
      if (snapshot != null) {
        for (final item in snapshot.items) {
          _checkCancelled(cancellation);
          yield item;
        }
        // one SEARCH covers the whole scope, so there is no subtree to publish or skip: the root is the only
        // collection the SEARCH strategy can vouch for. Its etag was read before the search started, so a
        // change made while paging bumps it and the next run lists again. An incomplete search (a hole the
        // server could not describe, a page the server would not serve) vouches for nothing, as in the crawl.
        if (snapshot.complete) {
          onCollection?.call(rootItem);
        }
        return;
      }
    }

    final crawl = _Crawl(root, knownCollectionEtags, onCollection, onItemFailure, cancellation);
    yield* _crawlCollection(rootItem, crawl, _Subtree(), 0);
  }

  Future<_SearchSnapshot> _searchMediaTree(String root, NextcloudItemFailureCallback? onItemFailure, NextcloudCancellation? cancellation) async {
    final scopeHref = NextcloudPaths.join('/files/${account.username}', NextcloudPaths.join(account.rootFolder, root));
    final results = <NextcloudRemoteItem>[];
    final seen = <String>{};
    var complete = false;
    // every failure reported while paging leaves the scope incompletely enumerated
    var reported = false;
    final NextcloudItemFailureCallback? onPageFailure = onItemFailure == null
        ? null
        : (path, failure) {
            reported = true;
            onItemFailure(path, failure);
          };
    for (var page = 0; page < _maxSearchPages; page++) {
      _checkCancelled(cancellation);
      final body = DavRequests.searchBody(scopeHref: scopeHref, limit: searchPageSize, offset: page * searchPageSize);
      final response = await _send(
        'SEARCH',
        _davRootUrl(),
        headers: {'content-type': 'text/xml; charset=utf-8'},
        body: body,
        relativePath: root,
      );
      final parsed = MultistatusParser.parsePage(response.body, rootHref: account.rootHref, onItemFailure: onPageFailure);
      var added = 0;
      for (final item in parsed.items) {
        if (item.isCollection || !item.isMedia) continue;
        if (!_isUnder(item.relativePath, root)) {
          _reportOrThrow(onPageFailure, item.relativePath, NextcloudPathEscapeFailure(item.relativePath));
          continue;
        }
        if (seen.add(item.relativePath)) {
          results.add(item);
          added++;
        }
      }
      // a short page is the last one; the response count is used rather than the item count because a page
      // can have holes (skipped hrefs, responses without a successful propstat) and still be full.
      // `added == 0` with items on a full page means the server ignored the offset: stop rather than loop
      // forever, and treat the scope as incomplete since the pages past the first were never served.
      // A full page whose responses all had holes has no items; keep paging, `_maxSearchPages` bounds it.
      if (parsed.responseCount < searchPageSize) {
        complete = true;
        break;
      }
      if (added == 0 && parsed.items.isNotEmpty) break;
    }
    return _SearchSnapshot(results, complete: complete && !reported);
  }

  // Lists `collection` and recurses into its changed sub-collections, depth first.
  // A collection's etag is published through `onCollection` only once its whole subtree has been listed
  // (or skipped as unchanged): the caller persists that etag as "this subtree was fully enumerated", and
  // on the next sync an unchanged ancestor is not descended into at all. Publishing before a descendant
  // fails would hide that descendant until something under the ancestor changes on the server.
  // The same holds per response: anything reported through `onItemFailure` while this collection is being
  // listed (an unmappable href, a response without a successful propstat, a result outside the collection)
  // leaves it incomplete, otherwise that one file would never be retried.
  Stream<NextcloudRemoteItem> _crawlCollection(NextcloudRemoteItem collection, _Crawl crawl, _Subtree subtree, int depth) async* {
    _checkCancelled(crawl.cancellation);
    final dir = collection.relativePath;
    final onItemFailure = crawl.onItemFailure;
    // every failure reported while listing `dir` makes `dir` incomplete
    final NextcloudItemFailureCallback? onListingFailure = onItemFailure == null
        ? null
        : (path, failure) {
            subtree.complete = false;
            onItemFailure(path, failure);
          };

    if (depth > maxCrawlDepth) {
      // a server can nest collections without end; the crawl must not follow it into the stack limit
      _reportOrThrow(onListingFailure, dir, const NextcloudParseFailure('collection deeper than $maxCrawlDepth levels'));
      return;
    }

    final List<NextcloudRemoteItem> children;
    try {
      children = await _listCollection(dir, onListingFailure);
    } on NextcloudFailure catch (e) {
      if (dir == crawl.root || onListingFailure == null || !_isItemLevel(e)) rethrow;
      // one sub-folder the server refuses (403 on a share without permission, 404 on a folder removed
      // meanwhile, a 5xx, a garbled body) must not stop the sync of everything else
      onListingFailure(dir, e);
      return;
    }
    for (final child in children) {
      if (!_isUnder(child.relativePath, dir)) {
        _reportOrThrow(onListingFailure, child.relativePath, NextcloudPathEscapeFailure(child.relativePath));
        continue;
      }
      if (child.isCollection) {
        if (crawl.knownCollectionEtags[child.relativePath] == child.etag) {
          // unchanged since it was last fully enumerated: skip it, and the etag is still good
          crawl.onCollection?.call(child);
          continue;
        }
        final sub = _Subtree();
        yield* _crawlCollection(child, crawl, sub, depth + 1);
        if (!sub.complete) subtree.complete = false;
      } else if (child.isMedia) {
        yield child;
      }
    }
    if (subtree.complete) {
      crawl.onCollection?.call(collection);
    }
  }

  @override
  Future<String?> downloadTo(
    NextcloudRemoteItem item,
    String localPath, {
    NextcloudProgressCallback? onProgress,
    NextcloudCancellation? cancellation,
  }) async {
    _checkScheme();
    _checkCancelled(cancellation);

    final request = _request('GET', account.filesUrl(item.relativePath));
    final response = await _guard(() => _client.send(request).timeout(requestTimeout));
    _checkStatus(response.statusCode, relativePath: item.relativePath);
    final total = response.contentLength;

    final target = File(localPath);
    final part = File('$localPath.part');
    await target.parent.create(recursive: true);
    final sink = part.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream.timeout(requestTimeout)) {
        _checkCancelled(cancellation);
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      if (total != null && received != total) {
        throw NextcloudNetworkFailure('incomplete download: $received of $total bytes');
      }
      await part.rename(localPath);
    } catch (error) {
      await sink.close().catchError((_) {});
      if (await part.exists()) {
        await part.delete();
      }
      throw _asFailure(error);
    }
    final etag = _header(response.headers, 'etag');
    return etag == null ? null : _unquote(etag);
  }

  @override
  Future<Uint8List> fetchPreview(NextcloudRemoteItem item, {required int width, required int height}) async {
    final fileId = item.fileId;
    if (fileId == null) {
      throw NextcloudNotFoundFailure(item.relativePath);
    }
    final response = await _send(
      'GET',
      _serverUrl('/core/preview', query: {'fileId': '$fileId', 'x': '$width', 'y': '$height', 'a': '1'}),
      relativePath: item.relativePath,
    );
    return response.bodyBytes;
  }

  @override
  void dispose() => _client.close();

  // request plumbing

  Future<List<NextcloudRemoteItem>> _propfind(String path, {required int depth, NextcloudItemFailureCallback? onItemFailure}) async {
    final response = await _send(
      'PROPFIND',
      account.filesUrl(path),
      headers: {'depth': '$depth', 'content-type': 'text/xml; charset=utf-8'},
      body: DavRequests.propfindBody,
      relativePath: path,
    );
    return MultistatusParser.parsePage(response.body, rootHref: account.rootHref, onItemFailure: onItemFailure).items;
  }

  static void _reportOrThrow(NextcloudItemFailureCallback? onItemFailure, String path, NextcloudFailure failure) {
    if (onItemFailure == null) throw failure;
    onItemFailure(path, failure);
  }

  // failures that concern one item or sub-tree rather than the account, the connection or the whole listing
  static bool _isItemLevel(NextcloudFailure failure) => switch (failure) {
    NextcloudServerFailure() || NextcloudNotFoundFailure() || NextcloudParseFailure() || NextcloudPathEscapeFailure() || NextcloudDepthRefusedFailure() => true,
    _ => false,
  };

  http.Request _request(String method, Uri url, {Map<String, String>? headers, String? body}) {
    final request = http.Request(method, url)
      ..followRedirects = false
      ..headers['authorization'] = _basicAuth();
    if (headers != null) request.headers.addAll(headers);
    if (body != null) request.body = body;
    return request;
  }

  Future<http.Response> _send(String method, Uri url, {Map<String, String>? headers, String? body, String relativePath = ''}) async {
    _checkScheme();
    final request = _request(method, url, headers: headers, body: body);
    final response = await _guard(() async {
      final streamed = await _client.send(request).timeout(requestTimeout);
      return http.Response.fromStream(streamed).timeout(requestTimeout);
    });
    _checkStatus(response.statusCode, relativePath: relativePath, body: response.body);
    return response;
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (error) {
      throw _asFailure(error);
    }
  }

  static NextcloudFailure _asFailure(Object error) {
    return switch (error) {
      NextcloudFailure() => error,
      TlsException() => NextcloudTlsFailure(error.message),
      SocketException() => NextcloudNetworkFailure(error.message, cause: error),
      HttpException() => NextcloudNetworkFailure(error.message, cause: error),
      http.ClientException() => NextcloudNetworkFailure(error.message, cause: error),
      TimeoutException() => const NextcloudNetworkFailure('request timed out'),
      FileSystemException() => NextcloudNetworkFailure('local write failed: ${error.message}', cause: error),
      _ => NextcloudNetworkFailure('unexpected error: ${error.runtimeType}', cause: error),
    };
  }

  void _checkStatus(int status, {required String relativePath, String? body}) {
    if (status >= 200 && status < 300) return;
    if (status == 401) throw NextcloudAuthFailure(status);
    if (status == 403) {
      if (body != null && body.contains('propfind-finite-depth')) throw const NextcloudDepthRefusedFailure();
      // Nextcloud answers an expired or wrong app password with 401; 403 is per resource (a share without
      // permission, an access-control app, a lock), so it is not an authentication failure and re-entering
      // the password would not fix it
      throw NextcloudServerFailure(status, 'access denied');
    }
    if (status == 404) throw NextcloudNotFoundFailure(relativePath);
    if (status >= 300 && status < 400) {
      throw NextcloudServerFailure(status, 'redirect refused; set the server URL to the final address');
    }
    throw NextcloudServerFailure(status);
  }

  void _checkScheme() {
    if (!account.isSchemeAllowed) {
      throw const NextcloudInsecureSchemeFailure();
    }
  }

  static void _checkCancelled(NextcloudCancellation? cancellation) {
    if (cancellation?.isCancelled ?? false) {
      throw const NextcloudCancelledFailure();
    }
  }

  String _basicAuth() => 'Basic ${base64Encode(utf8.encode('${_credentials.username}:${_credentials.appPassword}'))}';

  static String _normalize(String relativePath) {
    final normalized = NextcloudPaths.normalize(relativePath);
    if (normalized == null) {
      throw NextcloudPathEscapeFailure(relativePath);
    }
    return normalized;
  }

  static bool _isUnder(String relativePath, String dir) => dir.isEmpty || relativePath == dir || relativePath.startsWith('$dir${NextcloudPaths.separator}');

  String get _serverBasePath => account.serverUrl.path.replaceAll(RegExp(r'/+$'), '');

  Uri _serverUrl(String path, {Map<String, String>? query}) => account.serverUrl.replace(path: '$_serverBasePath$path', queryParameters: query);

  Uri _davRootUrl() => _serverUrl('/remote.php/dav/');

  static String? _header(Map<String, String> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value;
    }
    return null;
  }

  static String _unquote(String etag) {
    var value = etag.trim();
    if (value.startsWith('W/')) value = value.substring(2);
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    return value;
  }
}

// parameters shared by every level of one crawl
class _Crawl {
  final String root;
  final Map<String, String> knownCollectionEtags;
  final void Function(NextcloudRemoteItem collection)? onCollection;
  final NextcloudItemFailureCallback? onItemFailure;
  final NextcloudCancellation? cancellation;

  const new(this.root, this.knownCollectionEtags, this.onCollection, this.onItemFailure, this.cancellation);
}

// whether every collection under one crawl level was listed (or skipped as unchanged)
class _Subtree {
  bool complete = true;
}

// what one SEARCH over the scope returned, and whether it covered the whole scope
class _SearchSnapshot {
  final List<NextcloudRemoteItem> items;
  final bool complete;

  const new(this.items, {required this.complete});
}

class WebDavNextcloudRepositoryFactory implements NextcloudRepositoryFactory {
  final http.Client Function()? _clientBuilder;

  const new({this._clientBuilder});

  @override
  NextcloudRepository open(NextcloudAccount account, NextcloudCredentials credentials) {
    return WebDavNextcloudRepository(account, credentials, client: _clientBuilder?.call());
  }
}
