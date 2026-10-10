import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../models/isar/models/blockchain_data/v2/transaction_v2.dart';
import '../../../../models/isar/models/isar_models.dart';
import '../../../../providers/global/locale_provider.dart';
import '../../../../providers/global/prefs_provider.dart';
import '../../../../providers/global/price_provider.dart';
import '../../../../providers/global/wallets_provider.dart';
import '../../../../themes/stack_colors.dart';
import '../../../../utilities/amount/amount.dart';
import '../../../../utilities/amount/amount_formatter.dart';
import '../../../../utilities/constants.dart';
import '../../../../utilities/format.dart';
import '../../../../utilities/text_styles.dart';
import '../../../../utilities/util.dart';
import '../../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../../wallets/isar/providers/wallet_info_provider.dart';
import '../../../../widgets/desktop/desktop_dialog.dart';
import '../../sub_widgets/tx_icon.dart';
import 'transaction_v2_details_view.dart' as tvd;

class TransactionCardV2 extends ConsumerStatefulWidget {
  const TransactionCardV2({super.key, required this.transaction});

  final TransactionV2 transaction;

  @override
  ConsumerState<TransactionCardV2> createState() => _TransactionCardStateV2();
}

class _TransactionCardStateV2 extends ConsumerState<TransactionCardV2> {
  /// Always the widget's current transaction: callers may rebuild the
  /// card with an updated copy (confirmed, reclassified) under the same
  /// key.
  TransactionV2 get _transaction => widget.transaction;
  late final String walletId;
  late final CryptoCurrency coin;

  String get prefix {
    if (!Util.isDesktop) return "";
    return switch (_transaction.type) {
      TransactionType.outgoing => "-",
      TransactionType.incoming => "+",
      _ => "",
    };
  }

  String whatIsIt(CryptoCurrency coin, int currentHeight) =>
      _transaction.statusLabel(
        currentChainHeight: currentHeight,
        minConfirms: ref
            .read(pWallets)
            .getWallet(walletId)
            .cryptoCurrency
            .minConfirms,
        minCoinbaseConfirms: ref
            .read(pWallets)
            .getWallet(walletId)
            .cryptoCurrency
            .minCoinbaseConfirms,
      );

  @override
  void initState() {
    walletId = widget.transaction.walletId;
    coin = ref.read(pWalletCoin(walletId));
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final locale = ref.watch(
      localeServiceChangeNotifierProvider.select((value) => value.locale),
    );

    final baseCurrency = ref.watch(
      prefsChangeNotifierProvider.select((value) => value.currency),
    );

    Decimal? price;
    if (ref.watch(
      prefsChangeNotifierProvider.select((value) => value.externalCalls),
    )) {
      price = ref.watch(
        priceAnd24hChangeNotifierProvider.select(
          (value) => value.getPrice(coin)?.value,
        ),
      );
    }

    final currentHeight = ref.watch(pWalletChainHeight(walletId));

    final Amount amount;

    final fractionDigits = coin.fractionDigits;

    switch (_transaction.type) {
      case TransactionType.outgoing:
      case TransactionType.unknown:
        amount = _transaction.getAmountSentFromThisWallet(
          fractionDigits: fractionDigits,
          subtractFee: true,
        );
        break;

      case TransactionType.incoming:
      case TransactionType.sentToSelf:
        amount = _transaction.getAmountReceivedInThisWallet(
          fractionDigits: fractionDigits,
        );
        break;
    }

    return Material(
      color: Theme.of(context).extension<StackColors>()!.popupBG,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(
          Constants.size.circularBorderRadius,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: RawMaterialButton(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(
              Constants.size.circularBorderRadius,
            ),
          ),
          onPressed: () async {
            if (Util.isDesktop) {
              await showDialog<void>(
                context: context,
                builder: (context) => DesktopDialog(
                  maxHeight: MediaQuery.of(context).size.height - 64,
                  maxWidth: 640,
                  child: tvd.TransactionV2DetailsView(
                    transaction: _transaction,
                    coin: coin,
                    walletId: walletId,
                  ),
                ),
              );
            } else {
              unawaited(
                Navigator.of(context).pushNamed(
                  tvd.TransactionV2DetailsView.routeName,
                  arguments: (tx: _transaction, coin: coin, walletId: walletId),
                ),
              );
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                TxIcon(
                  transaction: _transaction,
                  coin: coin,
                  currentHeight: currentHeight,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    // crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                whatIsIt(coin, currentHeight),
                                style: STextStyles.itemSubtitle12(context),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Builder(
                                builder: (context) {
                                  final formattedAmount = ref
                                      .watch(pAmountFormatter(coin))
                                      .format(amount);

                                  return Text(
                                    "$prefix$formattedAmount",
                                    style: STextStyles.itemSubtitle12(context),
                                  );
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        // crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                Format.extractDateFrom(_transaction.timestamp),
                                style: STextStyles.label(context),
                              ),
                            ),
                          ),
                          if (price != null) const SizedBox(width: 10),
                          if (price != null)
                            Flexible(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Builder(
                                  builder: (context) {
                                    final formattedFiat =
                                        (amount.decimal * price!)
                                            .toAmount(fractionDigits: 2)
                                            .fiatString(locale: locale);

                                    return Text(
                                      "$prefix$formattedFiat $baseCurrency",
                                      style: STextStyles.label(context),
                                    );
                                  },
                                ),
                              ),
                            ),
                        ],
                      ),
                      // PIVX: memo of a received shield payment.
                      if (coin is Pivx &&
                          (_transaction.onChainNote?.isNotEmpty ?? false)) ...[
                        const SizedBox(height: 4),
                        Text(
                          _transaction.onChainNote!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: STextStyles.label(context),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
