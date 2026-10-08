import 'dart:convert';

import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/credential_store.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves_model/aves_model.dart';

// Pure decode of the stored string list into accounts. A single corrupt entry (e.g. from a future app
// version, or a manual edit of the backing store) is reported and skipped rather than failing the whole list.
List<NextcloudAccount> decodeNextcloudAccounts(List<String> raw) {
  final accounts = <NextcloudAccount>[];
  for (final entry in raw) {
    try {
      accounts.add(
        NextcloudAccount.fromJson(jsonDecode(entry) as Map<String, dynamic>),
      );
    } catch (error, stack) {
      reportService.recordError(error, stack);
    }
  }
  return accounts;
}

List<String> encodeNextcloudAccounts(List<NextcloudAccount> accounts) =>
    accounts.map((v) => jsonEncode(v.toJson())).toList();

// Default `NextcloudAccountStore`. Accounts are not secret, so they go straight into the regular settings
// store (same `SettingsAccess` API every other settings module uses) under `SettingKeys.nextcloudAccountsKey`,
// one JSON-encoded string per account. This talks to `settings` directly instead of adding a dedicated
// `NextcloudSettings` mixin, so this leaf does not need to touch `settings.dart`.
class SettingsNextcloudAccountStore implements NextcloudAccountStore {
  const new();

  @override
  Future<List<NextcloudAccount>> loadAll() async => decodeNextcloudAccounts(
    settings.getStringList(SettingKeys.nextcloudAccountsKey) ?? [],
  );

  @override
  Future<void> save(NextcloudAccount account) async {
    final accounts = await loadAll();
    accounts.removeWhere((v) => v.id == account.id);
    accounts.add(account);
    settings.set(
      SettingKeys.nextcloudAccountsKey,
      encodeNextcloudAccounts(accounts),
    );
  }

  // Only removes the account entry itself. The credential and the mirror directory (layer L3, not yet
  // implemented) are a different caller's responsibility; see `NextcloudAccountStore.remove`.
  @override
  Future<void> remove(String accountId) async {
    final accounts = await loadAll();
    accounts.removeWhere((v) => v.id == accountId);
    settings.set(
      SettingKeys.nextcloudAccountsKey,
      encodeNextcloudAccounts(accounts),
    );
  }
}
