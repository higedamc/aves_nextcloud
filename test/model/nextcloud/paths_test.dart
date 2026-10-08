import 'package:aves/model/nextcloud/paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NextcloudPaths.normalize', () {
    test('root forms', () {
      expect(NextcloudPaths.normalize(''), '');
      expect(NextcloudPaths.normalize('/'), '');
      expect(NextcloudPaths.normalize('///'), '');
    });

    test('strips leading and trailing separators', () {
      expect(NextcloudPaths.normalize('/Photos/2024/'), 'Photos/2024');
      expect(NextcloudPaths.normalize('Photos'), 'Photos');
    });

    test('rejects traversal, empty segments, backslashes and control characters', () {
      expect(NextcloudPaths.normalize('..'), isNull);
      expect(NextcloudPaths.normalize('Photos/../etc'), isNull);
      expect(NextcloudPaths.normalize('Photos/./x'), isNull);
      expect(NextcloudPaths.normalize('Photos//x'), isNull);
      expect(NextcloudPaths.normalize(r'Photos\x'), isNull);
      expect(NextcloudPaths.normalize('Photos/a\u0000b'), isNull);
    });

    test('keeps unicode and spaces', () {
      expect(NextcloudPaths.normalize('写真/2024 夏/IMG 001.jpg'), '写真/2024 夏/IMG 001.jpg');
    });
  });

  group('NextcloudPaths.relativePathFromHref', () {
    const root = '/remote.php/dav/files/alice/Photos';

    test('root itself', () {
      expect(NextcloudPaths.relativePathFromHref('/remote.php/dav/files/alice/Photos/', root), '');
    });

    test('decodes percent-encoded hrefs', () {
      expect(NextcloudPaths.relativePathFromHref('/remote.php/dav/files/alice/Photos/2024%20summer/IMG%20001.jpg', root), '2024 summer/IMG 001.jpg');
    });

    test('accepts absolute hrefs (reverse proxy / sabre baseUri)', () {
      expect(NextcloudPaths.relativePathFromHref('https://host:31001/remote.php/dav/files/alice/Photos/2024/a.jpg', root), '2024/a.jpg');
      expect(NextcloudPaths.relativePathFromHref('https://host:31001/remote.php/dav/files/alice/Photos/', root), '');
      expect(NextcloudPaths.relativePathFromHref('https://host:31001/remote.php/dav/files/alice/Photos/2024%20summer/a%26b.jpg', root), '2024 summer/a&b.jpg');
      expect(NextcloudPaths.relativePathFromHref('https://host:31001/remote.php/dav/files/alice/Documents/a.jpg', root), isNull);
    });

    test('returns null instead of throwing on undecodable hrefs', () {
      expect(NextcloudPaths.relativePathFromHref('/remote.php/dav/files/alice/Photos/%zz.jpg', root), isNull);
      expect(NextcloudPaths.relativePathFromHref('/remote.php/dav/files/alice/Photos/a%2', root), isNull);
      expect(NextcloudPaths.relativePathFromHref('/remote.php/dav/files/alice/Photos/%C3%28.jpg', root), isNull);
    });

    test('rejects hrefs outside the root', () {
      expect(NextcloudPaths.relativePathFromHref('/remote.php/dav/files/alice/Documents/x.jpg', root), isNull);
      expect(NextcloudPaths.relativePathFromHref('/remote.php/dav/files/alice/PhotosOld/x.jpg', root), isNull);
      expect(NextcloudPaths.relativePathFromHref('/remote.php/dav/files/alice/Photos/..%2Fetc', root), isNull);
    });
  });

  test('encodeForUrl keeps separators and encodes segments', () {
    expect(NextcloudPaths.encodeForUrl('2024 summer/a&b.jpg'), '2024%20summer/a%26b.jpg');
  });

  test('join, parentOf, nameOf', () {
    expect(NextcloudPaths.join('', 'a'), 'a');
    expect(NextcloudPaths.join('a', 'b'), 'a/b');
    expect(NextcloudPaths.join('a', ''), 'a');
    expect(NextcloudPaths.join('', ''), '');
    expect(NextcloudPaths.parentOf('a/b/c'), 'a/b');
    expect(NextcloudPaths.parentOf('a'), '');
    expect(NextcloudPaths.nameOf('a/b/c.jpg'), 'c.jpg');
  });
}
