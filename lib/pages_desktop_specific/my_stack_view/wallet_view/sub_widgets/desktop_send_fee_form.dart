import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../pages/send_view/sub_widgets/transaction_fee_selection_sheet.dart';
import '../../../../providers/providers.dart';
import '../../../../providers/wallet/desktop_fee_providers.dart';
import '../../../../themes/stack_colors.dart';
import '../../../../utilities/amount/amount.dart';
import '../../../../utilities/amount/amount_formatter.dart';
import '../../../../utilities/text_styles.dart';
import '../../../../wallets/isar/providers/wallet_info_provider.dart';
import '../../../../widgets/animated_text.dart';

/// The estimated network fee. PIVX has no fee market: every transparent
/// send pays the relay minimum, so there is nothing to choose.
class DesktopSendFeeForm extends ConsumerWidget {
  const DesktopSendFeeForm({super.key, required this.walletId});

  final String walletId;

  static const _stringsToLoopThrough = [
    "Calculating",
    "Calculating.",
    "Calculating..",
    "Calculating...",
  ];

  Future<Amount> _fee(WidgetRef ref, Amount amount) async {
    final cache = ref.read(feeSheetSessionCacheProvider);
    final wallet = ref.read(pWallets).getWallet(walletId);
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
          "Network fee (estimated)",
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
