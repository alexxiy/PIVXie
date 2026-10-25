import 'dart:async';

import 'package:flutter/material.dart';

import '../services/event_bus/events/global/refresh_percent_changed_event.dart';
import '../services/event_bus/global_event_bus.dart';
import '../themes/stack_colors.dart';
import '../utilities/format.dart';
import '../utilities/text_styles.dart';
import '../utilities/util.dart';
import 'no_internet_notice.dart';

/// How far a wallet's sync, rescan or restore is: a bar and "42 %",
/// shown once the wallet reports progress. Without a network, what to turn
/// on.
class WalletSyncProgress extends StatefulWidget {
  const WalletSyncProgress({super.key, required this.walletId});

  final String walletId;

  @override
  State<WalletSyncProgress> createState() => _WalletSyncProgressState();
}

class _WalletSyncProgressState extends State<WalletSyncProgress> {
  late final StreamSubscription<RefreshPercentChangedEvent> _sub;
  double? _percent;

  @override
  void initState() {
    super.initState();
    _sub = GlobalEventBus.instance.on<RefreshPercentChangedEvent>().listen((
      event,
    ) {
      if (event.walletId == widget.walletId && mounted) {
        setState(() => _percent = event.percent.clamp(0.0, 1.0));
      }
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final percent = _percent;
    if (percent == null) return const NoInternetNotice();
    final colors = Theme.of(context).extension<StackColors>()!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: percent,
            minHeight: 6,
            backgroundColor: colors.textFieldDefaultBG,
            color: colors.accentColorBlue,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          Format.percent((percent * 100).floorToDouble(), decimals: 0),
          textAlign: TextAlign.right,
          style: Util.isDesktop
              ? STextStyles.desktopTextExtraExtraSmall(context)
              : STextStyles.label(context),
        ),
        const NoInternetNotice(padding: EdgeInsets.only(top: 8)),
      ],
    );
  }
}
