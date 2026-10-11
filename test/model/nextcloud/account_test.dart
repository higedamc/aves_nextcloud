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

  group('view allowance', () {
    const mb = 1024 * 1024;

    test('is a stated slice of the limit, not what the sync leaves over', () {
      final account = NextcloudAccount.fromJson(json());

      expect(account.cacheLimitBytes, 2048 * mb);
      expect(account.viewAllowanceBytes, 256 * mb);
      expect(account.syncBudgetBytes, account.cacheLimitBytes - 256 * mb);
    });

    test('a small limit keeps three quarters of itself for the sync', () {
      expect(NextcloudAccount.fromJson({...json(), 'cacheLimitBytes': 100 * mb}).viewAllowanceBytes, 25 * mb);
      expect(NextcloudAccount.fromJson({...json(), 'cacheLimitBytes': 100 * mb}).syncBudgetBytes, 75 * mb);
      expect(NextcloudAccount.fromJson({...json(), 'cacheLimitBytes': 0}).viewAllowanceBytes, 0);
      expect(NextcloudAccount.fromJson({...json(), 'cacheLimitBytes': 0}).syncBudgetBytes, 0);
    });

    test('is not a setting: it is not stored, and a stored value is not read', () {
      final account = NextcloudAccount.fromJson({...json(), 'viewAllowanceBytes': 1});
      expect(account.viewAllowanceBytes, 256 * mb);
      expect(account.toJson().containsKey('viewAllowanceBytes'), isFalse);
    });
  });

  group('video auto-download threshold', () {
    test('an account stored before the field existed reads the default, not zero', () {
      final account = NextcloudAccount.fromJson(json());

      // 0 would mean "no video is ever small enough", which looks like a deliberate setting and would
      // never be reported as a bug
      expect(account.videoAutoDownloadLimitBytes, NextcloudAccount.defaultVideoAutoDownloadLimitBytes);
      expect(account.videoAutoDownloadLimitBytes, 500 * 1024 * 1024);
    });

    test('a stored value survives a round trip', () {
      final account = NextcloudAccount.fromJson({...json(), 'videoAutoDownloadLimitBytes': 100 * 1024 * 1024});
      expect(account.videoAutoDownloadLimitBytes, 100 * 1024 * 1024);
      expect(NextcloudAccount.fromJson(account.toJson()).videoAutoDownloadLimitBytes, 100 * 1024 * 1024);
    });

    test('a value outside the offered range is clamped into it', () {
      const steps = NextcloudAccount.videoAutoDownloadLimitSteps;

      expect(NextcloudAccount.fromJson({...json(), 'videoAutoDownloadLimitBytes': -1}).videoAutoDownloadLimitBytes, steps.first, reason: 'a negative limit fails closed invisibly: no video would ever be fetched again');
      expect(NextcloudAccount.fromJson({...json(), 'videoAutoDownloadLimitBytes': 0}).videoAutoDownloadLimitBytes, steps.first);
      expect(NextcloudAccount.fromJson({...json(), 'videoAutoDownloadLimitBytes': 1 << 50}).videoAutoDownloadLimitBytes, steps.last);
    });

    test('the offered steps cover the specified range and stay ordered', () {
      const steps = NextcloudAccount.videoAutoDownloadLimitSteps;

      expect(steps, containsAllInOrder([500 * 1024 * 1024, 10 * 1024 * 1024 * 1024]), reason: '500 MB to 10 GB was the specified range');
      expect(steps.contains(NextcloudAccount.defaultVideoAutoDownloadLimitBytes), isTrue, reason: 'the default must be selectable, or the picker cannot show the current value');
      for (var i = 1; i < steps.length; i++) {
        expect(steps[i], greaterThan(steps[i - 1]), reason: 'clamping uses first and last as the bounds, so the list must be ascending');
      }
    });
  });
}
