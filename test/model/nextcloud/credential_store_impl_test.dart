import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/credential_store_impl.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/services/security_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fake/security_service.dart';

void main() {
  final account = NextcloudAccount.fromJson({
    'id': 'acc1',
    'serverUrl': 'https://host:31001',
    'username': 'alice',
    'rootFolder': 'Photos',
  });

  setUp(() {
    getIt.registerSingleton<SecurityService>(FakeSecurityService());
  });

  tearDown(() {
    getIt.unregister<SecurityService>();
  });

  test(
    'round trips the app password under the account credential key',
    () async {
      final store = SecurityNextcloudCredentialStore();

      expect(await store.readAppPassword(account), isNull);

      expect(await store.writeAppPassword(account, 's3cret'), isTrue);
      expect(await store.readAppPassword(account), 's3cret');

      // never stored under a raw/guessable key, only under the account-derived one
      expect(await securityService.readValue<String>('s3cret'), isNull);

      expect(await store.writeAppPassword(account, null), isTrue);
      expect(await store.readAppPassword(account), isNull);
    },
  );

  test(
    'credentialsFor pairs the stored password with the account username',
    () async {
      final store = SecurityNextcloudCredentialStore();
      await store.writeAppPassword(account, 's3cret');

      final credentials = await store.credentialsFor(account);
      expect(credentials?.username, 'alice');
      expect(credentials?.appPassword, 's3cret');
    },
  );
}
