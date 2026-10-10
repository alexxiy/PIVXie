import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../models/isar/models/blockchain_data/v2/transaction_v2.dart';
import '../../../../themes/stack_colors.dart';
import '../../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../../widgets/breathing.dart';
import 'transaction_v2_card.dart';

class TxListItem extends ConsumerWidget {
  const TxListItem({
    super.key,
    required this.tx,
    this.radius,
    required this.coin,
  });

  final TransactionV2 tx;
  final BorderRadius? radius;
  final CryptoCurrency coin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keyed on content, not object identity: every database change
    // reloads the list as new objects, and identity keys rebuilt every
    // card (visible flicker on each sync).
    final txKeyString =
        "${tx.txid}${tx.type.name}${tx.subType.name}"
        "${tx.height}${tx.blockHash}${tx.otherData.hashCode}";

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).extension<StackColors>()!.popupBG,
        borderRadius: radius,
      ),
      child: Breathing(
        child: TransactionCardV2(key: Key(txKeyString), transaction: tx),
      ),
    );
  }
}
