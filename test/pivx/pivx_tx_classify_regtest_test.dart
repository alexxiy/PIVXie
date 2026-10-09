// How the history shows PIVX transactions (parsePivxTx), checked on real
// regtest transactions built like the wallet builds them: shielding,
// unshielding, shield to own shield, transparent to own transparent
// (e.g. a masternode collateral) and an external send.
//
// Run on the build VM (shares the regtest chain: --concurrency=1):
//   PIVX_BRIDGE=http://127.0.0.1:3000 \
//   PIVX_CLI="/opt/pivx/bin/pivx-cli -datadir=/srv/pivx-regtest -conf=/srv/pivx-regtest/pivx.conf" \
//   PIVX_SHIELD_LIB=/root/work/pivxshield/rust/target/release/libpivx_shield_ffi.so \
//   PIVX_PARAMS_DIR=/root/.pivx-params \
//   flutter test --concurrency=1 test/pivx/pivx_tx_classify_regtest_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:flutter_libpivxshield/flutter_libpivxshield.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/models/isar/models/blockchain_data/transaction.dart';
import 'package:paymint/models/isar/models/blockchain_data/v2/transaction_v2.dart';
import 'package:paymint/utilities/enums/derive_path_type_enum.dart';
import 'package:paymint/utilities/extensions/extensions.dart';
import 'package:paymint/wallets/api/pivx/pivx_bridge_client.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';
import 'package:paymint/wallets/wallet/impl/pivx/pivx_shield_stream.dart';
import 'package:paymint/wallets/wallet/impl/pivx/pivx_tx_parser.dart';

final _mnemonic = bip39.generateMnemonic();
const _coin = 100000000;

Future<String> _cli(List<String> args) async {
  final cli = Platform.environment["PIVX_CLI"]!.split(" ");
  final r = await Process.run(cli.first, [...cli.skip(1), ...args]);
  if (r.exitCode != 0) throw Exception("pivx-cli ${args.first}: ${r.stderr}");
  return (r.stdout as String).trim();
}

/// The wallet's shield scan, reduced to what parsing needs.
class _Scanner {
  _Scanner(this.bridge, this.extfvk, this.height, this.tree);

  final PivxBridgeClient bridge;
  final String extfvk;
  int height;
  String tree;
  List<Map<String, dynamic>> notes = [];
  final nullifierNotes = <String, Map<String, dynamic>>{};
  final txInfo = <String, Map<String, dynamic>>{};

  /// Scan what the bridge has (its stream only carries blocks with
  /// shield transactions).
  Future<void> sync() async {
    final blocks = await parsePivxShieldStream(
      bridge.shieldData(height + 1),
    ).toList();
    if (blocks.isNotEmpty) {
      final r = await PivxShield.handleBlocks(
        tree: tree,
        blocks: [for (final b in blocks) b.txs],
        extfvk: extfvk,
        isTestnet: true,
        notes: notes,
      );
      for (final n in r["decrypted_new_notes"] as List) {
        nullifierNotes[(n as Map)["nullifier"] as String] = {
          "value": n["value"],
          "address": n["address"],
        };
      }
      final spent = Set<String>.from(r["nullifiers"] as List);
      notes = [
        for (final n in [
          ...r["decrypted_notes"] as List,
          ...r["decrypted_new_notes"] as List,
        ])
          if (!spent.contains((n as Map)["nullifier"]))
            Map<String, dynamic>.from(n),
      ];
      // Same shape as PivxShieldState.txInfo.
      for (final w in r["wallet_transactions"] as List) {
        final wtx = Map<String, dynamic>.from(w as Map);
        txInfo[wtx["txid"] as String] = {
          "received": wtx["received"],
          "spentNullifiers": [
            for (final nf in wtx["nullifiers"] as List)
              if (nullifierNotes.containsKey(nf)) nf,
          ],
          "sent": wtx["sent"] ?? const [],
        };
      }
      tree = r["commitment_tree"] as String;
      height = blocks.last.height;
    }
  }
}

void main() {
  final env = Platform.environment;
  final skip = env["PIVX_BRIDGE"] == null || env["PIVX_SHIELD_LIB"] == null
      ? "PIVX_BRIDGE / PIVX_SHIELD_LIB not set"
      : null;

  final coin = Pivx(CryptoCurrencyNetwork.test);
  late PivxBridgeClient bridge;
  late Uint8List seed;
  late String extsk;
  late _Scanner scanner;
  late String shieldAddress; // handed out
  late String shieldChange; // next one: not handed out
  late coinlib.HDPrivateKey receive0;
  late String tReceive0;
  late String tReceive1;
  late String tChange0;

  coinlib.HDPrivateKey key(int chain, int index) =>
      coinlib.HDPrivateKey.fromSeed(seed).derivePath(
        coin.constructDerivePath(
          derivePathType: DerivePathType.bip44,
          chain: chain,
          index: index,
        ),
      );
  String address(coinlib.HDKey k) => coin
      .getAddressForPublicKey(
        publicKey: k.publicKey,
        derivePathType: DerivePathType.bip44,
      )
      .address
      .toString();

  Future<Map<String, dynamic>> utxoOf(String txid, String address) async {
    for (int i = 0; i < 40; i++) {
      final found = (await bridge.utxo(address)).where(
        (u) => u["txid"] == txid && (u["confirmations"] as int) > 0,
      );
      if (found.isNotEmpty) return found.first;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw Exception("utxo $txid not indexed");
  }

  /// Mine [txid], scan it and parse it the way the wallet does.
  Future<TransactionV2> confirmAndParse(String txid) async {
    await _cli(["generate", "1"]);
    var json = await bridge.tx(txid);
    for (int i = 0; (json["blockHeight"] as int? ?? -1) <= 0; i++) {
      if (i == 40) throw Exception("$txid not confirmed on the bridge");
      await Future<void>.delayed(const Duration(milliseconds: 500));
      json = await bridge.tx(txid);
    }
    await scanner.sync();
    final tx = parsePivxTx(
      json,
      walletId: "w",
      fractionDigits: coin.fractionDigits,
      receiving: {tReceive0, tReceive1},
      change: {tChange0},
      shieldAddresses: {shieldAddress},
      shield: scanner.txInfo[txid],
      nullifierNotes: scanner.nullifierNotes,
    )!;
    // Shown without throwing (the card computes these).
    tx.getFee(fractionDigits: coin.fractionDigits);
    tx.getAmountReceivedInThisWallet(fractionDigits: coin.fractionDigits);
    tx.getAmountSentFromThisWallet(
      fractionDigits: coin.fractionDigits,
      subtractFee: true,
    );
    return tx;
  }

  int shown(TransactionV2 tx) => tx
      .getAmountReceivedInThisWallet(fractionDigits: coin.fractionDigits)
      .raw
      .toInt();

  setUpAll(() async {
    if (skip != null) return;
    await coinlib.loadCoinlib();
    bridge = PivxBridgeClient(baseUri: Uri.parse(env["PIVX_BRIDGE"]!));
    seed = bip39.mnemonicToSeed(_mnemonic);
    extsk = PivxShield.extendedSpendingKey(
      seed: seed.sublist(0, 32),
      coinType: 1,
    );
    final extfvk = PivxShield.extendedFullViewingKey(
      extsk: extsk,
      isTestnet: true,
    );
    final cp = PivxShield.closestCheckpoint(
      height: await bridge.getBlockCount(),
      isTestnet: true,
    );
    scanner = _Scanner(bridge, extfvk, cp.height, cp.tree);
    final first = PivxShield.defaultAddress(extfvk: extfvk, isTestnet: true);
    shieldAddress = first.address;
    shieldChange = PivxShield.nextAddress(
      extfvk: extfvk,
      diversifierIndex: first.diversifierIndex,
      isTestnet: true,
    ).address;
    receive0 = key(0, 0);
    tReceive0 = address(receive0);
    tReceive1 = address(key(0, 1));
    tChange0 = address(key(1, 0));
    final dir = env["PIVX_PARAMS_DIR"]!;
    await PivxShield.loadProver(
      outputParamsPath: "$dir/sapling-output.params",
      spendParamsPath: "$dir/sapling-spend.params",
    );
  });

  test("transparent -> own transparent shows the amount moved, not the change "
      "(masternode collateral)", () async {
    final fund = await _cli(["sendtoaddress", tReceive0, "50"]);
    await _cli(["generate", "1"]);
    final u = await utxoOf(fund, tReceive0);
    final value = BigInt.parse(u["value"] as String);
    const fee = 10000;
    var tx = coinlib.Transaction(version: 1, inputs: [], outputs: [])
        .addInput(
          coinlib.P2PKHInput(
            prevOut: coinlib.OutPoint(
              Uint8List.fromList(fund.toUint8ListFromHex.reversed.toList()),
              u["vout"] as int,
            ),
            publicKey: receive0.publicKey,
          ),
        )
        .addOutput(
          coinlib.Output.fromAddress(
            BigInt.from(10 * _coin),
            coinlib.Address.fromString(tReceive1, coin.networkParams),
          ),
        )
        .addOutput(
          coinlib.Output.fromAddress(
            value - BigInt.from(10 * _coin + fee),
            coinlib.Address.fromString(tChange0, coin.networkParams),
          ),
        );
    tx = tx.signLegacy(inputN: 0, key: receive0.privateKey);
    final txid = await bridge.sendTx(tx.toHex());

    final parsed = await confirmAndParse(txid);
    expect(parsed.type, TransactionType.sentToSelf);
    expect(parsed.pivxKind, isNull);
    expect(shown(parsed), 10 * _coin);
    expect(parsed.pivxChangeAddresses, {tChange0});
  }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));

  test("transparent -> own shield is Shielded with the shielded amount",
      () async {
    final fund = await _cli(["sendtoaddress", tReceive0, "20"]);
    await _cli(["generate", "1"]);
    final u = await utxoOf(fund, tReceive0);
    final r = await PivxShield.createTransaction(
      utxos: [
        {
          "txid": fund,
          "vout": u["vout"],
          "amount": int.parse(u["value"] as String),
          "private_key": receive0.privateKey.data.toHex,
          "script": coinlib.Address.fromString(
            tReceive0,
            coin.networkParams,
          ).program.script.compiled.toHex,
        },
      ],
      extsk: extsk,
      toAddress: shieldAddress,
      changeAddress: tChange0,
      amount: 7 * _coin,
      blockHeight: (await bridge.getBlockCount()) + 1,
      isTestnet: true,
    );
    final txid = await bridge.sendTx(r["txhex"] as String);

    final parsed = await confirmAndParse(txid);
    expect(parsed.type, TransactionType.sentToSelf);
    expect(parsed.pivxKind, PivxTxKind.shield);
    expect(shown(parsed), 7 * _coin);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));

  test("shield -> own transparent is Unshielded with the amount", () async {
    final r = await PivxShield.createTransaction(
      notes: scanner.notes,
      extsk: extsk,
      toAddress: tReceive0,
      changeAddress: shieldChange,
      amount: 2 * _coin,
      blockHeight: (await bridge.getBlockCount()) + 1,
      isTestnet: true,
    );
    final txid = await bridge.sendTx(r["txhex"] as String);

    // Unconfirmed, the bridge only sees a transparent output to us (no
    // inputs): still shown without errors.
    final pending = parsePivxTx(
      await bridge.tx(txid),
      walletId: "w",
      fractionDigits: coin.fractionDigits,
      receiving: {tReceive0, tReceive1},
      change: {tChange0},
      shieldAddresses: {shieldAddress},
    )!;
    pending.getFee(fractionDigits: coin.fractionDigits);

    final parsed = await confirmAndParse(txid);
    expect(parsed.type, TransactionType.sentToSelf);
    expect(parsed.pivxKind, PivxTxKind.unshield);
    expect(shown(parsed), 2 * _coin);
    expect(parsed.pivxChangeAddresses, {shieldChange});
  }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));

  test("shield -> own shield shows the amount sent, not the change",
      () async {
    final r = await PivxShield.createTransaction(
      notes: scanner.notes,
      extsk: extsk,
      toAddress: shieldAddress,
      changeAddress: shieldChange,
      amount: 1 * _coin,
      blockHeight: (await bridge.getBlockCount()) + 1,
      isTestnet: true,
    );
    final txid = await bridge.sendTx(r["txhex"] as String);

    final parsed = await confirmAndParse(txid);
    expect(parsed.type, TransactionType.sentToSelf);
    expect(parsed.pivxKind, isNull);
    expect(shown(parsed), 1 * _coin);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));

  test("shield -> someone else is Sent with the amount", () async {
    final dest = await _cli(["getnewaddress"]);
    final r = await PivxShield.createTransaction(
      notes: scanner.notes,
      extsk: extsk,
      toAddress: dest,
      changeAddress: shieldChange,
      amount: 1 * _coin,
      blockHeight: (await bridge.getBlockCount()) + 1,
      isTestnet: true,
    );
    final txid = await bridge.sendTx(r["txhex"] as String);

    final parsed = await confirmAndParse(txid);
    expect(parsed.type, TransactionType.outgoing);
    expect(
      parsed
          .getAmountSentFromThisWallet(
            fractionDigits: coin.fractionDigits,
            subtractFee: true,
          )
          .raw
          .toInt(),
      1 * _coin,
    );
  }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));
}
