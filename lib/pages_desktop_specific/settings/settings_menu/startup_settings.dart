import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app_config.dart';
import '../../../providers/global/prefs_provider.dart';
import '../../../providers/global/wallets_provider.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../widgets/rounded_white_container.dart';

/// Desktop: what opens after unlocking, the wallet list or one wallet
/// (the mobile startup preferences).
class StartupSettings extends ConsumerWidget {
  const StartupSettings({super.key});

  static const String routeName = "/settingsMenuStartup";

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    debugPrint("BUILD: $runtimeType");
    final colors = Theme.of(context).extension<StackColors>()!;
    final prefs = ref.watch(prefsChangeNotifierProvider);
    final wallets = ref.watch(pWallets).wallets.toList();
    final startupWalletId =
        wallets.any((w) => w.walletId == prefs.startupWalletId)
        ? prefs.startupWalletId
        : null;
    final gotoWallet = prefs.gotoWalletOnStartup && startupWalletId != null;

    void openWallet(String? walletId) {
      prefs.startupWalletId = walletId;
      prefs.gotoWalletOnStartup = walletId != null;
    }

    Widget option({
      required String? value,
      required String title,
      String? subtitle,
    }) => RadioListTile<String?>(
      value: value,
      dense: true,
      contentPadding: EdgeInsets.zero,
      activeColor: colors.radioButtonIconEnabled,
      title: Text(
        title,
        style: STextStyles.desktopTextExtraSmall(context)
            .copyWith(color: colors.textDark),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: STextStyles.desktopTextExtraExtraSmall(context),
            ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 30),
          child: RoundedWhiteContainer(
            radiusMultiplier: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: const BoxDecoration(
                      color: Color(0xFFE0E3E3),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.power_settings_new_rounded,
                      size: 26,
                      color: Color(0xFF232323),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Startup",
                        style: STextStyles.desktopTextSmall(context),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        "Choose what opens after you unlock "
                        "${AppConfig.appName}.",
                        style: STextStyles.desktopTextExtraExtraSmall(context),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: 512,
                        child: RadioGroup<String?>(
                          groupValue: gotoWallet ? startupWalletId : null,
                          onChanged: openWallet,
                          child: Column(
                            children: [
                              option(
                                value: null,
                                title: "My Wallets",
                                subtitle: "The list of your wallets",
                              ),
                              for (final w in wallets)
                                option(
                                  value: w.walletId,
                                  title: w.info.name,
                                  subtitle: "Open this wallet",
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
