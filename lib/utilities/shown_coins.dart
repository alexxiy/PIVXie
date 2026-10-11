import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_config.dart';
import '../models/add_wallet_list_entity/sub_classes/coin_entity.dart';
import '../pages/add_wallet_views/add_wallet_view/add_wallet_view.dart';
import '../pages/add_wallet_views/create_or_restore_wallet_view/create_or_restore_wallet_view.dart';
import '../providers/global/prefs_provider.dart';
import '../providers/global/wallets_provider.dart';
import '../wallets/crypto_currency/crypto_currency.dart';

/// Coins the app lists: mainnets always, testnets when "show testnet
/// coins" is on or, with [withWalletCoins], when a wallet uses one.
///
/// When this is a single coin, screens that only pick a coin (add
/// wallet, nodes, units) are skipped.
List<CryptoCurrency> shownCoins(WidgetRef ref, {bool withWalletCoins = false}) {
  final showTestNet = ref.read(prefsChangeNotifierProvider).showTestNetCoins;
  final walletCoins = withWalletCoins
      ? {for (final w in ref.read(pWallets).wallets) w.info.coin}
      : const <CryptoCurrency>{};
  return [
    for (final coin in AppConfig.coins)
      if (!coin.network.isTestNet || showTestNet || walletCoins.contains(coin))
        coin,
  ];
}

/// Add a wallet: straight to "Create / Restore" when there is only one
/// coin to choose from.
Future<void> pushAddWallet(
  BuildContext context,
  WidgetRef ref, {
  bool rootNavigator = false,
}) async {
  final coins = shownCoins(ref);
  final nav = Navigator.of(context, rootNavigator: rootNavigator);
  if (coins.length == 1) {
    await nav.pushNamed(
      CreateOrRestoreWalletView.routeName,
      arguments: CoinEntity(coins.first),
    );
  } else {
    await nav.pushNamed(AddWalletView.routeName);
  }
}

/// Open the per-coin page [coinRoute] directly when only one coin is
/// listed, else the coin list [listRoute].
Future<void> pushCoinScoped(
  BuildContext context,
  WidgetRef ref, {
  required String listRoute,
  required String coinRoute,
  Object? listArguments,
}) async {
  final coins = shownCoins(ref, withWalletCoins: true);
  if (coins.length == 1) {
    await Navigator.of(context).pushNamed(coinRoute, arguments: coins.first);
  } else {
    await Navigator.of(context).pushNamed(listRoute, arguments: listArguments);
  }
}
