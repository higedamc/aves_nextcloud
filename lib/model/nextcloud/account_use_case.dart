import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/credential_store.dart';
import 'package:aves/model/nextcloud/mirror_store.dart';
import 'package:aves/model/nextcloud/sync_ports.dart';

// Account lifecycle (integration). Every write to the account list goes through here, because the account row,
// the credential, the mirror and the collection entries must change in a fixed order:
// - Saving a re-pointed account (`serverUrl`, `username` or `rootFolder` changed) purges the previous mirror BEFORE
//   the row is written. Mirror relative paths are rootFolder-based, so after a re-point a row like `a.jpg` would name
//   a different remote file: the index would answer "present" and the sync would skip the download. A crash between
//   the two steps leaves "no mirror, old row" (the next sync re-downloads), never "stale mirror, new row".
// - Removal wipes the credential first and aborts when the platform store fails, then purges, then drops the row, so
//   a credential never outlives its account.
// - A purge drops the mirror files and index rows, then the collection entries (an entry without a file is dropped
//   on its next refresh anyway, so this order heals itself; the reverse would leave files the sync trusts and no
//   entries to show them), then the sync state.
class NextcloudAccountUseCase {
  final NextcloudAccountStore _accounts;
  final NextcloudCredentialStore _credentials;
  final NextcloudMirrorStore _mirror;
  final NextcloudSyncSink _sink;
  final NextcloudSyncStateStore _states;

  // removes every collection entry under the account's mirror, whether or not the index still has a row for it
  final Future<void> Function(NextcloudAccount account) _removeAllEntries;

  new({
    required this._accounts,
    required this._credentials,
    required this._mirror,
    required this._sink,
    required this._states,
    required this._removeAllEntries,
  });

  static bool needsPurge(NextcloudAccount previous, NextcloudAccount next) => previous.serverUrl != next.serverUrl || previous.username != next.username || previous.rootFolder != next.rootFolder;

  // Saves a new or edited account. Returns false when the app password could not be stored; nothing else is
  // written then, so the account never points at a server it cannot authenticate against.
  Future<bool> save(NextcloudAccount account, {NextcloudAccount? previous, String? newPassword}) async {
    if (newPassword != null) {
      if (!await _credentials.writeAppPassword(account, newPassword)) return false;
    }
    if (previous != null && needsPurge(previous, account)) {
      await purge(previous);
    }
    await _accounts.save(account);
    return true;
  }

  // Returns false when the credential could not be wiped; the account is kept then, so the credential never
  // outlives its row.
  Future<bool> remove(NextcloudAccount account) async {
    if (!await _credentials.writeAppPassword(account, null)) return false;
    await purge(account);
    await _accounts.remove(account.id);
    return true;
  }

  Future<void> purge(NextcloudAccount account) async {
    final rows = await _mirror.listAll(account);
    await _mirror.purge(account);
    if (rows.isNotEmpty) {
      await _sink.removeMirroredFiles(account, rows.map((row) => row.relativePath).toSet());
    }
    await _removeAllEntries(account);
    await _states.clear(account);
  }
}
