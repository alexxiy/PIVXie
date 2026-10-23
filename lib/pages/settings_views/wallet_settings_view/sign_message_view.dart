import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../notifications/show_flush_bar.dart';
import '../../../providers/global/wallets_provider.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/text_styles.dart';
import '../../../utilities/util.dart';
import '../../../wallets/crypto_currency/intermediate/bip39_hd_currency.dart';
import '../../../wallets/wallet/impl/pivx_wallet.dart';
import '../../../widgets/background.dart';
import '../../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../../widgets/desktop/desktop_dialog.dart';
import '../../../widgets/desktop/desktop_dialog_close_button.dart';
import '../../../widgets/desktop/primary_button.dart';
import '../../../widgets/rounded_white_container.dart';
import '../../../widgets/stack_text_field.dart';
import '../../send_view/sub_widgets/pivx_funding_card.dart';

/// The text Core prefixes a signed message with ("DarkNet Signed
/// Message:\n"); the network params carry it with its length byte.
String signedMessageMagic(Bip39HDCurrency coin) {
  final prefix = coin.networkParams.messagePrefix;
  return prefix.isNotEmpty && prefix.codeUnitAt(0) == prefix.length - 1
      ? prefix.substring(1)
      : prefix;
}

/// Sign a message with one of the wallet's addresses, or check a signature,
/// as Core's signmessage / verifymessage do.
class SignMessageView extends StatelessWidget {
  const SignMessageView({super.key, required this.walletId});

  static const String routeName = "/signMessage";

  final String walletId;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          leading: AppBarBackButton(
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(l10n.signTitle, style: STextStyles.navBarTitle(context)),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SignMessageForm(walletId: walletId),
          ),
        ),
      ),
    );
  }
}

/// The desktop version: the same form in a dialog.
Future<void> showSignMessageDialog(BuildContext context, String walletId) =>
    showDialog<void>(
      context: context,
      builder: (context) => DesktopDialog(
        maxWidth: 640,
        maxHeight: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 32),
                  child: Text(
                    l10n.signTitle,
                    style: STextStyles.desktopH3(context),
                  ),
                ),
                const Spacer(),
                const DesktopDialogCloseButton(),
              ],
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                child: SignMessageForm(walletId: walletId),
              ),
            ),
          ],
        ),
      ),
    );

enum _Tab {
  sign,
  verify;

  String get label => switch (this) {
    _Tab.sign => l10n.signTabSign,
    _Tab.verify => l10n.verifyAction,
  };
}

class SignMessageForm extends ConsumerStatefulWidget {
  const SignMessageForm({super.key, required this.walletId});

  final String walletId;

  @override
  ConsumerState<SignMessageForm> createState() => _SignMessageFormState();
}

class _SignMessageFormState extends ConsumerState<SignMessageForm> {
  late final PivxWallet _wallet =
      ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;

  late _Tab _tab = _wallet.isViewOnly ? _Tab.verify : _Tab.sign;

  // Sign
  String? _address;
  final _message = TextEditingController();
  final _messageFocus = FocusNode();
  String? _signature;
  String? _signError;
  bool _signing = false;

  // Verify
  final _verifyAddress = TextEditingController();
  final _verifyAddressFocus = FocusNode();
  final _verifyMessage = TextEditingController();
  final _verifyMessageFocus = FocusNode();
  final _verifySignature = TextEditingController();
  final _verifySignatureFocus = FocusNode();

  /// Null until checked: then whether the signature matches.
  bool? _valid;
  String? _verifyError;

  @override
  void initState() {
    super.initState();
    if (!_wallet.isViewOnly) {
      _wallet.getCurrentReceivingAddress().then((a) {
        if (mounted && _address == null && a != null) {
          setState(() => _address = a.value);
        }
      });
    }
    // An edit makes an earlier result stale (and may enable the button).
    _message.addListener(_clearSignature);
    for (final c in [_verifyAddress, _verifyMessage, _verifySignature]) {
      c.addListener(_clearVerdict);
    }
  }

  @override
  void dispose() {
    for (final c in [
      _message,
      _verifyAddress,
      _verifyMessage,
      _verifySignature,
    ]) {
      c.dispose();
    }
    for (final f in [
      _messageFocus,
      _verifyAddressFocus,
      _verifyMessageFocus,
      _verifySignatureFocus,
    ]) {
      f.dispose();
    }
    super.dispose();
  }

  void _clearSignature() => setState(() {
    _signature = null;
    _signError = null;
  });

  void _clearVerdict() => setState(() {
    _valid = null;
    _verifyError = null;
  });

  Future<void> _sign() async {
    final address = _address;
    if (address == null || _message.text.isEmpty) return;
    setState(() {
      _signing = true;
      _signError = null;
    });
    try {
      final a = await _wallet.mainDB.getAddress(widget.walletId, address);
      if (a == null || a.derivationPath == null) {
        throw Exception(l10n.signNoKey(address));
      }
      final key = await _wallet.getPrivateKey(a);
      final signature = coinlib.MessageSignature.sign(
        key: key,
        message: _message.text,
        prefix: signedMessageMagic(_wallet.cryptoCurrency),
      ).toString();
      if (mounted) setState(() => _signature = signature);
    } catch (e) {
      if (mounted) setState(() => _signError = l10n.signFailed("$e"));
    } finally {
      if (mounted) setState(() => _signing = false);
    }
  }

  void _verify() {
    final coin = _wallet.cryptoCurrency;
    final text = _verifyAddress.text.trim();
    coinlib.Address address;
    try {
      address = coinlib.Address.fromString(text, coin.networkParams);
    } catch (_) {
      setState(() => _verifyError = l10n.signNotAddress(coin.ticker));
      return;
    }
    if (address is! coinlib.P2PKHAddress) {
      setState(() => _verifyError = l10n.signOnlyRegular(coin.ticker));
      return;
    }
    coinlib.MessageSignature signature;
    try {
      signature = coinlib.MessageSignature.fromBase64(
        _verifySignature.text.trim(),
      );
    } catch (_) {
      setState(() => _verifyError = l10n.signBadFormat);
      return;
    }
    setState(() {
      _verifyError = null;
      _valid = signature.verifyAddress(
        address: address,
        message: _verifyMessage.text,
        prefix: signedMessageMagic(coin),
      );
    });
  }

  Widget _field(
    TextEditingController controller,
    FocusNode focus,
    String hint, {
    bool multiline = false,
    bool plain = false,
    bool paste = false,
  }) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: TextField(
      controller: controller,
      focusNode: focus,
      autocorrect: !plain,
      enableSuggestions: !plain,
      minLines: multiline ? 3 : 1,
      maxLines: multiline ? 8 : 1,
      keyboardType: multiline ? TextInputType.multiline : null,
      style: STextStyles.field(context),
      decoration: standardInputDecoration(hint, focus, context).copyWith(
        suffixIcon: paste
            ? IconButton(
                tooltip: l10n.commonPaste,
                icon: const Icon(Icons.content_paste_rounded, size: 20),
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  final text = data?.text?.trim();
                  if (text != null && text.isNotEmpty) controller.text = text;
                },
              )
            : null,
      ),
    ),
  );

  Widget _tabs(StackColors colors) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: colors.textFieldDefaultBG,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        for (final t in _Tab.values)
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _tab = t),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: t == _tab ? colors.popupBG : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  t.label,
                  textAlign: TextAlign.center,
                  style: STextStyles.w600_14(context).copyWith(
                    color: t == _tab ? colors.textDark : colors.textSubtitle1,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _signTab(StackColors colors, TextStyle label, TextStyle secondary) {
    final signature = _signature;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.signExplain, style: secondary),
        const SizedBox(height: 16),
        Text(l10n.commonAddress, style: label),
        const SizedBox(height: 8),
        PivxOwnAddressField(
          walletId: widget.walletId,
          value: _address,
          onChanged: (a) => setState(() {
            _address = a;
            _signature = null;
            _signError = null;
          }),
        ),
        const SizedBox(height: 16),
        Text(l10n.signMessage, style: label),
        const SizedBox(height: 8),
        _field(
          _message,
          _messageFocus,
          l10n.signMessageToSign,
          multiline: true,
        ),
        const SizedBox(height: 16),
        PrimaryButton(
          label: _signing ? l10n.signSigning : l10n.signAction,
          enabled: !_signing && _address != null && _message.text.isNotEmpty,
          onPressed: _sign,
        ),
        if (_signError != null) ...[
          const SizedBox(height: 12),
          Text(
            _signError!,
            style: STextStyles.w500_12(context)
                .copyWith(color: colors.textError),
          ),
        ],
        if (signature != null) ...[
          const SizedBox(height: 16),
          RoundedWhiteContainer(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.signSignature, style: secondary),
                      const SizedBox(height: 4),
                      SelectableText(
                        signature,
                        style: STextStyles.w500_14(context),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: l10n.signCopy,
                  icon: Icon(
                    Icons.copy_rounded,
                    size: 20,
                    color: colors.accentColorBlue,
                  ),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: signature));
                    if (mounted) {
                      await showFloatingFlushBar(
                        type: FlushBarType.info,
                        message: l10n.signCopied,
                        iconAsset: Assets.svg.copy,
                        context: context,
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _verifyTab(StackColors colors, TextStyle label, TextStyle secondary) {
    final valid = _valid;
    final ready =
        _verifyAddress.text.trim().isNotEmpty &&
        _verifyMessage.text.isNotEmpty &&
        _verifySignature.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.signVerifyExplain, style: secondary),
        const SizedBox(height: 16),
        Text(l10n.commonAddress, style: label),
        const SizedBox(height: 8),
        _field(
          _verifyAddress,
          _verifyAddressFocus,
          l10n.signTickerAddress(_wallet.cryptoCurrency.ticker),
          plain: true,
          paste: true,
        ),
        const SizedBox(height: 16),
        Text(l10n.signMessage, style: label),
        const SizedBox(height: 8),
        _field(
          _verifyMessage,
          _verifyMessageFocus,
          l10n.signSignedMessage,
          multiline: true,
        ),
        const SizedBox(height: 16),
        Text(l10n.signSignature, style: label),
        const SizedBox(height: 8),
        _field(
          _verifySignature,
          _verifySignatureFocus,
          l10n.signSignature,
          plain: true,
          paste: true,
        ),
        const SizedBox(height: 16),
        PrimaryButton(
          label: l10n.signVerifyAction,
          enabled: ready,
          onPressed: _verify,
        ),
        if (_verifyError != null || valid != null) ...[
          const SizedBox(height: 16),
          RoundedWhiteContainer(
            borderColor: valid == true
                ? colors.accentColorGreen
                : colors.textError,
            child: Row(
              children: [
                Icon(
                  valid == true
                      ? Icons.verified_rounded
                      : Icons.error_outline_rounded,
                  color: valid == true
                      ? colors.accentColorGreen
                      : colors.textError,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _verifyError ??
                        (valid == true ? l10n.signValid : l10n.signNotValid),
                    style: STextStyles.w500_14(context),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final label = STextStyles.smallMed12(context);
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    // A view-only wallet has no keys: it can only verify.
    final canSign = !_wallet.isViewOnly;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (canSign) ...[
          _tabs(colors),
          SizedBox(height: Util.isDesktop ? 24 : 16),
        ],
        if (_tab == _Tab.sign && canSign)
          _signTab(colors, label, secondary)
        else
          _verifyTab(colors, label, secondary),
      ],
    );
  }
}
