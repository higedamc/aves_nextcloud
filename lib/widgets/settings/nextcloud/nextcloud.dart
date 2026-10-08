import 'package:aves/model/settings/settings.dart';
import 'package:aves/theme/colors.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/settings/common/tile_leading.dart';
import 'package:aves/widgets/settings/common/tiles/sub_page.dart';
import 'package:aves/widgets/settings/nextcloud/accounts_page.dart';
import 'package:aves/widgets/settings/settings_definition.dart';
import 'package:aves_model/aves_model.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

class NextcloudSection extends SettingsSection {
  @override
  String get key => 'nextcloud';

  @override
  Widget icon(BuildContext context) => SettingsTileLeading(
    icon: AIcons.nextcloud,
    color: context.select<AvesColorsData, Color>((v) => v.nextcloud),
  );

  @override
  String title(BuildContext context) =>
      context.l10n.settingsNextcloudSectionTitle;

  @override
  Future<List<SettingsTile>> tiles(BuildContext context) async {
    return [SettingsTileNextcloudAccounts()];
  }
}

class SettingsTileNextcloudAccounts extends SettingsTile {
  // the accounts themselves are not individually editable settings, so there is nothing to highlight
  @override
  List<String> get settingKeys => [SettingKeys.nextcloudAccountsKey];

  @override
  String title(BuildContext context) => context.l10n.nextcloudAccountsTile;

  @override
  Widget build(BuildContext context) => SettingsSubPageTile(
    title: title,
    routeName: NextcloudAccountsPage.routeName,
    builder: (context) => const NextcloudAccountsPage(),
  );
}
