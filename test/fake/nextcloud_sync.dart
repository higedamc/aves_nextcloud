import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/credential_store.dart';
import 'package:aves/model/nextcloud/errors.dart';
import 'package:aves/model/nextcloud/mirror_store.dart';
import 'package:aves/model/nextcloud/paths.dart';
import 'package:aves/model/nextcloud/remote_item.dart';
import 'package:aves/model/nextcloud/repository.dart';
import 'package:aves/model/nextcloud/sync_ports.dart';

// Fakes for the sync use case: a scripted server, a mirror store on a temp directory, a recording sink.

bool _isUnder(String path, String prefix) => prefix.isEmpty || path == prefix || path.startsWith('$prefix${NextcloudPaths.separator}');

NextcloudRemoteItem fakeFile(String relativePath, {String etag = 'v1', int size = 3, DateTime? modified, int fileId = 1}) => NextcloudRemoteItem(
  relativePath: relativePath,
  fileId: fileId,
  etag: etag,
  mimeType: relativePath.endsWith('.mp4') ? 'video/mp4' : 'image/jpeg',
  sizeBytes: size,
  lastModified: modified ?? DateTime.utc(2026, 10, 1),
  isCollection: false,
);

NextcloudRemoteItem fakeCollection(String relativePath, String etag) => NextcloudRemoteItem(
  relativePath: relativePath,
  fileId: null,
  etag: etag,
  mimeType: null,
  sizeBytes: 0,
  lastModified: DateTime.utc(2026, 10, 1),
  isCollection: true,
);

// The server, declared as a tree: collections by path (always including `''`), files, and paths that fail.
// `listMediaTree` reproduces the WebDAV repository's callback semantics: unchanged collections are skipped
// and published, failing paths are reported, and a collection is published post-order only when nothing
// under it was reported. Either strategy checks the root first: an unchanged root publishes the root and
// enumerates nothing. With `supportsSearch`, every file comes back as one snapshot and the root alone is
// published, and only when nothing was reported.
class FakeNextcloudRepository implements NextcloudRepository {
  @override
  final NextcloudAccount account;

  final Map<String, String> collections;
  final Map<String, NextcloudRemoteItem> files;
  final Map<String, NextcloudFailure> failing;
  final Map<String, NextcloudFailure> downloadFailures = {};
  final Map<String, List<int>> bodies = {};
  final bool supportsSearch;
  NextcloudFailure? probeFailure;
  int probeCount = 0;
  bool disposed = false;

  final List<String> listedRoots = [];
  final List<Map<String, String>> knownEtagsReceived = [];
  final List<String> downloads = [];
  // listings that went past the root check and enumerated the scope
  int enumerations = 0;

  new(this.account, {required Map<String, String> collections, required List<NextcloudRemoteItem> files, Map<String, NextcloudFailure> failing = const {}, this.supportsSearch = false})
    : collections = Map.of(collections),
      files = {for (final f in files) f.relativePath: f},
      failing = Map.of(failing);

  @override
  Future<NextcloudServerInfo> probe() async {
    probeCount++;
    final failure = probeFailure;
    if (failure != null) throw failure;
    return NextcloudServerInfo(version: '32.0.11', supportsSearch: supportsSearch, supportsInfiniteDepth: false, supportsPhotoMetadata: true);
  }

  @override
  Future<List<NextcloudRemoteItem>> listCollection(String relativePath) => throw UnimplementedError();

  @override
  Future<NextcloudRemoteItem> stat(String relativePath) => throw UnimplementedError();

  @override
  Stream<NextcloudRemoteItem> listMediaTree(
    String relativePath, {
    Map<String, String> knownCollectionEtags = const {},
    void Function(NextcloudRemoteItem collection)? onCollection,
    NextcloudItemFailureCallback? onItemFailure,
    NextcloudCancellation? cancellation,
  }) async* {
    listedRoots.add(relativePath);
    knownEtagsReceived.add(Map.of(knownCollectionEtags));
    if (cancellation?.isCancelled ?? false) throw const NextcloudCancelledFailure();

    final rootFailure = failing[''];
    if (rootFailure != null) throw rootFailure;
    final rootCollection = fakeCollection('', collections['']!);
    if (knownCollectionEtags[''] == collections['']) {
      onCollection?.call(rootCollection);
      return;
    }
    enumerations++;

    if (supportsSearch) {
      var reported = false;
      for (final file in files.values) {
        final failure = failing[file.relativePath];
        if (failure != null) {
          reported = true;
          onItemFailure?.call(file.relativePath, failure);
          continue;
        }
        yield file;
      }
      if (!reported) onCollection?.call(rootCollection);
      return;
    }

    final skipped = <String>{};
    final reported = <String>{};
    final byDepth = collections.keys.toList()..sort((a, b) => a.split('/').length.compareTo(b.split('/').length));
    for (final path in byDepth) {
      if (skipped.any((s) => _isUnder(path, s)) || reported.any((r) => _isUnder(path, r))) continue;
      final failure = failing[path];
      if (knownCollectionEtags[path] == collections[path]) {
        skipped.add(path);
        onCollection?.call(fakeCollection(path, collections[path]!));
      } else if (failure != null) {
        if (path == '') throw failure;
        reported.add(path);
        onItemFailure?.call(path, failure);
      }
    }
    for (final file in files.values) {
      final path = file.relativePath;
      if (skipped.any((s) => _isUnder(path, s)) || reported.any((r) => _isUnder(path, r))) continue;
      final failure = failing[path];
      if (failure != null) {
        reported.add(path);
        onItemFailure?.call(path, failure);
        continue;
      }
      yield file;
    }
    // post-order publish of the collections that were listed and have nothing reported beneath
    for (final path in byDepth.reversed) {
      if (skipped.contains(path) || skipped.any((s) => s != path && _isUnder(path, s))) continue;
      if (reported.any((r) => _isUnder(path, r) || _isUnder(r, path))) continue;
      onCollection?.call(fakeCollection(path, collections[path]!));
    }
  }

  @override
  Future<String?> downloadTo(NextcloudRemoteItem item, String localPath, {NextcloudProgressCallback? onProgress, NextcloudCancellation? cancellation}) async {
    if (cancellation?.isCancelled ?? false) throw const NextcloudCancelledFailure();
    final failure = downloadFailures[item.relativePath];
    if (failure != null) throw failure;
    downloads.add(item.relativePath);
    final bytes = bodies[item.relativePath] ?? List.filled(item.sizeBytes, 0);
    final part = File('$localPath.part');
    await part.parent.create(recursive: true);
    await part.writeAsBytes(bytes, flush: true);
    await part.rename(localPath);
    onProgress?.call(bytes.length, bytes.length);
    return item.etag;
  }

  @override
  Future<Uint8List> fetchPreview(NextcloudRemoteItem item, {required int width, required int height}) => throw UnimplementedError();

  @override
  void dispose() => disposed = true;
}

class FakeNextcloudRepositoryFactory implements NextcloudRepositoryFactory {
  final FakeNextcloudRepository repository;
  final List<NextcloudCredentials> opened = [];

  new(this.repository);

  @override
  NextcloudRepository open(NextcloudAccount account, NextcloudCredentials credentials) {
    opened.add(credentials);
    return repository;
  }
}

class FakeNextcloudCredentialStore extends NextcloudCredentialStore {
  final Map<String, String> passwords = {};

  @override
  Future<String?> readAppPassword(NextcloudAccount account) async => passwords[account.credentialKey];

  @override
  Future<bool> writeAppPassword(NextcloudAccount account, String? appPassword) async {
    if (appPassword == null) {
      passwords.remove(account.credentialKey);
    } else {
      passwords[account.credentialKey] = appPassword;
    }
    return true;
  }
}

// Mirror store over a temp directory with in-memory rows; the same policy as the real one where the
// sync depends on it: `record` reads the size from disk, `remove` deletes file then row, eviction is LRU.
class FakeNextcloudMirrorStore implements NextcloudMirrorStore {
  @override
  final String mirrorRoot;

  final Map<String, Map<String, NextcloudMirrorIndexEntry>> _rows = {};
  final List<String> evictCalls = [];

  new(this.mirrorRoot);

  Map<String, NextcloudMirrorIndexEntry> rows(NextcloudAccount account) => _rows.putIfAbsent(account.id, () => {});

  @override
  Future<void> init() async {}

  @override
  String localPathFor(NextcloudAccount account, String relativePath) {
    final root = '$mirrorRoot${Platform.pathSeparator}${account.mirrorDirName}';
    return relativePath.isEmpty ? root : '$root${Platform.pathSeparator}${relativePath.split(NextcloudPaths.separator).join(Platform.pathSeparator)}';
  }

  @override
  String? relativePathFor(NextcloudAccount account, String localPath) => throw UnimplementedError();

  @override
  Future<NextcloudMirrorIndexEntry?> lookup(NextcloudAccount account, String relativePath) async => rows(account)[relativePath];

  @override
  Future<Set<NextcloudMirrorIndexEntry>> listAll(NextcloudAccount account) async => rows(account).values.toSet();

  @override
  Future<void> record(NextcloudAccount account, NextcloudMirrorIndexEntry entry) async {
    final stat = await File(localPathFor(account, entry.relativePath)).stat();
    if (stat.type != FileSystemEntityType.file) throw NextcloudNotFoundFailure(entry.relativePath);
    rows(account)[entry.relativePath] = NextcloudMirrorIndexEntry(
      relativePath: entry.relativePath,
      etag: entry.etag,
      fileId: entry.fileId,
      sizeBytes: stat.size,
      remoteLastModified: entry.remoteLastModified,
      downloadedAt: entry.downloadedAt,
      lastAccessAt: entry.lastAccessAt,
    );
  }

  @override
  Future<void> remove(NextcloudAccount account, String relativePath) async {
    final file = File(localPathFor(account, relativePath));
    if (await file.exists()) await file.delete();
    rows(account).remove(relativePath);
  }

  @override
  Future<void> touch(NextcloudAccount account, String relativePath, DateTime accessedAt) async {
    final existing = rows(account)[relativePath];
    if (existing != null) rows(account)[relativePath] = existing.copyWith(lastAccessAt: accessedAt);
  }

  @override
  Future<int> usedBytes(NextcloudAccount account) async => rows(account).values.fold<int>(0, (sum, v) => sum + v.sizeBytes);

  @override
  Future<Set<String>> evictToFit(NextcloudAccount account, {int reserveBytes = 0}) async {
    evictCalls.add('${account.id}:$reserveBytes');
    final target = (account.cacheLimitBytes - reserveBytes).clamp(0, account.cacheLimitBytes);
    final evicted = <String>{};
    var used = await usedBytes(account);
    final candidates = rows(account).values.toList()
      ..sort((a, b) {
        final byAccess = a.lastAccessAt.compareTo(b.lastAccessAt);
        return byAccess != 0 ? byAccess : a.relativePath.compareTo(b.relativePath);
      });
    for (final victim in candidates) {
      if (used <= target) break;
      await remove(account, victim.relativePath);
      evicted.add(victim.relativePath);
      used -= victim.sizeBytes;
    }
    return evicted;
  }

  @override
  Future<void> purge(NextcloudAccount account) async {
    final dir = Directory(localPathFor(account, ''));
    if (await dir.exists()) await dir.delete(recursive: true);
    _rows.remove(account.id);
  }
}

class FakeNextcloudSyncSink implements NextcloudSyncSink {
  final List<String> puts = [];
  final List<Set<String>> removals = [];
  final Set<String> putFails = {};

  Set<String> get removed => removals.expand((v) => v).toSet();

  @override
  Future<bool> putMirroredFile(NextcloudAccount account, NextcloudRemoteItem item, String localPath) async {
    if (putFails.contains(item.relativePath)) return false;
    if (!await File(localPath).exists()) throw StateError('put before the file was written: $localPath');
    puts.add(item.relativePath);
    return true;
  }

  @override
  Future<void> removeMirroredFiles(NextcloudAccount account, Set<String> relativePaths) async => removals.add(Set.of(relativePaths));
}

class MemoryNextcloudSyncStateStore implements NextcloudSyncStateStore {
  final Map<String, NextcloudSyncState> states = {};
  int saves = 0;

  @override
  Future<NextcloudSyncState> load(NextcloudAccount account) async => states[account.id] ?? NextcloudSyncState.empty;

  @override
  Future<void> save(NextcloudAccount account, NextcloudSyncState state) async {
    saves++;
    states[account.id] = state;
  }

  @override
  Future<void> clear(NextcloudAccount account) async => states.remove(account.id);
}
