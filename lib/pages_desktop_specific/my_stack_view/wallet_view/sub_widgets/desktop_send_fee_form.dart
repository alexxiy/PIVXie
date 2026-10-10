import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../pages/send_view/sub_widgets/transaction_fee_selection_sheet.dart';
import '../../../../providers/providers.dart';
import '../../../../themes/stack_colors.dart';
import '../../../../utilities/amount/amount.dart';
import '../../../../utilities/enums/fee_rate_type_enum.dart';
import '../../../../utilities/text_styles.dart';
import '../../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../../widgets/animated_text.dart';
import '../../../../widgets/desktop/desktop_fee_dialog.dart';

class DesktopSendFeeForm extends ConsumerWidget {
  const DesktopSendFeeForm({super.key, required this.walletId});

  final String walletId;

  static const _stringsToLoopThrough = [
    "Calculating",
    "Calculating.",
    "Calculating..",
    "Calculating...",
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "Transaction fee (estimated)",
          style: STextStyles.desktopTextExtraSmall(context).copyWith(
            color: Theme.of(context)
                .extension<StackColors>()!
                .textFieldActiveSearchIconRight,
          ),
          textAlign: TextAlign.left,
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.all(10),
          child: FutureBuilder(
            future: ref.watch(
              pWallets.select((value) => value.getWallet(walletId).fees),
            ),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.done &&
                  snapshot.hasData) {
                return DesktopFeeItem(
                  feeObject: snapshot.data,
                  feeRateType: FeeRateType.average,
                  walletId: walletId,
                  isButton: false,
                  feeFor:
                      ({
                        required Amount amount,
                        required FeeRateType feeRateType,
                        required BigInt feeRate,
                        required CryptoCurrency coin,
                      }) async {
                        final cache = ref.read(feeSheetSessionCacheProvider);
                        return cache.average[amount] ??= await ref
                            .read(pWallets)
                            .getWallet(walletId)
                            .estimateFeeFor(amount, feeRate);
                      },
                  isSelected: true,
                );
              }
              return Row(
                children: [
                  AnimatedText(
                    stringsToLoopThrough: _stringsToLoopThrough,
                    style: STextStyles.desktopTextExtraExtraSmall(context)
                        .copyWith(
                          color: Theme.of(context)
                              .extension<StackColors>()!
                              .textFieldActiveText,
                        ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
