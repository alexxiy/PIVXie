import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../notifications/show_flush_bar.dart';
import '../../pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_auth_send.dart';
import '../../route_generator.dart';
import '../../utilities/util.dart';
import '../../wallets/crypto_currency/crypto_currency.dart';
import '../../widgets/desktop/desktop_dialog.dart';
import '../../widgets/desktop/desktop_dialog_close_button.dart';
import 'lock_screen_view.dart';

/// Asks the user to prove it's them before something sensitive (showing a
/// private key): the PIN or biometrics on mobile, the password on
/// desktop. [title] heads the request, [reason] says what it unlocks.
/// True once they did; a wrong password is reported, cancelling isn't.
Future<bool> authenticateUser(
  BuildContext context, {
  required CryptoCurrency coin,
  required String title,
  required String reason,
}) async {
  final bool? unlocked;
  if (Util.isDesktop) {
    unlocked = await showDialog<bool?>(
      context: context,
      builder: (context) => DesktopDialog(
        maxWidth: 580,
        maxHeight: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [DesktopDialogCloseButton()],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 32, right: 32, bottom: 32),
              child: DesktopAuthSend(coin: coin, title: title, message: reason),
            ),
          ],
        ),
      ),
    );
  } else {
    unlocked = await Navigator.push<bool>(
      context,
      RouteGenerator.getRoute<bool>(
        shouldUseMaterialRoute: RouteGenerator.useMaterialPageRoute,
        builder: (_) => LockscreenView(
          showBackButton: true,
          popOnSuccess: true,
          routeOnSuccessArguments: true,
          routeOnSuccess: "",
          biometricsCancelButtonString: l10n.commonCancelCaps,
          biometricsLocalizedReason: reason,
          biometricsAuthenticationTitle: title,
        ),
        settings: const RouteSettings(name: "/authenticateUserLockscreen"),
      ),
    );
  }
  if (unlocked == false && context.mounted) {
    unawaited(
      showFloatingFlushBar(
        type: FlushBarType.warning,
        message: l10n.pinWrongPassword,
        context: context,
      ),
    );
  }
  return unlocked == true;
}
