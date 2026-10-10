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

  // what is actually under the account's mirror root, which is what `usedBytes` claims to report
  Future<int> bytesOnDisk(NextcloudAccount account) async {
    final dir = Directory(mirror.localPathFor(account, ''));
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) total += await entity.length();
    }
    return total;
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
      // the whole grid class before any original, newest first within each: `b.mp4` is newer than `a.jpg`
      // and still goes last, since a run of recent video must not push older thumbnails behind the budget
      expect(server.fetched, ['Sub/Deep/c.jpg', 'a.jpg', 'Sub/b.mp4']);
      // images as their grid derivative, a video below the threshold whole
      expect(server.previews, ['Sub/Deep/c.jpg@256x256', 'a.jpg@256x256']);
      expect(server.downloads, ['Sub/b.mp4']);
      expect(sink.puts, ['Sub/Deep/c.jpg', 'a.jpg', 'Sub/b.mp4']);
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
    test('funds newest first until the budget says no, and records the rest as unfunded placeholders', () async {
      final server = serverWith();
      final result = await sync(useCaseWith(server), account: accountWith(cacheLimitBytes: 6));
      // the two previews (2 bytes each, 3 reserved) fit; the 3-byte video no longer does
      expect(server.fetched, ['Sub/Deep/c.jpg', 'a.jpg']);
      expect(sink.placeholders, ['Sub/b.mp4'], reason: 'the item is listed, so it is in the gallery and streams on demand');
      final row = mirror.rows(accountWith())['Sub/b.mp4']!;
      expect(row.tier, NextcloudMirrorTier.placeholder);
      expect(row.placeholderReason, NextcloudPlaceholderReason.unfunded, reason: 'the row says what it is waiting for: the budget, not the file');
      expect(result.added, 3);
      expect(result.skipped, 0);
      expect(result.evicted, 0);
      expect(result.itemFailures, isEmpty, reason: 'the budget saying no is an outcome, not a failure');
      // the mirror reflects the server honestly, placeholder included, so every subtree is promised
      expect(states.states['acc1']?.collectionEtags, {'': 'root-v1', 'Sub': 'sub-v1', 'Sub/Deep': 'deep-v1'});
    });

    test('a run the budget cut short converges: the next run lists nothing, fetches nothing and evicts nothing', () async {
      // SEARCH mode: the only etag the listing can earn is the root's, which skips the entire tree
      final server = serverWith(supportsSearch: true);
      final useCase = useCaseWith(server);
      final first = await sync(useCase, account: accountWith(cacheLimitBytes: 6));
      expect(first.added, 3);
      expect(server.enumerations, 1);

      final second = await sync(useCase, account: accountWith(cacheLimitBytes: 6));
      expect(server.enumerations, 1, reason: 'the root etag was published, so the unchanged root is not walked again');
      expect(server.knownEtagsReceived.last, containsPair('', 'root-v1'));
      expect(server.fetched.length, 2, reason: 'nothing re-fetched');
      expect(second.added + second.updated + second.evicted + second.demoted, 0);
      expect(mirror.rows(accountWith())['Sub/b.mp4']?.placeholderReason, NextcloudPlaceholderReason.unfunded, reason: 'and the row is as it was');
    });

    test('demotes older files from previous runs to make room, keeping their entries and the etags', () async {
      final server = serverWith(files: [fakeFile('old.jpg', modified: day1, fileId: 1)]);
      final useCase = useCaseWith(server);
      await sync(useCase, account: accountWith(cacheLimitBytes: 6));

      clock = clock.add(const Duration(days: 1));
      server.collections[''] = 'root-v2';
      server.files['new1.jpg'] = fakeFile('new1.jpg', modified: day2, fileId: 2);
      server.files['new2.jpg'] = fakeFile('new2.jpg', modified: day3, fileId: 3);
      final result = await sync(useCase, account: accountWith(cacheLimitBytes: 6));

      expect(server.fetched.sublist(1), ['new2.jpg', 'new1.jpg']);
      expect(result.demoted, 1);
      expect(result.evicted, 0, reason: 'the row did not leave the mirror');
      expect(sink.demoted, {'old.jpg'});
      expect(sink.removed, isEmpty, reason: 'the entry stays: the photo is still in the gallery');
      expect(mirror.rows(accountWith()).keys, {'old.jpg', 'new1.jpg', 'new2.jpg'});
      final old = mirror.rows(accountWith())['old.jpg']!;
      expect(old.tier, NextcloudMirrorTier.placeholder);
      expect(old.placeholderReason, NextcloudPlaceholderReason.unfunded);
      expect(await File(mirror.localPathFor(accountWith(), 'old.jpg')).exists(), isFalse);
      // a demotion is not a removal: nothing under any promised subtree is a lie, so the etags survive
      expect(states.states['acc1']?.collectionEtags, containsPair('', 'root-v2'));
    });

    test('a file larger than the whole budget is an unfunded placeholder and does not empty the mirror', () async {
      final server = serverWith(
        files: [
          fakeFile('small.jpg', modified: day1, fileId: 1),
          fakeFile('huge.mp4', size: 50, modified: day2, fileId: 2),
        ],
      );
      final result = await sync(useCaseWith(server), account: accountWith(cacheLimitBytes: 10));
      expect(result.itemFailures, isEmpty, reason: 'a file the budget can never hold is still a listed file');
      expect(sink.placeholders, ['huge.mp4']);
      expect(mirror.rows(accountWith())['huge.mp4']?.placeholderReason, NextcloudPlaceholderReason.unfunded);
      expect(result.added, 2);
      expect(mirror.rows(accountWith())['small.jpg']?.tier, NextcloudMirrorTier.grid);
      expect(mirror.evictCalls, isNot(contains('acc1:50')));
      expect(states.states['acc1']?.collectionEtags, isNotEmpty);
    });

    test('a raised cache limit lists everything again and funds what the old one could not', () async {
      final server = serverWith();
      final useCase = useCaseWith(server);
      await sync(useCase, account: accountWith(cacheLimitBytes: 6));
      expect(mirror.rows(accountWith())['Sub/b.mp4']?.placeholderReason, NextcloudPlaceholderReason.unfunded);
      expect(states.states['acc1']?.collectionEtags, isNotEmpty);

      final raised = await sync(useCase, account: accountWith(cacheLimitBytes: 1000));
      expect(server.enumerations, 2, reason: 'the stored etags must not be trusted after the limit rose');
      expect(server.downloads, ['Sub/b.mp4'], reason: 'an unfunded placeholder is a gap on a relist');
      expect(raised.updated, 1);
      final row = mirror.rows(accountWith())['Sub/b.mp4']!;
      expect(row.tier, NextcloudMirrorTier.original);
      expect(row.localSizeBytes, 3);
    });

    test('a relist that the budget still cannot fund leaves the row as it was, counted as nothing', () async {
      // 3-byte previews: two fill the budget exactly, and the 3-byte video is unfunded
      final server = serverWith()..previewBytes = 3;
      final useCase = useCaseWith(server);
      await sync(useCase, account: accountWith(cacheLimitBytes: 6));
      expect(mirror.rows(accountWith())['Sub/b.mp4']?.placeholderReason, NextcloudPlaceholderReason.unfunded);

      // one byte more: enough to relist, not enough to hold the video
      final raised = await sync(useCase, account: accountWith(cacheLimitBytes: 7));
      expect(server.enumerations, 2);
      expect(server.downloads, isEmpty);
      expect(raised.added + raised.updated, 0, reason: 'writing the same row again is not an update');
      expect(sink.placeholders, ['Sub/b.mp4', 'Sub/b.mp4'], reason: 'the entry is put again, which is harmless');
      expect(mirror.rows(accountWith())['Sub/b.mp4']?.placeholderReason, NextcloudPlaceholderReason.unfunded);
      expect(states.states['acc1']?.collectionEtags, isNotEmpty);
    });

    test('a policy placeholder is not a gap on a relist: the budget is not what it is waiting for', () async {
      // HEIC under the default providers: 404, and asked again only when the file changes
      final server = serverWith()..previewFailures['a.jpg'] = const NextcloudPreviewUnavailableFailure('a.jpg');
      final useCase = useCaseWith(server);
      await sync(useCase, account: accountWith(cacheLimitBytes: 6));
      expect(mirror.rows(accountWith())['a.jpg']?.placeholderReason, NextcloudPlaceholderReason.policy);

      final raised = await sync(useCase, account: accountWith(cacheLimitBytes: 1000));
      expect(server.enumerations, 2, reason: 'relisted');
      expect(sink.placeholders, ['a.jpg'], reason: 'not put again: the row was current');
      expect(raised.skipped, 3);
    });

    test('the sync evicts by server date, not by what was viewed: a treadmill cannot start from the access order', () async {
      final server = serverWith(
        files: [
          fakeFile('old.mp4', modified: day1, fileId: 1),
          fakeFile('mid.mp4', modified: day2, fileId: 2),
        ],
      );
      final useCase = useCaseWith(server);
      final account = accountWith(cacheLimitBytes: 6);
      await sync(useCase, account: account);
      // the oldest file is the one viewed last; under the access order `mid.mp4` would go first
      await mirror.touch(account, 'old.mp4', clock.add(const Duration(days: 10)));

      server.collections[''] = 'root-v2';
      server.files['new.mp4'] = fakeFile('new.mp4', modified: day3, fileId: 3);
      final result = await sync(useCase, account: account);
      expect(result.demoted, 1);
      expect(sink.demoted, {'old.mp4'});
      expect(mirror.rows(account)['mid.mp4']?.tier, NextcloudMirrorTier.original);
    });

    test('the whole grid class is funded before any original, so recent video cannot cost older photos their thumbnails', () async {
      // three 3-byte videos, newer than three images; a budget of 9 holds the three previews (2 bytes each)
      // and then exactly one video. With one newest-first list the videos would take it all.
      final server = serverWith(
        files: [
          fakeFile('v1.mp4', modified: day3, fileId: 1),
          fakeFile('v2.mp4', modified: day3.add(const Duration(hours: 1)), fileId: 2),
          fakeFile('v3.mp4', modified: day3.add(const Duration(hours: 2)), fileId: 3),
          fakeFile('a.jpg', modified: day1, fileId: 4),
          fakeFile('b.jpg', modified: day1.add(const Duration(hours: 1)), fileId: 5),
          fakeFile('c.jpg', modified: day2, fileId: 6),
        ],
      );
      final result = await sync(useCaseWith(server), account: accountWith(cacheLimitBytes: 9));
      expect(server.previewPaths, ['c.jpg', 'b.jpg', 'a.jpg'], reason: 'every thumbnail, newest first');
      expect(server.downloads, ['v3.mp4'], reason: 'then the newest video that still fits');
      expect(sink.placeholders, ['v2.mp4', 'v1.mp4']);
      expect(result.itemFailures, isEmpty);
      expect(states.states['acc1']?.collectionEtags, isNotEmpty);
    });

    test('where the grid class alone exceeds the budget, no original is funded and the newest thumbnails win', () async {
      // the degradation Lead asked to be measured rather than assumed: thumbnails for the newest images,
      // placeholders for the rest, and whole copies of nothing
      final server = serverWith(
        files: [
          fakeFile('v.mp4', modified: day3, fileId: 1),
          fakeFile('a.jpg', modified: day1, fileId: 2),
          fakeFile('b.jpg', modified: day2, fileId: 3),
        ],
      );
      final result = await sync(useCaseWith(server), account: accountWith(cacheLimitBytes: 3));
      expect(server.previewPaths, ['b.jpg'], reason: 'one 2-byte preview fits a 3-byte budget; the next 3-byte reservation does not');
      expect(server.downloads, isEmpty);
      expect(sink.placeholders, ['a.jpg', 'v.mp4']);
      expect(mirror.rows(accountWith()).values.where((row) => row.placeholderReason == NextcloudPlaceholderReason.unfunded).length, 2);
      expect(result.itemFailures, isEmpty);
      expect(states.states['acc1']?.collectionEtags, isNotEmpty);
    });

    test('converges over nine runs with three videos against a budget that holds two, through one change and one arrival', () async {
      // Lead's probe, pinned: on `develop` @ 73c5bfa this was a perfect three-cycle with `evicted=1` on
      // every run after the first and `etags={}` throughout
      final server = serverWith(
        collections: {'': 'root-v1'},
        files: [
          fakeFile('v1.mp4', modified: day3, fileId: 1),
          fakeFile('v2.mp4', modified: day2, fileId: 2),
          fakeFile('v3.mp4', modified: day1, fileId: 3),
        ],
      );
      final useCase = useCaseWith(server);
      final account = accountWith(cacheLimitBytes: 6);
      final fetchedPerRun = <List<String>>[];
      final demotedPerRun = <int>[];
      final day4 = day3.add(const Duration(days: 1));
      for (var run = 1; run <= 9; run++) {
        if (run == 6) {
          // v3 changes on the server
          server.collections[''] = 'root-v2';
          server.files['v3.mp4'] = fakeFile('v3.mp4', etag: 'v2', modified: day1, fileId: 3);
        }
        if (run == 8) {
          // a newer video arrives
          server.collections[''] = 'root-v3';
          server.files['v4.mp4'] = fakeFile('v4.mp4', modified: day4, fileId: 4);
        }
        final before = server.fetched.length;
        final result = await sync(useCase, account: account);
        fetchedPerRun.add(server.fetched.sublist(before));
        demotedPerRun.add(result.demoted);
        expect(result.evicted, 0, reason: 'run $run: a demotion is never counted as an eviction, which is what keeps the etags');
        expect(states.states['acc1']?.collectionEtags, containsPair('', run < 6 ? 'root-v1' : (run < 8 ? 'root-v2' : 'root-v3')), reason: 'run $run: the root is promised');
        clock = clock.add(const Duration(hours: 1));
      }
      expect(fetchedPerRun[0], ['v1.mp4', 'v2.mp4']);
      expect(fetchedPerRun.sublist(1, 7), everyElement(isEmpty), reason: 'runs 2-7: nothing to fetch');
      // run 6: the changed v3 is still the oldest of the three, so the budget still ranks it last. It is
      // recorded again, unfunded, with its new etag, and nothing held is touched to make room for it: the
      // held set is a function of the server's order, not of which file changed last
      expect(demotedPerRun.sublist(0, 7), everyElement(0));
      final v3 = mirror.rows(account)['v3.mp4']!;
      expect(v3.placeholderReason, NextcloudPlaceholderReason.unfunded);
      expect(v3.etag, 'v2', reason: 'the row follows the server even while unfunded');
      // run 8: the newest file outranks the oldest held one, which gives its bytes back and stays in the
      // gallery; run 9 has nothing to do, so the demotion did not restart the cycle
      expect(fetchedPerRun[7], ['v4.mp4']);
      expect(demotedPerRun[7], 1);
      expect(sink.demoted, {'v2.mp4'});
      expect(fetchedPerRun[8], isEmpty);
      expect(demotedPerRun[8], 0);
      final held = mirror.rows(account).entries.where((e) => e.value.tier == NextcloudMirrorTier.original).map((e) => e.key).toSet();
      expect(held, {'v1.mp4', 'v4.mp4'});
      expect(mirror.rows(account)['v2.mp4']?.placeholderReason, NextcloudPlaceholderReason.unfunded);
      expect(server.enumerations, 3, reason: 'the first run, the changed root and the arrival, nothing else');
    });

    test('a changed file that is held is re-fetched over its own bytes without demoting a neighbour', () async {
      final server = serverWith(
        collections: {'': 'root-v1'},
        files: [
          fakeFile('v1.mp4', modified: day3, fileId: 1),
          fakeFile('v2.mp4', modified: day2, fileId: 2),
        ],
      );
      final useCase = useCaseWith(server);
      final account = accountWith(cacheLimitBytes: 6);
      await sync(useCase, account: account);
      expect(await mirror.usedBytes(account), 6);

      server.collections[''] = 'root-v2';
      server.files['v1.mp4'] = fakeFile('v1.mp4', etag: 'v2', modified: day3, fileId: 1);
      final result = await sync(useCase, account: account);
      expect(server.downloads, ['v1.mp4', 'v2.mp4', 'v1.mp4']);
      expect(result.updated, 1);
      // reserved in full, the 3 bytes would have had to come from `v2.mp4`; net of the bytes being
      // replaced, the budget has nothing to find
      expect(result.demoted, 0);
      expect(mirror.rows(account)['v2.mp4']?.tier, NextcloudMirrorTier.original);
      expect(await mirror.usedBytes(account), 6);
    });

    test('a changed file the budget cannot fund over its own bytes gives them back, and the sink is told', () async {
      final server = serverWith(
        collections: {'': 'root-v1'},
        files: [
          fakeFile('v1.mp4', modified: day3, fileId: 1),
          fakeFile('v2.mp4', modified: day2, fileId: 2),
          fakeFile('v3.mp4', modified: day1, fileId: 3),
        ],
      );
      final useCase = useCaseWith(server);
      final account = accountWith(cacheLimitBytes: 6);
      await sync(useCase, account: account);
      expect(await mirror.usedBytes(account), 6);
      expect(mirror.rows(account)['v3.mp4']?.placeholderReason, NextcloudPlaceholderReason.unfunded);

      // `v2` grows on the server at the same mtime: nothing older than it is held (`v3` is already an
      // unfunded placeholder), so its own pass has no candidate and the budget says no to a row with bytes
      server.collections[''] = 'root-v2';
      server.files['v2.mp4'] = fakeFile('v2.mp4', etag: 'v2', modified: day2, fileId: 2, size: 6);
      final result = await sync(useCase, account: account);

      expect(server.downloads, ['v1.mp4', 'v2.mp4'], reason: 'nothing was fetched for a file the budget cannot hold');
      final row = mirror.rows(account)['v2.mp4']!;
      expect(row.tier, NextcloudMirrorTier.placeholder);
      expect(row.placeholderReason, NextcloudPlaceholderReason.unfunded);
      expect(row.etag, 'v2', reason: 'the new etag, or the subtree would be withheld and re-listed every run');
      expect(row.localSizeBytes, 0);
      // the old bytes went back to the budget rather than staying on disk under a row that claims none
      expect(await mirror.usedBytes(account), 3);
      expect(await bytesOnDisk(account), 3, reason: 'the accounting and the disk agree');
      // the entry exists and its bytes are gone: a demotion, not a new placeholder
      expect(sink.demoted, {'v2.mp4'});
      expect(sink.placeholders, ['v3.mp4'], reason: 'run 1 asked for v3; nothing in this run asked for a placeholder');
      expect(result.demoted, 1);
      expect(result.updated, 0);
      expect(mirror.rows(account)['v1.mp4']?.tier, NextcloudMirrorTier.original);
      expect(states.states['acc1']?.collectionEtags, containsPair('', 'root-v2'), reason: 'the mirror reflects the server, so the subtree is promised');
    });

    test('a file that grows past the whole budget is refused before anything is demoted for it', () async {
      final server = serverWith(
        collections: {'': 'root-v1'},
        files: [fakeFile('v1.mp4', modified: day3, fileId: 1, size: 6)],
      );
      final useCase = useCaseWith(server);
      final account = accountWith(cacheLimitBytes: 6);
      await sync(useCase, account: account);
      expect(mirror.rows(account)['v1.mp4']?.tier, NextcloudMirrorTier.original);

      // the file grows past the budget and its mtime moves, so its own row is inside the bound of its own
      // pass and is the only candidate there is; the netted reservation (3) would have fit
      server.collections[''] = 'root-v2';
      server.files['v1.mp4'] = fakeFile('v1.mp4', etag: 'v2', modified: DateTime.utc(2026, 10, 4), fileId: 1, size: 9);
      final result = await sync(useCase, account: account);

      expect(server.downloads, ['v1.mp4'], reason: 'a body the mirror cannot hold is not downloaded only to be thrown away');
      final row = mirror.rows(account)['v1.mp4']!;
      expect(row.tier, NextcloudMirrorTier.placeholder);
      expect(row.placeholderReason, NextcloudPlaceholderReason.unfunded);
      expect(row.etag, 'v2');
      expect(await mirror.usedBytes(account), 0);
      expect(await bytesOnDisk(account), 0);
      expect(sink.demotions, [
        {'v1.mp4'},
      ], reason: 'told once, by the refusal, not again by the sweep');
      expect(result.demoted, 1);
      expect(result.itemFailures, isEmpty);
      expect(states.states['acc1']?.collectionEtags, containsPair('', 'root-v2'));
    });

    test('a pinned original the budget cannot refresh keeps its bytes and its pin, and the refusal stays loud', () async {
      final server = serverWith(
        collections: {'': 'root-v1'},
        files: [fakeFile('v1.mp4', modified: day3, fileId: 1, size: 6)],
      );
      final useCase = useCaseWith(server);
      final account = accountWith(cacheLimitBytes: 6);
      await sync(useCase, account: account);
      mirror.rows(account)['v1.mp4'] = mirror.rows(account)['v1.mp4']!.copyWith(pinned: true);

      server.collections[''] = 'root-v2';
      server.files['v1.mp4'] = fakeFile('v1.mp4', etag: 'v2', modified: DateTime.utc(2026, 10, 4), fileId: 1, size: 9);
      final result = await sync(useCase, account: account);

      // the user asked for these bytes: a change the budget cannot fund is not a reason to take them
      expect(result.itemFailures['v1.mp4'], isA<NextcloudQuotaFailure>());
      final row = mirror.rows(account)['v1.mp4']!;
      expect(row.tier, NextcloudMirrorTier.original);
      expect(row.pinned, isTrue);
      expect(row.etag, 'v1', reason: 'the row still describes the bytes it holds');
      expect(await mirror.usedBytes(account), 6);
      expect(await bytesOnDisk(account), 6);
      expect(sink.demoted, isEmpty);
      expect(server.downloads, ['v1.mp4']);
      expect(states.states['acc1']?.collectionEtags, isNot(containsPair('', 'root-v2')), reason: 'a stale pinned row is a gap the next run must see');
    });

    test('an image that changed and can no longer be rendered gives back its grid bytes', () async {
      final server = serverWith();
      final useCase = useCaseWith(server);
      await sync(useCase);
      expect(mirror.rows(accountWith())['a.jpg']?.tier, NextcloudMirrorTier.grid);
      final held = await mirror.usedBytes(accountWith());
      final gridBytes = mirror.rows(accountWith())['a.jpg']!.localSizeBytes;
      expect(gridBytes, greaterThan(0));

      // the same policy placeholder a never-rendered image gets, but written over a row with bytes
      server.collections[''] = 'root-v2';
      server.files['a.jpg'] = fakeFile('a.jpg', etag: 'v2', modified: day1, fileId: 1);
      server.previewFailures['a.jpg'] = const NextcloudPreviewUnavailableFailure('a.jpg');
      final result = await sync(useCase);

      final row = mirror.rows(accountWith())['a.jpg']!;
      expect(row.tier, NextcloudMirrorTier.placeholder);
      expect(row.placeholderReason, NextcloudPlaceholderReason.policy);
      expect(row.etag, 'v2');
      expect(await mirror.usedBytes(accountWith()), held - gridBytes);
      expect(await bytesOnDisk(accountWith()), held - gridBytes);
      expect(sink.demoted, {'a.jpg'});
      expect(sink.placeholders, isEmpty, reason: '`putPlaceholder` would read the file it no longer has and drop the entry');
      expect(result.demoted, 1);
      expect(states.states['acc1']?.collectionEtags, containsPair('', 'root-v2'));
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

  group('pinned originals', () {
    test('fetchOriginal downloads the whole file, pins it, and no later run downgrades or unpins it', () async {
      final server = serverWith();
      final useCase = useCaseWith(server);
      await sync(useCase);
      expect(mirror.rows(accountWith())['a.jpg']?.tier, NextcloudMirrorTier.grid);

      clock = clock.add(const Duration(hours: 1));
      expect(await useCase.fetchOriginal(accountWith(), 'a.jpg'), isNull);
      expect(server.downloads, ['Sub/b.mp4', 'a.jpg']);
      expect(sink.putTiers['a.jpg'], NextcloudMirrorTier.original);
      var row = mirror.rows(accountWith())['a.jpg']!;
      expect(row.tier, NextcloudMirrorTier.original);
      expect(row.pinned, isTrue);
      expect(row.localSizeBytes, 3);
      expect(row.lastAccessAt, clock, reason: 'asked for by the user: a view');

      // a re-listed, unchanged file is current at the held tier: the preview and the original are all
      // that was ever fetched for it
      server.collections[''] = 'root-v2';
      await sync(useCase);
      expect(server.fetched.where((v) => v == 'a.jpg').length, 2);

      // a forced run re-fetches it whole and keeps the pin
      await sync(useCase, force: true);
      expect(server.downloads.where((v) => v == 'a.jpg').length, 2);
      expect(server.previewPaths.where((v) => v == 'a.jpg').length, 1, reason: 'never previewed again');
      row = mirror.rows(accountWith())['a.jpg']!;
      expect(row.tier, NextcloudMirrorTier.original);
      expect(row.pinned, isTrue, reason: 'a refresh does not unpin');
    });

    test('a pinned original survives a budget squeeze that evicts everything else', () async {
      final server = serverWith(files: [fakeFile('old.jpg', modified: day1, fileId: 1)]);
      final useCase = useCaseWith(server);
      final account = accountWith(cacheLimitBytes: 6);
      await sync(useCase, account: account);
      expect(await useCase.fetchOriginal(account, 'old.jpg'), isNull);

      server.collections[''] = 'root-v2';
      server.files['new2.jpg'] = fakeFile('new2.jpg', modified: day2, fileId: 2);
      await sync(useCase, account: account);
      expect(mirror.rows(account).keys, {'old.jpg', 'new2.jpg'});

      clock = clock.add(const Duration(days: 1));
      server.collections[''] = 'root-v3';
      server.files['new1.jpg'] = fakeFile('new1.jpg', modified: day3, fileId: 3);
      final squeezed = await sync(useCase, account: account);
      expect(squeezed.demoted, 1);
      expect(sink.demoted, {'new2.jpg'}, reason: 'the unpinned row gives back its bytes, however old the pinned one is');
      expect(mirror.rows(account).keys, {'old.jpg', 'new1.jpg', 'new2.jpg'});
      expect(mirror.rows(account)['new2.jpg']?.tier, NextcloudMirrorTier.placeholder);
      expect(mirror.rows(account)['old.jpg']?.pinned, isTrue);
    });

    test('a budget full of pinned rows records what it cannot fund as unfunded, and never touches the pin', () async {
      final server = serverWith(files: [fakeFile('old.jpg', modified: day1, fileId: 1)]);
      final useCase = useCaseWith(server);
      final account = accountWith(cacheLimitBytes: 3);
      await sync(useCase, account: account);
      // the pin evicts the item's own unpinned grid row to make room for its original
      expect(await useCase.fetchOriginal(account, 'old.jpg'), isNull);
      expect(await mirror.usedBytes(account), 3);

      server.collections[''] = 'root-v2';
      server.files['new2.jpg'] = fakeFile('new2.jpg', modified: day2, fileId: 2);
      final result = await sync(useCase, account: account);
      expect(result.itemFailures, isEmpty);
      expect(sink.placeholders, ['new2.jpg']);
      expect(mirror.rows(account)['new2.jpg']?.placeholderReason, NextcloudPlaceholderReason.unfunded);
      expect(result.evicted + result.demoted, 0);
      expect(mirror.rows(account)['old.jpg']?.pinned, isTrue);
      expect(mirror.rows(account)['old.jpg']?.tier, NextcloudMirrorTier.original);

      // known limitation, written down rather than discovered: releasing the pin frees the bytes but does
      // not relist, so the unfunded row waits for a raised limit or a forced run
      expect(await useCase.releaseOriginal(account, 'old.jpg'), isNull);
      server.collections[''] = 'root-v3';
      await sync(useCase, account: account);
      expect(server.previewPaths, isNot(contains('new2.jpg')));
      await sync(useCase, account: account, force: true);
      expect(server.previewPaths, contains('new2.jpg'), reason: 'force recovers it');
    });

    test('releaseOriginal unpins, and the row is then evictable like any other', () async {
      final server = serverWith(files: [fakeFile('old.jpg', modified: day1, fileId: 1)]);
      final useCase = useCaseWith(server);
      final account = accountWith(cacheLimitBytes: 3);
      await sync(useCase, account: account);
      expect(await useCase.fetchOriginal(account, 'old.jpg'), isNull);

      expect(await useCase.releaseOriginal(account, 'old.jpg'), isNull);
      expect(mirror.rows(account)['old.jpg']?.pinned, isFalse);
      expect(mirror.rows(account)['old.jpg']?.tier, NextcloudMirrorTier.original, reason: 'the bytes stay until the budget wants them');

      server.collections[''] = 'root-v2';
      server.files['new2.jpg'] = fakeFile('new2.jpg', modified: day2, fileId: 2);
      final result = await sync(useCase, account: account);
      expect(result.demoted, 1);
      expect(sink.demoted, {'old.jpg'});
      expect(mirror.rows(account)['old.jpg']?.tier, NextcloudMirrorTier.placeholder, reason: 'demoted, not gone');
      expect(await useCase.releaseOriginal(account, 'old.jpg'), isNull, reason: 'nothing left to unpin');
    });

    test("fetchOriginal's own eviction demotes too, so a download never costs the gallery an entry", () async {
      final server = serverWith(
        files: [
          fakeFile('old.jpg', modified: day1, fileId: 1),
          fakeFile('new.jpg', modified: day2, fileId: 2),
        ],
      )..previewBodies['old.jpg'] = [0, 0, 0];
      final useCase = useCaseWith(server);
      final account = accountWith(cacheLimitBytes: 5);
      await sync(useCase, account: account);
      expect(await mirror.usedBytes(account), 5);
      // the item's own preview is the one viewed last, so the other row is the one that goes
      await mirror.touch(account, 'new.jpg', clock.add(const Duration(hours: 1)));

      // the 3-byte original replaces its own 2-byte preview and needs 1 more: the least recently accessed
      // grid row gives it back
      expect(await useCase.fetchOriginal(account, 'new.jpg'), isNull);
      expect(sink.demoted, {'old.jpg'});
      expect(sink.removed, isEmpty);
      expect(mirror.rows(account)['old.jpg']?.placeholderReason, NextcloudPlaceholderReason.unfunded);
      expect(mirror.rows(account)['new.jpg']?.pinned, isTrue);
    });

    test('fetchOriginal reports its failure instead of throwing, and only pins what is already whole', () async {
      final server = serverWith();
      final useCase = useCaseWith(server);
      expect(await useCase.fetchOriginal(accountWith(), 'nope.jpg'), isA<NextcloudNotFoundFailure>());
      expect(await useCase.fetchOriginal(accountWith(), 'Sub'), isA<NextcloudNotFoundFailure>(), reason: 'a folder is not an item');

      // a row written before tiers existed: whole, unpinned
      final path = mirror.localPathFor(accountWith(), 'a.jpg');
      await File(path).parent.create(recursive: true);
      await File(path).writeAsBytes([1, 2, 3]);
      await mirror.record(
        accountWith(),
        NextcloudMirrorIndexEntry(relativePath: 'a.jpg', etag: 'v1', fileId: 1, tier: NextcloudMirrorTier.original, remoteSizeBytes: 3, localSizeBytes: 3, remoteLastModified: day1, downloadedAt: day1, lastAccessAt: day1),
      );
      expect(await useCase.fetchOriginal(accountWith(), 'a.jpg'), isNull);
      expect(server.downloads, isEmpty, reason: 'already whole: only the pin was missing');
      expect(mirror.rows(accountWith())['a.jpg']?.pinned, isTrue);
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

      expect(sink.placeholders, ['v.mp4', 'a.jpg'], reason: 'the policy placeholder first, then the one the budget made');
      expect(server.fetched, ['c.jpg']);
      expect(mirror.rows(account).keys, {'c.jpg', 'a.jpg', 'v.mp4'});
      expect(mirror.rows(account)['v.mp4']?.placeholderReason, NextcloudPlaceholderReason.policy);
      expect(mirror.rows(account)['a.jpg']?.placeholderReason, NextcloudPlaceholderReason.unfunded);
      expect(result.added, 3);
      expect(result.skipped, 0);
      expect(result.itemFailures, isEmpty);
      expect(states.states['acc1']?.collectionEtags, isNotEmpty, reason: 'both placeholders reflect the server');
    });

    test('a promotion the budget cannot fund turns the placeholder from policy to unfunded, and the subtree stays promised', () async {
      final server = serverWith(files: [fakeFile('Sub/b.mp4', size: 5, modified: day2, fileId: 2)]);
      final useCase = useCaseWith(server);
      await sync(useCase, account: accountWith(cacheLimitBytes: 4, videoAutoDownloadLimitBytes: above));
      expect(mirror.rows(accountWith())['Sub/b.mp4']?.placeholderReason, NextcloudPlaceholderReason.policy);
      expect(states.states['acc1']?.collectionEtags, isNotEmpty);

      final raised = await sync(useCase, account: accountWith(cacheLimitBytes: 4, videoAutoDownloadLimitBytes: 10));
      expect(raised.itemFailures, isEmpty);
      final row = mirror.rows(accountWith())['Sub/b.mp4']!;
      expect(row.tier, NextcloudMirrorTier.placeholder, reason: 'a promotion the budget cannot fund keeps what was there');
      expect(row.placeholderReason, NextcloudPlaceholderReason.unfunded, reason: 'but now it is the budget it waits for, not the threshold');
      // an unfunded placeholder reflects the server, so the subtree is promised and the tree is not walked
      // again until the budget changes
      expect(states.states['acc1']?.collectionEtags, isNotEmpty);

      final funded = await sync(useCase, account: accountWith(cacheLimitBytes: 10, videoAutoDownloadLimitBytes: 10));
      expect(server.downloads, ['Sub/b.mp4'], reason: 'the raised budget relists and funds it');
      expect(funded.updated, 1);
      expect(mirror.rows(accountWith())['Sub/b.mp4']?.tier, NextcloudMirrorTier.original);
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
