import 'package:aves/l10n/l10n.dart';
import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/account_store_impl.dart';
import 'package:aves/model/nextcloud/errors.dart';
import 'package:aves/model/nextcloud/nextcloud.dart';
import 'package:aves/model/nextcloud/sync.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/model/source/collection_source.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/action_mixins/feedback.dart';
import 'package:aves/widgets/common/basic/scaffold.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/common/identity/buttons/outlined_button.dart';
import 'package:aves/widgets/common/identity/empty.dart';
import 'package:aves/widgets/dialogs/aves_confirmation_dialog.dart';
import 'package:aves/widgets/dialogs/aves_dialog.dart';
import 'package:aves/widgets/dialogs/nextcloud/edit_nextcloud_account_dialog.dart';
import 'package:aves_model/aves_model.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

// Account/settings UI (layer L2 + integration). Every write goes through `NextcloudAccountUseCase`, which
// sequences credential, mirror, collection entries and account row (see `account_use_case.dart`).
class NextcloudAccountsPage extends StatelessWidget with FeedbackMixin, _NextcloudAccountOps {
  static const routeName = '/settings/nextcloud_accounts';

  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AvesScaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !settings.useTvLayout,
        title: Text(l10n.nextcloudAccountsPageTitle),
      ),
      body: SafeArea(
        child: Selector<Settings, List<String>>(
          selector: (context, s) => s.getStringList(SettingKeys.nextcloudAccountsKey) ?? const [],
          builder: (context, raw, child) {
            final accounts = decodeNextcloudAccounts(raw)..sort((a, b) => a.displayName.compareTo(b.displayName));
            return Column(
              children: [
                Expanded(
                  child: accounts.isEmpty
                      ? EmptyContent(
                          icon: AIcons.nextcloud,
                          text: l10n.nextcloudAccountsPageEmpty,
                        )
                      : ListView(
                          children: accounts.map((account) => _AccountTile(account: account)).toList(),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: AvesOutlinedButton(
                    icon: const Icon(AIcons.add),
                    label: l10n.nextcloudAccountsPageAddAccount,
                    onPressed: () => _add(context),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _add(BuildContext context) async {
    final source = context.read<CollectionSource>();
    final result = await showAvesDialog<(NextcloudAccount, String?)>(
      context: context,
      builder: (context) => const EditNextcloudAccountDialog(),
      routeSettings: const RouteSettings(
        name: EditNextcloudAccountDialog.routeName,
      ),
    );
    if (result == null || !context.mounted) return;

    final (account, newPassword) = result;
    await runAccountOp(context, () async {
      final accounts = await nextcloud.accounts(source);
      return accounts.save(account, newPassword: newPassword);
    });
  }
}

class _AccountTile extends StatelessWidget with FeedbackMixin, _NextcloudAccountOps {
  final NextcloudAccount account;

  const new({required this.account});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final source = context.read<CollectionSource>();
    final folder = account.rootFolder.isEmpty ? '/' : '/${account.rootFolder}';
    return ValueListenableBuilder<NextcloudSyncStatus>(
      valueListenable: nextcloud.statusOf(account.id),
      builder: (context, status, child) {
        final statusText = _statusText(l10n, status);
        return SwitchListTile(
          value: account.enabled,
          onChanged: (v) => runAccountOp(context, () async {
            final accounts = await nextcloud.accounts(source);
            return accounts.save(account.copyWith(enabled: v), previous: account);
          }),
          title: Text(account.displayName),
          subtitle: Text(statusText == null ? folder : '$folder\n$statusText'),
          isThreeLine: statusText != null,
          secondary: Row(
            mainAxisSize: .min,
            children: [
              IconButton(
                icon: const Icon(AIcons.refresh),
                onPressed: status.isRunning || !account.enabled ? null : () => nextcloud.sync(source, account),
                tooltip: l10n.nextcloudSyncTooltip,
              ),
              IconButton(
                icon: const Icon(AIcons.edit),
                onPressed: () => _edit(context),
                tooltip: l10n.changeTooltip,
              ),
              IconButton(
                icon: const Icon(AIcons.clear),
                onPressed: () => _remove(context),
                tooltip: l10n.actionRemove,
              ),
            ],
          ),
        );
      },
    );
  }

  String? _statusText(AppLocalizations l10n, NextcloudSyncStatus status) {
    final progress = status.progress;
    if (progress != null) {
      return progress.phase == NextcloudSyncPhase.downloading && progress.total > 0 ? l10n.nextcloudSyncStatusDownloading(progress.done, progress.total) : l10n.nextcloudSyncStatusSyncing;
    }
    final error = status.error;
    if (error != null) {
      return l10n.nextcloudSyncStatusFailed(error is NextcloudFailure ? error.message : error.runtimeType.toString());
    }
    final result = status.lastResult;
    if (result == null) return null;
    final fatal = result.fatal;
    if (fatal != null) return l10n.nextcloudSyncStatusFailed(fatal.message);
    return l10n.nextcloudSyncStatusDone(result.added, result.updated, result.removed, result.itemFailures.length);
  }

  Future<void> _edit(BuildContext context) async {
    final source = context.read<CollectionSource>();
    final result = await showAvesDialog<(NextcloudAccount, String?)>(
      context: context,
      builder: (context) => EditNextcloudAccountDialog(initialAccount: account),
      routeSettings: const RouteSettings(
        name: EditNextcloudAccountDialog.routeName,
      ),
    );
    if (result == null || !context.mounted) return;

    final (updated, newPassword) = result;
    await runAccountOp(context, () async {
      final accounts = await nextcloud.accounts(source);
      return accounts.save(updated, previous: account, newPassword: newPassword);
    });
  }

  Future<void> _remove(BuildContext context) async {
    final l10n = context.l10n;
    final source = context.read<CollectionSource>();
    if (!await showConfirmationDialog(
      context: context,
      message: l10n.genericDangerWarningDialogMessage,
      ok: l10n.applyButtonLabel,
    )) {
      return;
    }
    if (!context.mounted) return;

    await runAccountOp(context, () async {
      final accounts = await nextcloud.accounts(source);
      final removed = await accounts.remove(account);
      if (removed) {
        // deferred past this tile's own removal from the tree, so its `ValueListenableBuilder` has already
        // called `removeListener` by the time the notifier is disposed
        WidgetsBinding.instance.addPostFrameCallback((_) => nextcloud.disposeStatus(account.id));
      }
      return removed;
    });
  }
}

mixin _NextcloudAccountOps on FeedbackMixin {
  // Runs an account operation and tells the user when it did not go through: a `false` (the platform credential
  // store refused) or a `NextcloudFailure` (the mirror root is unavailable). Anything else is a bug and propagates.
  Future<void> runAccountOp(BuildContext context, Future<bool> Function() op) async {
    final l10n = context.l10n;
    bool done;
    try {
      done = await op();
    } on NextcloudFailure catch (e, stack) {
      await reportService.recordError(e, stack);
      done = false;
    }
    if (!context.mounted) return;
    if (done) {
      // Nextcloud album names depend on the account list (a root album is named after its account only when
      // there are several), so the source's cached names are stale or wrong after any account change
      context.read<CollectionSource>().invalidateStoredAlbumDisplayNames();
    } else {
      showFeedback(context, FeedbackType.warn, l10n.genericFailureFeedback);
    }
  }
}
