import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/models.dart';
import '../../providers/global/wallets_provider.dart';
import '../../providers/ui/fee_rate_type_state_provider.dart';
import '../../providers/wallet/desktop_fee_providers.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/amount/amount.dart';
import '../../utilities/amount/amount_formatter.dart';
import '../../utilities/enums/fee_rate_type_enum.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/crypto_currency/crypto_currency.dart';
import '../animated_text.dart';
import '../conditional_parent.dart';

class DesktopFeeItem extends ConsumerStatefulWidget {
  const DesktopFeeItem({
    super.key,
    required this.feeObject,
    required this.feeRateType,
    required this.walletId,
    required this.feeFor,
    required this.isSelected,
    this.isButton = true,
  });

  final FeeObject? feeObject;
  final FeeRateType feeRateType;
  final String walletId;
  final Future<Amount> Function({
    required Amount amount,
    required FeeRateType feeRateType,
    required BigInt feeRate,
    required CryptoCurrency coin,
  })
  feeFor;
  final bool isSelected;
  final bool isButton;

  @override
  ConsumerState<DesktopFeeItem> createState() => _DesktopFeeItemState();
}

class _DesktopFeeItemState extends ConsumerState<DesktopFeeItem> {
  String? feeString;
  String? timeString;

  static const stringsToLoopThrough = [
    "Calculating",
    "Calculating.",
    "Calculating..",
    "Calculating...",
  ];

  String estimatedTimeToBeIncludedInNextBlock(
    int targetBlockTime,
    int estimatedNumberOfBlocks,
  ) {
    final int time = targetBlockTime * estimatedNumberOfBlocks;

    final int hours = (time / 3600).floor();
    if (hours > 1) {
      return "~$hours hours";
    } else if (hours == 1) {
      return "~$hours hour";
    }

    // less than an hour

    final string = (time / 60).toStringAsFixed(1);

    if (string == "1.0") {
      return "~1 minute";
    } else {
      if (string.endsWith(".0")) {
        return "~${(time / 60).floor()} minutes";
      }
      return "~$string minutes";
    }
  }

  @override
  Widget build(BuildContext context) {
    debugPrint("BUILD: $runtimeType : ${widget.feeRateType}");

    return ConditionalParent(
      condition: widget.isButton,
      builder: (child) => MaterialButton(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onPressed: () {
          ref.read(feeRateTypeDesktopStateProvider.notifier).state =
              widget.feeRateType;
          Navigator.of(context)
              .pop((widget.feeRateType, feeString, timeString));
        },
        child: child,
      ),
      child: Builder(
        builder: (_) {
          if (widget.feeRateType == FeeRateType.custom) {
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  widget.feeRateType.prettyName,
                  style: STextStyles.desktopTextExtraExtraSmall(context)
                      .copyWith(
                        color: Theme.of(context)
                            .extension<StackColors>()!
                            .textFieldActiveText,
                      ),
                  textAlign: TextAlign.left,
                ),
              ],
            );
          }

          final wallet = ref.watch(
            pWallets.select((value) => value.getWallet(widget.walletId)),
          );

          if (widget.feeObject == null) {
            return AnimatedText(
              stringsToLoopThrough: stringsToLoopThrough,
              style: STextStyles.desktopTextExtraExtraSmall(context).copyWith(
                color: Theme.of(context)
                    .extension<StackColors>()!
                    .textFieldActiveText,
              ),
            );
          } else {
            return FutureBuilder(
              future: widget.feeFor(
                coin: wallet.info.coin,
                feeRateType: widget.feeRateType,
                feeRate: widget.feeRateType == FeeRateType.fast
                    ? widget.feeObject!.fast
                    : widget.feeRateType == FeeRateType.slow
                    ? widget.feeObject!.slow
                    : widget.feeObject!.medium,
                amount: ref.watch(sendAmountProvider),
              ),
              builder: (_, AsyncSnapshot<Amount> snapshot) {
                if (snapshot.connectionState == ConnectionState.done &&
                    snapshot.hasData) {
                  feeString =
                      "${widget.feeRateType.prettyName} "
                      "(~${ref.watch(pAmountFormatter(wallet.info.coin)).format(snapshot.data!, indicatePrecisionLoss: false)})";

                  timeString = estimatedTimeToBeIncludedInNextBlock(
                    wallet.info.coin.targetBlockTimeSeconds,
                    widget.feeRateType == FeeRateType.fast
                        ? widget.feeObject!.numberOfBlocksFast
                        : widget.feeRateType == FeeRateType.slow
                        ? widget.feeObject!.numberOfBlocksSlow
                        : widget.feeObject!.numberOfBlocksAverage,
                  );

                  return Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        feeString!,
                        style: STextStyles.desktopTextExtraExtraSmall(context)
                            .copyWith(
                              color: Theme.of(context)
                                  .extension<StackColors>()!
                                  .textFieldActiveText,
                            ),
                        textAlign: TextAlign.left,
                      ),
                      if (widget.feeObject != null)
                        Text(
                          timeString!,
                          style: STextStyles.desktopTextExtraExtraSmall(context)
                              .copyWith(
                                color: Theme.of(context)
                                    .extension<StackColors>()!
                                    .textFieldActiveSearchIconRight,
                              ),
                        ),
                    ],
                  );
                } else {
                  return AnimatedText(
                    stringsToLoopThrough: stringsToLoopThrough,
                    style: STextStyles.desktopTextExtraExtraSmall(context)
                        .copyWith(
                          color: Theme.of(context)
                              .extension<StackColors>()!
                              .textFieldActiveText,
                        ),
                  );
                }
              },
            );
          }
        },
      ),
    );
  }
}
