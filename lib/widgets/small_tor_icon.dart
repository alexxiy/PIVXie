import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../l10n/l10n.dart';
import '../pages/settings_views/global_settings_view/network_privacy/network_privacy_view.dart';
import '../themes/stack_colors.dart';
import 'custom_buttons/app_bar_icon_button.dart';
import 'network_privacy.dart';

/// The app bar button for Tor and Nym: its colour shows the status of the
/// one that's on (grey when both are off).
class SmallTorIcon extends StatelessWidget {
  const SmallTorIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return NetworkStatusBuilder(
      builder: (context, network, status) => AppBarIconButton(
        semanticsLabel: l10n.networkPrivacySemantics,
        key: const Key("walletsViewTorButton"),
        size: 36,
        shadows: const [],
        color: colors.backgroundAppBar,
        icon: SvgPicture.asset(
          networkIconAsset(network),
          color: networkStatusColor(status, colors),
          width: 20,
          height: 20,
        ),
        onPressed: () {
          Navigator.of(context).pushNamed(NetworkPrivacyView.routeName);
        },
      ),
    );
  }
}
