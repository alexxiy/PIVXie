import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:tuple/tuple.dart';

import '../../app_config.dart';
import '../../l10n/l10n.dart';
import '../../models/isar/models/contact_entry.dart';
import '../../models/send_view_auto_fill_data.dart';
import '../../notifications/show_flush_bar.dart';
import '../../pages_desktop_specific/desktop_menu.dart';
import '../../pages_desktop_specific/my_stack_view/my_stack_view.dart';
import '../../pages_desktop_specific/my_stack_view/wallet_view/desktop_wallet_view.dart';
import '../../providers/desktop/current_desktop_menu_item.dart';
import '../../providers/global/active_wallet_provider.dart';
import '../../providers/providers.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/address_utils.dart';
import '../../utilities/contact_address_title.dart';
import '../../utilities/logger.dart';
import '../../utilities/show_loading.dart';
import '../../utilities/show_node_tor_settings_mismatch.dart';
import '../../utilities/text_styles.dart';
import '../../utilities/util.dart';
import '../../wallets/crypto_currency/coins/pivx.dart';
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
    warn(l10n.paymentLinkNoAddress);
    return null;
  }

  final wallets = [
    for (final w in ref.read(pWallets).wallets)
      if (w.info.coin == coin &&
          !(w is ViewOnlyOptionInterface && w.isViewOnly))
        w,
  ];
  if (wallets.isEmpty) {
    warn(l10n.paymentLinkNoWallet(coin.prettyName));
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
      : await _chooseWallet(context, wallets, desktop: false);
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
      warn(l10n.paymentLinkCloseWallet);
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
    message: l10n.walletOpening(wallet.info.name),
  );
  if (!context.mounted) return;
  unawaited(nav.pushNamed(WalletView.routeName, arguments: walletId));
  unawaited(nav.pushNamed(SendView.routeName, arguments: sendArgs));
}

/// Desktop: open the Send tab of a wallet for [link], filled in as if the
/// link was pasted there. [context] is the desktop home's, [nav] the
/// navigator of My Wallets.
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
      : await _chooseWallet(context, wallets, desktop: true);
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

/// "Pay to {name}" for a one-line button: a long contact name is cut, as
/// the buttons don't wrap or shrink their label.
String payContactLabel(ContactEntry contact) {
  final name = contact.name.characters;
  return l10n.paymentPayTo(
    name.length > 20 ? "${name.take(19)}…" : contact.name,
  );
}

/// Pay a contact: one of its addresses (asked when it has several) opens
/// the send screen of a wallet that can pay it. On mobile with a wallet
/// open, that's its send screen on top, as the contact's send button
/// does; otherwise as a pivx: link would.
Future<void> payContact(
  BuildContext context,
  WidgetRef ref,
  ContactEntry contact,
) async {
  final active = Util.isDesktop ? null : ref.read(currentWalletIdProvider);
  final activeWallet = active == null
      ? null
      : ref.read(pWallets).getWallet(active);
  final payFromActive =
      activeWallet != null &&
      !(activeWallet is ViewOnlyOptionInterface && activeWallet.isViewOnly);
  final addresses = [
    for (final a in contact.addressesSorted)
      if (!payFromActive || a.coin == activeWallet.info.coin) a,
  ];
  if (addresses.isEmpty) return;
  final entry = addresses.length == 1
      ? addresses.first
      : await _chooseOne<ContactAddressEntry>(
          context,
          title: l10n.paymentPayTo(contact.name),
          desktop: Util.isDesktop,
          options: [
            for (final a in addresses)
              (
                label: a.address,
                detail: switch (a.coin) {
                  final Pivx pivx =>
                    pivx.isShieldAddress(a.address)
                        ? "${l10n.addressKindShielded} (${pivx.ticker})"
                        : "${l10n.addressKindTransparent} (${pivx.ticker})",
                  final coin => coin.prettyName,
                },
                value: a,
              ),
          ],
        );
  if (entry == null || !context.mounted) return;
  if (payFromActive) {
    unawaited(
      Navigator.of(context).pushNamed(
        SendView.routeName,
        arguments: Tuple3(
          activeWallet.walletId,
          activeWallet.info.coin,
          SendViewAutoFillData(
            address: entry.address,
            contactLabel: "${contact.name} (${entry.kind})",
          ),
        ),
      ),
    );
    return;
  }
  // The wallet list handles it (HomeView, DesktopHomeView).
  ref.read(pPendingPaymentLink.notifier).state = "pivx:${entry.address}";
}

Future<String?> _chooseWallet(
  BuildContext context,
  List<Wallet> wallets, {
  required bool desktop,
}) => _chooseOne<String>(
  context,
  title: l10n.paymentPayFrom,
  desktop: desktop,
  options: [
    for (final w in wallets)
      (label: w.info.name, detail: null, value: w.walletId),
  ],
);

/// A titled list to pick one option from: a dialog on desktop, a bottom
/// sheet on mobile.
Future<T?> _chooseOne<T>(
  BuildContext context, {
  required String title,
  required bool desktop,
  required List<({String label, String? detail, T value})> options,
}) {
  final colors = Theme.of(context).extension<StackColors>()!;
  Widget option(
    BuildContext context,
    ({String label, String? detail, T value}) o,
  ) => RoundedWhiteContainer(
    borderColor: desktop ? colors.textFieldDefaultBG : null,
    onPressed: () => Navigator.of(context).pop(o.value),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          o.label,
          style: desktop
              ? STextStyles.desktopTextExtraSmall(context)
                    .copyWith(color: colors.textDark)
              : STextStyles.titleBold12(context),
        ),
        if (o.detail != null)
          Text(
            o.detail!,
            style: desktop
                ? STextStyles.desktopTextExtraExtraSmall(context)
                : STextStyles.itemSubtitle(context),
          ),
      ],
    ),
  );

  if (desktop) {
    return showDialog<T>(
      context: context,
      // Up to the screen's height; the options scroll beyond it.
      builder: (context) => DesktopDialog(
        maxWidth: 450,
        maxHeight: null,
        child: Padding(
          padding: const EdgeInsets.only(left: 32, bottom: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(title, style: STextStyles.desktopH3(context)),
                  const DesktopDialogCloseButton(),
                ],
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(right: 32),
                  children: [
                    for (final o in options)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: option(context, o),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: colors.popupBG,
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
            Text(title, style: STextStyles.pageTitleH2(context)),
            const SizedBox(height: 16),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final o in options)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: option(context, o),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
