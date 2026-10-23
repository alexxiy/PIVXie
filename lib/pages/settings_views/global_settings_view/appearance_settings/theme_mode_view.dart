import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/l10n.dart';
import '../../../../providers/global/prefs_provider.dart';
import '../../../../themes/stack_colors.dart';
import '../../../../themes/theme_providers.dart';
import '../../../../themes/theme_service.dart';
import '../../../../utilities/text_styles.dart';
import '../../../../widgets/background.dart';
import '../../../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../../../widgets/rounded_white_container.dart';

enum AppThemeMode { system, light, dark }

AppThemeMode currentThemeMode(WidgetRef ref) {
  final prefs = ref.watch(prefsChangeNotifierProvider);
  if (prefs.enableSystemBrightness) return AppThemeMode.system;
  return prefs.themeId == "dark" ? AppThemeMode.dark : AppThemeMode.light;
}

void setThemeMode(BuildContext context, WidgetRef ref, AppThemeMode mode) {
  final prefs = ref.read(prefsChangeNotifierProvider);
  final String themeId;
  switch (mode) {
    case AppThemeMode.system:
      prefs.systemBrightnessLightThemeId = "light";
      prefs.systemBrightnessDarkThemeId = "dark";
      prefs.enableSystemBrightness = true;
      themeId = MediaQuery.platformBrightnessOf(context) == Brightness.dark
          ? "dark"
          : "light";
    case AppThemeMode.light:
      prefs.enableSystemBrightness = false;
      prefs.themeId = themeId = "light";
    case AppThemeMode.dark:
      prefs.enableSystemBrightness = false;
      prefs.themeId = themeId = "dark";
  }
  final theme = ref.read(pThemeService).getTheme(themeId: themeId);
  if (theme != null) ref.read(themeProvider.notifier).state = theme;
}

/// Show the theme the preferences ask for, e.g. after restoring a backup
/// changed them.
void applyThemePrefs(BuildContext context, WidgetRef ref) {
  final prefs = ref.read(prefsChangeNotifierProvider);
  final themeId = !prefs.enableSystemBrightness
      ? prefs.themeId
      : MediaQuery.platformBrightnessOf(context) == Brightness.dark
      ? prefs.systemBrightnessDarkThemeId
      : prefs.systemBrightnessLightThemeId;
  final theme = ref.read(pThemeService).getTheme(themeId: themeId);
  if (theme != null) ref.read(themeProvider.notifier).state = theme;
}

/// Title and subtitle of each [AppThemeMode].
Map<AppThemeMode, (String, String)> get kThemeModeTexts => {
  AppThemeMode.system: (l10n.themeSystem, l10n.themeSystemText),
  AppThemeMode.light: (l10n.themeLight, l10n.themeLightText),
  AppThemeMode.dark: (l10n.themeDark, l10n.themeDarkText),
};

/// Light / Dark / follow the system, for apps that ship both default
/// themes but no theme store ([AppFeature.darkTheme]).
class ThemeModeView extends ConsumerWidget {
  const ThemeModeView({super.key});

  static const routeName = "/themeMode";

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final current = currentThemeMode(ref);

    Widget option(AppThemeMode mode) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () => setThemeMode(context, ref, mode),
        child: RoundedWhiteContainer(
          child: Row(
            children: [
              Radio<AppThemeMode>(
                value: mode,
                groupValue: current,
                activeColor: colors.radioButtonIconEnabled,
                onChanged: (_) => setThemeMode(context, ref, mode),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      kThemeModeTexts[mode]!.$1,
                      style: STextStyles.titleBold12(context),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      kThemeModeTexts[mode]!.$2,
                      style: STextStyles.itemSubtitle(context),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          leading: AppBarBackButton(
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(
            l10n.settingsTheme,
            style: STextStyles.navBarTitle(context),
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [for (final mode in AppThemeMode.values) option(mode)],
            ),
          ),
        ),
      ),
    );
  }
}
