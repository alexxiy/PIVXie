import 'package:flutter/material.dart';

import '../../../../app_config.dart';
import '../../../../themes/stack_colors.dart';
import '../../../../utilities/assets.dart';
import '../../../../utilities/text_styles.dart';
import '../../../../widgets/background.dart';
import '../../../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../../../widgets/rounded_white_container.dart';
import '../../sub_widgets/settings_list_button.dart';
import '../language_view.dart';
import 'theme_mode_view.dart';

/// Settings > Appearance: language and theme.
class AppearanceView extends StatelessWidget {
  const AppearanceView({super.key});

  static const routeName = "/appearance";

  @override
  Widget build(BuildContext context) {
    return Background(
      child: Scaffold(
        backgroundColor: Theme.of(context).extension<StackColors>()!.background,
        appBar: AppBar(
          leading: AppBarBackButton(
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text("Appearance", style: STextStyles.navBarTitle(context)),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                RoundedWhiteContainer(
                  padding: const EdgeInsets.all(4),
                  child: Column(
                    children: [
                      SettingsListButton(
                        iconAssetName: Assets.svg.language,
                        iconSize: 18,
                        title: "Language",
                        onPressed: () =>
                            Navigator.of(context)
                                .pushNamed(LanguageSettingsView.routeName),
                      ),
                      if (AppConfig.hasFeature(AppFeature.darkTheme)) ...[
                        const SizedBox(height: 8),
                        SettingsListButton(
                          iconAssetName: Assets.svg.sun,
                          iconSize: 18,
                          title: "Theme",
                          onPressed: () =>
                              Navigator.of(context)
                                  .pushNamed(ThemeModeView.routeName),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
