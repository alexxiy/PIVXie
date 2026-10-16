// A phrase's other accounts on regtest pivxd + pivx-bridge: finding the
// used ones as a restore does (PivxWallet.findUsedAccounts), and each
// account's own shield key.
//
// The regtest suites share one chain, so run them with --concurrency=1.
//
// Run on the build VM:
//   PIVX_BRIDGE=http://127.0.0.1:3000 \
//   PIVX_CLI="/opt/pivx/bin/pivx-cli -datadir=/srv/pivx-regtest -conf=/srv/pivx-regtest/pivx.conf" \
//   PIVX_SHIELD_LIB=/root/work/pivxshield/rust/target/release/libpivx_shield_ffi.so \
//   flutter test --concurrency=1 test/pivx/pivx_accounts_regtest_test.dart
import 'dart:io';

import 'package:bip39/bip39.dart' as bip39;
import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:flutter_libpivxshield/flutter_libpivxshield.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/utilities/enums/derive_path_type_enum.dart';
import 'package:paymint/wallets/api/pivx/pivx_bridge_client.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';
import 'package:paymint/wallets/wallet/impl/pivx_wallet.dart';

// A fresh phrase per run keeps runs independent on a reused regtest chain.
final _mnemonic = bip39.generateMnemonic();

Future<String> _cli(List<String> args) async {
  final cli = Platform.environment["PIVX_CLI"]!.split(" ");
  final r = await Process.run(cli.first, [...cli.skip(1), ...args]);
  if (r.exitCode != 0) throw Exception("pivx-cli ${args.first}: ${r.stderr}");
  return (r.stdout as String).trim();
}

Future<void> _waitFor(Future<bool> Function() check) async {
  for (int i = 0; i < 90; i++) {
    if (await check()) return;
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  throw Exception("timed out");
}

void main() {
  final bridgeUrl = Platform.environment["PIVX_BRIDGE"];
  final skip = bridgeUrl == null ? "PIVX_BRIDGE not set" : null;
  final skipShield = Platform.environment["PIVX_SHIELD_LIB"] == null
      ? "PIVX_SHIELD_LIB not set"
      : null;

  final coin = Pivx(CryptoCurrencyNetwork.test);
  final seed = bip39.mnemonicToSeed(_mnemonic);
  late PivxBridgeClient bridge;
  late coinlib.HDPrivateKey root;

  setUpAll(() async {
    await coinlib.loadCoinlib();
    root = coinlib.HDPrivateKey.fromSeed(seed);
    if (bridgeUrl != null) {
      bridge = PivxBridgeClient(baseUri: Uri.parse(bridgeUrl));
    }
  });

  String address(int account, {int chain = 0, int index = 0}) => coin
      .getAddressForPublicKey(
        publicKey: coinlib.HDPublicKey.decode(
          pivxAccountXpub(root, coin, account),
          coin.networkParams.pubHDPrefix,
        ).derivePath("$chain/$index").publicKey,
        derivePathType: DerivePathType.bip44,
      )
      .address
      .toString();

  // As PivxWallet.findUsedAccounts.
  Future<bool> used(int account) async => pivxXpubIsUsed(
    await bridge.xpub(
      pivxAccountXpub(root, coin, account),
      details: "basic",
      gap: 20,
    ),
  );

  test("finds the used accounts after the first", () async {
    expect(await pivxFindAccounts(from: 1, isUsed: used), isEmpty);

    // Account 2 at a later receiving address, account 5 on its change
    // chain only; 1, 3 and 4 stay unused.
    await _cli(["sendtoaddress", address(2, index: 3), "1"]);
    await _cli(["sendtoaddress", address(5, chain: 1), "1"]);
    await _cli(["generate", "1"]);
    await _waitFor(() async => await used(2) && await used(5));

    expect(await used(1), isFalse);
    expect(await pivxFindAccounts(from: 1, isUsed: used), [2, 5]);
    expect(await pivxFindAccounts(from: 3, isUsed: used), [5]);
    expect(await pivxFindAccounts(from: 6, isUsed: used), isEmpty);
  }, skip: skip);

  test("each account has its own shield key", () {
    String extsk(int account) => PivxShield.extendedSpendingKey(
      seed: seed.sublist(0, 32),
      coinType: 1,
      accountIndex: account,
    );
    expect(
      PivxShield.extendedSpendingKey(seed: seed.sublist(0, 32), coinType: 1),
      extsk(0),
    );
    expect({extsk(0), extsk(1), extsk(2)}, hasLength(3));
    String shieldAddress(int account) => PivxShield.defaultAddress(
      extfvk: PivxShield.extendedFullViewingKey(
        extsk: extsk(account),
        isTestnet: true,
      ),
      isTestnet: true,
    ).address;
    expect(shieldAddress(1), isNot(shieldAddress(0)));
    expect(coin.isShieldAddress(shieldAddress(1)), isTrue);
  }, skip: skipShield);
}
