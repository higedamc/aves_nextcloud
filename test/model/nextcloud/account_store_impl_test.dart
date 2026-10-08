import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/account_store_impl.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../common.dart';

void main() {
  NextcloudAccount account({String id = 'acc1', String username = 'alice'}) =>
      NextcloudAccount.fromJson({
        'id': id,
        'serverUrl': 'https://host:31001',
        'username': username,
        'rootFolder': 'Photos',
      });

  group('decodeNextcloudAccounts', () {
    test('decodes every well-formed entry', () {
      final raw = encodeNextcloudAccounts([
        account(),
        account(id: 'acc2', username: 'bob'),
      ]);
      final decoded = decodeNextcloudAccounts(raw);
      expect(decoded.map((v) => v.id), ['acc1', 'acc2']);
    });

    test('skips a corrupt entry instead of failing the whole list', () {
      final raw = [
        jsonEncodeAccount(account()),
        'not json at all',
        jsonEncodeAccount(account(id: 'acc2', username: 'bob')),
      ];
      final decoded = decodeNextcloudAccounts(raw);
      expect(decoded.map((v) => v.id), ['acc1', 'acc2']);
    });
  });

  group('SettingsNextcloudAccountStore', () {
    setUpAll(() async => await setUpAllServices());
    setUp(() async => await setUpServices());
    tearDownAll(() async => await tearDownAllServices());

    test('starts empty', () async {
      final store = const SettingsNextcloudAccountStore();
      expect(await store.loadAll(), isEmpty);
    });

    test('save adds and updates by id, remove drops it', () async {
      final store = const SettingsNextcloudAccountStore();

      await store.save(account());
      expect((await store.loadAll()).map((v) => v.id), ['acc1']);

      await store.save(account(username: 'alice2'));
      final afterUpdate = await store.loadAll();
      expect(afterUpdate.length, 1);
      expect(afterUpdate.single.username, 'alice2');

      await store.save(account(id: 'acc2', username: 'bob'));
      expect((await store.loadAll()).map((v) => v.id).toSet(), {
        'acc1',
        'acc2',
      });

      await store.remove('acc1');
      expect((await store.loadAll()).map((v) => v.id), ['acc2']);
    });
  });
}

String jsonEncodeAccount(NextcloudAccount account) =>
    encodeNextcloudAccounts([account]).single;
