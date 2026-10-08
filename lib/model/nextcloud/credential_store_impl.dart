import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/credential_store.dart';
import 'package:aves/services/common/services.dart';

// Default `NextcloudCredentialStore`, wrapping the same `securityService` channel vault passwords use
// (Android `EncryptedSharedPreferences`, AES256-GCM, Keystore-backed master key). No new storage mechanism.
class SecurityNextcloudCredentialStore implements NextcloudCredentialStore {
  const new();

  @override
  Future<String?> readAppPassword(NextcloudAccount account) =>
      securityService.readValue<String>(account.credentialKey);

  @override
  Future<bool> writeAppPassword(
    NextcloudAccount account,
    String? appPassword,
  ) => securityService.writeValue<String>(account.credentialKey, appPassword);
}
