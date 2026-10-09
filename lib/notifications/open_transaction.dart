import 'package:flutter/material.dart';
import 'package:isar_community/isar.dart';

import '../db/isar/main_db.dart';
import '../models/isar/models/blockchain_data/v2/transaction_v2.dart';
import '../pages/wallet_view/transaction_views/tx_v2/transaction_v2_details_view.dart';
import '../services/wallets.dart';

/// Routes that guard the app (PIN / biometrics); nothing is opened on
/// top of them.
const _lockRoutes = {
  "/",
  "/unlockTimedOutAppScreen",
  "/swbrestorelockscreen",
};

/// Opens the details of [txid] in [walletId] (from a notification).
/// Does nothing while the app is locked or if the tx is unknown.
Future<void> openTransactionDetails(
  NavigatorState navigator,
  String walletId,
  String txid,
) async {
  String? top;
  navigator.popUntil((route) {
    top = route.settings.name;
    return true;
  });
  if (top == null || _lockRoutes.contains(top)) return;

  final tx = await MainDB.instance.isar.transactionV2s
      .where()
      .txidWalletIdEqualTo(txid, walletId)
      .findFirst();
  if (tx == null) return;
  final coin = Wallets.sharedInstance.getWallet(walletId).info.coin;
  await navigator.pushNamed(
    TransactionV2DetailsView.routeName,
    arguments: (tx: tx, coin: coin, walletId: walletId),
  );
}
