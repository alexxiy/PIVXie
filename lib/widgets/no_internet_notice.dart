import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../services/device_network.dart';
import '../themes/stack_colors.dart';
import '../utilities/text_styles.dart';
import '../utilities/util.dart';
import 'rounded_container.dart';

/// While the device has no network: what to turn on. Nothing otherwise.
class NoInternetNotice extends ConsumerWidget {
  const NoInternetNotice({super.key, this.padding = EdgeInsets.zero});

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(pDeviceNetwork.select((e) => e.online))) {
      return const SizedBox.shrink();
    }
    final colors = Theme.of(context).extension<StackColors>()!;
    return Padding(
      padding: padding,
      child: RoundedContainer(
        color: colors.warningBackground,
        child: Text(
          noInternetText(),
          style: STextStyles.baseXS(context)
              .copyWith(color: colors.warningForeground),
        ),
      ),
    );
  }
}

/// What to do without a network, on this device.
String noInternetText() =>
    Util.isDesktop ? l10n.netNoInternetDesktop : l10n.netNoInternetPhone;
