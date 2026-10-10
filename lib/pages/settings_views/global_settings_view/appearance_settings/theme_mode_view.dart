import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../providers/global/prefs_provider.dart';
import '../../../../themes/stack_colors.dart';
import '../../../../themes/theme_providers.dart';
import '../../../../themes/theme_service.dart';
import '../../../../utilities/text_styles.dart';
import '../../../../widgets/background.dart';
import '../../../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../../../widgets/rounded_white_container.dart';

enum _ThemeMode { system, light, dark }

/// Light / Dark / follow the system, for apps that ship both default
/// themes but no theme store ([AppFeature.darkTheme]).
class ThemeModeView extends ConsumerWidget {
  const ThemeModeView({super.key});

  static const routeName = "/themeMode";

  _ThemeMode _current(WidgetRef ref) {
    final prefs = ref.watch(prefsChangeNotifierProvider);
    if (prefs.enableSystemBrightness) return _ThemeMode.system;
    return prefs.themeId == "dark" ? _ThemeMode.dark : _ThemeMode.light;
  }

  void _select(BuildContext context, WidgetRef ref, _ThemeMode mode) {
    final prefs = ref.read(prefsChangeNotifierProvider);
    final String themeId;
    switch (mode) {
      case _ThemeMode.system:
        prefs.systemBrightnessLightThemeId = "light";
        prefs.systemBrightnessDarkThemeId = "dark";
        prefs.enableSystemBrightness = true;
        themeId = MediaQuery.platformBrightnessOf(context) == Brightness.dark
            ? "dark"
            : "light";
      case _ThemeMode.light:
        prefs.enableSystemBrightness = false;
        prefs.themeId = themeId = "light";
      case _ThemeMode.dark:
        prefs.enableSystemBrightness = false;
        prefs.themeId = themeId = "dark";
    }
    final theme = ref.read(pThemeService).getTheme(themeId: themeId);
    if (theme != null) ref.read(themeProvider.notifier).state = theme;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final current = _current(ref);

    Widget option(_ThemeMode mode, String title, String subtitle) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () => _select(context, ref, mode),
        child: RoundedWhiteContainer(
          child: Row(
            children: [
              Radio<_ThemeMode>(
                value: mode,
                groupValue: current,
                activeColor: colors.radioButtonIconEnabled,
                onChanged: (_) => _select(context, ref, mode),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: STextStyles.titleBold12(context)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: STextStyles.itemSubtitle(context)),
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
          title: Text("Appearance", style: STextStyles.navBarTitle(context)),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              option(
                _ThemeMode.system,
                "System default",
                "Follow the phone's light or dark mode",
              ),
              option(_ThemeMode.light, "Light", "Always light"),
              option(_ThemeMode.dark, "Dark", "Always dark"),
            ],
          ),
        ),
      ),
    );
  }
}
