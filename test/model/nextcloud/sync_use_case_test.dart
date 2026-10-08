import 'dart:io';

import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/errors.dart';
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

  NextcloudAccount accountWith({int cacheLimitBytes = 1000, String id = 'acc1'}) => NextcloudAccount(
    id: id,
    serverUrl: Uri.parse('https://cloud.example.com'),
    username: 'alice',
    rootFolder: 'Photos',
    cacheLimitBytes: cacheLimitBytes,
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
      expect(server.downloads, ['Sub/Deep/c.jpg', 'Sub/b.mp4', 'a.jpg']);
      expect(sink.puts, ['Sub/Deep/c.jpg', 'Sub/b.mp4', 'a.jpg']);
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
      expect(server.downloads.length, 3, reason: 'nothing downloaded again');
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
    });

    test('a file the sink cannot turn into an entry is dropped from the mirror so it is retried next time', () async {
      final server = serverWith();
      sink.putFails.add('a.jpg');
      final result = await sync(useCaseWith(server));
      expect(result.itemFailures.keys, ['a.jpg']);
      expect(mirror.rows(accountWith()).containsKey('a.jpg'), isFalse);
      expect(await File(mirror.localPathFor(accountWith(), 'a.jpg')).exists(), isFalse);
      // the root is complete as far as the listing is concerned: next run re-lists only if the etag changed,
      // which is why the bytes had to go
      expect(result.added, 2);
    });

    test('a network failure during download is fatal and persists no etags', () async {
      final server = serverWith()..downloadFailures['Sub/Deep/c.jpg'] = const NextcloudNetworkFailure('reset');
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
      expect(server.downloads.where((v) => v == 'a.jpg').length, 2);
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
      expect(server.downloads, ['Sub/Deep/c.jpg', 'Sub/b.mp4']);
      expect(result.added, 2);
      expect(result.skipped, 1);
      expect(result.evicted, 0);
      expect(mirror.rows(accountWith()).keys, {'Sub/Deep/c.jpg', 'Sub/b.mp4'});
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

      expect(server.downloads.sublist(1), ['new2.jpg', 'new1.jpg']);
      expect(result.evicted, 1);
      expect(sink.removed, {'old.jpg'});
      expect(mirror.rows(accountWith()).keys, {'new1.jpg', 'new2.jpg'});
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
      expect(states.states['acc1']?.collectionEtags, isEmpty);

      server.files.remove('a.jpg');
      server.failing['Sub/b.mp4'] = const NextcloudParseFailure('no successful propstat');
      final result = await sync(useCase);
      expect(result.removed, 1);
      expect(sink.removed, {'a.jpg'});
      expect(mirror.rows(accountWith()).keys, {'Sub/b.mp4', 'Sub/Deep/c.jpg'});
      expect(result.itemFailures.keys, ['Sub/b.mp4']);
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
      expect(server.downloads.length, 3);
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

  group('FileNextcloudSyncStateStore', () {
    test('round trips, survives a corrupt file, and clears', () async {
      final store = FileNextcloudSyncStateStore(tempDir.path);
      final account = accountWith();
      expect((await store.load(account)).collectionEtags, isEmpty);

      await store.save(account, const NextcloudSyncState(collectionEtags: {'': 'r1', 'Sub': 's1'}, cacheLimitBytes: 42));
      final loaded = await store.load(account);
      expect(loaded.collectionEtags, {'': 'r1', 'Sub': 's1'});
      expect(loaded.cacheLimitBytes, 42);
      expect(await File('${tempDir.path}/acc1.sync.json.part').exists(), isFalse);

      await File('${tempDir.path}/acc1.sync.json').writeAsString('{not json');
      expect((await store.load(account)).collectionEtags, isEmpty);

      await store.save(account, const NextcloudSyncState(collectionEtags: {'': 'r2'}));
      await store.clear(account);
      expect(await File('${tempDir.path}/acc1.sync.json').exists(), isFalse);
    });
  });
}
