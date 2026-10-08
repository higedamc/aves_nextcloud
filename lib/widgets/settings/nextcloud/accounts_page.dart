import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/account_store_impl.dart';
import 'package:aves/model/nextcloud/credential_store_impl.dart';
import 'package:aves/model/settings/settings.dart';
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

// Account/settings UI (layer L2). Account removal here only drops the account entry and its credential;
// the mirror directory on disk (layer L3, `NextcloudMirrorStore.purge`) is not wired up yet, because L3
// is still just a contract. Whoever lands the integration leaf should route removal through that store too.
class NextcloudAccountsPage extends StatelessWidget {
  static const routeName = '/settings/nextcloud_accounts';

  static const accountStore = SettingsNextcloudAccountStore();
  static final credentialStore = SecurityNextcloudCredentialStore();

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
          selector: (context, s) =>
              s.getStringList(SettingKeys.nextcloudAccountsKey) ?? const [],
          builder: (context, raw, child) {
            final accounts = decodeNextcloudAccounts(raw)
              ..sort((a, b) => a.displayName.compareTo(b.displayName));
            return Column(
              children: [
                Expanded(
                  child: accounts.isEmpty
                      ? EmptyContent(
                          icon: AIcons.nextcloud,
                          text: l10n.nextcloudAccountsPageEmpty,
                        )
                      : ListView(
                          children: accounts
                              .map((account) => _AccountTile(account: account))
                              .toList(),
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

  static Future<void> _add(BuildContext context) async {
    final result = await showAvesDialog<(NextcloudAccount, String?)>(
      context: context,
      builder: (context) => const EditNextcloudAccountDialog(),
      routeSettings: const RouteSettings(
        name: EditNextcloudAccountDialog.routeName,
      ),
    );
    if (result == null) return;

    final (account, newPassword) = result;
    if (newPassword != null) {
      await credentialStore.writeAppPassword(account, newPassword);
    }
    await accountStore.save(account);
  }
}

class _AccountTile extends StatelessWidget with FeedbackMixin {
  final NextcloudAccount account;

  const new({required this.account});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SwitchListTile(
      value: account.enabled,
      onChanged: (v) =>
          NextcloudAccountsPage.accountStore.save(account.copyWith(enabled: v)),
      title: Text(account.displayName),
      subtitle: Text(
        account.rootFolder.isEmpty ? '/' : '/${account.rootFolder}',
      ),
      secondary: Row(
        mainAxisSize: .min,
        children: [
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
  }

  Future<void> _edit(BuildContext context) async {
    final result = await showAvesDialog<(NextcloudAccount, String?)>(
      context: context,
      builder: (context) => EditNextcloudAccountDialog(initialAccount: account),
      routeSettings: const RouteSettings(
        name: EditNextcloudAccountDialog.routeName,
      ),
    );
    if (result == null) return;

    final (updated, newPassword) = result;
    if (newPassword != null) {
      await NextcloudAccountsPage.credentialStore.writeAppPassword(
        updated,
        newPassword,
      );
    }
    await NextcloudAccountsPage.accountStore.save(updated);
  }

  Future<void> _remove(BuildContext context) async {
    final l10n = context.l10n;
    if (!await showConfirmationDialog(
      context: context,
      message: l10n.genericDangerWarningDialogMessage,
      ok: l10n.applyButtonLabel,
    )) {
      return;
    }

    final credentialWiped = await NextcloudAccountsPage.credentialStore
        .writeAppPassword(account, null);
    if (!credentialWiped) {
      if (context.mounted) {
        showFeedback(context, FeedbackType.warn, l10n.genericFailureFeedback);
      }
      return;
    }
    await NextcloudAccountsPage.accountStore.remove(account.id);
  }
}
