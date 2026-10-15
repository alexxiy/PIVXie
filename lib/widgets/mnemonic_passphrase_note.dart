import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/global/wallets_provider.dart';
import '../themes/stack_colors.dart';
import '../utilities/text_styles.dart';
import '../wallets/wallet/wallet_mixin_interfaces/mnemonic_interface.dart';
import 'custom_buttons/blue_text_button.dart';
import 'rounded_container.dart';

/// Shown with a recovery phrase when the wallet also has a BIP39
/// passphrase: restoring needs both, and the words alone give an empty
/// wallet. The passphrase itself is shown on request.
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
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    final wallet = ref.read(pWallets).getWallet(widget.walletId);
    _passphrase = wallet is MnemonicInterface
        ? wallet.getMnemonicPassphrase()
        : Future.value("");
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final style = STextStyles.baseXS(context)
        .copyWith(color: colors.warningForeground);
    return FutureBuilder<String>(
      future: _passphrase,
      builder: (context, snapshot) {
        final passphrase = snapshot.data;
        if (passphrase == null || passphrase.isEmpty) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: RoundedContainer(
            color: colors.warningBackground,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "This wallet also has a passphrase. To restore it you need "
                  "the passphrase as well as these words: the words alone "
                  "open a different, empty wallet.",
                  style: style,
                ),
                const SizedBox(height: 8),
                _shown
                    ? SelectableText(
                        passphrase,
                        style: style.copyWith(fontWeight: FontWeight.w600),
                      )
                    : CustomTextButton(
                        text: "Show passphrase",
                        onTap: () => setState(() => _shown = true),
                      ),
              ],
            ),
          ),
        );
      },
    );
  }
}
