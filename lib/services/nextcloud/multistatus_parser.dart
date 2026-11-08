import 'dart:io';

import 'package:aves/model/nextcloud/errors.dart';
import 'package:aves/model/nextcloud/paths.dart';
import 'package:aves/model/nextcloud/remote_item.dart';
import 'package:aves/model/nextcloud/repository.dart';
import 'package:aves/services/nextcloud/dav_requests.dart';
import 'package:collection/collection.dart';
import 'package:xml/xml.dart';

// Parses a WebDAV `207 Multi-Status` body (PROPFIND or SEARCH) into remote items.
// `rootHref` is the unencoded root href of the account (`NextcloudAccount.rootHref`), so every
// returned `relativePath` is relative to the account root folder. An href that cannot be mapped
// inside that root is a `NextcloudPathEscapeFailure`: with `onItemFailure` the response is reported
// and skipped, without it the failure is thrown. A response without a successful propstat is reported
// with `onItemFailure` and skipped either way. A document that is not a multistatus at all is always
// a thrown `NextcloudParseFailure`: nothing in it can be trusted.
typedef MultistatusPage = ({List<NextcloudRemoteItem> items, int responseCount});

class MultistatusParser {
  static List<NextcloudRemoteItem> parse(String body, {required String rootHref}) => parsePage(body, rootHref: rootHref).items;

  // `responseCount` counts every `d:response` in the document, including the ones that yielded no item
  // (skipped, or without a successful propstat), so a caller paging through SEARCH results can tell a short
  // last page from a full page with holes.
  static MultistatusPage parsePage(String body, {required String rootHref, NextcloudItemFailureCallback? onItemFailure}) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(body);
    } on XmlException catch (e) {
      throw NextcloudParseFailure('invalid multistatus: ${e.message}');
    }

    final multistatus = document.rootElement;
    if (multistatus.localName != 'multistatus' || multistatus.namespaceUri != DavNamespaces.dav) {
      throw NextcloudParseFailure('expected d:multistatus, got ${multistatus.name.qualified}');
    }

    final items = <NextcloudRemoteItem>[];
    var responseCount = 0;
    for (final response in multistatus.findElements('response', namespace: DavNamespaces.dav)) {
      responseCount++;
      final href = response.getElement('href', namespace: DavNamespaces.dav)?.innerText.trim();
      if (href == null || href.isEmpty) {
        throw const NextcloudParseFailure('response without href');
      }
      final relativePath = NextcloudPaths.relativePathFromHref(href, rootHref);
      if (relativePath == null) {
        final failure = NextcloudPathEscapeFailure(href);
        if (onItemFailure == null) throw failure;
        onItemFailure(href, failure);
        continue;
      }

      final prop = _okProp(response);
      if (prop == null) {
        // no successful propstat (every requested prop is 404, or the props are forbidden): nothing usable.
        // Reported so a crawl knows the folder was not fully enumerated; without a callback the response
        // is skipped as before, since nothing in it threatens the rest of the document.
        onItemFailure?.call(relativePath, NextcloudParseFailure('no successful propstat for $relativePath: ${_propstatStatuses(response)}'));
        continue;
      }
      items.add(_toItem(prop, relativePath));
    }
    return (items: items, responseCount: responseCount);
  }

  static String _propstatStatuses(XmlElement response) {
    final statuses = response.findElements('propstat', namespace: DavNamespaces.dav).map((v) => v.getElement('status', namespace: DavNamespaces.dav)?.innerText.trim()).whereType<String>().toList();
    return statuses.isEmpty ? 'no propstat' : statuses.join(', ');
  }

  static XmlElement? _okProp(XmlElement response) {
    for (final propstat in response.findElements('propstat', namespace: DavNamespaces.dav)) {
      final status = propstat.getElement('status', namespace: DavNamespaces.dav)?.innerText ?? '';
      if (status.contains(' 200')) {
        return propstat.getElement('prop', namespace: DavNamespaces.dav);
      }
    }
    return null;
  }

  static NextcloudRemoteItem _toItem(XmlElement prop, String relativePath) {
    final resourceType = prop.getElement('resourcetype', namespace: DavNamespaces.dav);
    final isCollection = resourceType?.getElement('collection', namespace: DavNamespaces.dav) != null;

    final contentLength = int.tryParse(_text(prop, 'getcontentlength', DavNamespaces.dav) ?? '');
    final ocSize = int.tryParse(_text(prop, 'size', DavNamespaces.oc) ?? '');

    return NextcloudRemoteItem(
      relativePath: relativePath,
      fileId: int.tryParse(_text(prop, 'fileid', DavNamespaces.oc) ?? ''),
      etag: _unquote(_text(prop, 'getetag', DavNamespaces.dav) ?? ''),
      mimeType: isCollection ? null : _text(prop, 'getcontenttype', DavNamespaces.dav),
      sizeBytes: (isCollection ? ocSize : contentLength ?? ocSize) ?? 0,
      lastModified: _parseHttpDate(_text(prop, 'getlastmodified', DavNamespaces.dav)),
      isCollection: isCollection,
      hasPreview: _parseBool(_text(prop, 'has-preview', DavNamespaces.nc)),
      photoMetadata: isCollection ? null : _photoMetadata(prop),
    );
  }

  static NextcloudPhotoMetadata? _photoMetadata(XmlElement prop) {
    final size = prop.getElement('metadata-photos-size', namespace: DavNamespaces.nc);
    final width = _childInt(size, 'width');
    final height = _childInt(size, 'height');

    final dateSecs = int.tryParse(_text(prop, 'metadata-photos-original_date_time', DavNamespaces.nc) ?? '');
    final originalDateTime = dateSecs != null && dateSecs > 0 && dateSecs <= _maxDateSeconds ? DateTime.fromMillisecondsSinceEpoch(dateSecs * 1000, isUtc: true) : null;

    final gps = prop.getElement('metadata-photos-gps', namespace: DavNamespaces.nc);
    // in range or absent, for the same reason `NaN` is absent below: `hasGps` is a null check, so a
    // coordinate outside the only values a coordinate can take would still be published as a location
    final latitude = _inRange(_childDouble(gps, 'latitude'), 90);
    final longitude = _inRange(_childDouble(gps, 'longitude'), 180);

    if (width == null && height == null && originalDateTime == null && latitude == null && longitude == null) return null;
    return NextcloudPhotoMetadata(
      width: width,
      height: height,
      originalDateTime: originalDateTime,
      latitude: latitude,
      longitude: longitude,
    );
  }

  static String? _text(XmlElement parent, String name, String namespace) {
    final element = parent.getElement(name, namespace: namespace);
    if (element == null) return null;
    final text = element.innerText.trim();
    return text.isEmpty ? null : text;
  }

  // metadata children are emitted without a namespace prefix by the server, so match on local name only
  static String? _childText(XmlElement? parent, String localName) {
    final child = parent?.childElements.firstWhereOrNull((v) => v.localName == localName);
    final text = child?.innerText.trim();
    return text == null || text.isEmpty ? null : text;
  }

  // A dimension the server declares is a positive whole number of pixels, and anything else is not a
  // partial answer but a wrong one, so it is read as unknown. The guard is here rather than at the call
  // sites because the parser is the one place every consumer reads through, and because `.toInt()` on
  // what the server said is not safe:
  //
  // - it **throws** `UnsupportedError` on a non-finite double, and `NaN`, `Infinity`, `-Infinity` and
  //   `1e400` are all things a `<width>` can say. `_toItem` is called with no `try`, and `UnsupportedError`
  //   is not a `NextcloudFailure`, so one such field used to abort the whole sync run out of `parse()`:
  //   no etags saved, nothing listed, on every run until that one file's server-side metadata changed.
  // - it saturates silently on a finite-but-huge double (`1e30` -> `9223372036854775807`), which is why
  //   rejecting non-finite values alone is not enough.
  //
  // `_maxDimension` is a sanity bound, not a format limit: it is far above any real image (a stitched
  // gigapixel panorama is tens of thousands of pixels per side) and far below the magnitudes that only
  // arise from a server writing a float, a counter or a corrupted field into this element.
  static const _maxDimension = 1 << 20;

  // The same contract for the capture date, which `dateSecs * 1000` reaches by two different routes:
  //
  // - `DateTime.fromMillisecondsSinceEpoch` **throws** `RangeError` outside +/-8.64e15 ms, so a plain
  //   `10000000000000` (a server writing milliseconds, or microseconds, where the property says seconds)
  //   aborted the crawl exactly as a non-finite `<width>` did.
  // - above that, `dateSecs * 1000` wraps: 2^63-1 seconds becomes -1000 ms, i.e. a confident
  //   `1969-12-31` for a photo, which is worse than no date at all.
  //
  // The bound is the last second `DateTime` can render (9999-12-31T23:59:59Z): far beyond any capture
  // date, and below a milliseconds value mistakenly sent as seconds (1.76e12 > 2.53e11), so that
  // common server-side mistake is read as unknown rather than filed under the year 57800.
  static const _maxDateSeconds = 253402300799;

  static int? _childInt(XmlElement? parent, String localName) {
    final text = _childText(parent, localName);
    if (text == null) return null;
    final value = num.tryParse(text);
    if (value == null || !value.isFinite) return null;
    // `0` already means unknown downstream (`displayAspectRatio`), and a negative or fractional count of
    // pixels is not a number this parser can stand behind
    if (value <= 0 || value > _maxDimension || value != value.truncate()) return null;
    return value.toInt();
  }

  // Same contract for the GPS pair: a non-finite coordinate reaches `CatalogMetadata` and from there the
  // country lookup and the geocoder, and neither gate stops it -- `NextcloudPhotoMetadata.hasGps` is a null
  // check and `AvesEntry.hasGps` is `!= 0`, which `NaN` passes. So an item would claim a location that no
  // lookup can resolve. Unlike the dimensions above this one never threw: `double.tryParse` is total and
  // nothing calls `.toInt()` on it.
  static double? _childDouble(XmlElement? parent, String localName) {
    final text = _childText(parent, localName);
    if (text == null) return null;
    final value = double.tryParse(text);
    return value == null || !value.isFinite ? null : value;
  }

  static double? _inRange(double? value, double limit) => value == null || value.abs() > limit ? null : value;

  static bool _parseBool(String? text) => text == 'true' || text == '1';

  static String _unquote(String etag) {
    var value = etag.trim();
    if (value.startsWith('W/')) value = value.substring(2);
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    return value;
  }

  static DateTime _parseHttpDate(String? text) {
    if (text == null) return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    try {
      return HttpDate.parse(text);
    } on HttpException {
      return DateTime.tryParse(text)?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
  }
}
