import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../providers/global/wallets_provider.dart';
import '../themes/stack_colors.dart';
import '../utilities/text_styles.dart';
import '../wallets/wallet/impl/pivx_wallet.dart';
import '../wallets/wallet/wallet_mixin_interfaces/mnemonic_interface.dart';
import 'custom_buttons/blue_text_button.dart';
import 'rounded_container.dart';

/// Shown with a recovery phrase when the wallet also has a BIP39
/// passphrase: restoring needs both, and the words alone give an empty
/// wallet. The passphrase itself is shown on request. A PIVX wallet that
/// is another account of its phrase says which, as restoring the phrase
/// gives account 0 first.
class MnemonicPassphraseNote extends ConsumerStatefulWidget {
  const MnemonicPassphraseNote({super.key, required this.walletId});

  final String walletId;

  @override
  ConsumerState<MnemonicPassphraseNote> createState() =>
      _MnemonicPassphraseNoteState();
}

class _MnemonicPassphraseNoteState
    extends ConsumerState<MnemonicPassphraseNote> {
  late final Future<String> _passphrase;
  late final int _account;
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    final wallet = ref.read(pWallets).getWallet(widget.walletId);
    _passphrase = wallet is MnemonicInterface
        ? wallet.getMnemonicPassphrase()
        : Future.value("");
    _account = wallet is PivxWallet ? wallet.account : 0;
  }

  Widget _note(BuildContext context, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: RoundedContainer(
      color: Theme.of(context).extension<StackColors>()!.warningBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final style = STextStyles.baseXS(context)
        .copyWith(color: colors.warningForeground);
    return FutureBuilder<String>(
      future: _passphrase,
      builder: (context, snapshot) {
        final passphrase = snapshot.data;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_account > 0)
              _note(context, [
                Text(l10n.mnemonicAccountNote(_account), style: style),
              ]),
            if (passphrase != null && passphrase.isNotEmpty)
              _note(context, [
                Text(l10n.mnemonicPassphraseNote, style: style),
                const SizedBox(height: 8),
                _shown
                    ? SelectableText(
                        passphrase,
                        style: style.copyWith(fontWeight: FontWeight.w600),
                      )
                    : CustomTextButton(
                        text: l10n.mnemonicShowPassphrase,
                        onTap: () => setState(() => _shown = true),
                      ),
              ]),
          ],
        );
      },
    );
  }
}
