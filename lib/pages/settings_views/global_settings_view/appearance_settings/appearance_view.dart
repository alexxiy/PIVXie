import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app_config.dart';
import '../../../../l10n/l10n.dart';
import '../../../../providers/global/prefs_provider.dart';
import '../../../../themes/stack_colors.dart';
import '../../../../utilities/assets.dart';
import '../../../../utilities/text_styles.dart';
import '../../../../widgets/background.dart';
import '../../../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../../../widgets/custom_buttons/draggable_switch_button.dart';
import '../../../../widgets/rounded_white_container.dart';
import '../../sub_widgets/settings_list_button.dart';
import '../language_view.dart';
import 'theme_mode_view.dart';

/// Settings > Appearance: language, theme and sound effects.
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
          title: Text(
            l10n.settingsAppearance,
            style: STextStyles.navBarTitle(context),
          ),
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
                        title: l10n.languageTitle,
                        onPressed: () =>
                            Navigator.of(context)
                                .pushNamed(LanguageSettingsView.routeName),
                      ),
                      if (AppConfig.hasFeature(AppFeature.darkTheme)) ...[
                        const SizedBox(height: 8),
                        SettingsListButton(
                          iconAssetName: Assets.svg.sun,
                          iconSize: 18,
                          title: l10n.settingsTheme,
                          onPressed: () =>
                              Navigator.of(context)
                                  .pushNamed(ThemeModeView.routeName),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                RoundedWhiteContainer(
                  child: Consumer(
                    builder: (_, ref, __) => Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.appearanceSounds,
                                style: STextStyles.titleBold12(context),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                l10n.appearanceSoundsText,
                                style: STextStyles.itemSubtitle(context),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          height: 20,
                          width: 40,
                          child: DraggableSwitchButton(
                            key: const Key("soundEffectsSwitch"),
                            isOn: ref.watch(
                              prefsChangeNotifierProvider.select(
                                (value) => value.soundEffects,
                              ),
                            ),
                            onValueChanged: (on) =>
                                ref
                                        .read(prefsChangeNotifierProvider)
                                        .soundEffects =
                                    on,
                          ),
                        ),
                      ],
                    ),
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
