import 'dart:io';

import 'package:aves/model/nextcloud/errors.dart';
import 'package:aves/model/nextcloud/paths.dart';
import 'package:aves/model/nextcloud/remote_item.dart';
import 'package:aves/services/nextcloud/dav_requests.dart';
import 'package:collection/collection.dart';
import 'package:xml/xml.dart';

// Parses a WebDAV `207 Multi-Status` body (PROPFIND or SEARCH) into remote items.
// `rootHref` is the unencoded root href of the account (`NextcloudAccount.rootHref`), so every
// returned `relativePath` is relative to the account root folder. Any href that cannot be mapped
// inside that root is a `NextcloudPathEscapeFailure`: a server that lies about hrefs gets nothing.
class MultistatusParser {
  static List<NextcloudRemoteItem> parse(String body, {required String rootHref}) {
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
    for (final response in multistatus.findElements('response', namespace: DavNamespaces.dav)) {
      final href = response.getElement('href', namespace: DavNamespaces.dav)?.innerText.trim();
      if (href == null || href.isEmpty) {
        throw const NextcloudParseFailure('response without href');
      }
      final relativePath = NextcloudPaths.relativePathFromHref(href, rootHref);
      if (relativePath == null) {
        throw NextcloudPathEscapeFailure(href);
      }

      final prop = _okProp(response);
      if (prop == null) {
        // no successful propstat (e.g. all requested props are 404): nothing usable
        continue;
      }
      items.add(_toItem(prop, relativePath));
    }
    return items;
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
    final originalDateTime = dateSecs != null && dateSecs > 0 ? DateTime.fromMillisecondsSinceEpoch(dateSecs * 1000, isUtc: true) : null;

    final gps = prop.getElement('metadata-photos-gps', namespace: DavNamespaces.nc);
    final latitude = _childDouble(gps, 'latitude');
    final longitude = _childDouble(gps, 'longitude');

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

  static int? _childInt(XmlElement? parent, String localName) {
    final text = _childText(parent, localName);
    return text == null ? null : num.tryParse(text)?.toInt();
  }

  static double? _childDouble(XmlElement? parent, String localName) {
    final text = _childText(parent, localName);
    return text == null ? null : double.tryParse(text);
  }

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
