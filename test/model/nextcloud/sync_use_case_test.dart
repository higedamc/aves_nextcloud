import 'dart:io';

import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/errors.dart';
import 'package:aves/model/nextcloud/mirror_store.dart';
import 'package:aves/model/nextcloud/remote_item.dart';
import 'package:aves/model/nextcloud/repository.dart';
import 'package:aves/model/nextcloud/sync.dart';
import 'package:aves/model/nextcloud/sync_ports.dart';
import 'package:aves/model/nextcloud/sync_use_case.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fake/nextcloud_sync.dart';

void main() {
  late Directory tempDir;
  late FakeNextcloudMirrorStore mirror;
  late FakeNextcloudSyncSink sink;
  late MemoryNextcloudSyncStateStore states;
  late FakeNextcloudCredentialStore credentials;
  var clock = DateTime.utc(2026, 10, 9, 12);

  NextcloudAccount accountWith({int cacheLimitBytes = 1000, String id = 'acc1', int videoAutoDownloadLimitBytes = NextcloudAccount.defaultVideoAutoDownloadLimitBytes}) => NextcloudAccount(
    id: id,
    serverUrl: Uri.parse('https://cloud.example.com'),
    username: 'alice',
    rootFolder: 'Photos',
    cacheLimitBytes: cacheLimitBytes,
    videoAutoDownloadLimitBytes: videoAutoDownloadLimitBytes,
  );

  final day1 = DateTime.utc(2026, 10, 1);
  final day2 = DateTime.utc(2026, 10, 2);
  final day3 = DateTime.utc(2026, 10, 3);

  // Photos/{a.jpg (day1), Sub/{b.mp4 (day2), Deep/{c.jpg (day3)}}}
  FakeNextcloudRepository serverWith({Map<String, String>? collections, List<NextcloudRemoteItem>? files, Map<String, NextcloudFailure> failing = const {}, bool supportsSearch = false}) => FakeNextcloudRepository(
    accountWith(),
    collections: collections ?? {'': 'root-v1', 'Sub': 'sub-v1', 'Sub/Deep': 'deep-v1'},
    files: files ?? [fakeFile('a.jpg', modified: day1, fileId: 1), fakeFile('Sub/b.mp4', modified: day2, fileId: 2), fakeFile('Sub/Deep/c.jpg', modified: day3, fileId: 3)],
    failing: failing,
    supportsSearch: supportsSearch,
  );

  NextcloudSyncUseCaseImpl useCaseWith(FakeNextcloudRepository repository) => NextcloudSyncUseCaseImpl(
    repositories: FakeNextcloudRepositoryFactory(repository),
    credentials: credentials,
    mirror: mirror,
    sink: sink,
    states: states,
    now: () => clock,
  );

  Future<NextcloudSyncResult> sync(NextcloudSyncUseCaseImpl useCase, {NextcloudAccount? account, bool force = false, NextcloudCancellation? cancellation, List<NextcloudSyncProgress>? progress}) async {
    final events = await useCase.run(NextcloudSyncRequest(account: account ?? accountWith(), force: force, cancellation: cancellation)).toList();
    progress?.addAll(events);
    return useCase.lastResult;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('aves_nextcloud_sync');
    mirror = FakeNextcloudMirrorStore(tempDir.path);
    sink = FakeNextcloudSyncSink();
    states = MemoryNextcloudSyncStateStore();
    credentials = FakeNextcloudCredentialStore();
    await credentials.writeAppPassword(accountWith(), 'app-pass');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('first run', () {
    test('lists the account root, downloads newest first, records, creates entries, persists etags', () async {
      final server = serverWith();
      final progress = <NextcloudSyncProgress>[];
      final result = await sync(useCaseWith(server), progress: progress);

      expect(result.isSuccess, isTrue);
      expect(result.added, 3);
      expect(server.listedRoots, ['']);
      expect(server.fetched, ['Sub/Deep/c.jpg', 'Sub/b.mp4', 'a.jpg']);
      // images as their grid derivative, a video below the threshold whole
      expect(server.previews, ['Sub/Deep/c.jpg@256x256', 'a.jpg@256x256']);
      expect(server.downloads, ['Sub/b.mp4']);
      expect(sink.puts, ['Sub/Deep/c.jpg', 'Sub/b.mp4', 'a.jpg']);
      expect(sink.putTiers, {'Sub/Deep/c.jpg': NextcloudMirrorTier.grid, 'Sub/b.mp4': NextcloudMirrorTier.original, 'a.jpg': NextcloudMirrorTier.grid});
      expect(mirror.rows(accountWith())['a.jpg']?.localSizeBytes, 2, reason: 'the preview bytes, not the remote size');
      expect(mirror.rows(accountWith())['a.jpg']?.remoteSizeBytes, 3);
      expect(mirror.rows(accountWith()).keys, containsAll(['a.jpg', 'Sub/b.mp4', 'Sub/Deep/c.jpg']));
      expect(await File(mirror.localPathFor(accountWith(), 'Sub/Deep/c.jpg')).exists(), isTrue);
      expect(states.states['acc1']?.collectionEtags, {'': 'root-v1', 'Sub': 'sub-v1', 'Sub/Deep': 'deep-v1'});
      expect(states.states['acc1']?.cacheLimitBytes, 1000);
      expect(progress.map((v) => v.phase), containsAllInOrder([NextcloudSyncPhase.probing, NextcloudSyncPhase.listing, NextcloudSyncPhase.downloading, NextcloudSyncPhase.evicting, NextcloudSyncPhase.done]));
      expect(progress.last.phase, NextcloudSyncPhase.done);
      expect(server.disposed, isTrue);
    });

    test('opens the repository with the stored credentials and fails fatally without them', () async {
      final server = serverWith();
      final factory = FakeNextcloudRepositoryFactory(server);
      final useCase = NextcloudSyncUseCaseImpl(repositories: factory, credentials: credentials, mirror: mirror, sink: sink, states: states);
      await sync(useCase);
      expect(factory.opened.single.appPassword, 'app-pass');

      await credentials.writeAppPassword(accountWith(), null);
      final result = await sync(useCase);
      expect(result.fatal, isA<NextcloudAuthFailure>());
      expect(server.probeCount, 1, reason: 'no request without credentials');
    });
  });

  group('second run', () {
    test('an unchanged root skips everything and keeps the etags', () async {
      final server = serverWith();
      final useCase = useCaseWith(server);
      await sync(useCase);
      sink.puts.clear();

      final result = await sync(useCase);
      expect(result.added + result.updated + result.removed + result.evicted, 0);
      expect(server.knownEtagsReceived.last, {'': 'root-v1', 'Sub': 'sub-v1', 'Sub/Deep': 'deep-v1'});
      expect(server.fetched.length, 3, reason: 'nothing fetched again');
      expect(sink.puts, isEmpty);
      expect(sink.removed, isEmpty);
      expect(states.states['acc1']?.collectionEtags, {'': 'root-v1', 'Sub': 'sub-v1', 'Sub/Deep': 'deep-v1'});
    });

    test('a changed file is re-downloaded and keeps its LRU position', () async {
      final server = serverWith();
      final useCase = useCaseWith(server);
      await sync(useCase);
      final before = mirror.rows(accountWith())['a.jpg']!;

      clock = clock.add(const Duration(days: 1));
      server.collections[''] = 'root-v2';
      server.files['a.jpg'] = fakeFile('a.jpg', etag: 'a-v2', modified: day1, fileId: 1);
      final result = await sync(useCase);

      expect(result.updated, 1);
      expect(result.skipped, 0, reason: 'Sub was skipped by etag, so its files were not emitted at all');
      final after = mirror.rows(accountWith())['a.jpg']!;
      expect(after.etag, 'a-v2');
      expect(after.lastAccessAt, before.lastAccessAt);
      expect(after.downloadedAt, clock);
      expect(states.states['acc1']?.collectionEtags[''], 'root-v2');
    });

    test('a file removed on the server is removed from the mirror and the collection', () async {
      final server = serverWith();
      final useCase = useCaseWith(server);
      await sync(useCase);

      server.collections[''] = 'root-v2';
      server.files.remove('a.jpg');
      final result = await sync(useCase);

      expect(result.removed, 1);
      expect(mirror.rows(accountWith()).containsKey('a.jpg'), isFalse);
      expect(await File(mirror.localPathFor(accountWith(), 'a.jpg')).exists(), isFalse);
      expect(sink.removed, {'a.jpg'});
      // Sub was skipped as unchanged: its files are untouched
      expect(mirror.rows(accountWith()).keys, containsAll(['Sub/b.mp4', 'Sub/Deep/c.jpg']));
    });

    test('force re-downloads everything and ignores the known etags', () async {
      final server = serverWith();
      final useCase = useCaseWith(server);
      await sync(useCase);

      final result = await sync(useCase, force: true);
      expect(server.knownEtagsReceived.last, isEmpty);
      expect(result.updated, 3);
      expect(result.skipped, 0);
    });

    test('a raised cache limit lists everything again so evicted files can come back', () async {
      final server = serverWith();
      final useCase = useCaseWith(server);
      await sync(useCase);

      await sync(useCase, account: accountWith(cacheLimitBytes: 2000));
      expect(server.knownEtagsReceived.last, isEmpty);
      expect(states.states['acc1']?.cacheLimitBytes, 2000);

      await sync(useCase, account: accountWith(cacheLimitBytes: 2000));
      expect(server.knownEtagsReceived.last, isNotEmpty, reason: 'same limit: etags apply again');
    });
  });

  group('item failures', () {
    test('a reported sub-folder is not enumerated: nothing under it is removed, and its etags are not promised', () async {
      final server = serverWith();
      final useCase = useCaseWith(server);
      await sync(useCase);

      server.collections[''] = 'root-v2';
      server.collections['Sub'] = 'sub-v2';
      server.files.remove('Sub/b.mp4');
      server.failing['Sub'] = const NextcloudServerFailure(403, 'access denied');
      final result = await sync(useCase);

      expect(result.isSuccess, isTrue);
      expect(result.itemFailures.keys, ['Sub']);
      expect(result.removed, 0);
      expect(mirror.rows(accountWith()).keys, containsAll(['a.jpg', 'Sub/b.mp4', 'Sub/Deep/c.jpg']));
      expect(sink.removed, isEmpty);
      // the old etags from a real enumeration stay; the new root etag was never published
      expect(states.states['acc1']?.collectionEtags, {'': 'root-v1', 'Sub': 'sub-v1', 'Sub/Deep': 'deep-v1'});
    });

    test('a file that fails to download is reported and the rest continues', () async {
      final server = serverWith()..downloadFailures['Sub/b.mp4'] = const NextcloudNotFoundFailure('Sub/b.mp4');
      final result = await sync(useCaseWith(server));
      expect(result.added, 2);
      expect(result.itemFailures.keys, ['Sub/b.mp4']);
      expect(result.itemFailures['Sub/b.mp4'], isA<NextcloudNotFoundFailure>());
      expect(mirror.rows(accountWith()).containsKey('Sub/b.mp4'), isFalse);
      expect(states.states['acc1']?.collectionEtags, isEmpty, reason: 'the listing was complete, the mirror was not');
    });

    test('a file the sink cannot turn into an entry is dropped from the mirror so it is retried next time', () async {
      final server = serverWith();
      sink.putFails.add('a.jpg');
      final result = await sync(useCaseWith(server));
      expect(result.itemFailures.keys, ['a.jpg']);
      expect(mirror.rows(accountWith()).containsKey('a.jpg'), isFalse);
      expect(await File(mirror.localPathFor(accountWith(), 'a.jpg')).exists(), isFalse);
      // no etag is promised, so the next run lists again; the bytes still had to go, or that listing would
      // find a current row with a file and skip the entry-less file forever
      expect(result.added, 2);
      expect(states.states['acc1']?.collectionEtags, isEmpty);
    });

    test('a network failure during download is fatal and persists no etags', () async {
      // an image is fetched as a preview, so the failure sits on that endpoint
      final server = serverWith()..previewFailures['Sub/Deep/c.jpg'] = const NextcloudNetworkFailure('reset');
      final progress = <NextcloudSyncProgress>[];
      final result = await sync(useCaseWith(server), progress: progress);
      expect(result.fatal, isA<NextcloudNetworkFailure>());
      expect(progress.last.phase, NextcloudSyncPhase.failed);
      expect(states.saves, 0);
      expect(server.disposed, isTrue);
    });
  });

  group('filesystem is the truth', () {
    test('a row whose file is missing is re-downloaded when emitted', () async {
      final server = serverWith();
      final useCase = useCaseWith(server);
      await sync(useCase);
      await File(mirror.localPathFor(accountWith(), 'a.jpg')).delete();

      final result = await sync(useCase, force: true);
      expect(server.fetched.where((v) => v == 'a.jpg').length, 2);
      expect(await File(mirror.localPathFor(accountWith(), 'a.jpg')).exists(), isTrue);
      expect(result.isSuccess, isTrue);
    });

    test('a row whose file is missing and that the listing cannot refill is dropped with its entry', () async {
      final server = serverWith();
      final useCase = useCaseWith(server);
      await sync(useCase);
      await File(mirror.localPathFor(accountWith(), 'Sub/b.mp4')).delete();

      // unchanged root: nothing is emitted, so the row is a lie that cannot be fixed now
      final result = await sync(useCase);
      expect(mirror.rows(accountWith()).containsKey('Sub/b.mp4'), isFalse);
      expect(sink.removed, {'Sub/b.mp4'});
      expect(result.lost, 1);
      expect(result.evicted, 0);
      expect(result.removed, 0);
      // the loss sits under `Sub`, skipped on an etag the server will never bump for it: forget the map
      expect(states.states['acc1']?.collectionEtags, isEmpty);

      // so the following run lists everything and refills the file, with the server still unchanged
      final refill = await sync(useCase);
      expect(server.downloads.where((v) => v == 'Sub/b.mp4').length, 2);
      expect(await File(mirror.localPathFor(accountWith(), 'Sub/b.mp4')).exists(), isTrue);
      expect(refill.added, 1);
      expect(states.states['acc1']?.collectionEtags, {'': 'root-v1', 'Sub': 'sub-v1', 'Sub/Deep': 'deep-v1'});
    });

    test('part files left by a dead download are swept before listing', () async {
      final server = serverWith();
      final part = File('${mirror.localPathFor(accountWith(), 'Sub/zombie.jpg')}.part');
      await part.create(recursive: true);
      await sync(useCaseWith(server));
      expect(await part.exists(), isFalse);
    });
  });

  group('budget', () {
    test('downloads newest first until the budget is full, then counts the rest as skipped without thrashing', () async {
      final server = serverWith();
      final result = await sync(useCaseWith(server), account: accountWith(cacheLimitBytes: 6));
      expect(server.fetched, ['Sub/Deep/c.jpg', 'Sub/b.mp4']);
      expect(result.added, 2);
      expect(result.skipped, 1);
      expect(result.evicted, 0);
      expect(mirror.rows(accountWith()).keys, {'Sub/Deep/c.jpg', 'Sub/b.mp4'});
      expect(states.states['acc1']?.collectionEtags, isEmpty, reason: 'a listed file was not mirrored, so no subtree is promised');
    });

    test('after a run cut short by the budget, the next run enumerates the whole scope again even though nothing changed', () async {
      // SEARCH mode: the only etag the listing can earn is the root's, which would skip the entire tree
      final server = serverWith(supportsSearch: true);
      final useCase = useCaseWith(server);
      final first = await sync(useCase, account: accountWith(cacheLimitBytes: 6));
      expect(first.added, 2);
      expect(first.skipped, 1);

      final second = await sync(useCase, account: accountWith(cacheLimitBytes: 6));
      expect(server.enumerations, 2, reason: 'the root etag must not have been published by the truncated run');
      expect(server.knownEtagsReceived.last, isEmpty);
      // the file left over is fetched by evicting one of the previous run's (the budget starts empty each
      // run), which is an eviction: the map stays empty either way
      expect(second.added + second.evicted, greaterThan(0));
      expect(states.states['acc1']?.collectionEtags, isEmpty);
    });

    test('evicts older files from previous runs to make room, dropping their entries in the same step', () async {
      final server = serverWith(files: [fakeFile('old.jpg', modified: day1, fileId: 1)]);
      final useCase = useCaseWith(server);
      await sync(useCase, account: accountWith(cacheLimitBytes: 6));

      clock = clock.add(const Duration(days: 1));
      server.collections[''] = 'root-v2';
      server.files['new1.jpg'] = fakeFile('new1.jpg', modified: day2, fileId: 2);
      server.files['new2.jpg'] = fakeFile('new2.jpg', modified: day3, fileId: 3);
      final result = await sync(useCase, account: accountWith(cacheLimitBytes: 6));

      expect(server.fetched.sublist(1), ['new2.jpg', 'new1.jpg']);
      expect(result.evicted, 1);
      expect(sink.removed, {'old.jpg'});
      expect(mirror.rows(accountWith()).keys, {'new1.jpg', 'new2.jpg'});
      // an eviction is a local removal no server etag can see: the whole map goes, not only this run's etags
      expect(states.states['acc1']?.collectionEtags, isEmpty);
    });

    test('a file larger than the whole budget is a quota failure and does not empty the mirror', () async {
      final server = serverWith(
        files: [
          fakeFile('small.jpg', modified: day1, fileId: 1),
          fakeFile('huge.mp4', size: 50, modified: day2, fileId: 2),
        ],
      );
      final result = await sync(useCaseWith(server), account: accountWith(cacheLimitBytes: 10));
      expect(result.itemFailures['huge.mp4'], isA<NextcloudQuotaFailure>());
      expect(result.added, 1);
      expect(mirror.rows(accountWith()).keys, {'small.jpg'});
      expect(mirror.evictCalls, isNot(contains('acc1:50')));
    });
  });

  group('search mode', () {
    test('diffs against the full snapshot: a vanished file is removed, a reported one is not', () async {
      final server = serverWith(supportsSearch: true);
      final useCase = useCaseWith(server);
      await sync(useCase);
      expect(states.states['acc1']?.collectionEtags, {'': 'root-v1'}, reason: 'one query covered the scope, so the root alone is earned');

      server.collections[''] = 'root-v2';
      server.files.remove('a.jpg');
      server.failing['Sub/b.mp4'] = const NextcloudParseFailure('no successful propstat');
      final result = await sync(useCase);
      expect(result.removed, 1);
      expect(sink.removed, {'a.jpg'});
      expect(mirror.rows(accountWith()).keys, {'Sub/b.mp4', 'Sub/Deep/c.jpg'});
      expect(result.itemFailures.keys, ['Sub/b.mp4']);
      expect(states.states['acc1']?.collectionEtags, {'': 'root-v1'}, reason: 'an incomplete search promises nothing new');
    });

    test('an unchanged root is not searched again', () async {
      final server = serverWith(supportsSearch: true);
      final useCase = useCaseWith(server);
      await sync(useCase);

      final result = await sync(useCase);
      expect(server.enumerations, 1);
      expect(result.added + result.updated + result.removed + result.lost, 0);
      expect(mirror.rows(accountWith()).keys, containsAll(['a.jpg', 'Sub/b.mp4', 'Sub/Deep/c.jpg']));
      expect(states.states['acc1']?.collectionEtags, {'': 'root-v1'});
    });
  });

  group('runs', () {
    test('two runs for the same account are serialized, runs for different accounts are not blocked', () async {
      final server = serverWith();
      final useCase = useCaseWith(server);
      final first = useCase.run(NextcloudSyncRequest(account: accountWith())).toList();
      final second = useCase.run(NextcloudSyncRequest(account: accountWith())).toList();
      await Future.wait([first, second]);
      expect(server.probeCount, 2);
      // the second run saw the first run's state: unchanged root, nothing downloaded again
      expect(server.fetched.length, 3);
      expect(server.knownEtagsReceived.last, isNotEmpty);
    });

    test('cancellation is fatal and persists nothing', () async {
      final server = serverWith();
      final cancellation = NextcloudCancellation()..cancel();
      final result = await sync(useCaseWith(server), cancellation: cancellation);
      expect(result.fatal, isA<NextcloudCancelledFailure>());
      expect(states.saves, 0);
    });

    test('never throws a NextcloudFailure out of the stream', () async {
      final server = serverWith()..probeFailure = const NextcloudTlsFailure('bad cert');
      final events = await useCaseWith(server).run(NextcloudSyncRequest(account: accountWith())).toList();
      expect(events.last.phase, NextcloudSyncPhase.failed);
    });
  });

  group('grid tier', () {
    test('an image the server cannot render gets a placeholder row, not a failure, and the subtree is still promised', () async {
      // HEIC and HEIF under Nextcloud's default preview providers answer 404 while remaining listed
      final server = serverWith()..previewFailures['a.jpg'] = const NextcloudPreviewUnavailableFailure('a.jpg');
      final result = await sync(useCaseWith(server));

      expect(result.added, 3);
      expect(result.itemFailures, isEmpty);
      expect(sink.placeholders, ['a.jpg']);
      expect(server.downloads, ['Sub/b.mp4'], reason: 'no fallback to the original here; that is a later call');
      expect(mirror.rows(accountWith())['a.jpg']?.tier, NextcloudMirrorTier.placeholder);
      expect(states.states['acc1']?.collectionEtags, containsPair('', 'root-v1'));

      // and it is current until the file changes: not re-asked every run
      server.collections[''] = 'root-v2';
      final again = await sync(useCaseWith(server));
      expect(again.skipped, 1);
      expect(sink.placeholders.length, 1);
    });

    test('the budget reserves a ceiling for a derivative and accounts the bytes that landed', () async {
      // a 10 MB original whose preview is 2 bytes must fit a 128 KB budget (the grid ceiling is 64 KB):
      // the remote size has no bearing on a derivative
      final server = serverWith(
        files: [fakeFile('big.jpg', size: 10 * 1024 * 1024, modified: day1, fileId: 1)],
      );
      final result = await sync(useCaseWith(server), account: accountWith(cacheLimitBytes: 128 * 1024));

      expect(result.itemFailures, isEmpty);
      expect(server.previewPaths, ['big.jpg']);
      final row = mirror.rows(accountWith())['big.jpg']!;
      expect(row.tier, NextcloudMirrorTier.grid);
      expect(row.localSizeBytes, 2);
      expect(row.remoteSizeBytes, 10 * 1024 * 1024);
      expect(await mirror.usedBytes(accountWith()), 2);
      expect(states.states['acc1']?.collectionEtags, isNotEmpty);
    });

    test('a derivative is written through a part file and carries the server date', () async {
      final server = serverWith();
      await sync(useCaseWith(server));
      final path = mirror.localPathFor(accountWith(), 'a.jpg');
      expect(await File(path).exists(), isTrue);
      expect(await File('$path.part').exists(), isFalse);
      // a preview carries no Exif, so the file date is the only date the entry has until the catalogue learns it
      expect((await File(path).lastModified()).toUtc().millisecondsSinceEpoch ~/ 1000, day1.millisecondsSinceEpoch ~/ 1000);
    });

    test('an image already held as an original is not downgraded, not even by a forced run', () async {
      // a row written before tiers existed: the file is whole and the row says so
      final server = serverWith();
      final path = mirror.localPathFor(accountWith(), 'a.jpg');
      await File(path).parent.create(recursive: true);
      await File(path).writeAsBytes([1, 2, 3]);
      await mirror.record(
        accountWith(),
        NextcloudMirrorIndexEntry(relativePath: 'a.jpg', etag: 'v1', fileId: 1, tier: NextcloudMirrorTier.original, remoteSizeBytes: 3, localSizeBytes: 3, remoteLastModified: day1, downloadedAt: day1, lastAccessAt: day1),
      );
      final useCase = useCaseWith(server);

      await sync(useCase);
      expect(server.fetched, isNot(contains('a.jpg')), reason: 'an original satisfies the grid tier');
      expect(mirror.rows(accountWith())['a.jpg']?.tier, NextcloudMirrorTier.original);

      // forcing re-fetches what is held, not what is wanted
      await sync(useCase, force: true);
      expect(server.downloads, containsAll(['a.jpg']));
      expect(server.previewPaths, isNot(contains('a.jpg')));
      final row = mirror.rows(accountWith())['a.jpg']!;
      expect(row.tier, NextcloudMirrorTier.original);
      expect(row.localSizeBytes, 3);
    });
  });

  group('video threshold and placeholders', () {
    // `Sub/b.mp4` is 3 bytes; a threshold of 2 puts it above, the default puts it below
    const above = 2;

    test('a video above the threshold gets a placeholder row, no download, and the subtree is still promised', () async {
      final server = serverWith();
      final account = accountWith(videoAutoDownloadLimitBytes: above);
      final result = await sync(useCaseWith(server), account: account);

      expect(server.fetched, ['Sub/Deep/c.jpg', 'a.jpg'], reason: 'the video is not fetched');
      expect(sink.placeholders, ['Sub/b.mp4']);
      final row = mirror.rows(account)['Sub/b.mp4']!;
      expect(row.tier, NextcloudMirrorTier.placeholder);
      expect(row.localSizeBytes, 0);
      expect(row.remoteSizeBytes, 3);
      expect(await File(mirror.localPathFor(account, 'Sub/b.mp4')).exists(), isFalse);
      expect(result.added, 3);
      // the completeness rule admits a placeholder, so the etags are earned despite the missing file
      expect(states.states['acc1']?.collectionEtags, containsPair('', 'root-v1'));
    });

    test('a placeholder row is current on the next run and is not dropped as lost', () async {
      final server = serverWith();
      final useCase = useCaseWith(server);
      final account = accountWith(videoAutoDownloadLimitBytes: above);
      await sync(useCase, account: account);

      // re-enumerate the video's folder (`Deep` stays trusted) so the currency check actually runs on it
      server.collections[''] = 'root-v2';
      server.collections['Sub'] = 'sub-v2';
      final second = await sync(useCase, account: account);
      expect(second.lost, 0, reason: 'a row with no file is a cache miss, except a placeholder');
      expect(second.skipped, 2, reason: 'a.jpg and the placeholder video are both current');
      expect(sink.placeholders.length, 1, reason: 'not put again');
      expect(server.fetched.length, 2);
      expect(mirror.rows(account)['Sub/b.mp4']?.tier, NextcloudMirrorTier.placeholder);
    });

    test('a video already held as an original is not downgraded when the threshold drops below it', () async {
      final server = serverWith();
      final useCase = useCaseWith(server);
      await sync(useCase, account: accountWith());
      expect(mirror.rows(accountWith())['Sub/b.mp4']?.tier, NextcloudMirrorTier.original);

      // every row migrated from v1 is exactly this shape: original, not pinned, possibly above the threshold
      server.collections[''] = 'root-v2';
      server.collections['Sub'] = 'sub-v2';
      final lowered = await sync(useCase, account: accountWith(videoAutoDownloadLimitBytes: above));
      expect(sink.placeholders, isEmpty);
      expect(lowered.skipped, 2, reason: 'an original answers for a placeholder, so the video is current');
      expect(server.fetched.length, 3, reason: 'nothing re-fetched');
      final row = mirror.rows(accountWith())['Sub/b.mp4']!;
      expect(row.tier, NextcloudMirrorTier.original);
      expect(row.localSizeBytes, 3);
    });

    test('raising the threshold lists everything again and promotes the placeholder to an original', () async {
      final server = serverWith();
      final useCase = useCaseWith(server);
      await sync(useCase, account: accountWith(videoAutoDownloadLimitBytes: above));
      expect(states.states['acc1']?.collectionEtags, isNotEmpty);
      expect(server.enumerations, 1);

      // the promised subtrees would skip the video forever: a raised threshold has to relist, like a raised
      // cache limit does
      final raised = await sync(useCase, account: accountWith());
      expect(server.enumerations, 2, reason: 'the stored etags must not be trusted after the threshold rose');
      expect(server.downloads, contains('Sub/b.mp4'));
      expect(raised.updated, 1);
      final row = mirror.rows(accountWith())['Sub/b.mp4']!;
      expect(row.tier, NextcloudMirrorTier.original);
      expect(row.localSizeBytes, 3);
    });

    test('a placeholder the sink refuses leaves no row and withholds the etags', () async {
      sink.putFails.add('Sub/b.mp4');
      final server = serverWith();
      final account = accountWith(videoAutoDownloadLimitBytes: above);
      final result = await sync(useCaseWith(server), account: account);

      expect(mirror.rows(account).containsKey('Sub/b.mp4'), isFalse, reason: 'a row with no entry would be skipped by etag forever');
      expect(result.itemFailures.keys, ['Sub/b.mp4']);
      // a local condition, not an untrusted server document
      expect(result.itemFailures['Sub/b.mp4'], isA<NextcloudLocalStorageFailure>());
      expect(states.states['acc1']?.collectionEtags, isEmpty);
    });

    test('a placeholder sorted behind the budget break still gets its row', () async {
      // newest first: c.jpg (4 B) fills the 5 B budget, so the byte loop breaks at a.jpg (4 B), and the
      // video (3 B, above the threshold) is the oldest item, sorted behind the break. A placeholder costs
      // no bytes, so the budget has no bearing on it: it must not end the run with no row, no entry and no
      // failure, counted as skipped.
      final server = serverWith(
        files: [
          fakeFile('c.jpg', size: 4, modified: day3, fileId: 1),
          fakeFile('a.jpg', size: 4, modified: day2, fileId: 2),
          fakeFile('v.mp4', size: 3, modified: day1, fileId: 3),
        ],
      );
      final account = accountWith(cacheLimitBytes: 5, videoAutoDownloadLimitBytes: above);
      final result = await sync(useCaseWith(server), account: account);

      expect(sink.placeholders, ['v.mp4'], reason: 'the video behind the break is listed, so it must appear');
      expect(server.fetched, ['c.jpg']);
      expect(mirror.rows(account).keys, {'c.jpg', 'v.mp4'});
      expect(result.added, 2);
      expect(result.skipped, 1, reason: 'only the byte-wanted remainder is skipped by the budget');
      expect(result.itemFailures, isEmpty);
      expect(states.states['acc1']?.collectionEtags, isEmpty, reason: 'a.jpg was not mirrored');
    });

    test('a promotion the budget cannot fund keeps the placeholder and withholds the subtree', () async {
      final server = serverWith(files: [fakeFile('Sub/b.mp4', size: 5, modified: day2, fileId: 2)]);
      final useCase = useCaseWith(server);
      await sync(useCase, account: accountWith(cacheLimitBytes: 4, videoAutoDownloadLimitBytes: above));
      expect(states.states['acc1']?.collectionEtags, isNotEmpty);

      final raised = await sync(useCase, account: accountWith(cacheLimitBytes: 4, videoAutoDownloadLimitBytes: 10));
      expect(raised.itemFailures['Sub/b.mp4'], isA<NextcloudQuotaFailure>());
      expect(mirror.rows(accountWith())['Sub/b.mp4']?.tier, NextcloudMirrorTier.placeholder, reason: 'a failed promotion keeps what was there');
      // the row is below the tier this run wanted, so the subtree is a gap and must not be promised
      expect(states.states['acc1']?.collectionEtags, isEmpty);
    });
  });

  group('FileNextcloudSyncStateStore', () {
    test('round trips, survives a corrupt file, and clears', () async {
      final store = FileNextcloudSyncStateStore(tempDir.path);
      final account = accountWith();
      expect((await store.load(account)).collectionEtags, isEmpty);

      await store.save(account, const NextcloudSyncState(collectionEtags: {'': 'r1', 'Sub': 's1'}, cacheLimitBytes: 42, videoAutoDownloadLimitBytes: 7));
      final loaded = await store.load(account);
      expect(loaded.collectionEtags, {'': 'r1', 'Sub': 's1'});
      expect(loaded.cacheLimitBytes, 42);
      expect(loaded.videoAutoDownloadLimitBytes, 7);
      expect(await File('${tempDir.path}/acc1.sync.json.part').exists(), isFalse);

      // a state written before the threshold existed reads as 0, so any configured limit counts as raised
      await File('${tempDir.path}/acc1.sync.json').writeAsString('{"collectionEtags": {"": "r1"}, "cacheLimitBytes": 42}');
      expect((await store.load(account)).videoAutoDownloadLimitBytes, 0);

      // a wrong type is as recoverable as a missing key; a throwing cast would fail every later sync
      await File('${tempDir.path}/acc1.sync.json').writeAsString('{"collectionEtags": {"": "r1"}, "cacheLimitBytes": "42", "videoAutoDownloadLimitBytes": null}');
      final tolerant = await store.load(account);
      expect(tolerant.cacheLimitBytes, 0);
      expect(tolerant.videoAutoDownloadLimitBytes, 0);
      expect(tolerant.collectionEtags, {'': 'r1'});

      await File('${tempDir.path}/acc1.sync.json').writeAsString('{not json');
      expect((await store.load(account)).collectionEtags, isEmpty);

      await store.save(account, const NextcloudSyncState(collectionEtags: {'': 'r2'}));
      await store.clear(account);
      expect(await File('${tempDir.path}/acc1.sync.json').exists(), isFalse);
    });
  });
}
