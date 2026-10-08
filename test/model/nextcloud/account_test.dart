import 'package:aves/model/nextcloud/account.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> json({String id = 'acc1', String username = 'alice', String rootFolder = 'Photos'}) => {
    'id': id,
    'serverUrl': 'https://host:31001',
    'username': username,
    'rootFolder': rootFolder,
  };

  test('round trips through json', () {
    final account = NextcloudAccount.fromJson(json());
    expect(NextcloudAccount.fromJson(account.toJson()), account);
    expect(account.rootHref, '/remote.php/dav/files/alice/Photos');
    expect(account.filesUrl('2024 summer/a&b.jpg').toString(), 'https://host:31001/remote.php/dav/files/alice/Photos/2024%20summer/a%26b.jpg');
    expect(account.filesUrl().toString(), 'https://host:31001/remote.php/dav/files/alice/Photos');
  });

  test('encodes username in URLs and keeps a sub-path server base', () {
    final account = NextcloudAccount.fromJson({...json(username: 'bob@example.com', rootFolder: ''), 'serverUrl': 'https://host/nextcloud/'});
    expect(account.filesUrl('a.jpg').toString(), 'https://host/nextcloud/remote.php/dav/files/bob%40example.com/a.jpg');
    expect(account.rootHref, '/remote.php/dav/files/bob@example.com');
  });

  test('rejects ids and usernames that are not single safe segments', () {
    expect(() => NextcloudAccount.fromJson(json(id: '../../databases')), throwsFormatException);
    expect(() => NextcloudAccount.fromJson(json(id: '')), throwsFormatException);
    expect(() => NextcloudAccount.fromJson(json(id: 'a/b')), throwsFormatException);
    expect(() => NextcloudAccount.fromJson(json(username: '../alice')), throwsFormatException);
    expect(() => NextcloudAccount.fromJson(json(username: 'alice/..')), throwsFormatException);
    expect(() => NextcloudAccount.fromJson(json(rootFolder: '../x')), throwsFormatException);
  });

  test('rejects server URLs with credentials, query, fragment or non-http schemes', () {
    for (final bad in ['https://alice:pw@host', 'https://host/?x=1', 'https://host/#frag', 'ftp://host', 'host:31001', '']) {
      expect(() => NextcloudAccount.fromJson({...json(), 'serverUrl': bad}), throwsFormatException, reason: bad);
    }
  });

  test('scheme policy', () {
    final https = NextcloudAccount.fromJson(json());
    expect(https.isSchemeAllowed, isTrue);
    final http = https.copyWith(serverUrl: Uri.parse('http://host'));
    expect(http.isSchemeAllowed, isFalse);
    expect(http.copyWith(allowInsecureHttp: true).isSchemeAllowed, isTrue);
  });
}
