import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/l10n.dart';
import '../../../../models/isar/models/blockchain_data/utxo.dart';
import '../../../../pages/send_view/sub_widgets/transaction_fee_selection_sheet.dart';
import '../../../../providers/providers.dart';
import '../../../../providers/wallet/desktop_fee_providers.dart';
import '../../../../themes/stack_colors.dart';
import '../../../../utilities/amount/amount.dart';
import '../../../../utilities/amount/amount_formatter.dart';
import '../../../../utilities/text_styles.dart';
import '../../../../wallets/isar/providers/wallet_info_provider.dart';
import '../../../../wallets/wallet/impl/pivx_wallet.dart';
import '../../../../widgets/animated_text.dart';

/// The estimated network fee. PIVX has no fee market: every transparent
/// send pays the relay minimum, so there is nothing to choose. Shield
/// sends pay by size, so their fee depends on the balance spent, the
/// recipient, the chosen coins and whether the fee comes out of the amount.
class DesktopSendFeeForm extends ConsumerWidget {
  const DesktopSendFeeForm({
    super.key,
    required this.walletId,
    this.fromShield = false,
    this.toShield = false,
    this.subtractFee = false,
    this.selected = const {},
  });

  final String walletId;
  final bool fromShield;
  final bool toShield;
  final bool subtractFee;
  final Set<UTXO> selected;

  static List<String> get _stringsToLoopThrough => [
    l10n.commonCalculating,
    "${l10n.commonCalculating}.",
    "${l10n.commonCalculating}..",
    "${l10n.commonCalculating}...",
  ];

  Future<Amount> _fee(WidgetRef ref, Amount amount) async {
    final cache = ref.read(feeSheetSessionCacheProvider);
    final wallet = ref.read(pWallets).getWallet(walletId);
    if (wallet is PivxWallet && (fromShield || toShield)) {
      return wallet.estimateShieldFee(
        amount: amount,
        fromShield: fromShield,
        toShield: toShield,
        selected: selected.isEmpty ? null : selected,
        subtractFee: subtractFee,
      );
    }
    return cache.average[amount] ??= await wallet.estimateFeeFor(
      amount,
      (await wallet.fees).medium,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final coin = ref.watch(pWalletCoin(walletId));
    final amount = ref.watch(sendAmountProvider);
    final style = STextStyles.desktopTextExtraExtraSmall(context)
        .copyWith(color: colors.textFieldActiveText);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.sendNetworkFeeEstimated,
          style: STextStyles.desktopTextExtraSmall(context)
              .copyWith(color: colors.textFieldActiveSearchIconRight),
          textAlign: TextAlign.left,
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.all(10),
          child: FutureBuilder(
            future: _fee(ref, amount),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.done &&
                  snapshot.hasData) {
                return Text(
                  "~${ref.watch(pAmountFormatter(coin)).format(snapshot.data!, indicatePrecisionLoss: false)}",
                  style: style,
                );
              }
              return AnimatedText(
                stringsToLoopThrough: _stringsToLoopThrough,
                style: style,
              );
            },
          ),
        ),
      ],
    );
  }
}
