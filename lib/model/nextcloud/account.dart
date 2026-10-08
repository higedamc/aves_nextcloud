import 'package:aves/model/nextcloud/paths.dart';

// A configured Nextcloud account.
// Non-secret fields are persisted in settings as JSON (see `SettingKeys.nextcloudAccountsKey`).
// The app password is NEVER stored here; it lives in the credential store under `credentialKey`.
class NextcloudAccount {
  // stable local identifier, generated once at creation, used for the credential key and the mirror directory name
  final String id;

  // base URL without WebDAV path, e.g. `https://cloud.example.com` or `https://host:31001`
  final Uri serverUrl;

  final String username;

  // folder to browse, relative to the user's files root, normalized by `NextcloudPaths.normalize`, `''` = root
  final String rootFolder;

  // `http://` is refused unless the user explicitly opts in for this account
  final bool allowInsecureHttp;

  // local mirror budget for this account; older items are evicted when exceeded
  final int cacheLimitBytes;

  final bool enabled;

  const NextcloudAccount({
    required this.id,
    required this.serverUrl,
    required this.username,
    required this.rootFolder,
    this.allowInsecureHttp = false,
    required this.cacheLimitBytes,
    this.enabled = true,
  });

  static const defaultCacheLimitBytes = 2 * 1024 * 1024 * 1024;

  String get credentialKey => 'nextcloud_app_password_$id';

  // directory name of this account under the mirror root
  String get mirrorDirName => id;

  bool get isInsecure => serverUrl.scheme == 'http';

  bool get isSchemeAllowed => serverUrl.scheme == 'https' || (isInsecure && allowInsecureHttp);

  // e.g. `/remote.php/dav/files/alice` (unencoded)
  String get filesRootDavPath => '/remote.php/dav/files/$username';

  String get displayName => '$username@${serverUrl.host}';

  NextcloudAccount copyWith({
    Uri? serverUrl,
    String? username,
    String? rootFolder,
    bool? allowInsecureHttp,
    int? cacheLimitBytes,
    bool? enabled,
  }) {
    return NextcloudAccount(
      id: id,
      serverUrl: serverUrl ?? this.serverUrl,
      username: username ?? this.username,
      rootFolder: rootFolder ?? this.rootFolder,
      allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
      cacheLimitBytes: cacheLimitBytes ?? this.cacheLimitBytes,
      enabled: enabled ?? this.enabled,
    );
  }

  factory NextcloudAccount.fromJson(Map<String, dynamic> json) {
    final rootFolder = NextcloudPaths.normalize(json['rootFolder'] as String? ?? '');
    if (rootFolder == null) {
      throw FormatException('unsafe rootFolder in account json: ${json['rootFolder']}');
    }
    return NextcloudAccount(
      id: json['id'] as String,
      serverUrl: Uri.parse(json['serverUrl'] as String),
      username: json['username'] as String,
      rootFolder: rootFolder,
      allowInsecureHttp: json['allowInsecureHttp'] as bool? ?? false,
      cacheLimitBytes: json['cacheLimitBytes'] as int? ?? defaultCacheLimitBytes,
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'serverUrl': serverUrl.toString(),
    'username': username,
    'rootFolder': rootFolder,
    'allowInsecureHttp': allowInsecureHttp,
    'cacheLimitBytes': cacheLimitBytes,
    'enabled': enabled,
  };

  @override
  bool operator ==(Object other) => other is NextcloudAccount && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => '$runtimeType{id=$id, server=$serverUrl, user=$username, root=$rootFolder}';
}

// Secret counterpart of `NextcloudAccount`, held in memory only for the duration of a session.
class NextcloudCredentials {
  final String username, appPassword;

  const NextcloudCredentials({required this.username, required this.appPassword});

  // intentionally no secret in `toString`
  @override
  String toString() => '$runtimeType{username=$username}';
}
