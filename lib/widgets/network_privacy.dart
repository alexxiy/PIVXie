import 'dart:async';

import 'package:event_bus/event_bus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../providers/global/prefs_provider.dart';
import '../services/event_bus/events/global/nym_connection_status_changed_event.dart';
import '../services/event_bus/events/global/tor_connection_status_changed_event.dart';
import '../services/event_bus/global_event_bus.dart';
import '../services/network_privacy.dart';
import '../themes/stack_colors.dart';
import '../utilities/assets.dart';
import '../utilities/text_styles.dart';
import '../utilities/util.dart';
import 'conditional_parent.dart';
import 'desktop/desktop_dialog.dart';
import 'desktop/primary_button.dart';
import 'desktop/secondary_button.dart';
import 'stack_dialog.dart';

/// Header icon: the onion for Tor, the mixnet mark for Nym and a globe
/// with a lock when both are off.
String networkIconAsset(PrivacyNetwork? network) => switch (network) {
  PrivacyNetwork.tor => Assets.svg.tor,
  PrivacyNetwork.nym => Assets.svg.nym,
  null => Assets.svg.networkPrivacy,
};

/// Grey when off, yellow while connecting, green when connected.
Color networkStatusColor(TorConnectionStatus status, StackColors colors) =>
    switch (status) {
      TorConnectionStatus.disconnected => colors.textSubtitle3,
      TorConnectionStatus.connecting => colors.accentColorYellow,
      TorConnectionStatus.connected => colors.accentColorGreen,
    };

/// "Tor connected", "Connecting to Nym", "Network privacy off", ...
String networkStatusText(PrivacyNetwork? network, TorConnectionStatus status) {
  if (network == null) return l10n.networkPrivacyOff;
  return switch (status) {
    TorConnectionStatus.connected => l10n.networkConnected(network.label),
    TorConnectionStatus.connecting => l10n.networkConnecting(network.label),
    TorConnectionStatus.disconnected => l10n.networkDisconnected(network.label),
  };
}

/// Rebuilds with a network's status as it changes. With [network] null,
/// that of the network that's on (null when Tor and Nym are off).
class NetworkStatusBuilder extends ConsumerStatefulWidget {
  const NetworkStatusBuilder({super.key, this.network, required this.builder});

  final PrivacyNetwork? network;
  final Widget Function(
    BuildContext context,
    PrivacyNetwork? network,
    TorConnectionStatus status,
  )
  builder;

  @override
  ConsumerState<NetworkStatusBuilder> createState() =>
      _NetworkStatusBuilderState();
}

class _NetworkStatusBuilderState extends ConsumerState<NetworkStatusBuilder> {
  final EventBus _bus = GlobalEventBus.instance;
  final List<StreamSubscription<Object>> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    void changed(Object _) {
      if (mounted) setState(() {});
    }

    _subscriptions
      ..add(_bus.on<TorConnectionStatusChangedEvent>().listen(changed))
      ..add(_bus.on<NymConnectionStatusChangedEvent>().listen(changed));
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = ref.watch(
      prefsChangeNotifierProvider.select(NetworkPrivacy.activeIn),
    );
    final network = widget.network ?? active;
    final status = network == null || !NetworkPrivacy.isAvailable(network)
        ? TorConnectionStatus.disconnected
        : NetworkPrivacy.statusOf(network);
    return widget.builder(context, network, status);
  }
}

/// Whether a tap is asking to switch networks, so taps meanwhile don't
/// ask again.
bool _confirming = false;

/// What a tap on [network] does at [status]: connect it (switching over
/// from the other one), cancel the connection, or disconnect it.
///
/// Returns once that's under way, not when connected: connecting can
/// take minutes, and a tap meanwhile has to cancel it.
Future<void> tapNetwork(
  WidgetRef ref,
  BuildContext context,
  PrivacyNetwork network,
  TorConnectionStatus status,
) async {
  switch (status) {
    case TorConnectionStatus.disconnected:
      if (_confirming) return;
      _confirming = true;
      try {
        await connectNetwork(ref, context, network);
      } finally {
        _confirming = false;
      }
    case TorConnectionStatus.connecting:
    case TorConnectionStatus.connected:
      await disconnectNetwork(ref, network);
  }
}

/// Turns [network] on. When the other one is on, asks first: only one
/// of them is on at a time. Returns once connecting has started; the
/// status shows how it goes.
Future<void> connectNetwork(
  WidgetRef ref,
  BuildContext context,
  PrivacyNetwork network,
) async {
  final prefs = ref.read(prefsChangeNotifierProvider);
  final other = NetworkPrivacy.activeIn(prefs);
  if (other != null && other != network) {
    final confirmed = await _confirmSwitch(context, from: other, to: network);
    if (confirmed != true) return;
  }
  // Logged when it fails; the status then shows it didn't connect.
  unawaited(NetworkPrivacy.turnOn(prefs, network).catchError((Object _) {}));
}

/// The button under a network's status: connect (or switch over to it),
/// a spinner while connecting that cancels on a tap, or disconnect.
class NetworkActionButton extends ConsumerWidget {
  const NetworkActionButton({
    super.key,
    required this.network,
    required this.status,
    this.width,
    this.buttonHeight,
  });

  final PrivacyNetwork network;
  final TorConnectionStatus status;
  final double? width;
  final ButtonHeight? buttonHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tor = network == PrivacyNetwork.tor;
    final active = ref.watch(
      prefsChangeNotifierProvider.select(NetworkPrivacy.activeIn),
    );
    final label = switch (status) {
      TorConnectionStatus.disconnected
          when active != null && active != network =>
        l10n.networkSwitchButton(network.label),
      TorConnectionStatus.disconnected =>
        tor ? l10n.torConnectTo : l10n.nymConnectTo,
      TorConnectionStatus.connecting => l10n.torConnectingTapToCancel,
      TorConnectionStatus.connected =>
        tor ? l10n.torDisconnectFrom : l10n.nymDisconnectFrom,
    };
    return SecondaryButton(
      label: label,
      width: width,
      buttonHeight: buttonHeight,
      icon: status == TorConnectionStatus.connecting
          ? SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Theme.of(context)
                    .extension<StackColors>()!
                    .buttonTextSecondary,
              ),
            )
          : null,
      onPressed: () => tapNetwork(ref, context, network, status),
    );
  }
}

/// Turns [network] off, also cancelling a connection in progress.
Future<void> disconnectNetwork(WidgetRef ref, PrivacyNetwork network) =>
    NetworkPrivacy.turnOff(ref.read(prefsChangeNotifierProvider), network);

Future<bool?> _confirmSwitch(
  BuildContext context, {
  required PrivacyNetwork from,
  required PrivacyNetwork to,
}) {
  final isDesktop = Util.isDesktop;
  return showDialog<bool>(
    context: context,
    builder: (context) => ConditionalParent(
      condition: isDesktop,
      builder: (child) => DesktopDialog(
        maxHeight: double.infinity,
        child: Padding(padding: const EdgeInsets.all(32), child: child),
      ),
      child: ConditionalParent(
        condition: !isDesktop,
        builder: (child) => StackDialogBase(child: child),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.networkSwitchTitle(to.label),
              style: isDesktop
                  ? STextStyles.desktopH3(context)
                  : STextStyles.pageTitleH2(context),
            ),
            SizedBox(height: isDesktop ? 16 : 8),
            Text(
              l10n.networkSwitchText(from.label, to.label),
              style: isDesktop
                  ? STextStyles.desktopTextSmall(context)
                  : STextStyles.smallMed14(context),
            ),
            SizedBox(height: isDesktop ? 32 : 20),
            Row(
              children: [
                Expanded(
                  child: SecondaryButton(
                    buttonHeight: isDesktop ? ButtonHeight.l : null,
                    label: l10n.commonCancel,
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                ),
                SizedBox(width: isDesktop ? 24 : 16),
                Expanded(
                  child: PrimaryButton(
                    buttonHeight: isDesktop ? ButtonHeight.l : null,
                    label: l10n.networkSwitchButton(to.label),
                    onPressed: () => Navigator.of(context).pop(true),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
