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

  @override
  final NextcloudAccount account;

  final NextcloudCredentials _credentials;
  final http.Client _client;
  NextcloudServerInfo? _serverInfo;

  WebDavNextcloudRepository(this.account, this._credentials, {http.Client? client}) : _client = client ?? http.Client();

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
  Future<List<NextcloudRemoteItem>> listCollection(String relativePath) async {
    final path = _normalize(relativePath);
    final items = await _propfind(path, depth: 1);
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
    NextcloudCancellation? cancellation,
  }) async* {
    final root = _normalize(relativePath);
    final info = _serverInfo ?? await probe();

    if (info.supportsSearch) {
      List<NextcloudRemoteItem>? snapshot;
      try {
        snapshot = await _searchMediaTree(root, cancellation);
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
        for (final item in snapshot) {
          _checkCancelled(cancellation);
          yield item;
        }
        return;
      }
    }

    yield* _crawlMediaTree(root, knownCollectionEtags, onCollection, cancellation);
  }

  Future<List<NextcloudRemoteItem>> _searchMediaTree(String root, NextcloudCancellation? cancellation) async {
    final scopeHref = NextcloudPaths.join('/files/${account.username}', NextcloudPaths.join(account.rootFolder, root));
    final results = <NextcloudRemoteItem>[];
    final seen = <String>{};
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
      final items = MultistatusParser.parse(response.body, rootHref: account.rootHref);
      var added = 0;
      for (final item in items) {
        if (item.isCollection || !item.isMedia) continue;
        if (!_isUnder(item.relativePath, root)) {
          throw NextcloudPathEscapeFailure(item.relativePath);
        }
        if (seen.add(item.relativePath)) {
          results.add(item);
          added++;
        }
      }
      if (items.length < searchPageSize || added == 0) break;
    }
    return results;
  }

  Stream<NextcloudRemoteItem> _crawlMediaTree(
    String root,
    Map<String, String> knownCollectionEtags,
    void Function(NextcloudRemoteItem collection)? onCollection,
    NextcloudCancellation? cancellation,
  ) async* {
    _checkCancelled(cancellation);
    final rootItem = await stat(root);
    if (!rootItem.isCollection) {
      throw NextcloudNotFoundFailure(root);
    }
    onCollection?.call(rootItem);
    if (knownCollectionEtags[root] == rootItem.etag) {
      // Nextcloud propagates etag changes up to every ancestor, so an unchanged root means an unchanged tree
      return;
    }

    final pending = <String>[root];
    while (pending.isNotEmpty) {
      _checkCancelled(cancellation);
      final dir = pending.removeAt(0);
      final children = await listCollection(dir);
      for (final child in children) {
        if (!_isUnder(child.relativePath, dir)) {
          throw NextcloudPathEscapeFailure(child.relativePath);
        }
        if (child.isCollection) {
          onCollection?.call(child);
          if (knownCollectionEtags[child.relativePath] != child.etag) {
            pending.add(child.relativePath);
          }
        } else if (child.isMedia) {
          yield child;
        }
      }
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

  Future<List<NextcloudRemoteItem>> _propfind(String path, {required int depth}) async {
    final response = await _send(
      'PROPFIND',
      account.filesUrl(path),
      headers: {'depth': '$depth', 'content-type': 'text/xml; charset=utf-8'},
      body: DavRequests.propfindBody,
      relativePath: path,
    );
    return MultistatusParser.parse(response.body, rootHref: account.rootHref);
  }

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
      throw NextcloudAuthFailure(status);
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

class WebDavNextcloudRepositoryFactory implements NextcloudRepositoryFactory {
  final http.Client Function()? _clientBuilder;

  const WebDavNextcloudRepositoryFactory({http.Client Function()? clientBuilder}) : _clientBuilder = clientBuilder;

  @override
  NextcloudRepository open(NextcloudAccount account, NextcloudCredentials credentials) {
    return WebDavNextcloudRepository(account, credentials, client: _clientBuilder?.call());
  }
}
