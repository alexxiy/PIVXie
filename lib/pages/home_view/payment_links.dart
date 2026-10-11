import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../app_config.dart';
import '../../notifications/show_flush_bar.dart';
import '../../providers/global/active_wallet_provider.dart';
import '../../providers/providers.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/address_utils.dart';
import '../../utilities/logger.dart';
import '../../utilities/show_loading.dart';
import '../../utilities/show_node_tor_settings_mismatch.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/wallet/wallet.dart';
import '../../wallets/wallet/wallet_mixin_interfaces/view_only_option_interface.dart';
import '../../widgets/rounded_white_container.dart';
import '../send_view/send_view.dart';
import '../wallet_view/wallet_view.dart';
import 'home_view.dart';

/// A pivx: payment link opened from another app (e.g. a QR code scanned
/// with the camera), waiting for the unlocked wallet list ([HomeView]) to
/// handle it.
final pPendingPaymentLink = StateProvider<String?>((_) => null);

/// Catch pivx: links, including the one the app was started with.
StreamSubscription<String>? listenForPaymentLinks(WidgetRef ref) {
  if (!Platform.isAndroid && !Platform.isIOS) return null;
  return AppLinks().stringLinkStream.listen(
    (link) {
      if (link.toLowerCase().startsWith("pivx:")) {
        ref.read(pPendingPaymentLink.notifier).state = link;
      }
    },
    onError: (Object e, StackTrace s) =>
        Logging.instance.w("Payment link failed", error: e, stackTrace: s),
  );
}

/// Open the send screen of a wallet for [link], as if its QR code was
/// scanned there. [context] is the wallet list's.
Future<void> openPaymentLink(
  BuildContext context,
  WidgetRef ref,
  String link,
) async {
  void warn(String message) => unawaited(
    showFloatingFlushBar(
      type: FlushBarType.warning,
      message: message,
      context: context,
    ),
  );

  final data = AddressUtils.parsePaymentUri(link, logging: Logging.instance);
  final address = data?.address ?? "";
  final coin = address.isEmpty
      ? null
      : AppConfig.coins.where((c) => c.validateAddress(address)).firstOrNull;
  if (data == null || coin == null) {
    warn("The payment link has no valid PIVX address");
    return;
  }

  final wallets = [
    for (final w in ref.read(pWallets).wallets)
      if (w.info.coin == coin &&
          !(w is ViewOnlyOptionInterface && w.isViewOnly))
        w,
  ];
  if (wallets.isEmpty) {
    warn("No ${coin.prettyName} wallet to pay from");
    return;
  }
  final walletId = wallets.length == 1
      ? wallets.first.walletId
      : await _chooseWallet(context, wallets);
  if (walletId == null || !context.mounted) return;

  final nav = Navigator.of(context);
  final sendArgs = (coin: coin, walletId: walletId, paymentUri: data);

  final open = ref.read(currentWalletIdProvider);
  if (open != null) {
    nav.popUntil(
      (r) =>
          r.settings.name == WalletView.routeName ||
          r.settings.name == HomeView.routeName,
    );
    if (open == walletId) {
      unawaited(nav.pushNamed(SendView.routeName, arguments: sendArgs));
      return;
    }
    // Leave the other wallet as its back button does: that closes it or
    // keeps it syncing, per the syncing preferences.
    await nav.maybePop();
    if (ref.read(currentWalletIdProvider) != null) {
      warn("Close the open wallet first");
      return;
    }
  }
  if (!context.mounted) return;
  nav.popUntil(ModalRoute.withName(HomeView.routeName));

  final wallet = ref.read(pWallets).getWallet(walletId);
  final canContinue = await checkShowNodeTorSettingsMismatch(
    context: context,
    currency: wallet.cryptoCurrency,
    prefs: ref.read(prefsChangeNotifierProvider),
    nodeService: ref.read(nodeServiceChangeNotifierProvider),
    allowCancel: true,
    rootNavigator: false,
  );
  if (!canContinue || !context.mounted) return;
  await showLoading(
    whileFuture: wallet.init(),
    context: context,
    message: "Opening ${wallet.info.name}",
  );
  if (!context.mounted) return;
  unawaited(nav.pushNamed(WalletView.routeName, arguments: walletId));
  unawaited(nav.pushNamed(SendView.routeName, arguments: sendArgs));
}

Future<String?> _chooseWallet(BuildContext context, List<Wallet> wallets) =>
    showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).extension<StackColors>()!.popupBG,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text("Pay from", style: STextStyles.pageTitleH2(context)),
              const SizedBox(height: 16),
              for (final w in wallets)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: RoundedWhiteContainer(
                    onPressed: () => Navigator.of(context).pop(w.walletId),
                    child: Text(
                      w.info.name,
                      style: STextStyles.titleBold12(context),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
