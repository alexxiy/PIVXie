// End-to-end checks of PIVX key derivation and transaction signing
// against a regtest pivxd + pivx-bridge (with ADDR_INDEX enabled).
//
// Both regtest suites share one regtest chain (they mine blocks), so
// run them with --concurrency=1.
//
// Run on the build VM:
//   PIVX_BRIDGE=http://127.0.0.1:3000 \
//   PIVX_CLI="/opt/pivx/bin/pivx-cli -datadir=/srv/pivx-regtest -conf=/srv/pivx-regtest/pivx.conf" \
//   flutter test --concurrency=1 test/pivx/pivx_regtest_test.dart
//
// Skipped when PIVX_BRIDGE is not set.
import 'dart:io';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/models/coinlib/exp2pkh_address.dart';
import 'package:paymint/utilities/enums/derive_path_type_enum.dart';
import 'package:paymint/utilities/extensions/extensions.dart';
import 'package:paymint/wallets/api/pivx/pivx_bridge_client.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';

const _mnemonic =
    "abandon abandon abandon abandon abandon abandon abandon abandon "
    "abandon abandon abandon about";

Future<String> _cli(List<String> args) async {
  final cli = Platform.environment["PIVX_CLI"]!.split(" ");
  final r = await Process.run(cli.first, [...cli.skip(1), ...args]);
  if (r.exitCode != 0) throw Exception("pivx-cli ${args.first}: ${r.stderr}");
  return (r.stdout as String).trim();
}

Future<void> _waitFor(Future<bool> Function() check) async {
  for (int i = 0; i < 30; i++) {
    if (await check()) return;
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  throw Exception("timed out");
}

void main() {
  final bridgeUrl = Platform.environment["PIVX_BRIDGE"];
  final skip = bridgeUrl == null ? "PIVX_BRIDGE not set" : null;

  final coin = Pivx(CryptoCurrencyNetwork.test);
  late PivxBridgeClient bridge;
  late coinlib.HDPrivateKey root;

  setUpAll(() async {
    if (skip != null) return;
    await coinlib.loadCoinlib();
    bridge = PivxBridgeClient(baseUri: Uri.parse(bridgeUrl!));
    root = coinlib.HDPrivateKey.fromSeed(bip39.mnemonicToSeed(_mnemonic));
  });

  String addressAt(int chain, int index) {
    final path = coin.constructDerivePath(
      derivePathType: DerivePathType.bip44,
      chain: chain,
      index: index,
    );
    return coin
        .getAddressForPublicKey(
          publicKey: root.derivePath(path).publicKey,
          derivePathType: DerivePathType.bip44,
        )
        .address
        .toString();
  }

  String accountXpub() => root
      .derivePath("m/44'/1'/0'")
      .hdPublicKey
      .encode(coin.networkParams.pubHDPrefix);

  test("bridge verifies as a test-network bridge", () async {
    expect(await bridge.verifyFor(coin), isNull);
  }, skip: skip);

  test("bridge derives the same addresses from the account xpub", () async {
    final xpub = accountXpub();
    final info = await bridge.xpub(xpub, details: "tokens", tokens: "derived");
    final tokens = (info["tokens"] as List).cast<Map>();
    String tokenAt(String suffix) =>
        tokens.firstWhere((t) => (t["path"] as String).endsWith(suffix))["name"]
            as String;
    expect(tokenAt("/0/0"), addressAt(0, 0));
    expect(tokenAt("/0/7"), addressAt(0, 7));
    expect(tokenAt("/1/3"), addressAt(1, 3));
    // The node agrees it is a valid address for this chain.
    expect(await _cli(["validateaddress", addressAt(0, 0)]), contains('"isvalid": true'));
  }, skip: skip);

  test("funds, signs and broadcasts a v1 transaction", () async {
    final xpub = accountXpub();
    final receive = addressAt(0, 0);

    // Fund the wallet from the node and confirm it.
    final fundTxid = await _cli(["sendtoaddress", receive, "12.5"]);
    await _cli(["generate", "1"]);
    await _waitFor(() async {
      final utxos = await bridge.utxo(xpub);
      return utxos.any((u) => u["txid"] == fundTxid && (u["confirmations"] as int) > 0);
    });

    final utxo = (await bridge.utxo(xpub)).firstWhere((u) => u["txid"] == fundTxid);
    final value = BigInt.parse(utxo["value"] as String);
    expect(utxo["address"], receive);
    expect(utxo["path"], "m/44'/1'/0'/0/0");

    // Spend it: one output to the node, one to an exchange address,
    // change back to our change chain. Same construction as PivxWallet.
    final key = root.derivePath("m/44'/1'/0'/0/0");
    final nodeAddress = await _cli(["getnewaddress"]);
    final exchangeAddress = await _cli(["getnewexchangeaddress"]);
    final change = addressAt(1, 0);
    final fee = BigInt.from((10 + 149 + 3 * 35) * coin.minFeePerByte);
    final toNode = BigInt.from(300000000);
    final toExchange = BigInt.from(200000000);

    var tx = coinlib.Transaction(version: 1, inputs: [], outputs: [])
        .addInput(
          coinlib.P2PKHInput(
            prevOut: coinlib.OutPoint(
              Uint8List.fromList(fundTxid.toUint8ListFromHex.reversed.toList()),
              utxo["vout"] as int,
            ),
            publicKey: key.publicKey,
            sequence: 0xffffffff,
          ),
        )
        .addOutput(
          coinlib.Output.fromAddress(
            toNode,
            coinlib.Address.fromString(nodeAddress, coin.networkParams),
          ),
        )
        .addOutput(
          coinlib.Output.fromAddress(
            toExchange,
            EXP2PKHAddress.fromString(exchangeAddress, coin.exAddressVersion),
          ),
        )
        .addOutput(
          coinlib.Output.fromAddress(
            value - toNode - toExchange - fee,
            coinlib.Address.fromString(change, coin.networkParams),
          ),
        );
    tx = tx.signLegacy(inputN: 0, key: key.privateKey);

    final txid = await bridge.sendTx(tx.toHex());
    expect(txid, tx.txid);

    // In the node's mempool, then visible through the bridge as unconfirmed.
    expect(await _cli(["getrawmempool"]), contains(txid));
    await _waitFor(() async {
      final info = await bridge.xpub(xpub, details: "basic");
      return (info["unconfirmedTxs"] as int) > 0;
    });

    await _cli(["generate", "1"]);
    await _waitFor(() async {
      final t = await bridge.tx(txid);
      return (t["confirmations"] as int) > 0;
    });
    final t = await bridge.tx(txid);
    expect(t["fees"], fee.toString());
    expect((t["vout"] as List)[1]["type"], "exchangeaddress");
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}
