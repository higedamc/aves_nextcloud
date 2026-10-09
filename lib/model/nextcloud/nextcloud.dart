import 'dart:async';

import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/account_store_impl.dart';
import 'package:aves/model/nextcloud/account_use_case.dart';
import 'package:aves/model/nextcloud/credential_store.dart';
import 'package:aves/model/nextcloud/credential_store_impl.dart';
import 'package:aves/model/nextcloud/mirror_index_sqflite.dart';
import 'package:aves/model/nextcloud/mirror_store.dart';
import 'package:aves/model/nextcloud/mirror_store_impl.dart';
import 'package:aves/model/nextcloud/paths.dart';
import 'package:aves/model/nextcloud/sync.dart';
import 'package:aves/model/nextcloud/sync_ports.dart';
import 'package:aves/model/nextcloud/sync_sink_impl.dart';
import 'package:aves/model/nextcloud/sync_use_case.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/model/source/collection_source.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/services/nextcloud/webdav_repository.dart';
import 'package:aves/utils/android_file_utils.dart';
import 'package:aves_model/aves_model.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

final Nextcloud nextcloud = Nextcloud._private();

// Wires the Nextcloud layers to the app (integration). The graph is built once, lazily, on the collection source
// of the main app: the analysis service and the widget isolate also build a `MediaStoreSource`, but only the
// main app syncs, and `localMediaDb.nextId` is process-local (contract, `sync.dart`).
class Nextcloud {
  static const NextcloudAccountStore accountStore = SettingsNextcloudAccountStore();
  final NextcloudCredentialStore credentialStore = SecurityNextcloudCredentialStore();
  final NextcloudMirrorStore mirrorStore = NextcloudMirrorStoreImpl(SqfliteNextcloudMirrorIndex());

  NextcloudCollectionSyncSink? _sink;
  NextcloudSyncUseCase? _sync;
  NextcloudAccountUseCase? _accountUseCase;
  Future<void>? _initializer;
  bool _startupSyncRequested = false;
  final Map<String, ValueNotifier<NextcloudSyncStatus>> _statuses = {};

  new _private();

  // Initializes the mirror store and builds the use cases on `source`. A failed initialization (no mirror root)
  // is not cached, so the next call tries again.
  Future<void> init(CollectionSource source) {
    final initializer = _initializer ??= _doInit(source);
    return initializer.catchError((Object error) {
      if (identical(_initializer, initializer)) _initializer = null;
      throw error;
    });
  }

  Future<void> _doInit(CollectionSource source) async {
    await mirrorStore.init();
    final sink = NextcloudCollectionSyncSink(source, mirrorStore);
    final states = FileNextcloudSyncStateStore(mirrorStore.mirrorRoot);
    _sink = sink;
    _sync = NextcloudSyncUseCaseImpl(
      repositories: const WebDavNextcloudRepositoryFactory(),
      credentials: credentialStore,
      mirror: mirrorStore,
      sink: sink,
      states: states,
    );
    _accountUseCase = NextcloudAccountUseCase(
      accounts: accountStore,
      credentials: credentialStore,
      mirror: mirrorStore,
      states: states,
      removeAllEntries: sink.removeAccountEntries,
    );
  }

  Future<NextcloudAccountUseCase> accounts(CollectionSource source) async {
    await init(source);
    return _accountUseCase!;
  }

  // the non-secret account list, as the settings UI sees it
  List<NextcloudAccount> get knownAccounts => decodeNextcloudAccounts(settings.getStringList(SettingKeys.nextcloudAccountsKey) ?? const []);

  ValueListenable<NextcloudSyncStatus> statusOf(String accountId) => _statusNotifier(accountId);

  ValueNotifier<NextcloudSyncStatus> _statusNotifier(String accountId) => _statuses.putIfAbsent(accountId, () => ValueNotifier(NextcloudSyncStatus.idle));

  // Drops a removed account's status notifier. Nothing in the account lifecycle calls this on its own:
  // `_statuses` is a field of this singleton, not of `NextcloudAccountUseCase`, so the UI that drives a removal
  // has to call it after the removal succeeds. No `dispose()`: `sync()` holds a reference to this exact notifier
  // for the lifetime of a run, including inside its `catch`, so disposing it while a sync is in flight turns the
  // next progress or error update into a use-after-dispose. The map entry is the only retainer, so dropping it
  // is enough for the notifier to be collected once nothing (a running sync, a listener) still holds it.
  void forgetStatus(String accountId) => _statuses.remove(accountId);

  // Runs one sync for `account`. Returns null when a sync for it is already running (the use case would queue it,
  // but a second user tap should not double the work). A `NextcloudFailure` is reported in the result; anything
  // else is a bug, recorded and shown as a failure.
  Future<NextcloudSyncResult?> sync(CollectionSource source, NextcloudAccount account, {bool force = false}) async {
    final notifier = _statusNotifier(account.id);
    if (notifier.value.isRunning) return null;
    notifier.value = const NextcloudSyncStatus(progress: NextcloudSyncProgress(phase: NextcloudSyncPhase.probing));
    try {
      await init(source);
      final useCase = _sync!;
      final progressStream = useCase.run(NextcloudSyncRequest(account: account, force: force));
      // `lastResult` is set synchronously by `run`, so this is this run's result
      final resultFuture = useCase.lastResult;
      await for (final progress in progressStream) {
        notifier.value = NextcloudSyncStatus(progress: progress, lastResult: notifier.value.lastResult);
      }
      final result = await resultFuture;
      _sink?.flush();
      notifier.value = NextcloudSyncStatus(lastResult: result);
      unawaited(reportService.log('Nextcloud sync ${account.id}: $result'));
      return result;
    } catch (error, stack) {
      await reportService.recordError(error, stack);
      notifier.value = NextcloudSyncStatus(lastResult: notifier.value.lastResult, error: error);
      return null;
    }
  }

  Future<void> syncAll(CollectionSource source) async {
    for (final account in knownAccounts.where((account) => account.enabled)) {
      await sync(source, account);
    }
  }

  // One sync of every enabled account, the first time the main app source is ready. Registered once per process.
  void syncOnceWhenReady(CollectionSource source) {
    if (_startupSyncRequested) return;
    _startupSyncRequested = true;
    if (knownAccounts.isEmpty) return;

    void listener() {
      if (source.state != SourceState.ready) return;
      source.stateNotifier.removeListener(listener);
      unawaited(syncAll(source));
    }

    source.stateNotifier.addListener(listener);
  }

  // Display name of a mirror directory: the remote folder path relative to the account root, or the account
  // (`user@host`) for the root itself. With several accounts the account is appended, so two mirrors of a
  // `Photos` folder stay apart.
  String albumDisplayName(String dirPath) {
    final root = androidFileUtils.nextcloudMirrorRoot;
    final prefix = '$root${pContext.separator}';
    if (root.isEmpty || !dirPath.startsWith(prefix)) return pContext.basename(dirPath);

    final parts = pContext.split(dirPath.substring(prefix.length));
    if (parts.isEmpty) return pContext.basename(dirPath);

    final accounts = knownAccounts;
    final account = accounts.firstWhereOrNull((account) => account.mirrorDirName == parts.first);
    final accountName = account?.displayName ?? parts.first;
    final relative = parts.skip(1).join(NextcloudPaths.separator);
    if (relative.isEmpty) return accountName;
    return accounts.length > 1 ? '$relative ($accountName)' : relative;
  }
}

// What the settings UI shows for one account: the running progress, the last result, or the last unexpected error.
@immutable
class NextcloudSyncStatus {
  final NextcloudSyncProgress? progress;
  final NextcloudSyncResult? lastResult;
  final Object? error;

  const new({this.progress, this.lastResult, this.error});

  static const idle = NextcloudSyncStatus();

  bool get isRunning => progress != null;
}
