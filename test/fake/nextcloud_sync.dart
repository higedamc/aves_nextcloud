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

  // every byte request in order, originals and previews alike, for assertions about fetch order
  final List<String> fetched = [];
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
  Future<NextcloudRemoteItem> stat(String relativePath) async {
    final failure = failing[relativePath];
    if (failure != null) throw failure;
    final file = files[relativePath];
    if (file != null) return file;
    final etag = collections[relativePath];
    if (etag != null) return fakeCollection(relativePath, etag);
    throw NextcloudNotFoundFailure(relativePath);
  }

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
    fetched.add(item.relativePath);
    final bytes = bodies[item.relativePath] ?? List.filled(item.sizeBytes, 0);
    final part = File('$localPath.part');
    await part.parent.create(recursive: true);
    await part.writeAsBytes(bytes, flush: true);
    await part.rename(localPath);
    onProgress?.call(bytes.length, bytes.length);
    return item.etag;
  }

  // preview requests, in order, as `path@WIDTHxHEIGHT`; the bytes are `previewBytes` zeros unless a body is given
  final List<String> previews = [];
  final Map<String, NextcloudFailure> previewFailures = {};
  final Map<String, List<int>> previewBodies = {};
  int previewBytes = 2;

  @override
  Future<Uint8List> fetchPreview(NextcloudRemoteItem item, {required int width, required int height}) async {
    final failure = previewFailures[item.relativePath];
    if (failure != null) throw failure;
    previews.add('${item.relativePath}@${width}x$height');
    fetched.add(item.relativePath);
    return Uint8List.fromList(previewBodies[item.relativePath] ?? List.filled(previewBytes, 0));
  }

  // paths requested as previews, without the size suffix
  List<String> get previewPaths => previews.map((v) => v.substring(0, v.lastIndexOf('@'))).toList();

  @override
  Future<Uint8List> fetchPoster(NextcloudRemoteItem item, {required int width, required int height}) => throw UnimplementedError();

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
// sync depends on it: `record` reads the size from disk (both files for a view row), `remove` deletes
// files then row, eviction works one budget class per order and demotes rather than removes, and the
// sidecars live apart from the mirror tree.
class FakeNextcloudMirrorStore implements NextcloudMirrorStore {
  @override
  final String mirrorRoot;

  final Map<String, Map<String, NextcloudMirrorIndexEntry>> _rows = {};
  final List<String> evictCalls = [];

  new(this.mirrorRoot);

  Map<String, NextcloudMirrorIndexEntry> rows(NextcloudAccount account) => _rows.putIfAbsent(account.id, () => {});

  @override
  Future<void> init() async {}

  String _accountRoot(NextcloudAccount account) => '$mirrorRoot${Platform.pathSeparator}${account.mirrorDirName}';

  String _sidecarRoot(NextcloudAccount account) => '$mirrorRoot${Platform.pathSeparator}${NextcloudMirrorStore.sidecarsDirName}${Platform.pathSeparator}${account.mirrorDirName}';

  String _join(String root, String relativePath) => relativePath.isEmpty ? root : '$root${Platform.pathSeparator}${relativePath.split(NextcloudPaths.separator).join(Platform.pathSeparator)}';

  @override
  String localPathFor(NextcloudAccount account, String relativePath) => _join(_accountRoot(account), relativePath);

  @override
  String sidecarPathFor(NextcloudAccount account, String relativePath) => _join(_sidecarRoot(account), relativePath);

  @override
  String? relativePathFor(NextcloudAccount account, String localPath) {
    final prefix = '${_accountRoot(account)}${Platform.pathSeparator}';
    if (!localPath.startsWith(prefix)) return null;
    return localPath.substring(prefix.length).split(Platform.pathSeparator).join(NextcloudPaths.separator);
  }

  @override
  String? accountIdFor(String localPath) {
    final prefix = '$mirrorRoot${Platform.pathSeparator}';
    if (!localPath.startsWith(prefix)) return null;
    final segments = localPath.substring(prefix.length).split(Platform.pathSeparator);
    if (segments.length < 2 || segments.first == NextcloudMirrorStore.sidecarsDirName) return null;
    return segments.first;
  }

  @override
  Future<NextcloudMirrorIndexEntry?> lookup(NextcloudAccount account, String relativePath) async => rows(account)[relativePath];

  @override
  Future<Set<NextcloudMirrorIndexEntry>> listAll(NextcloudAccount account) async => rows(account).values.toSet();

  Future<void> _deleteIfExists(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> record(NextcloudAccount account, NextcloudMirrorIndexEntry entry) async {
    // same branches as the real store: a placeholder has no file to stat and no bytes to count, and any
    // file already at the path (and any sidecar) goes back to the budget; a view row needs its sidecar
    // and counts both files; every other tier drops a stale sidecar
    final isPlaceholder = entry.tier == NextcloudMirrorTier.placeholder;
    final file = File(localPathFor(account, entry.relativePath));
    final sidecar = File(sidecarPathFor(account, entry.relativePath));
    if (isPlaceholder) {
      await _deleteIfExists(file.path);
      await _deleteIfExists(sidecar.path);
    }
    final stat = isPlaceholder ? null : await file.stat();
    if (stat != null && stat.type != FileSystemEntityType.file) throw NextcloudNotFoundFailure(entry.relativePath);
    var sidecarBytes = 0;
    if (entry.tier == NextcloudMirrorTier.view) {
      final sidecarStat = await sidecar.stat();
      if (sidecarStat.type != FileSystemEntityType.file) throw NextcloudNotFoundFailure(entry.relativePath);
      sidecarBytes = sidecarStat.size;
    } else if (!isPlaceholder) {
      await _deleteIfExists(sidecar.path);
    }
    rows(account)[entry.relativePath] = NextcloudMirrorIndexEntry(
      relativePath: entry.relativePath,
      etag: entry.etag,
      fileId: entry.fileId,
      tier: entry.tier,
      placeholderReason: entry.placeholderReason,
      remoteSizeBytes: entry.remoteSizeBytes,
      localSizeBytes: (stat?.size ?? 0) + sidecarBytes,
      sidecarSizeBytes: sidecarBytes,
      pinned: entry.pinned,
      remoteLastModified: entry.remoteLastModified,
      downloadedAt: entry.downloadedAt,
      lastAccessAt: entry.lastAccessAt,
    );
  }

  @override
  Future<void> remove(NextcloudAccount account, String relativePath) async {
    await _deleteIfExists(localPathFor(account, relativePath));
    await _deleteIfExists(sidecarPathFor(account, relativePath));
    rows(account).remove(relativePath);
  }

  @override
  Future<void> touch(NextcloudAccount account, String relativePath, DateTime accessedAt) async {
    final existing = rows(account)[relativePath];
    if (existing != null) rows(account)[relativePath] = existing.copyWith(lastAccessAt: accessedAt);
  }

  @override
  Future<int> usedBytes(NextcloudAccount account, {NextcloudBudgetClass? of}) async => rows(account).values.fold<int>(
    0,
    (sum, v) =>
        sum +
        switch (of) {
          null => v.localSizeBytes,
          NextcloudBudgetClass.sync => v.syncClassBytes,
          NextcloudBudgetClass.view => v.viewClassBytes,
        },
  );

  @override
  Future<int> freeBytes(NextcloudAccount account, NextcloudBudgetClass of) async => of.limitFor(account) - await usedBytes(account, of: of);

  @override
  Future<NextcloudEvictionOutcome> evictToFit(
    NextcloudAccount account, {
    int reserveBytes = 0,
    NextcloudEvictionOrder order = NextcloudEvictionOrder.leastRecentlyAccessed,
    NextcloudSyncFunding? funding,
  }) async {
    evictCalls.add('${account.id}:$reserveBytes');
    final budgetClass = order.budgetClass;
    final limit = budgetClass.limitFor(account);
    final target = (limit - reserveBytes).clamp(0, limit < 0 ? 0 : limit);
    final demoted = <String>{};
    final demotedToGrid = <String>{};
    var used = await usedBytes(account, of: budgetClass);
    int byPath(NextcloudMirrorIndexEntry a, NextcloudMirrorIndexEntry b) => a.relativePath.compareTo(b.relativePath);
    int byAccess(NextcloudMirrorIndexEntry a, NextcloudMirrorIndexEntry b) {
      final cmp = a.lastAccessAt.compareTo(b.lastAccessAt);
      return cmp != 0 ? cmp : byPath(a, b);
    }

    int byDate(NextcloudMirrorIndexEntry a, NextcloudMirrorIndexEntry b) {
      final cmp = a.remoteLastModified.compareTo(b.remoteLastModified);
      return cmp != 0 ? cmp : byPath(a, b);
    }

    // mirrors the real store: neither a pinned row nor a placeholder is a candidate; the order decides
    // which tiers and which bound, and a view row taken by a sync order goes to grid first and comes up
    // again as a grid row (the candidates are re-read after every demotion, as the real store re-queries)
    List<NextcloudMirrorIndexEntry> candidates() {
      final all = rows(account).values.where((v) => !v.pinned && v.tier != NextcloudMirrorTier.placeholder).toList();
      switch (order) {
        case NextcloudEvictionOrder.leastRecentlyAccessed:
          return all..sort(byAccess);
        case NextcloudEvictionOrder.viewRowsLeastRecentlyAccessed:
          return all.where((v) => v.tier == NextcloudMirrorTier.view).toList()..sort(byAccess);
        case NextcloudEvictionOrder.oldestFirst:
          final fundsGrid = funding == null || funding.tier == NextcloudMirrorTier.grid;
          bool older(NextcloudMirrorIndexEntry v) => funding == null || v.remoteLastModified.isBefore(funding.lastModified);
          final originals = all.where((v) => v.tier == NextcloudMirrorTier.original && (fundsGrid || older(v))).toList()..sort(byDate);
          final grids = fundsGrid ? (all.where((v) => v.tier != NextcloudMirrorTier.original && older(v)).toList()..sort(byDate)) : const <NextcloudMirrorIndexEntry>[];
          return [...originals, ...grids];
      }
    }

    while (used > target) {
      final next = candidates();
      if (next.isEmpty) break;
      final victim = next.first;
      final path = victim.relativePath;
      final file = File(localPathFor(account, path));
      final sidecar = File(sidecarPathFor(account, path));
      if (victim.tier == NextcloudMirrorTier.view && await sidecar.exists()) {
        await _deleteIfExists(file.path);
        await sidecar.rename(file.path);
        rows(account)[path] = victim.asGrid(localSizeBytes: await file.length());
        demotedToGrid.add(path);
        if (budgetClass == NextcloudBudgetClass.view) used -= victim.viewClassBytes;
      } else {
        await _deleteIfExists(file.path);
        await _deleteIfExists(sidecar.path);
        rows(account)[path] = victim.asUnfundedPlaceholder();
        demoted.add(path);
        demotedToGrid.remove(path);
        used -= budgetClass == NextcloudBudgetClass.view ? victim.viewClassBytes : victim.syncClassBytes;
      }
    }
    return NextcloudEvictionOutcome(demoted: demoted, demotedToGrid: demotedToGrid);
  }

  @override
  Future<void> sweepStraySidecars(NextcloudAccount account) async {
    final root = Directory(_sidecarRoot(account));
    if (!await root.exists()) return;
    await for (final entity in root.list(recursive: true)) {
      if (entity is! File) continue;
      final relativePath = entity.path.substring(root.path.length + 1).split(Platform.pathSeparator).join(NextcloudPaths.separator);
      if (rows(account)[relativePath]?.tier == NextcloudMirrorTier.view) continue;
      await entity.delete();
    }
  }

  @override
  Future<void> purge(NextcloudAccount account) async {
    for (final dir in [Directory(_accountRoot(account)), Directory(_sidecarRoot(account))]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
    _rows.remove(account.id);
  }
}

class FakeNextcloudSyncSink implements NextcloudSyncSink {
  final List<String> puts = [];
  final List<Set<String>> removals = [];
  final Set<String> putFails = {};

  // tier each put was made at, so a test can assert what the sync claimed the bytes were
  final Map<String, NextcloudMirrorTier> putTiers = {};

  // paths put with no local bytes; deliberately a separate list, because the whole point of the separate
  // port method is that a placeholder and a mirrored file cannot be confused for one another
  final List<String> placeholders = [];

  // paths whose bytes the budget took back, per call; the entries survive
  final List<Set<String>> demotions = [];

  // paths whose view bytes went back and whose grid bytes are in place again, per call
  final List<Set<String>> gridDemotions = [];

  Set<String> get removed => removals.expand((v) => v).toSet();

  Set<String> get demoted => demotions.expand((v) => v).toSet();

  Set<String> get demotedToGrid => gridDemotions.expand((v) => v).toSet();

  @override
  Future<bool> putMirroredFile(NextcloudAccount account, NextcloudRemoteItem item, String localPath, NextcloudMirrorTier tier) async {
    if (putFails.contains(item.relativePath)) return false;
    if (!await File(localPath).exists()) throw StateError('put before the file was written: $localPath');
    puts.add(item.relativePath);
    putTiers[item.relativePath] = tier;
    return true;
  }

  @override
  Future<bool> putPlaceholder(NextcloudAccount account, NextcloudRemoteItem item) async {
    if (putFails.contains(item.relativePath)) return false;
    placeholders.add(item.relativePath);
    return true;
  }

  @override
  Future<void> removeMirroredFiles(NextcloudAccount account, Set<String> relativePaths) async => removals.add(Set.of(relativePaths));

  @override
  Future<void> demoteToPlaceholders(NextcloudAccount account, Set<String> relativePaths) async => demotions.add(Set.of(relativePaths));

  @override
  Future<void> demoteToGrid(NextcloudAccount account, Set<String> relativePaths) async => gridDemotions.add(Set.of(relativePaths));
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
