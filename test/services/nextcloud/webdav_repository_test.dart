import 'dart:convert';
import 'dart:io';

import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/errors.dart';
import 'package:aves/model/nextcloud/remote_item.dart';
import 'package:aves/model/nextcloud/repository.dart';
import 'package:aves/services/nextcloud/webdav_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _account = NextcloudAccount(
  id: 'acc1',
  serverUrl: Uri.parse('https://host:31001'),
  username: 'alice',
  rootFolder: 'Photos',
  cacheLimitBytes: 1 << 30,
);
const _credentials = NextcloudCredentials(username: 'alice', appPassword: 'app-pass');
final _expectedAuth = 'Basic ${base64Encode(utf8.encode('alice:app-pass'))}';

String _collection(String href, String etag) => '''
  <d:response>
    <d:href>$href</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:getetag>"$etag"</d:getetag>
        <d:getlastmodified>Tue, 06 Oct 2026 10:00:00 GMT</d:getlastmodified>
        <oc:size>1</oc:size>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>''';

String _file(String href, String etag, {String mime = 'image/jpeg', int fileId = 1}) => '''
  <d:response>
    <d:href>$href</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:getetag>"$etag"</d:getetag>
        <d:getcontenttype>$mime</d:getcontenttype>
        <d:getcontentlength>3</d:getcontentlength>
        <d:getlastmodified>Tue, 06 Oct 2026 10:00:00 GMT</d:getlastmodified>
        <oc:fileid>$fileId</oc:fileid>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>''';

String _multistatus(List<String> responses) => '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">${responses.join()}</d:multistatus>';

const _davFiles = '/remote.php/dav/files/alice/Photos';

// a two-level tree: Photos/{a.jpg, notes.txt, Sub/{b.mp4}}
final _tree = <String, String>{
  '$_davFiles/': _multistatus([_collection('$_davFiles/', 'root-v1'), _file('$_davFiles/a.jpg', 'a-v1', fileId: 1), _file('$_davFiles/notes.txt', 'n-v1', mime: 'text/plain', fileId: 2), _collection('$_davFiles/Sub/', 'sub-v1')]),
  '$_davFiles/Sub/': _multistatus([_collection('$_davFiles/Sub/', 'sub-v1'), _file('$_davFiles/Sub/b.mp4', 'b-v1', mime: 'video/mp4', fileId: 3)]),
};

class _Server {
  final bool supportsSearch;
  final List<http.Request> requests = [];
  final Map<String, int> propfindDepthByPath = {};

  _Server({this.supportsSearch = true});

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    expect(request.headers['authorization'], _expectedAuth);
    expect(request.followRedirects, isFalse);
    final path = request.url.path;
    switch (request.method) {
      case 'OPTIONS':
        return http.Response('', 200, headers: {'Allow': 'OPTIONS, GET, HEAD, PROPFIND, PUT, REPORT${supportsSearch ? ', SEARCH' : ''}', 'DAV': '1, 3'});
      case 'GET':
        if (path == '/ocs/v2.php/cloud/capabilities') {
          return http.Response(jsonEncode({'ocs': {'data': {'version': {'string': '32.0.11'}}}}), 200);
        }
        if (path == '/core/preview') {
          return http.Response.bytes([0x89, 0x50, 0x4e, 0x47], 200);
        }
        if (path == '$_davFiles/a.jpg') {
          return http.Response.bytes([1, 2, 3], 200, headers: {'ETag': '"a-v1"'});
        }
        return http.Response('', 404);
      case 'PROPFIND':
        final depth = int.parse(request.headers['depth']!);
        final key = path.endsWith('/') ? path : '$path/';
        propfindDepthByPath[key] = depth;
        final body = _tree[key];
        if (body == null) return http.Response('', 404);
        if (depth == 0) {
          // only the self entry
          final selfOnly = _multistatus([_collection(key, key == '$_davFiles/' ? 'root-v1' : 'sub-v1')]);
          return http.Response(selfOnly, 207);
        }
        return http.Response(body, 207);
      case 'SEARCH':
        expect(path, '/remote.php/dav/');
        expect(request.body, contains('<d:href>/files/alice/Photos</d:href>'));
        expect(request.body, contains('<d:depth>infinity</d:depth>'));
        return http.Response(_multistatus([_file('$_davFiles/a.jpg', 'a-v1', fileId: 1), _file('$_davFiles/Sub/b.mp4', 'b-v1', mime: 'video/mp4', fileId: 3)]), 207);
    }
    return http.Response('', 405);
  }
}

WebDavNextcloudRepository _repo(_Server server) => WebDavNextcloudRepository(_account, _credentials, client: MockClient(server.handle));

void main() {
  test('probe reports version and SEARCH support from OPTIONS + capabilities', () async {
    final info = await _repo(_Server()).probe();
    expect(info.version, '32.0.11');
    expect(info.supportsSearch, isTrue);
    expect(info.supportsPhotoMetadata, isTrue);
    expect(info.supportsInfiniteDepth, isFalse);

    final noSearch = await _repo(_Server(supportsSearch: false)).probe();
    expect(noSearch.supportsSearch, isFalse);
  });

  test('listMediaTree uses SEARCH when supported and emits media files only', () async {
    final server = _Server();
    final items = await _repo(server).listMediaTree('').toList();
    expect(items.map((v) => v.relativePath), ['a.jpg', 'Sub/b.mp4']);
    expect(server.requests.where((r) => r.method == 'PROPFIND'), isEmpty);
  });

  test('listMediaTree crawls with PROPFIND Depth 1 when SEARCH is unavailable, recursing into sub-folders', () async {
    final server = _Server(supportsSearch: false);
    final collections = <NextcloudRemoteItem>[];
    final items = await _repo(server).listMediaTree('', onCollection: collections.add).toList();
    expect(items.map((v) => v.relativePath), ['a.jpg', 'Sub/b.mp4']);
    expect(collections.map((v) => '${v.relativePath}=${v.etag}'), ['=root-v1', 'Sub=sub-v1']);
    expect(server.propfindDepthByPath['$_davFiles/'], 1);
    expect(server.propfindDepthByPath['$_davFiles/Sub/'], 1);
    expect(server.requests.where((r) => r.method == 'SEARCH'), isEmpty);
  });

  test('crawl skips sub-trees whose collection etag is unchanged, and the whole tree when the root is unchanged', () async {
    final server = _Server(supportsSearch: false);
    final items = await _repo(server).listMediaTree('', knownCollectionEtags: {'Sub': 'sub-v1'}).toList();
    expect(items.map((v) => v.relativePath), ['a.jpg']);
    expect(server.propfindDepthByPath.containsKey('$_davFiles/Sub/'), isFalse);

    final unchanged = _Server(supportsSearch: false);
    final none = await _repo(unchanged).listMediaTree('', knownCollectionEtags: {'': 'root-v1'}).toList();
    expect(none, isEmpty);
    expect(unchanged.requests.where((r) => r.method == 'PROPFIND').length, 1);
  });

  test('listCollection and stat', () async {
    final repo = _repo(_Server());
    final children = await repo.listCollection('');
    expect(children.map((v) => v.relativePath), ['a.jpg', 'notes.txt', 'Sub']);
    final sub = await repo.stat('Sub');
    expect(sub.isCollection, isTrue);
    expect(sub.etag, 'sub-v1');
    await expectLater(repo.stat('Missing'), throwsA(isA<NextcloudNotFoundFailure>()));
  });

  test('downloadTo writes through a temporary file and returns the etag', () async {
    final dir = await Directory.systemTemp.createTemp('aves-nextcloud-test');
    try {
      final target = '${dir.path}/nested/a.jpg';
      final progress = <int>[];
      final item = (await _repo(_Server()).listCollection('')).firstWhere((v) => v.relativePath == 'a.jpg');
      final etag = await _repo(_Server()).downloadTo(item, target, onProgress: (received, total) => progress.add(received));
      expect(etag, 'a-v1');
      expect(await File(target).readAsBytes(), [1, 2, 3]);
      expect(await File('$target.part').exists(), isFalse);
      expect(progress.last, 3);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('downloadTo is cancellable and leaves no partial file', () async {
    final dir = await Directory.systemTemp.createTemp('aves-nextcloud-test');
    try {
      final target = '${dir.path}/a.jpg';
      final item = (await _repo(_Server()).listCollection('')).firstWhere((v) => v.relativePath == 'a.jpg');
      final cancellation = NextcloudCancellation()..cancel();
      await expectLater(_repo(_Server()).downloadTo(item, target, cancellation: cancellation), throwsA(isA<NextcloudCancelledFailure>()));
      expect(await File(target).exists(), isFalse);
      expect(await File('$target.part').exists(), isFalse);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('fetchPreview hits the core preview endpoint by file id', () async {
    final server = _Server();
    final item = (await _repo(server).listCollection('')).firstWhere((v) => v.relativePath == 'a.jpg');
    final bytes = await _repo(server).fetchPreview(item, width: 256, height: 256);
    expect(bytes.length, 4);
    final preview = server.requests.last;
    expect(preview.url.path, '/core/preview');
    expect(preview.url.queryParameters, {'fileId': '1', 'x': '256', 'y': '256', 'a': '1'});
  });

  test('maps HTTP statuses to failures', () async {
    Future<NextcloudRepository> withStatus(int status, {String body = ''}) async {
      return WebDavNextcloudRepository(_account, _credentials, client: MockClient((_) async => http.Response(body, status)));
    }

    await expectLater((await withStatus(401)).probe(), throwsA(isA<NextcloudAuthFailure>()));
    await expectLater((await withStatus(403)).probe(), throwsA(isA<NextcloudAuthFailure>()));
    await expectLater((await withStatus(403, body: '<s:exception>propfind-finite-depth</s:exception>')).listCollection(''), throwsA(isA<NextcloudDepthRefusedFailure>()));
    await expectLater((await withStatus(404)).listCollection('Sub'), throwsA(isA<NextcloudNotFoundFailure>()));
    await expectLater((await withStatus(302)).probe(), throwsA(isA<NextcloudServerFailure>()));
    await expectLater((await withStatus(503)).probe(), throwsA(isA<NextcloudServerFailure>()));
  });

  test('maps transport errors to network failures', () async {
    final repo = WebDavNextcloudRepository(_account, _credentials, client: MockClient((_) async => throw const SocketException('refused')));
    await expectLater(repo.probe(), throwsA(isA<NextcloudNetworkFailure>()));
  });

  test('refuses http:// unless the account opted in, before any request', () async {
    final server = _Server();
    final insecure = _account.copyWith(serverUrl: Uri.parse('http://host'));
    await expectLater(WebDavNextcloudRepository(insecure, _credentials, client: MockClient(server.handle)).probe(), throwsA(isA<NextcloudInsecureSchemeFailure>()));
    expect(server.requests, isEmpty);

    final optedIn = insecure.copyWith(allowInsecureHttp: true);
    await WebDavNextcloudRepository(optedIn, _credentials, client: MockClient(server.handle)).probe();
    expect(server.requests, isNotEmpty);
  });

  test('rejects unsafe relative paths before any request', () async {
    final server = _Server();
    await expectLater(_repo(server).listCollection('../etc'), throwsA(isA<NextcloudPathEscapeFailure>()));
    expect(server.requests, isEmpty);
  });

  test('failure messages never contain the app password', () async {
    final repo = WebDavNextcloudRepository(_account, _credentials, client: MockClient((_) async => http.Response('', 401)));
    try {
      await repo.probe();
      fail('expected failure');
    } on NextcloudFailure catch (e) {
      expect(e.toString(), isNot(contains('app-pass')));
      expect(e.toString(), isNot(contains(_expectedAuth)));
    }
  });
}
