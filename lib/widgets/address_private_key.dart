import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../models/isar/models/isar_models.dart';
import '../pages/pinpad_views/pinpad_dialog.dart';
import '../pages_desktop_specific/password/request_desktop_auth_dialog.dart';
import '../providers/global/wallets_provider.dart';
import '../utilities/show_loading.dart';
import '../utilities/text_styles.dart';
import '../utilities/util.dart';
import '../wallets/wallet/intermediate/bip39_hd_wallet.dart';
import 'custom_buttons/blue_text_button.dart';
import 'detail_item.dart';
import 'secret_screen.dart';

class AddressPrivateKey extends ConsumerStatefulWidget {
  /// The [walletId] MUST be the id of a [Bip39HDWallet]!
  const AddressPrivateKey({
    super.key,
    required this.walletId,
    required this.address,
  });

  final String walletId;
  final Address address;

  @override
  ConsumerState<AddressPrivateKey> createState() => _AddressPrivateKeyState();
}

class _AddressPrivateKeyState extends ConsumerState<AddressPrivateKey> {
  String? _private;

  bool _lock = false;

  Future<void> _loadPrivKey() async {
    // sanity check that should never actually fail in practice.
    // Big problems if it actually does though so we check and crash if it fails.
    assert(widget.walletId == widget.address.walletId);

    if (_lock) {
      return;
    }
    _lock = true;

    try {
      final verified = await showDialog<String?>(
        context: context,
        builder: (context) => Util.isDesktop
            ? RequestDesktopAuthDialog(title: l10n.privateKeyShowWif)
            : PinpadDialog(
                biometricsAuthenticationTitle: l10n.privateKeyShowWif,
                biometricsLocalizedReason: l10n.privateKeyAuthReason,
                biometricsCancelButtonString: l10n.commonCancelCaps,
              ),
        barrierDismissible: !Util.isDesktop,
      );

      if (verified == "verified success" && mounted) {
        final wallet =
            ref.read(pWallets).getWallet(widget.walletId) as Bip39HDWallet;

        _private = await showLoading(
          whileFuture: wallet.getPrivateKeyWIF(widget.address),
          context: context,
          message: l10n.commonLoading,
          delay: const Duration(milliseconds: 800),
          rootNavigator: Util.isDesktop,
        );

        if (mounted) setState(() {});
      }
    } finally {
      _lock = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return DetailItemBase(
      button: CustomTextButton(
        text: l10n.commonShow,
        onTap: _loadPrivKey,
        enabled: _private == null,
      ),
      title: Text(l10n.privateKeyWif, style: STextStyles.itemSubtitle(context)),
      detail: _private == null
          ? Text(
              "*" * 52, // 52 is approx length
              style: STextStyles.w500_14(context),
            )
          // No screenshots while the key is shown.
          : SecretScreen(
              child: SelectableText(
                _private!,
                style: STextStyles.w500_14(context),
              ),
            ),
    );
  }
}
