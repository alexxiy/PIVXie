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
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/models/coinlib/exp2pkh_address.dart';
import 'package:paymint/utilities/enums/derive_path_type_enum.dart';
import 'package:paymint/utilities/extensions/extensions.dart';
import 'package:paymint/wallets/api/pivx/pivx_bridge_client.dart';
import 'package:paymint/wallets/wallet/impl/pivx/pivx_tx_parser.dart';
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

/// Regtest blocks can be reorged (the masternode nodes stake too), so a
/// confirmation may take a little while.
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
    expect(
      await _cli(["validateaddress", addressAt(0, 0)]),
      contains('"isvalid": true'),
    );
  }, skip: skip);

  test(
    "funds, signs and broadcasts a v1 transaction",
    () async {
      final xpub = accountXpub();
      final receive = addressAt(0, 0);

      // Fund the wallet from the node and confirm it.
      final fundTxid = await _cli(["sendtoaddress", receive, "12.5"]);
      await _cli(["generate", "1"]);
      await _waitFor(() async {
        final utxos = await bridge.utxo(xpub);
        return utxos.any(
          (u) => u["txid"] == fundTxid && (u["confirmations"] as int) > 0,
        );
      });

      final utxo = (await bridge.utxo(xpub))
          .firstWhere((u) => u["txid"] == fundTxid);
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
                Uint8List.fromList(
                  fundTxid.toUint8ListFromHex.reversed.toList(),
                ),
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
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    "raw transactions hash to their txid and give the real output values",
    () async {
      // Recent blocks: coinbase/coinstake, transparent and (after the
      // shield tests) Sapling v3 transactions.
      var height = await bridge.getBlockCount();
      int checked = 0;
      int v3 = 0;
      while (height > 0 && (checked < 20 || v3 == 0) && checked < 400) {
        final hash = await _cli(["getblockhash", "$height"]);
        final block = jsonDecode(await _cli(["getblock", hash, "1"])) as Map;
        for (final txid in (block["tx"] as List).cast<String>()) {
          final raw = await bridge.rawTx(txid);
          final values = pivxVerifiedOutputs(
            txid,
            raw,
          ).map((e) => e.value).toList();
          final node =
              jsonDecode(await _cli(["getrawtransaction", txid, "1"])) as Map;
          expect(values, [
            for (final o in node["vout"] as List)
              BigInt.from((((o as Map)["value"] as num) * 1e8).round()),
          ], reason: txid);
          if (node["version"] == 3) v3++;
          checked++;
        }
        height--;
      }
      expect(checked, greaterThan(0));
      // A tampered transaction doesn't pass.
      final hash = await _cli([
        "getblockhash",
        "${await bridge.getBlockCount()}",
      ]);
      final txid =
          ((jsonDecode(await _cli(["getblock", hash, "1"])) as Map)["tx"]
                      as List)
                  .first
              as String;
      final raw = await bridge.rawTx(txid);
      final tampered = "${raw.substring(0, raw.length - 2)}ff";
      expect(() => pivxVerifiedOutputs(txid, tampered), throwsException);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    "watch long-poll wakes on our mempool tx and on blocks only",
    () async {
      final mine = addressAt(0, 5);
      late int height;
      late PivxBridgeWatch r;
      late String paid;
      // The VM's miner (a block a minute) may wake the watch first: then
      // the round is tried again.
      for (var round = 1; ; round++) {
        height = await bridge.getBlockCount();
        // Establish the mempool sequence.
        final base = await bridge.watch(height: height, timeoutSeconds: 1);
        expect(base.changed, isFalse);

        // An unrelated tx does not wake us; a payment to our address does.
        final watched = bridge.watch(
          height: height,
          mempoolSeq: base.mempoolSeq,
          addresses: [mine],
          timeoutSeconds: 30,
        );
        await Future<void>.delayed(const Duration(seconds: 1));
        await _cli([
          "sendtoaddress",
          await _cli(["getnewaddress"]),
          "1",
        ]);
        await Future<void>.delayed(const Duration(seconds: 3));
        paid = await _cli(["sendtoaddress", mine, "1"]);
        r = await watched;
        if (!r.newBlock || round == 3) break;
      }
      expect(r.changed, isTrue);
      expect(r.newBlock, isFalse);
      expect(r.txids, [paid]);

      // A new block wakes us.
      final next = bridge.watch(
        height: height,
        mempoolSeq: r.mempoolSeq,
        addresses: [mine],
        timeoutSeconds: 30,
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      await _cli(["generate", "1"]);
      final b = await next;
      expect(b.newBlock, isTrue);
      expect(b.height, greaterThan(height));

      // A sequence the bridge never issued asks for a full resync.
      final reset = await bridge.watch(
        height: b.height,
        hash: b.hash,
        mempoolSeq: 1 << 40,
        timeoutSeconds: 5,
      );
      expect(reset.reset, isTrue);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
