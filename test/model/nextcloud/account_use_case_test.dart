import 'dart:io';

import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/account_use_case.dart';
import 'package:aves/model/nextcloud/credential_store.dart';
import 'package:aves/model/nextcloud/mirror_store.dart';
import 'package:aves/model/nextcloud/sync_ports.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fake/nextcloud_sync.dart';

class _MemoryAccountStore implements NextcloudAccountStore {
  final Map<String, NextcloudAccount> accounts = {};
  final List<String> log = [];

  @override
  Future<List<NextcloudAccount>> loadAll() async => accounts.values.toList();

  @override
  Future<void> save(NextcloudAccount account) async {
    accounts[account.id] = account;
    log.add('save:${account.id}');
  }

  @override
  Future<void> remove(String accountId) async {
    accounts.remove(accountId);
    log.add('remove:$accountId');
  }
}

class _FailingCredentialStore extends FakeNextcloudCredentialStore {
  bool failWrites = false;

  @override
  Future<bool> writeAppPassword(NextcloudAccount account, String? appPassword) async {
    if (failWrites) return false;
    return super.writeAppPassword(account, appPassword);
  }
}

void main() {
  late Directory tempDir;
  late FakeNextcloudMirrorStore mirror;
  late _MemoryAccountStore accounts;
  late _FailingCredentialStore credentials;
  late FakeNextcloudSyncSink sink;
  late MemoryNextcloudSyncStateStore states;
  late List<String> purgedEntriesFor;
  late NextcloudAccountUseCase useCase;

  final account = NextcloudAccount(
    id: 'acc1',
    serverUrl: Uri.parse('https://cloud.example.org'),
    username: 'alice',
    rootFolder: 'Photos',
    cacheLimitBytes: NextcloudAccount.defaultCacheLimitBytes,
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('aves_nc_account_');
    mirror = FakeNextcloudMirrorStore(tempDir.path);
    accounts = _MemoryAccountStore();
    credentials = _FailingCredentialStore();
    sink = FakeNextcloudSyncSink();
    states = MemoryNextcloudSyncStateStore();
    purgedEntriesFor = [];
    useCase = NextcloudAccountUseCase(
      accounts: accounts,
      credentials: credentials,
      mirror: mirror,
      sink: sink,
      states: states,
      removeAllEntries: (account) async => purgedEntriesFor.add(account.id),
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> mirrorFile(String relativePath) async {
    final file = File(mirror.localPathFor(account, relativePath));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.filled(10, 1));
    final now = DateTime.now();
    await mirror.record(
      account,
      NextcloudMirrorIndexEntry(
        relativePath: relativePath,
        etag: 'e',
        fileId: null,
        sizeBytes: 10,
        remoteLastModified: now,
        downloadedAt: now,
        lastAccessAt: now,
      ),
    );
    await states.save(account, const NextcloudSyncState(collectionEtags: {'': 'root'}));
  }

  group('save', () {
    test('a new account stores the password before the row', () async {
      expect(await useCase.save(account, newPassword: 'pw'), isTrue);
      expect(credentials.passwords[account.credentialKey], 'pw');
      expect(accounts.accounts.keys, {'acc1'});
    });

    test('a failed password write saves nothing', () async {
      credentials.failWrites = true;
      expect(await useCase.save(account, newPassword: 'pw'), isFalse);
      expect(accounts.accounts, isEmpty);
    });

    test('an edit that keeps the identity keeps the mirror', () async {
      await mirrorFile('a.jpg');
      final edited = account.copyWith(enabled: false);
      expect(await useCase.save(edited, previous: account), isTrue);
      expect(mirror.rows(account).keys, {'a.jpg'});
      expect(sink.removed, isEmpty);
      expect(purgedEntriesFor, isEmpty);
      expect(states.states.containsKey(account.id), isTrue);
    });

    for (final (label, change) in [
      ('server', account.copyWith(serverUrl: Uri.parse('https://other.example.org'))),
      ('username', account.copyWith(username: 'bob')),
      ('root folder', account.copyWith(rootFolder: 'Pictures')),
    ]) {
      test('a changed $label purges the previous mirror before saving the row', () async {
        await mirrorFile('a.jpg');
        expect(await useCase.save(change, previous: account), isTrue);
        expect(mirror.rows(account), isEmpty);
        expect(await File(mirror.localPathFor(account, 'a.jpg')).exists(), isFalse);
        expect(sink.removed, {'a.jpg'});
        expect(purgedEntriesFor, ['acc1']);
        expect(states.states.containsKey(account.id), isFalse);
        expect(accounts.accounts['acc1'], change);
      });
    }

    test('a re-point whose password write fails leaves the old mirror and row alone', () async {
      await mirrorFile('a.jpg');
      credentials.failWrites = true;
      final change = account.copyWith(username: 'bob');
      expect(await useCase.save(change, previous: account, newPassword: 'pw'), isFalse);
      expect(mirror.rows(account).keys, {'a.jpg'});
      expect(accounts.accounts, isEmpty);
    });
  });

  group('remove', () {
    test('wipes the credential, purges, then drops the row', () async {
      await useCase.save(account, newPassword: 'pw');
      await mirrorFile('a.jpg');
      expect(await useCase.remove(account), isTrue);
      expect(credentials.passwords, isEmpty);
      expect(mirror.rows(account), isEmpty);
      expect(sink.removed, {'a.jpg'});
      expect(purgedEntriesFor, ['acc1']);
      expect(states.states.containsKey(account.id), isFalse);
      expect(accounts.accounts, isEmpty);
    });

    test('keeps the account when the credential cannot be wiped', () async {
      await useCase.save(account, newPassword: 'pw');
      await mirrorFile('a.jpg');
      credentials.failWrites = true;
      expect(await useCase.remove(account), isFalse);
      expect(accounts.accounts.keys, {'acc1'});
      expect(mirror.rows(account).keys, {'a.jpg'});
      expect(sink.removed, isEmpty);
    });
  });

  test('purge removes entries even when the index has no rows', () async {
    await useCase.purge(account);
    expect(sink.removals, isEmpty);
    expect(purgedEntriesFor, ['acc1']);
  });
}
