import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notifications/show_flush_bar.dart';
import '../../providers/global/secure_store_provider.dart';
import '../../providers/providers.dart';
import '../../utilities/logger.dart';
import '../../utilities/show_loading.dart';
import '../../wallets/isar/models/wallet_info.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../wallets/wallet/wallet.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/stack_dialog.dart';

// The accounts of a PIVX recovery phrase ([kPivxAccountKey]), each a
// wallet of its own, like the ones MyPIVXWallet's "Add account" makes.

/// The lowest account number from 1 on that none of [taken] uses: a
/// deleted account is the next one added again.
int pivxNextAccount(Iterable<int> taken) {
  final used = taken.toSet();
  var n = 1;
  while (used.contains(n)) {
    n++;
  }
  return n;
}

/// Name of account [account] of the wallet named [base], e.g. "Savings
/// (account 2)", and not one of [taken].
String pivxAccountWalletName(String base, int account, Set<String> taken) {
  final root = base.replaceFirst(RegExp(r" \(account \d+\)( \d+)?$"), "");
  final name = "$root (account $account)";
  if (!taken.contains(name)) return name;
  for (var i = 2; ; i++) {
    if (!taken.contains("$name $i")) return "$name $i";
  }
}

/// The wallets here with [wallet]'s recovery phrase, passphrase and
/// network, by account.
Future<Map<int, PivxWallet>> pivxPhraseAccounts(
  WidgetRef ref,
  PivxWallet wallet,
) async {
  final mnemonic = await wallet.getMnemonic();
  final passphrase = await wallet.getMnemonicPassphrase();
  final accounts = <int, PivxWallet>{};
  for (final w in ref.read(pWallets).wallets) {
    if (w is! PivxWallet ||
        w.isViewOnly ||
        w.cryptoCurrency.identifier != wallet.cryptoCurrency.identifier) {
      continue;
    }
    if (await w.getMnemonic() == mnemonic &&
        await w.getMnemonicPassphrase() == passphrase) {
      accounts.putIfAbsent(w.account, () => w);
    }
  }
  return accounts;
}

/// Restores of added accounts, one at a time: each scans the shield
/// blocks from the restore height.
Future<void> _restores = Future.value();

/// Adds account [account] of [from]'s recovery phrase as a new wallet
/// named [name], then restores it in the background: its history, and
/// its shield notes from where [from] starts.
Future<PivxWallet> pivxAddAccountWallet(
  WidgetRef ref, {
  required PivxWallet from,
  required int account,
  required String name,
}) async {
  final duress = ref.read(pDuress);
  final isar = ref.read(mainDBProvider).isar;
  final info = WalletInfo.createNew(
    coin: from.cryptoCurrency,
    name: name,
    restoreHeight: from.shieldRestoreHeight,
    otherDataJsonString: jsonEncode({
      kPivxAccountKey: account,
      // Like a restore: one hidden right after adding would give duress
      // mode away.
      if (duress) WalletInfoKeys.duressMarkedVisibleWalletKey: true,
    }),
  );
  final wallet = await Wallet.create(
    walletInfo: info,
    mainDB: ref.read(mainDBProvider),
    secureStorageInterface: ref.read(secureStoreProvider),
    nodeService: ref.read(nodeServiceChangeNotifierProvider),
    prefs: ref.read(prefsChangeNotifierProvider),
    mnemonic: await from.getMnemonic(),
    mnemonicPassphrase: await from.getMnemonicPassphrase(),
  ) as PivxWallet;
  await wallet.init();
  if (await from.info.isMnemonicVerified(isar)) {
    await wallet.info.setMnemonicVerified(isar: isar);
  }
  if (duress) {
    await wallet.info.updateDuressVisibilityStatus(
      isDuressVisible: true,
      isar: isar,
    );
  }
  ref.read(pWallets).addWallet(wallet);
  _restores = _restores.then((_) async {
    try {
      await wallet.recover(isRescan: false);
    } catch (e, s) {
      // The next sync picks it up again.
      Logging.instance.w(
        "PIVX: restoring account $account failed",
        error: e,
        stackTrace: s,
      );
    }
  });
  return wallet;
}

/// The other accounts of [wallet]'s recovery phrase that have been used
/// (see [PivxWallet.findUsedAccounts]); none when looking fails.
Future<List<int>> pivxFindUsedAccounts(PivxWallet wallet) async {
  try {
    return await wallet.findUsedAccounts();
  } catch (e, s) {
    Logging.instance.w(
      "PIVX: looking for other accounts failed",
      error: e,
      stackTrace: s,
    );
    return const [];
  }
}

/// Adds [accounts] of [wallet]'s recovery phrase that aren't here yet
/// (after a restore) and returns their names.
Future<List<String>> pivxAddAccounts(
  WidgetRef ref,
  PivxWallet wallet,
  List<int> accounts,
) async {
  if (accounts.isEmpty) return const [];
  final here = await pivxPhraseAccounts(ref, wallet);
  final names = {for (final w in ref.read(pWallets).wallets) w.info.name};
  final added = <String>[];
  for (final account in accounts) {
    if (here.containsKey(account)) continue;
    final name = pivxAccountWalletName(wallet.info.name, account, names);
    names.add(name);
    await pivxAddAccountWallet(ref, from: wallet, account: account, name: name);
    added.add(name);
  }
  return added;
}

/// What the restore succeeded dialog says about [added] accounts.
String? pivxAddedAccountsMessage(List<String> added) {
  if (added.isEmpty) return null;
  final names = added.map((n) => "“$n”").join(", ");
  return added.length == 1
      ? "This recovery phrase has another account with history. PIVXie "
            "added it as a separate wallet, $names, which is still syncing."
      : "This recovery phrase has other accounts with history. PIVXie "
            "added them as separate wallets, which are still syncing: "
            "$names.";
}

/// "Add account" of a PIVX wallet's menu: asks, then adds the phrase's
/// next account as a new wallet.
Future<void> showPivxAddAccountDialog(
  BuildContext context,
  WidgetRef ref,
  String walletId,
) async {
  final wallet = ref.read(pWallets).getWallet(walletId) as PivxWallet;
  final here = await pivxPhraseAccounts(ref, wallet);
  final account = pivxNextAccount(here.keys);
  final name = pivxAccountWalletName((here[0] ?? wallet).info.name, account, {
    for (final w in ref.read(pWallets).wallets) w.info.name,
  });
  if (!context.mounted) return;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => StackDialog(
      title: "Add account $account?",
      message:
          "Account $account of this recovery phrase becomes a separate "
          "wallet, “$name”, with its own addresses and balance. It's the "
          "same account $account as in MyPIVXWallet, so any coins it "
          "already holds show up once it has synced.",
      leftButton: SecondaryButton(
        label: "Cancel",
        onPressed: () => Navigator.of(context).pop(false),
      ),
      rightButton: PrimaryButton(
        label: "Add account",
        onPressed: () => Navigator.of(context).pop(true),
      ),
    ),
  );
  if (confirmed != true || !context.mounted) return;

  Exception? error;
  final added = await showLoading<PivxWallet>(
    whileFuture: pivxAddAccountWallet(
      ref,
      from: wallet,
      account: account,
      name: name,
    ),
    context: context,
    message: "Adding account $account",
    onException: (e) => error = e,
  );
  if (!context.mounted) return;
  unawaited(
    showFloatingFlushBar(
      type: added == null ? FlushBarType.warning : FlushBarType.success,
      message: added == null
          ? "Couldn't add the account: "
                "${error.toString().replaceFirst("Exception: ", "")}"
          : "Added “$name”. It's syncing now.",
      context: context,
    ),
  );
}
