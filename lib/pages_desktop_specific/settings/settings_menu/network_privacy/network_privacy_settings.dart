import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../l10n/l10n.dart';
import '../../../../providers/global/prefs_provider.dart';
import '../../../../services/event_bus/events/global/tor_connection_status_changed_event.dart';
import '../../../../services/network_privacy.dart';
import '../../../../themes/stack_colors.dart';
import '../../../../utilities/assets.dart';
import '../../../../utilities/text_styles.dart';
import '../../../../widgets/desktop/desktop_dialog.dart';
import '../../../../widgets/desktop/desktop_dialog_close_button.dart';
import '../../../../widgets/desktop/secondary_button.dart';
import '../../../../widgets/network_privacy.dart';
import '../../../../widgets/nym_animation.dart';
import '../../../../widgets/rounded_white_container.dart';
import '../../../../widgets/status_chip.dart';

/// Desktop settings: a card for Tor and one for Nym; only one is on.
class NetworkPrivacySettings extends StatelessWidget {
  const NetworkPrivacySettings({super.key});

  static const String routeName = "/networkPrivacyDesktopSettings";

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          for (final network in NetworkPrivacy.available)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 30, bottom: 16),
              child: _NetworkCard(network: network),
            ),
        ],
      ),
    );
  }
}

class _NetworkCard extends ConsumerStatefulWidget {
  const _NetworkCard({required this.network});

  final PrivacyNetwork network;

  @override
  ConsumerState<_NetworkCard> createState() => _NetworkCardState();
}

class _NetworkCardState extends ConsumerState<_NetworkCard> {
  bool get _tor => widget.network == PrivacyNetwork.tor;

  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    _busy = true;
    try {
      await action();
    } finally {
      _busy = false;
    }
  }

  /// With the other network on, connecting this one switches over.
  String get _connectLabel {
    final active = ref.watch(
      prefsChangeNotifierProvider.select(NetworkPrivacy.activeIn),
    );
    if (active != null && active != widget.network) {
      return l10n.networkSwitchButton(widget.network.label);
    }
    return _tor ? l10n.torConnectTo : l10n.nymConnectTo;
  }

  Widget _button(TorConnectionStatus status) => switch (status) {
    TorConnectionStatus.disconnected => SecondaryButton(
      label: _connectLabel,
      width: 200,
      buttonHeight: ButtonHeight.m,
      onPressed: () => _run(() => connectNetwork(ref, context, widget.network)),
    ),
    // A click cancels.
    TorConnectionStatus.connecting => SecondaryButton(
      label: l10n.torConnectingTapToCancel,
      width: 200,
      buttonHeight: ButtonHeight.m,
      onPressed: () => _run(() => disconnectNetwork(ref, widget.network)),
    ),
    TorConnectionStatus.connected => SecondaryButton(
      label: _tor ? l10n.torDisconnectFrom : l10n.nymDisconnectFrom,
      width: 200,
      buttonHeight: ButtonHeight.m,
      onPressed: () => _run(() => disconnectNetwork(ref, widget.network)),
    ),
  };

  void _showWhatIs() {
    showDialog<dynamic>(
      context: context,
      useSafeArea: false,
      barrierDismissible: true,
      builder: (context) => DesktopDialog(
        maxWidth: 580,
        maxHeight: double.infinity,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(
            top: 10,
            start: 20,
            bottom: 20,
            end: 10,
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _tor ? l10n.torWhatIs : l10n.nymWhatIs,
                    style: STextStyles.desktopH2(context),
                  ),
                  DesktopDialogCloseButton(
                    onPressedOverride: () => Navigator.of(context).pop(true),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                _tor ? l10n.torWhatIsText : l10n.nymWhatIsText,
                style: STextStyles.desktopTextMedium(context).copyWith(
                  color: Theme.of(context).extension<StackColors>()!.textDark3,
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
    return NetworkStatusBuilder(
      network: widget.network,
      builder: (context, _, status) => RoundedWhiteContainer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: _tor
                      ? SvgPicture.asset(
                          Assets.svg.circleTor,
                          width: 48,
                          height: 48,
                        )
                      : NymAnimation(size: 48, status: status),
                ),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: _StatusChip(status: status),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.network.label,
                    style: STextStyles.desktopTextSmall(context),
                  ),
                  RichText(
                    textAlign: TextAlign.start,
                    text: TextSpan(
                      children: [
                        TextSpan(
                          text:
                              "\n${_tor ? l10n.torOneClick : l10n.nymOneClick}",
                          style: STextStyles.desktopTextExtraExtraSmall(
                            context,
                          ),
                        ),
                        TextSpan(
                          text: "\t${_tor ? l10n.torWhatIs : l10n.nymWhatIs}",
                          style: STextStyles.richLink(context)
                              .copyWith(fontSize: 14),
                          recognizer: TapGestureRecognizer()
                            ..onTap = _showWhatIs,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.all(10.0),
              child: _button(status),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.all(10.0),
              child: Text(
                _tor ? l10n.torOnlyText : l10n.nymOnlyText,
                style: STextStyles.desktopTextExtraExtraSmall(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The status as a small label.
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final TorConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final (text, color) = switch (status) {
      TorConnectionStatus.connected => (
        l10n.commonConnected,
        colors.accentColorGreen,
      ),
      TorConnectionStatus.connecting => (
        l10n.commonConnecting,
        colors.accentColorYellow,
      ),
      TorConnectionStatus.disconnected => (
        l10n.commonDisconnected,
        colors.textSubtitle1,
      ),
    };
    return StatusChip(text: text, color: color);
  }
}
