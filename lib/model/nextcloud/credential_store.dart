import 'package:aves/model/nextcloud/account.dart';

// Secret storage contract (layer L2). The default implementation wraps the existing `securityService`
// (Android `EncryptedSharedPreferences`, AES256-GCM, Keystore-backed master key), the same store as vault passwords.
// Keys are `account.credentialKey`. Nothing else about the account is secret.
abstract class NextcloudCredentialStore {
  Future<String?> readAppPassword(NextcloudAccount account);

  // `null` removes the entry. Returns false when the platform store failed (already reported).
  Future<bool> writeAppPassword(NextcloudAccount account, String? appPassword);

  Future<NextcloudCredentials?> credentialsFor(NextcloudAccount account) async {
    final appPassword = await readAppPassword(account);
    return appPassword == null ? null : NextcloudCredentials(username: account.username, appPassword: appPassword);
  }
}

// Non-secret account list contract (layer L2). The default implementation serializes `NextcloudAccount.toJson`
// into settings under `SettingKeys.nextcloudAccountsKey`.
abstract class NextcloudAccountStore {
  Future<List<NextcloudAccount>> loadAll();

  Future<void> save(NextcloudAccount account);

  // Removing an account must also remove its credential and its mirror directory; the caller (use case) sequences that.
  Future<void> remove(String accountId);
}
