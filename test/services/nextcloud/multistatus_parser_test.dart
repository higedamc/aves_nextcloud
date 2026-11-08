import 'package:aves/model/nextcloud/errors.dart';
import 'package:aves/model/nextcloud/remote_item.dart';
import 'package:aves/services/nextcloud/multistatus_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const _root = '/remote.php/dav/files/alice/Photos';

const _propfindDepth1 = '''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/alice/Photos/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:getetag>"root-etag"</d:getetag>
        <d:getlastmodified>Tue, 06 Oct 2026 10:00:00 GMT</d:getlastmodified>
        <oc:fileid>10</oc:fileid>
        <oc:size>123456</oc:size>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
    <d:propstat>
      <d:prop>
        <d:getcontenttype/>
        <d:getcontentlength/>
        <nc:metadata-photos-size/>
      </d:prop>
      <d:status>HTTP/1.1 404 Not Found</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/alice/Photos/2024%20summer/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:getetag>"sub-etag"</d:getetag>
        <d:getlastmodified>Wed, 07 Oct 2026 10:00:00 GMT</d:getlastmodified>
        <oc:fileid>11</oc:fileid>
        <oc:size>99</oc:size>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/alice/Photos/IMG%20001.jpg</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:getetag>W/"img-etag"</d:getetag>
        <d:getcontenttype>image/jpeg</d:getcontenttype>
        <d:getcontentlength>4096</d:getcontentlength>
        <d:getlastmodified>Thu, 08 Oct 2026 12:34:56 GMT</d:getlastmodified>
        <oc:fileid>12</oc:fileid>
        <oc:size>4096</oc:size>
        <nc:has-preview>true</nc:has-preview>
        <nc:metadata-photos-size><width>4000</width><height>3000</height></nc:metadata-photos-size>
        <nc:metadata-photos-original_date_time>1759900000</nc:metadata-photos-original_date_time>
        <nc:metadata-photos-gps><latitude>35.68</latitude><longitude>139.76</longitude></nc:metadata-photos-gps>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/alice/Photos/notes.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:getetag>"txt-etag"</d:getetag>
        <d:getcontenttype>text/plain</d:getcontenttype>
        <d:getcontentlength>12</d:getcontentlength>
        <d:getlastmodified>Thu, 08 Oct 2026 12:34:56 GMT</d:getlastmodified>
        <oc:fileid>13</oc:fileid>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

void main() {
  test('parses collections, files, etags and photo metadata', () {
    final items = MultistatusParser.parse(_propfindDepth1, rootHref: _root);
    expect(items.map((v) => v.relativePath), ['', '2024 summer', 'IMG 001.jpg', 'notes.txt']);

    final root = items[0];
    expect(root.isCollection, isTrue);
    expect(root.etag, 'root-etag');
    expect(root.sizeBytes, 123456);
    expect(root.mimeType, isNull);
    expect(root.fileId, 10);

    final image = items[2];
    expect(image.isCollection, isFalse);
    expect(image.isImage, isTrue);
    expect(image.etag, 'img-etag');
    expect(image.sizeBytes, 4096);
    expect(image.hasPreview, isTrue);
    expect(image.lastModified, DateTime.utc(2026, 10, 8, 12, 34, 56));
    expect(image.photoMetadata?.width, 4000);
    expect(image.photoMetadata?.height, 3000);
    expect(image.photoMetadata?.originalDateTime, DateTime.fromMillisecondsSinceEpoch(1759900000 * 1000, isUtc: true));
    expect(image.photoMetadata?.latitude, closeTo(35.68, 1e-9));
    expect(image.photoMetadata?.longitude, closeTo(139.76, 1e-9));

    final text = items[3];
    expect(text.isMedia, isFalse);
    expect(text.photoMetadata, isNull);
  });

  // A field the server fills in cannot be allowed to end the run: `_toItem` is called with no `try`, and
  // an `UnsupportedError` out of `parse()` is not a `NextcloudFailure`, so the per-item catch in the sync
  // use case does not see it -- the whole crawl stops, no etags are saved, and the account cannot sync
  // until that one file's server-side metadata changes.
  group('a server-declared number this parser cannot stand behind is read as unknown', () {
    NextcloudRemoteItem imageWith(String sizeElement) {
      final body = _propfindDepth1.replaceAll('<nc:metadata-photos-size><width>4000</width><height>3000</height></nc:metadata-photos-size>', sizeElement);
      final items = MultistatusParser.parse(body, rootHref: _root);
      return items.firstWhere((v) => v.relativePath == 'IMG 001.jpg');
    }

    // `num.tryParse` returns a double for every one of these, and `.toInt()` on it throws
    for (final text in ['NaN', 'Infinity', '-Infinity', '1e400']) {
      test('$text in <width> does not throw', () {
        final image = imageWith('<nc:metadata-photos-size><width>$text</width><height>3000</height></nc:metadata-photos-size>');
        expect(image.photoMetadata?.width, isNull, reason: '$text is not a number of pixels');
        expect(image.photoMetadata?.height, 3000, reason: 'and the field next to it is still read');
      });
    }

    // finite, so "reject non-finite" would let it through, and `.toInt()` saturates it to 2^63-1
    test('1e30 in <width> is unknown rather than 9223372036854775807', () {
      expect(imageWith('<nc:metadata-photos-size><width>1e30</width><height>3000</height></nc:metadata-photos-size>').photoMetadata?.width, isNull);
    });

    test('a dimension that is zero, negative or fractional is unknown', () {
      expect(imageWith('<nc:metadata-photos-size><width>0</width><height>3000</height></nc:metadata-photos-size>').photoMetadata?.width, isNull);
      expect(imageWith('<nc:metadata-photos-size><width>-1</width><height>3000</height></nc:metadata-photos-size>').photoMetadata?.width, isNull);
      expect(imageWith('<nc:metadata-photos-size><width>3.7</width><height>3000</height></nc:metadata-photos-size>').photoMetadata?.width, isNull);
    });

    // the tolerance the old `num.tryParse` had, kept on purpose: a server that writes a whole number as a
    // float still means that number of pixels
    test('a whole number written as a float is still that dimension', () {
      expect(imageWith('<nc:metadata-photos-size><width>4000.0</width><height>3000</height></nc:metadata-photos-size>').photoMetadata?.width, 4000);
    });

    NextcloudRemoteItem imageWithDate(String secs) {
      final body = _propfindDepth1.replaceAll(
        '<nc:metadata-photos-original_date_time>1759900000</nc:metadata-photos-original_date_time>',
        '<nc:metadata-photos-original_date_time>$secs</nc:metadata-photos-original_date_time>',
      );
      return MultistatusParser.parse(body, rootHref: _root).firstWhere((v) => v.relativePath == 'IMG 001.jpg');
    }

    // `DateTime.fromMillisecondsSinceEpoch` throws `RangeError`, not an `UnsupportedError`, but it leaves
    // `parse()` by the same uncaught route
    test('a seconds value whose milliseconds are unrepresentable does not throw', () {
      expect(imageWithDate('10000000000000').photoMetadata?.originalDateTime, isNull);
      expect(imageWithDate('9223372036854776').photoMetadata?.originalDateTime, isNull);
    });

    // `dateSecs * 1000` wraps here, so "reject what RangeError would reject" is not enough: this one
    // produces a confident wrong date instead of an error
    test('a seconds value that overflows to a negative is unknown rather than 1969', () {
      expect(imageWithDate('9223372036854775807').photoMetadata?.originalDateTime, isNull);
    });

    // the mistake a real server makes: the property says seconds and the value is milliseconds
    test('milliseconds sent where seconds are declared is unknown rather than the year 57800', () {
      expect(imageWithDate('1762531200000').photoMetadata?.originalDateTime, isNull);
    });

    test('a date at the bound is still read, and a real date is untouched', () {
      expect(imageWithDate('253402300799').photoMetadata?.originalDateTime, DateTime.utc(9999, 12, 31, 23, 59, 59));
      expect(imageWithDate('1759900000').photoMetadata?.originalDateTime, DateTime.utc(2025, 10, 8, 5, 6, 40));
    });

    NextcloudRemoteItem imageWithGps(String lat, String lon) {
      final body = _propfindDepth1.replaceAll(
        '<nc:metadata-photos-gps><latitude>35.68</latitude><longitude>139.76</longitude></nc:metadata-photos-gps>',
        '<nc:metadata-photos-gps><latitude>$lat</latitude><longitude>$lon</longitude></nc:metadata-photos-gps>',
      );
      return MultistatusParser.parse(body, rootHref: _root).firstWhere((v) => v.relativePath == 'IMG 001.jpg');
    }

    // finite, so "reject non-finite" would publish it, and `hasGps` would say the photo has a location
    test('a coordinate outside the values a coordinate can take is no coordinate', () {
      expect(imageWithGps('91', '139.76').photoMetadata?.latitude, isNull);
      expect(imageWithGps('-90.1', '139.76').photoMetadata?.latitude, isNull);
      expect(imageWithGps('35.68', '180.1').photoMetadata?.longitude, isNull);
      expect(imageWithGps('91', '139.76').photoMetadata?.hasGps, isFalse);
    });

    test('the poles and the antimeridian are still coordinates', () {
      expect(imageWithGps('-90', '180').photoMetadata?.latitude, -90);
      expect(imageWithGps('-90', '180').photoMetadata?.longitude, 180);
      expect(imageWithGps('-90', '180').photoMetadata?.hasGps, isTrue);
    });

    test('a non-finite coordinate is no coordinate, so the item does not claim a location', () {
      final body = _propfindDepth1.replaceAll(
        '<nc:metadata-photos-gps><latitude>35.68</latitude><longitude>139.76</longitude></nc:metadata-photos-gps>',
        '<nc:metadata-photos-gps><latitude>NaN</latitude><longitude>139.76</longitude></nc:metadata-photos-gps>',
      );
      final image = MultistatusParser.parse(body, rootHref: _root).firstWhere((v) => v.relativePath == 'IMG 001.jpg');
      expect(image.photoMetadata?.latitude, isNull);
      expect(image.photoMetadata?.hasGps, isFalse, reason: 'half a pair is not a location, and `hasGps` is only a null check');
    });
  });

  test('accepts absolute hrefs', () {
    final body = _propfindDepth1.replaceAll('<d:href>/remote.php', '<d:href>https://host:31001/remote.php');
    final items = MultistatusParser.parse(body, rootHref: _root);
    expect(items.map((v) => v.relativePath), ['', '2024 summer', 'IMG 001.jpg', 'notes.txt']);
  });

  test('rejects hrefs outside the root', () {
    final body = _propfindDepth1.replaceAll('/Photos/notes.txt', '/Documents/notes.txt');
    expect(() => MultistatusParser.parse(body, rootHref: _root), throwsA(isA<NextcloudPathEscapeFailure>()));
  });

  test('reports an href outside the root through onItemFailure and keeps the rest', () {
    final body = _propfindDepth1.replaceAll('/Photos/notes.txt', '/Documents/notes.txt');
    final failures = <String, NextcloudFailure>{};
    final page = MultistatusParser.parsePage(body, rootHref: _root, onItemFailure: (path, failure) => failures[path] = failure);
    expect(page.items.map((v) => v.relativePath), ['', '2024 summer', 'IMG 001.jpg']);
    expect(page.responseCount, 4);
    expect(failures.keys, ['/remote.php/dav/files/alice/Documents/notes.txt']);
    expect(failures.values.single, isA<NextcloudPathEscapeFailure>());
  });

  test('a document that is not a multistatus is rejected even with onItemFailure', () {
    expect(() => MultistatusParser.parsePage('<d:error xmlns:d="DAV:"/>', rootHref: _root, onItemFailure: (_, _) {}), throwsA(isA<NextcloudParseFailure>()));
  });

  test('rejects traversal hidden in percent encoding', () {
    final body = _propfindDepth1.replaceAll('/Photos/notes.txt', '/Photos/..%2F..%2Fetc%2Fpasswd');
    expect(() => MultistatusParser.parse(body, rootHref: _root), throwsA(isA<NextcloudPathEscapeFailure>()));
  });

  test('rejects malformed XML and non-multistatus documents', () {
    expect(() => MultistatusParser.parse('<d:multistatus xmlns:d="DAV:"><d:response>', rootHref: _root), throwsA(isA<NextcloudParseFailure>()));
    expect(() => MultistatusParser.parse('<d:error xmlns:d="DAV:"/>', rootHref: _root), throwsA(isA<NextcloudParseFailure>()));
  });

  test('skips responses without a successful propstat', () {
    const body = '''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/remote.php/dav/files/alice/Photos/gone.jpg</d:href>
    <d:propstat><d:prop><d:getetag/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
  </d:response>
</d:multistatus>''';
    expect(MultistatusParser.parse(body, rootHref: _root), isEmpty);
    // the response still counts towards the page size
    expect(MultistatusParser.parsePage(body, rootHref: _root).responseCount, 1);
    // and is reported when there is someone to tell, so a crawl knows the folder was not fully enumerated
    final failures = <String, NextcloudFailure>{};
    final page = MultistatusParser.parsePage(body, rootHref: _root, onItemFailure: (path, failure) => failures[path] = failure);
    expect(page.items, isEmpty);
    expect(failures.keys, ['gone.jpg']);
    expect(failures['gone.jpg'], isA<NextcloudParseFailure>().having((e) => e.toString(), 'message', contains('404')));
  });
}
