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

  const new({
    required this.id,
    required this.serverUrl,
    required this.username,
    required this.rootFolder,
    this.allowInsecureHttp = false,
    required this.cacheLimitBytes,
    this.enabled = true,
  });

  // `id` becomes a directory name (`mirrorDirName`) and a credential key, `username` becomes a URL segment:
  // both must be single safe path segments. Creators (settings UI) must check these before constructing.
  static bool isValidId(String id) => id.isNotEmpty && NextcloudPaths.isSafeSegment(id);

  static bool isValidUsername(String username) => username.isNotEmpty && NextcloudPaths.isSafeSegment(username);

  // http(s) only, with a host, and never credentials/query/fragment embedded in the base URL
  static bool isValidServerUrl(Uri url) => (url.scheme == 'https' || url.scheme == 'http') && url.host.isNotEmpty && url.userInfo.isEmpty && !url.hasQuery && !url.hasFragment;

  static const defaultCacheLimitBytes = 2 * 1024 * 1024 * 1024;

  String get credentialKey => 'nextcloud_app_password_$id';

  // directory name of this account under the mirror root
  String get mirrorDirName => id;

  bool get isInsecure => serverUrl.scheme == 'http';

  bool get isSchemeAllowed => serverUrl.scheme == 'https' || (isInsecure && allowInsecureHttp);

  // unencoded form, for comparing against decoded server hrefs (`NextcloudPaths.relativePathFromHref`)
  String get filesRootDavPath => '/remote.php/dav/files/$username';

  // unencoded root href of `rootFolder`, e.g. `/remote.php/dav/files/alice/Photos`
  String get rootHref => rootFolder.isEmpty ? filesRootDavPath : '$filesRootDavPath/$rootFolder';

  // encoded form, for building request URLs; appends the encoded relative path when given
  Uri filesUrl([String relativePath = '']) {
    final encodedRoot = NextcloudPaths.encodeForUrl(rootFolder);
    final encodedPath = NextcloudPaths.encodeForUrl(relativePath);
    final segments = ['remote.php', 'dav', 'files', Uri.encodeComponent(username), encodedRoot, encodedPath].where((v) => v.isNotEmpty);
    return serverUrl.replace(path: '${serverUrl.path.replaceAll(RegExp(r'/+$'), '')}/${segments.join('/')}');
  }

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

  factory fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String? ?? '';
    if (!isValidId(id)) {
      throw const FormatException('unsafe id in account json');
    }
    final username = json['username'] as String? ?? '';
    if (!isValidUsername(username)) {
      throw const FormatException('unsafe username in account json');
    }
    final rootFolder = NextcloudPaths.normalize(json['rootFolder'] as String? ?? '');
    if (rootFolder == null) {
      throw FormatException('unsafe rootFolder in account json: ${json['rootFolder']}');
    }
    final serverUrl = Uri.parse(json['serverUrl'] as String? ?? '');
    if (!isValidServerUrl(serverUrl)) {
      throw const FormatException('unsupported serverUrl in account json');
    }
    return NextcloudAccount(
      id: id,
      serverUrl: serverUrl,
      username: username,
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

  const new({required this.username, required this.appPassword});

  // intentionally no secret in `toString`
  @override
  String toString() => '$runtimeType{username=$username}';
}
