import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../app_config.dart';
import '../../notifications/show_flush_bar.dart';
import '../../pages_desktop_specific/desktop_menu.dart';
import '../../pages_desktop_specific/my_stack_view/my_stack_view.dart';
import '../../pages_desktop_specific/my_stack_view/wallet_view/desktop_wallet_view.dart';
import '../../providers/desktop/current_desktop_menu_item.dart';
import '../../providers/global/active_wallet_provider.dart';
import '../../providers/providers.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/address_utils.dart';
import '../../utilities/logger.dart';
import '../../utilities/show_loading.dart';
import '../../utilities/show_node_tor_settings_mismatch.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/crypto_currency/crypto_currency.dart';
import '../../wallets/wallet/wallet.dart';
import '../../wallets/wallet/wallet_mixin_interfaces/view_only_option_interface.dart';
import '../../widgets/desktop/desktop_dialog.dart';
import '../../widgets/desktop/desktop_dialog_close_button.dart';
import '../../widgets/rounded_white_container.dart';
import '../send_view/send_view.dart';
import '../wallet_view/wallet_view.dart';
import 'home_view.dart';

/// A pivx: payment link opened from another app (e.g. a QR code scanned
/// with the camera, or a link clicked in a browser), waiting for the
/// unlocked wallet list ([HomeView], or DesktopHomeView) to handle it.
final pPendingPaymentLink = StateProvider<String?>((_) => null);

/// Desktop: the payment for the send form of a wallet to fill in. The
/// wallet's send/receive panel (MyWallet) opens a fresh send form
/// (DesktopSend), which takes it.
final pDesktopPaymentLink =
    StateProvider<({String walletId, PaymentUriData data})?>((_) => null);

/// Catch pivx: links, including the one the app was started with.
StreamSubscription<String>? listenForPaymentLinks(WidgetRef ref) {
  if (kIsWeb) return null;
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

/// The coin and the wallets that can pay [link]; null after telling why
/// not.
({PaymentUriData data, CryptoCurrency coin, List<Wallet> wallets})?
_paymentLinkWallets(BuildContext context, WidgetRef ref, String link) {
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
    return null;
  }

  final wallets = [
    for (final w in ref.read(pWallets).wallets)
      if (w.info.coin == coin &&
          !(w is ViewOnlyOptionInterface && w.isViewOnly))
        w,
  ];
  if (wallets.isEmpty) {
    warn("No ${coin.prettyName} wallet to pay from");
    return null;
  }
  return (data: data, coin: coin, wallets: wallets);
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

  final found = _paymentLinkWallets(context, ref, link);
  if (found == null) return;
  final (:data, :coin, :wallets) = found;
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

/// Desktop: open the Send tab of a wallet for [link], filled in as if the
/// link was pasted there. [context] is the desktop home's, [nav] the
/// navigator of My PIVXie.
Future<void> openPaymentLinkDesktop(
  BuildContext context,
  WidgetRef ref,
  NavigatorState nav,
  String link,
) async {
  final found = _paymentLinkWallets(context, ref, link);
  if (found == null) return;
  final (:data, coin: _, :wallets) = found;
  final walletId = wallets.length == 1
      ? wallets.first.walletId
      : await _chooseWalletDesktop(context, wallets);
  if (walletId == null || !context.mounted) return;

  ref.read(prevDesktopMenuItemProvider.notifier).state =
      DesktopMenuItemId.myStack;
  ref.read(currentDesktopMenuItemProvider.notifier).state =
      DesktopMenuItemId.myStack;

  final open = ref.read(currentWalletIdProvider);
  if (open == walletId) {
    nav.popUntil(
      (r) =>
          r.settings.name == DesktopWalletView.routeName ||
          r.settings.name == MyStackView.routeName,
    );
    ref.read(pDesktopPaymentLink.notifier).state = (
      walletId: walletId,
      data: data,
    );
    return;
  }

  nav.popUntil(ModalRoute.withName(MyStackView.routeName));
  if (open != null) await closeDesktopWallet(ref, open);
  if (!context.mounted) return;

  await openDesktopWallet(
    context,
    ref,
    nav,
    walletId,
    beforePush: () => ref.read(pDesktopPaymentLink.notifier).state = (
      walletId: walletId,
      data: data,
    ),
  );
}

Future<String?> _chooseWalletDesktop(
  BuildContext context,
  List<Wallet> wallets,
) => showDialog<String>(
  context: context,
  builder: (context) => DesktopDialog(
    maxWidth: 450,
    maxHeight: double.infinity,
    child: Padding(
      padding: const EdgeInsets.only(left: 32, bottom: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text("Pay from", style: STextStyles.desktopH3(context)),
              const DesktopDialogCloseButton(),
            ],
          ),
          const SizedBox(height: 12),
          for (final w in wallets)
            Padding(
              padding: const EdgeInsets.only(right: 32, bottom: 8),
              child: RoundedWhiteContainer(
                borderColor: Theme.of(context)
                    .extension<StackColors>()!
                    .textFieldDefaultBG,
                onPressed: () => Navigator.of(context).pop(w.walletId),
                child: Text(
                  w.info.name,
                  style: STextStyles.desktopTextExtraSmall(context).copyWith(
                    color: Theme.of(context).extension<StackColors>()!.textDark,
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  ),
);

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
