import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';

import '../app_config.dart';
import '../l10n/l10n.dart';
import '../pages_desktop_specific/password/create_password_view.dart';
import '../providers/global/prefs_provider.dart';
import '../providers/global/price_provider.dart';
import '../services/event_bus/events/global/tor_connection_status_changed_event.dart';
import '../services/network_privacy.dart';
import '../themes/stack_colors.dart';
import '../utilities/assets.dart';
import '../utilities/constants.dart';
import '../utilities/text_styles.dart';
import '../utilities/util.dart';
import '../widgets/adaptive_page.dart';
import '../widgets/conditional_parent.dart';
import '../widgets/custom_buttons/app_bar_icon_button.dart';
import '../widgets/desktop/desktop_app_bar.dart';
import '../widgets/desktop/desktop_scaffold.dart';
import '../widgets/desktop/primary_button.dart';
import '../widgets/nym_animation.dart';
import 'pinpad_views/create_pin_view.dart';

/// First start, after the experience: whether to mask the app's traffic
/// with Tor or Nym. Asked before the app connects to anything.
class NetworkChoiceView extends ConsumerStatefulWidget {
  const NetworkChoiceView({super.key});

  static const String routeName = "/networkChoice";

  @override
  ConsumerState<NetworkChoiceView> createState() => _NetworkChoiceViewState();
}

class _NetworkChoiceViewState extends ConsumerState<NetworkChoiceView> {
  final isDesktop = Util.isDesktop;

  /// Null: a direct connection. Incognito starts with Tor picked.
  late PrivacyNetwork? _choice =
      NetworkPrivacy.activeIn(ref.read(prefsChangeNotifierProvider)) ??
      (ref.read(prefsChangeNotifierProvider).externalCalls ||
              !NetworkPrivacy.isAvailable(PrivacyNetwork.tor)
          ? null
          : PrivacyNetwork.tor);

  void _continue() {
    final prefs = ref.read(prefsChangeNotifierProvider);
    final choice = _choice;
    if (choice != null) {
      // The setting changes at once; connecting goes on in the background.
      unawaited(NetworkPrivacy.turnOn(prefs, choice).catchError((_) {}));
    } else {
      for (final network in NetworkPrivacy.available) {
        unawaited(NetworkPrivacy.turnOff(prefs, network));
      }
    }
    if (prefs.externalCalls) {
      ref.read(priceAnd24hChangeNotifierProvider).start(true);
    }
    Navigator.of(context).pushNamed(
      isDesktop ? CreatePasswordView.routeName : CreatePinView.routeName,
    );
  }

  Widget _option({
    required PrivacyNetwork? network,
    required Widget icon,
    required String title,
    required String text,
  }) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final selected = _choice == network;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: RawMaterialButton(
        elevation: 0,
        fillColor: colors.popupBG,
        shape: RoundedRectangleBorder(
          side: selected
              ? BorderSide(color: colors.infoItemIcons, width: 2)
              : BorderSide.none,
          borderRadius: BorderRadius.circular(
            Constants.size.circularBorderRadius * 2,
          ),
        ),
        onPressed: () => setState(() => _choice = network),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              SizedBox.square(dimension: 40, child: Center(child: icon)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: isDesktop
                          ? STextStyles.desktopTextSmall(context)
                          : STextStyles.label700(context),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      text,
                      style: isDesktop
                          ? STextStyles.desktopTextExtraExtraSmall(context)
                          : STextStyles.label(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              selected
                  ? SvgPicture.asset(
                      Assets.svg.checkCircle,
                      width: 20,
                      height: 20,
                      color: colors.infoItemIcons,
                    )
                  : Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(1000),
                        color: colors.textFieldDefaultBG,
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return MasterScaffold(
      background: colors.background,
      isDesktop: isDesktop,
      appBar: isDesktop
          ? const DesktopAppBar(
              isCompactHeight: false,
              leading: AppBarBackButton(),
            )
          : AppBar(
              leading: AppBarBackButton(
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: isDesktop ? 480 : ScreenFit.columnWidth,
            ),
            child: ConditionalParent(
              condition: !isDesktop,
              builder: (child) => LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: IntrinsicHeight(child: child),
                  ),
                ),
              ),
              child: ConditionalParent(
                condition: isDesktop,
                builder: (child) => SingleChildScrollView(child: child),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: isDesktop ? 0 : 16),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        height: isDesktop || ScreenFit.short(context) ? 8 : 24,
                      ),
                      Text(
                        l10n.networkChooseTitle,
                        textAlign: TextAlign.center,
                        style: isDesktop
                            ? STextStyles.desktopH2(context)
                            : STextStyles.pageTitleH1(context),
                      ),
                      SizedBox(height: isDesktop ? 16 : 8),
                      Text(
                        l10n.networkChooseText(AppConfig.prefix),
                        textAlign: TextAlign.center,
                        style: isDesktop
                            ? STextStyles.desktopSubtitleH2(context)
                            : STextStyles.subtitle(context),
                      ),
                      SizedBox(height: isDesktop ? 32 : 24),
                      if (NetworkPrivacy.isAvailable(PrivacyNetwork.tor))
                        _option(
                          network: PrivacyNetwork.tor,
                          icon: SvgPicture.asset(
                            Assets.svg.circleTor,
                            width: 40,
                            height: 40,
                          ),
                          title: PrivacyNetwork.tor.label,
                          text: l10n.networkOptionTorText,
                        ),
                      if (NetworkPrivacy.isAvailable(PrivacyNetwork.nym))
                        _option(
                          network: PrivacyNetwork.nym,
                          icon: const NymAnimation(
                            size: 40,
                            status: TorConnectionStatus.connected,
                          ),
                          title: PrivacyNetwork.nym.label,
                          text: l10n.networkOptionNymText,
                        ),
                      _option(
                        network: null,
                        icon: SvgPicture.asset(
                          Assets.svg.network,
                          width: 24,
                          height: 24,
                          color: colors.textSubtitle1,
                        ),
                        title: l10n.networkOptionDirect,
                        text: l10n.networkOptionDirectText,
                      ),
                      if (!isDesktop) const Spacer(),
                      SizedBox(height: isDesktop ? 20 : 16),
                      Row(
                        children: [
                          Expanded(
                            child: PrimaryButton(
                              label: l10n.commonContinue,
                              onPressed: _continue,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: isDesktop ? kDesktopAppBarHeight : 16),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
