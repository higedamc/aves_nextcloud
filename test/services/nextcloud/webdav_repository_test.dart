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

String _collection(String href, String etag) =>
    '''
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

String _file(String href, String etag, {String mime = 'image/jpeg', int fileId = 1}) =>
    '''
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

// a response the server cannot describe: no successful propstat
String _unreadable(String href) =>
    '''
  <d:response>
    <d:href>$href</d:href>
    <d:propstat>
      <d:prop><d:getetag/><d:getcontenttype/></d:prop>
      <d:status>HTTP/1.1 403 Forbidden</d:status>
    </d:propstat>
  </d:response>''';

String _multistatus(List<String> responses) => '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">${responses.join()}</d:multistatus>';

const _davFiles = '/remote.php/dav/files/alice/Photos';

// a three-level tree: Photos/{a.jpg, notes.txt, Sub/{b.mp4, Deep/{c.jpg}}}
final _tree = <String, String>{
  '$_davFiles/': _multistatus([_collection('$_davFiles/', 'root-v1'), _file('$_davFiles/a.jpg', 'a-v1', fileId: 1), _file('$_davFiles/notes.txt', 'n-v1', mime: 'text/plain', fileId: 2), _collection('$_davFiles/Sub/', 'sub-v1')]),
  '$_davFiles/Sub/': _multistatus([_collection('$_davFiles/Sub/', 'sub-v1'), _file('$_davFiles/Sub/b.mp4', 'b-v1', mime: 'video/mp4', fileId: 3), _collection('$_davFiles/Sub/Deep/', 'deep-v1')]),
  '$_davFiles/Sub/Deep/': _multistatus([_collection('$_davFiles/Sub/Deep/', 'deep-v1'), _file('$_davFiles/Sub/Deep/c.jpg', 'c-v1', fileId: 4)]),
};

class _Server {
  final bool supportsSearch;
  final List<http.Request> requests = [];
  final Map<String, int> propfindDepthByPath = {};

  // collection paths (with trailing slash) that answer PROPFIND with 403
  final Set<String> forbidden = {};

  // an extra file response injected into the root listing and the SEARCH result
  String? injectedHref;

  // a raw response injected into the root listing
  String? injectedRootResponse;

  // advertise SEARCH but answer it with 400, so the fallback crawl is taken
  bool rejectSearch = false;

  new({this.supportsSearch = true});

  String _withInjected(String body) {
    final href = injectedHref;
    if (href == null) return body;
    return body.replaceFirst('</d:multistatus>', '${_file(href, 'x-v1', fileId: 9)}</d:multistatus>');
  }

  String _withInjectedRoot(String body) {
    final response = injectedRootResponse;
    if (response == null) return body;
    return body.replaceFirst('</d:multistatus>', '$response</d:multistatus>');
  }

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
          return http.Response(
            jsonEncode({
              'ocs': {
                'data': {
                  'version': {'string': '32.0.11'},
                },
              },
            }),
            200,
          );
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
        if (forbidden.contains(key)) return http.Response('', 403);
        final body = _tree[key];
        if (body == null) return http.Response('', 404);
        if (depth == 0) {
          // only the self entry
          final selfOnly = _multistatus([_collection(key, key == '$_davFiles/' ? 'root-v1' : 'sub-v1')]);
          return http.Response(selfOnly, 207);
        }
        return http.Response(key == '$_davFiles/' ? _withInjectedRoot(_withInjected(body)) : body, 207);
      case 'SEARCH':
        if (rejectSearch) return http.Response('', 400);
        expect(path, '/remote.php/dav/');
        expect(request.body, contains('<d:href>/files/alice/Photos</d:href>'));
        expect(request.body, contains('<d:depth>infinity</d:depth>'));
        return http.Response(_withInjected(_multistatus([_file('$_davFiles/a.jpg', 'a-v1', fileId: 1), _file('$_davFiles/Sub/b.mp4', 'b-v1', mime: 'video/mp4', fileId: 3)])), 207);
    }
    return http.Response('', 405);
  }
}

int _offsetOf(String searchBody) => int.parse(RegExp(r'<ns:firstresult>(\d+)</ns:firstresult>').firstMatch(searchBody)!.group(1)!);

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
    // the only PROPFIND is the Depth 0 stat of the root; nothing is crawled
    expect(server.requests.where((r) => r.method == 'PROPFIND').length, 1);
    expect(server.propfindDepthByPath, {'$_davFiles/': 0});
    expect(server.requests.where((r) => r.method == 'SEARCH').length, 1);
  });

  test('SEARCH publishes the root etag, and only the root, once the whole scope was enumerated', () async {
    final server = _Server();
    // items and collections in the order they came out, so the post-order rule can be checked
    final events = <String>[];
    await for (final item in _repo(server).listMediaTree('', onCollection: (c) => events.add('collection:${c.relativePath}=${c.etag}'))) {
      events.add('item:${item.relativePath}');
    }
    expect(events, ['item:a.jpg', 'item:Sub/b.mp4', 'collection:=root-v1']);
  });

  test('SEARCH is not issued at all when the root etag is unchanged', () async {
    final server = _Server();
    final collections = <NextcloudRemoteItem>[];
    final items = await _repo(server).listMediaTree('', knownCollectionEtags: {'': 'root-v1'}, onCollection: collections.add).toList();
    expect(items, isEmpty);
    expect(collections.map((v) => '${v.relativePath}=${v.etag}'), ['=root-v1']);
    expect(server.requests.where((r) => r.method == 'SEARCH'), isEmpty);
    expect(server.propfindDepthByPath, {'$_davFiles/': 0});

    // a sub-collection etag means nothing to the SEARCH strategy: the scope is queried in full
    final subOnly = _Server();
    final again = await _repo(subOnly).listMediaTree('', knownCollectionEtags: {'Sub': 'sub-v1'}).toList();
    expect(again.map((v) => v.relativePath), ['a.jpg', 'Sub/b.mp4']);
    expect(subOnly.requests.where((r) => r.method == 'SEARCH').length, 1);
  });

  test('a root that cannot be listed fails the SEARCH strategy before any query', () async {
    final server = _Server();
    await expectLater(_repo(server).listMediaTree('Nope').toList(), throwsA(isA<NextcloudNotFoundFailure>()));
    expect(server.requests.where((r) => r.method == 'SEARCH'), isEmpty);
  });

  test('a rejected SEARCH falls back to the crawl, which stats the root once and publishes per collection', () async {
    final server = _Server()..rejectSearch = true;
    final collections = <NextcloudRemoteItem>[];
    final items = await _repo(server).listMediaTree('', onCollection: collections.add).toList();
    expect(items.map((v) => v.relativePath), ['a.jpg', 'Sub/b.mp4', 'Sub/Deep/c.jpg']);
    expect(collections.map((v) => '${v.relativePath}=${v.etag}'), ['Sub/Deep=deep-v1', 'Sub=sub-v1', '=root-v1']);
    expect(server.requests.where((r) => r.method == 'SEARCH').length, 1);
    // one Depth 0 stat before the strategy choice, then the Depth 1 crawl: the root is not stat'd again
    expect(server.requests.where((r) => r.method == 'PROPFIND' && r.headers['depth'] == '0').length, 1);
    expect(server.propfindDepthByPath['$_davFiles/'], 1);
  });

  test('listMediaTree crawls with PROPFIND Depth 1 when SEARCH is unavailable, recursing into sub-folders', () async {
    final server = _Server(supportsSearch: false);
    final collections = <NextcloudRemoteItem>[];
    final items = await _repo(server).listMediaTree('', onCollection: collections.add).toList();
    expect(items.map((v) => v.relativePath), ['a.jpg', 'Sub/b.mp4', 'Sub/Deep/c.jpg']);
    // etags come out post-order: a collection is published only once its whole subtree was listed
    expect(collections.map((v) => '${v.relativePath}=${v.etag}'), ['Sub/Deep=deep-v1', 'Sub=sub-v1', '=root-v1']);
    expect(server.propfindDepthByPath['$_davFiles/'], 1);
    expect(server.propfindDepthByPath['$_davFiles/Sub/'], 1);
    expect(server.propfindDepthByPath['$_davFiles/Sub/Deep/'], 1);
    expect(server.requests.where((r) => r.method == 'SEARCH'), isEmpty);
  });

  test('crawl skips sub-trees whose collection etag is unchanged, and the whole tree when the root is unchanged', () async {
    final server = _Server(supportsSearch: false);
    final collections = <NextcloudRemoteItem>[];
    final items = await _repo(server).listMediaTree('', knownCollectionEtags: {'Sub': 'sub-v1'}, onCollection: collections.add).toList();
    expect(items.map((v) => v.relativePath), ['a.jpg']);
    expect(server.propfindDepthByPath.containsKey('$_davFiles/Sub/'), isFalse);
    // an unchanged sub-tree is skipped, and its etag is still good
    expect(collections.map((v) => v.relativePath), ['Sub', '']);

    final unchanged = _Server(supportsSearch: false);
    final rootOnly = <NextcloudRemoteItem>[];
    final none = await _repo(unchanged).listMediaTree('', knownCollectionEtags: {'': 'root-v1'}, onCollection: rootOnly.add).toList();
    expect(none, isEmpty);
    expect(rootOnly.map((v) => v.relativePath), ['']);
    expect(unchanged.requests.where((r) => r.method == 'PROPFIND').length, 1);
  });

  test('an href outside the root is reported through onItemFailure and the listing continues', () async {
    const escaped = '/remote.php/dav/files/alice/Documents/secret.jpg';
    for (final supportsSearch in [true, false]) {
      final server = _Server(supportsSearch: supportsSearch)..injectedHref = escaped;
      final failures = <String, NextcloudFailure>{};
      final collections = <NextcloudRemoteItem>[];
      final items = await _repo(server).listMediaTree('', onItemFailure: (path, failure) => failures[path] = failure, onCollection: collections.add).toList();
      // the bad href sits in the root listing: the root stays unpublished, the clean sub-folders do not
      expect(collections.map((v) => v.relativePath), supportsSearch ? isEmpty : ['Sub/Deep', 'Sub'], reason: 'search=$supportsSearch');
      // the SEARCH fixture is a static two-item snapshot; the crawl walks the full three-level tree
      expect(items.map((v) => v.relativePath), supportsSearch ? ['a.jpg', 'Sub/b.mp4'] : ['a.jpg', 'Sub/b.mp4', 'Sub/Deep/c.jpg'], reason: 'search=$supportsSearch');
      expect(failures.keys, [escaped]);
      expect(failures[escaped], isA<NextcloudPathEscapeFailure>());
    }
  });

  test('without onItemFailure, an href outside the root still fails the listing', () async {
    final server = _Server(supportsSearch: false)..injectedHref = '/remote.php/dav/files/alice/Documents/secret.jpg';
    await expectLater(_repo(server).listMediaTree('').toList(), throwsA(isA<NextcloudPathEscapeFailure>()));
    await expectLater(_repo(server).listCollection(''), throwsA(isA<NextcloudPathEscapeFailure>()));
  });

  test('crawl reports a sub-folder it cannot list and continues with the rest', () async {
    final server = _Server(supportsSearch: false)..forbidden.add('$_davFiles/Sub/');
    final failures = <String, NextcloudFailure>{};
    final collections = <NextcloudRemoteItem>[];
    final items = await _repo(server).listMediaTree('', onItemFailure: (path, failure) => failures[path] = failure, onCollection: collections.add).toList();
    expect(items.map((v) => v.relativePath), ['a.jpg']);
    expect(failures.keys, ['Sub']);
    expect((failures['Sub'] as NextcloudServerFailure).statusCode, 403);
    // neither the failed folder nor its ancestor gets an etag: persisting one would hide `Sub` until it changes
    expect(collections, isEmpty);

    // the same 403 on the root is the whole listing failing, reported or not
    final rootForbidden = _Server(supportsSearch: false)..forbidden.add('$_davFiles/');
    await expectLater(_repo(rootForbidden).listMediaTree('', onItemFailure: (_, _) {}).toList(), throwsA(isA<NextcloudServerFailure>()));
  });

  test('a failed sub-folder keeps every ancestor unpublished, siblings still get their etag', () async {
    final server = _Server(supportsSearch: false)..forbidden.add('$_davFiles/Sub/Deep/');
    final failures = <String, NextcloudFailure>{};
    final collections = <NextcloudRemoteItem>[];
    final items = await _repo(server).listMediaTree('', onItemFailure: (path, failure) => failures[path] = failure, onCollection: collections.add).toList();
    expect(items.map((v) => v.relativePath), ['a.jpg', 'Sub/b.mp4']);
    expect(failures.keys, ['Sub/Deep']);
    // `Sub` listed fine but a descendant did not: with `Sub` persisted, the next crawl would skip it and never
    // reach `Deep` again until something under `Sub` changes on the server
    expect(collections, isEmpty);

    // the next crawl, with nothing persisted, lists everything again and the transient failure heals
    final healed = _Server(supportsSearch: false);
    final again = <NextcloudRemoteItem>[];
    await _repo(healed).listMediaTree('', onCollection: again.add).toList();
    expect(again.map((v) => v.relativePath), ['Sub/Deep', 'Sub', '']);
  });

  test('a file the server cannot describe leaves its folder unpublished, so it is retried next time', () async {
    final server = _Server(supportsSearch: false)..injectedRootResponse = _unreadable('$_davFiles/locked.jpg');
    final failures = <String, NextcloudFailure>{};
    final collections = <NextcloudRemoteItem>[];
    final items = await _repo(server).listMediaTree('', onItemFailure: (path, failure) => failures[path] = failure, onCollection: collections.add).toList();
    expect(items.map((v) => v.relativePath), ['a.jpg', 'Sub/b.mp4', 'Sub/Deep/c.jpg']);
    expect(failures.keys, ['locked.jpg']);
    expect(failures['locked.jpg'], isA<NextcloudParseFailure>().having((e) => e.toString(), 'message', contains('403')));
    // one response of the root listing was unusable: the root is not "fully enumerated", its sub-folders are
    expect(collections.map((v) => v.relativePath), ['Sub/Deep', 'Sub']);

    // without a callback the response is skipped and the listing is not failed (the public listCollection contract)
    expect((await _repo(server).listCollection('')).map((v) => v.relativePath), ['a.jpg', 'notes.txt', 'Sub']);
  });

  test('stops descending at the depth cap and reports the folder instead of overflowing', () async {
    // a server with a collection nested without end: Photos/n/n/n/...
    final client = MockClient((request) async {
      switch (request.method) {
        case 'OPTIONS':
          return http.Response('', 200, headers: {'Allow': 'OPTIONS, PROPFIND'});
        case 'GET':
          return http.Response('{}', 200);
        case 'PROPFIND':
          final path = request.url.path.endsWith('/') ? request.url.path : '${request.url.path}/';
          final self = _collection(path, 'v');
          return http.Response(_multistatus(request.headers['depth'] == '0' ? [self] : [self, _collection('${path}n/', 'v')]), 207);
      }
      return http.Response('', 405);
    });
    final repo = WebDavNextcloudRepository(_account, _credentials, client: client);
    final failures = <String, NextcloudFailure>{};
    final collections = <NextcloudRemoteItem>[];
    final items = await repo.listMediaTree('', onItemFailure: (path, failure) => failures[path] = failure, onCollection: collections.add).toList();
    expect(items, isEmpty);
    final deepest = List.filled(WebDavNextcloudRepository.maxCrawlDepth + 1, 'n').join('/');
    expect(failures.keys, [deepest]);
    expect(failures[deepest], isA<NextcloudParseFailure>());
    // nothing above the cap is complete, so nothing is published and the next crawl tries again
    expect(collections, isEmpty);

    // without a callback the cap is a thrown failure
    await expectLater(WebDavNextcloudRepository(_account, _credentials, client: client).listMediaTree('').toList(), throwsA(isA<NextcloudParseFailure>()));
  });

  test('SEARCH paging keeps going past a full page of holes but stops when the server ignores the offset', () async {
    const pageSize = WebDavNextcloudRepository.searchPageSize;
    http.Client clientWith(String Function(int offset) pageFor, List<int> offsets) => MockClient((request) async {
      switch (request.method) {
        case 'OPTIONS':
          return http.Response('', 200, headers: {'Allow': 'OPTIONS, PROPFIND, SEARCH'});
        case 'GET':
          return http.Response('{}', 200);
        case 'PROPFIND':
          expect(request.headers['depth'], '0');
          return http.Response(_multistatus([_collection('$_davFiles/', 'root-v1')]), 207);
        case 'SEARCH':
          final offset = _offsetOf(request.body);
          offsets.add(offset);
          return http.Response(pageFor(offset), 207);
      }
      return http.Response('', 405);
    });
    // page 0: full, every response outside the root (all holes); page 1: short, one item
    const outside = '/remote.php/dav/files/alice/Documents/x.jpg';
    final holesThenItem = <int>[];
    final holesCollections = <NextcloudRemoteItem>[];
    final items = await WebDavNextcloudRepository(
      _account,
      _credentials,
      client: clientWith((offset) => offset == 0 ? _multistatus([for (var i = 0; i < pageSize; i++) _file(outside, 'v', fileId: i)]) : _multistatus([_file('$_davFiles/last.jpg', 'v', fileId: 1)]), holesThenItem),
    ).listMediaTree('', onItemFailure: (_, _) {}, onCollection: holesCollections.add).toList();
    expect(holesThenItem, [0, pageSize]);
    expect(items.map((v) => v.relativePath), ['last.jpg']);
    // the holes were reported: the scope was not fully enumerated, so the root is not published
    expect(holesCollections, isEmpty);

    // a server that ignores the offset returns the same full page forever: stop after the first repeat
    final ignoresOffset = <int>[];
    final ignoredCollections = <NextcloudRemoteItem>[];
    final repeated = await WebDavNextcloudRepository(
      _account,
      _credentials,
      client: clientWith((_) => _multistatus([for (var i = 0; i < pageSize; i++) _file('$_davFiles/p$i.jpg', 'v', fileId: i)]), ignoresOffset),
    ).listMediaTree('', onCollection: ignoredCollections.add).toList();
    expect(ignoresOffset, [0, pageSize]);
    expect(repeated.length, pageSize);
    // the pages past the first were never served: nothing vouches for the whole scope
    expect(ignoredCollections, isEmpty);
  });

  test('SEARCH paging counts responses, not items, so a page with a hole is not mistaken for the last one', () async {
    const pageSize = WebDavNextcloudRepository.searchPageSize;
    final offsets = <int>[];
    final client = MockClient((request) async {
      switch (request.method) {
        case 'OPTIONS':
          return http.Response('', 200, headers: {'Allow': 'OPTIONS, PROPFIND, SEARCH'});
        case 'GET':
          return http.Response('{}', 200);
        case 'PROPFIND':
          return http.Response(_multistatus([_collection('$_davFiles/', 'root-v1')]), 207);
        case 'SEARCH':
          final offset = _offsetOf(request.body);
          offsets.add(offset);
          if (offset == 0) {
            // a full page, with one response that maps outside the root
            final responses = [for (var i = 0; i < pageSize - 1; i++) _file('$_davFiles/p$i.jpg', 'v', fileId: i), _file('/remote.php/dav/files/alice/Documents/x.jpg', 'v', fileId: 9999)];
            return http.Response(_multistatus(responses), 207);
          }
          return http.Response(_multistatus([_file('$_davFiles/last.jpg', 'v', fileId: 10000)]), 207);
      }
      return http.Response('', 405);
    });
    final repo = WebDavNextcloudRepository(_account, _credentials, client: client);
    final failures = <String, NextcloudFailure>{};
    final collections = <NextcloudRemoteItem>[];
    final items = await repo.listMediaTree('', onItemFailure: (path, failure) => failures[path] = failure, onCollection: collections.add).toList();
    expect(offsets, [0, pageSize]);
    expect(items.length, pageSize);
    expect(items.last.relativePath, 'last.jpg');
    expect(failures.keys, ['/remote.php/dav/files/alice/Documents/x.jpg']);
    // one response the server could not place inside the root: that file would never be retried if the
    // root were published now
    expect(collections, isEmpty);
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
    // 403 is per resource on Nextcloud (share without permission, access control, lock); a bad app password is 401
    await expectLater((await withStatus(403)).probe(), throwsA(isA<NextcloudServerFailure>().having((e) => e.statusCode, 'statusCode', 403)));
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
