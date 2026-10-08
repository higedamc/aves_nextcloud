import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/paths.dart';
import 'package:aves/widgets/common/basic/labeled_checkbox.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/dialogs/aves_dialog.dart';
import 'package:material_ui/material_ui.dart';

// Add/edit form for a `NextcloudAccount`. The app password is never prefilled (it is read from the
// credential store only when needed to talk to the server, never surfaced back to the UI); leaving it
// blank while editing keeps the previously stored password.
class EditNextcloudAccountDialog extends StatefulWidget {
  static const routeName = '/dialog/edit_nextcloud_account';

  final NextcloudAccount? initialAccount;

  const new({super.key, this.initialAccount});

  @override
  State<EditNextcloudAccountDialog> createState() =>
      _EditNextcloudAccountDialogState();
}

class _EditNextcloudAccountDialogState
    extends State<EditNextcloudAccountDialog> {
  final TextEditingController _serverUrlController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _appPasswordController = TextEditingController();
  final TextEditingController _rootFolderController = TextEditingController();
  final ValueNotifier<bool> _allowInsecureHttpNotifier = ValueNotifier(false);
  final ValueNotifier<bool> _isValidNotifier = ValueNotifier(false);

  NextcloudAccount? get initialAccount => widget.initialAccount;

  bool get isNew => initialAccount == null;

  @override
  void initState() {
    super.initState();
    final initial = initialAccount;
    if (initial != null) {
      _serverUrlController.text = initial.serverUrl.toString();
      _usernameController.text = initial.username;
      _rootFolderController.text = initial.rootFolder;
      _allowInsecureHttpNotifier.value = initial.allowInsecureHttp;
    }
    for (final controller in [
      _serverUrlController,
      _usernameController,
      _appPasswordController,
      _rootFolderController,
    ]) {
      controller.addListener(_validate);
    }
    _allowInsecureHttpNotifier.addListener(_validate);
    _validate();
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _usernameController.dispose();
    _appPasswordController.dispose();
    _rootFolderController.dispose();
    _allowInsecureHttpNotifier.dispose();
    _isValidNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AvesDialog(
      title: isNew
          ? l10n.nextcloudAccountDialogAddTitle
          : l10n.nextcloudAccountDialogEditTitle,
      scrollableContent: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          child: TextField(
            controller: _serverUrlController,
            decoration: InputDecoration(
              labelText: l10n.nextcloudAccountDialogServerUrl,
              hintText: 'https://cloud.example.com',
            ),
            keyboardType: TextInputType.url,
            autofillHints: const [AutofillHints.url],
            autofocus: isNew,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          child: TextField(
            controller: _usernameController,
            decoration: InputDecoration(
              labelText: l10n.nextcloudAccountDialogUsername,
            ),
            autofillHints: const [AutofillHints.username],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          child: TextField(
            controller: _appPasswordController,
            decoration: InputDecoration(
              labelText: l10n.nextcloudAccountDialogAppPassword,
              hintText: isNew
                  ? null
                  : l10n.nextcloudAccountDialogAppPasswordKeepHint,
            ),
            obscureText: true,
            autofillHints: const [AutofillHints.password],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          child: TextField(
            controller: _rootFolderController,
            decoration: InputDecoration(
              labelText: l10n.nextcloudAccountDialogRootFolder,
              hintText: '/',
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          child: ValueListenableBuilder<bool>(
            valueListenable: _allowInsecureHttpNotifier,
            builder: (context, allowInsecureHttp, child) => LabeledCheckbox(
              value: allowInsecureHttp,
              onChanged: (v) => _allowInsecureHttpNotifier.value = v ?? false,
              text: l10n.nextcloudAccountDialogAllowInsecureHttp,
            ),
          ),
        ),
      ],
      actions: [
        const CancelButton(),
        ValueListenableBuilder<bool>(
          valueListenable: _isValidNotifier,
          builder: (context, isValid, child) {
            return TextButton(
              onPressed: isValid ? () => _submit(context) : null,
              child: Text(
                isNew ? l10n.createButtonLabel : l10n.applyButtonLabel,
              ),
            );
          },
        ),
      ],
    );
  }

  Uri? get _parsedServerUrl => Uri.tryParse(_serverUrlController.text.trim());

  String? get _normalizedRootFolder =>
      NextcloudPaths.normalize(_rootFolderController.text.trim());

  void _validate() {
    final serverUrl = _parsedServerUrl;
    final username = _usernameController.text.trim();
    final rootFolder = _normalizedRootFolder;
    final hasPassword = isNew ? _appPasswordController.text.isNotEmpty : true;

    _isValidNotifier.value =
        serverUrl != null &&
        NextcloudAccount.isValidServerUrl(serverUrl) &&
        NextcloudAccount.isValidUsername(username) &&
        rootFolder != null &&
        hasPassword;
  }

  void _submit(BuildContext context) {
    if (!_isValidNotifier.value) return;

    final serverUrl = _parsedServerUrl!;
    final username = _usernameController.text.trim();
    final rootFolder = _normalizedRootFolder!;
    final allowInsecureHttp = _allowInsecureHttpNotifier.value;
    final newPassword = _appPasswordController.text.isEmpty
        ? null
        : _appPasswordController.text;

    final initial = initialAccount;
    final account = initial != null
        ? initial.copyWith(
            serverUrl: serverUrl,
            username: username,
            rootFolder: rootFolder,
            allowInsecureHttp: allowInsecureHttp,
          )
        : NextcloudAccount(
            id: 'nc_${DateTime.now().microsecondsSinceEpoch}',
            serverUrl: serverUrl,
            username: username,
            rootFolder: rootFolder,
            allowInsecureHttp: allowInsecureHttp,
            cacheLimitBytes: NextcloudAccount.defaultCacheLimitBytes,
          );

    Navigator.maybeOf(context)
        ?.pop<(NextcloudAccount, String?)>((account, newPassword));
  }
}
