// Request bodies and namespaces for the Nextcloud WebDAV endpoints used by `WebDavNextcloudRepository`.
class DavNamespaces {
  static const dav = 'DAV:';
  static const oc = 'http://owncloud.org/ns';
  static const nc = 'http://nextcloud.org/ns';

  // pagination extension used by Nextcloud's SEARCH backend (icewind1991/SearchDAV)
  static const searchDav = 'https://github.com/icewind1991/SearchDAV/ns';
}

class DavRequests {
  static const _namespaceAttributes = 'xmlns:d="${DavNamespaces.dav}" xmlns:oc="${DavNamespaces.oc}" xmlns:nc="${DavNamespaces.nc}"';

  // properties requested for every listing; the `nc:metadata-photos-*` ones are only served by Nextcloud 28+
  // and come back in a 404 propstat elsewhere, which the parser ignores
  static const _props = '''
      <d:resourcetype/>
      <d:getetag/>
      <d:getcontenttype/>
      <d:getcontentlength/>
      <d:getlastmodified/>
      <oc:fileid/>
      <oc:size/>
      <nc:has-preview/>
      <nc:metadata-photos-size/>
      <nc:metadata-photos-original_date_time/>
      <nc:metadata-photos-gps/>''';

  static const propfindBody =
      '''<?xml version="1.0" encoding="UTF-8"?>
<d:propfind $_namespaceAttributes>
  <d:prop>$_props
  </d:prop>
</d:propfind>
''';

  // `scopeHref` is relative to `/remote.php/dav/`, e.g. `/files/alice/Photos` (unencoded; escaped here for XML)
  static String searchBody({required String scopeHref, required int limit, required int offset}) {
    return '''<?xml version="1.0" encoding="UTF-8"?>
<d:searchrequest $_namespaceAttributes xmlns:ns="${DavNamespaces.searchDav}">
  <d:basicsearch>
    <d:select>
      <d:prop>$_props
      </d:prop>
    </d:select>
    <d:from>
      <d:scope>
        <d:href>${escapeXml(scopeHref)}</d:href>
        <d:depth>infinity</d:depth>
      </d:scope>
    </d:from>
    <d:where>
      <d:or>
        <d:like>
          <d:prop><d:getcontenttype/></d:prop>
          <d:literal>image/%</d:literal>
        </d:like>
        <d:like>
          <d:prop><d:getcontenttype/></d:prop>
          <d:literal>video/%</d:literal>
        </d:like>
      </d:or>
    </d:where>
    <d:orderby>
      <d:order>
        <d:prop><d:getlastmodified/></d:prop>
        <d:descending/>
      </d:order>
    </d:orderby>
    <d:limit>
      <d:nresults>$limit</d:nresults>
      <ns:firstresult>$offset</ns:firstresult>
    </d:limit>
  </d:basicsearch>
</d:searchrequest>
''';
  }

  static String escapeXml(String value) => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
}
