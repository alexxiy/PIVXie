// End-to-end shield (Sapling) checks against regtest pivxd + pivx-bridge,
// using the native library, the wallet's stream parser and bridge client.
//
// Both regtest suites share one regtest chain (they mine blocks), so
// run them with --concurrency=1.
//
// Run on the build VM:
//   PIVX_BRIDGE=http://127.0.0.1:3000 \
//   PIVX_CLI="/opt/pivx/bin/pivx-cli -datadir=/srv/pivx-regtest -conf=/srv/pivx-regtest/pivx.conf" \
//   PIVX_SHIELD_LIB=/root/work/pivxshield/rust/target/release/libpivx_shield_ffi.so \
//   PIVX_PARAMS_DIR=/root/.pivx-params \
//   flutter test --concurrency=1 test/pivx/pivx_shield_regtest_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:flutter_libpivxshield/flutter_libpivxshield.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/utilities/enums/derive_path_type_enum.dart';
import 'package:paymint/utilities/extensions/extensions.dart';
import 'package:paymint/wallets/api/pivx/pivx_bridge_client.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';
import 'package:paymint/wallets/wallet/impl/pivx/pivx_shield_stream.dart';

// A fresh mnemonic per run keeps runs independent on a reused regtest chain.
final _mnemonic = bip39.generateMnemonic();

Future<String> _cli(List<String> args) async {
  final cli = Platform.environment["PIVX_CLI"]!.split(" ");
  final r = await Process.run(cli.first, [...cli.skip(1), ...args]);
  if (r.exitCode != 0) throw Exception("pivx-cli ${args.first}: ${r.stderr}");
  return (r.stdout as String).trim();
}

Future<void> _waitFor(Future<bool> Function() check) async {
  for (int i = 0; i < 40; i++) {
    if (await check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw Exception("timed out");
}

/// Minimal port of the wallet's scanning loop (see pivx_wallet_shield.dart).
class _Scanner {
  _Scanner(this.bridge, this.extfvk, this.height, this.tree);

  final PivxBridgeClient bridge;
  final String extfvk;
  int height;
  String tree;
  List<Map<String, dynamic>> notes = [];
  final walletTxs = <Map<String, dynamic>>[];

  Future<void> sync() async {
    final blocks = await parsePivxShieldStream(bridge.shieldData(height + 1)).toList();
    if (blocks.isEmpty) return;
    final r = await PivxShield.handleBlocks(
      tree: tree,
      blocks: [for (final b in blocks) b.txs],
      extfvk: extfvk,
      isTestnet: true,
      notes: notes,
    );
    final spent = Set<String>.from(r["nullifiers"] as List);
    notes = [
      for (final n in [...r["decrypted_notes"] as List, ...r["decrypted_new_notes"] as List])
        if (!spent.contains((n as Map)["nullifier"])) Map<String, dynamic>.from(n),
    ];
    walletTxs.addAll((r["wallet_transactions"] as List).map((e) => Map<String, dynamic>.from(e as Map)));
    tree = r["commitment_tree"] as String;
    height = blocks.last.height;
    // Same verification as the wallet.
    expect(PivxShield.saplingRoot(tree), await bridge.finalSaplingRoot(height));
  }

  int get balance => notes.fold(0, (p, n) => p + (n["value"] as num).toInt());
}

void main() {
  final bridgeUrl = Platform.environment["PIVX_BRIDGE"];
  final skip = bridgeUrl == null || Platform.environment["PIVX_SHIELD_LIB"] == null
      ? "PIVX_BRIDGE / PIVX_SHIELD_LIB not set"
      : null;

  final coin = Pivx(CryptoCurrencyNetwork.test);
  late PivxBridgeClient bridge;
  late Uint8List seed;
  late String extsk;
  late String extfvk;
  late _Scanner scanner;

  setUpAll(() async {
    if (skip != null) return;
    await coinlib.loadCoinlib();
    bridge = PivxBridgeClient(baseUri: Uri.parse(bridgeUrl!));
    seed = bip39.mnemonicToSeed(_mnemonic);
    extsk = PivxShield.extendedSpendingKey(seed: seed.sublist(0, 32), coinType: 1);
    extfvk = PivxShield.extendedFullViewingKey(extsk: extsk, isTestnet: true);
    // New wallet: start at the tip, like the wallet does.
    final cp = PivxShield.closestCheckpoint(height: await bridge.getBlockCount(), isTestnet: true);
    scanner = _Scanner(bridge, extfvk, await bridge.getBlockCount(), cp.tree);
    // Regtest checkpoints only contain the empty tree at 0, so a wallet
    // starting mid-chain must scan from 0 to rebuild the tree.
    scanner.height = cp.height;
    final dir = Platform.environment["PIVX_PARAMS_DIR"]!;
    await PivxShield.loadProver(
      outputParamsPath: "$dir/sapling-output.params",
      spendParamsPath: "$dir/sapling-spend.params",
    );
  });

  test("receives a shield note from the node", () async {
    final address = PivxShield.defaultAddress(extfvk: extfvk, isTestnet: true).address;
    expect(coin.isShieldAddress(address), isTrue);
    await _cli(["shieldsendmany", "from_transparent", '[{"address":"$address","amount":7}]']);
    await _cli(["generate", "1"]);
    await _waitFor(() async {
      await scanner.sync();
      return scanner.balance == 700000000;
    });
    expect(scanner.notes.single["address"], address);
    expect(scanner.walletTxs.last["received"][0]["value"], 700000000);
    // Coin control identifies notes by txid + output index.
    expect(
      scanner.walletTxs.last["received"][0]["nullifier"],
      scanner.notes.single["nullifier"],
    );
    expect(scanner.walletTxs.last["received"][0]["index"], isA<int>());
  }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));

  test("spends shield -> transparent with shield change", () async {
    final change = PivxShield.nextAddress(
      extfvk: extfvk,
      diversifierIndex: PivxShield.defaultAddress(extfvk: extfvk, isTestnet: true).diversifierIndex,
      isTestnet: true,
    ).address;
    final dest = await _cli(["getnewaddress"]);
    final height = await bridge.getBlockCount();
    final r = await PivxShield.createTransaction(
      notes: scanner.notes,
      extsk: extsk,
      toAddress: dest,
      changeAddress: change,
      amount: 200000000,
      blockHeight: height + 1,
      isTestnet: true,
    );
    final txid = await bridge.sendTx(r["txhex"] as String);
    expect(txid, r["txid"]);
    expect(await _cli(["getrawmempool"]), contains(txid));
    await _cli(["generate", "1"]);
    final fee = r["fee"] as int;
    await _waitFor(() async {
      await scanner.sync();
      return scanner.balance == 700000000 - 200000000 - fee;
    });
    expect(scanner.notes.single["address"], change);
    // The bridge's fee for the tx matches the library's.
    expect((await bridge.tx(txid))["fees"], "$fee");
  }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));

  test("shields transparent coins (utxos -> own shield address)", () async {
    final path = coin.constructDerivePath(derivePathType: DerivePathType.bip44, chain: 0, index: 0);
    final key = coinlib.HDPrivateKey.fromSeed(seed).derivePath(path);
    final tAddress = coin.getAddressForPublicKey(publicKey: key.publicKey, derivePathType: DerivePathType.bip44).address.toString();
    final fundTxid = await _cli(["sendtoaddress", tAddress, "5"]);
    await _cli(["generate", "1"]);
    late Map<String, dynamic> utxo;
    await _waitFor(() async {
      final list = await bridge.utxo(tAddress);
      final found = list.where((u) => u["txid"] == fundTxid && (u["confirmations"] as int) > 0);
      if (found.isEmpty) return false;
      utxo = found.first;
      return true;
    });

    final shieldAddress = PivxShield.defaultAddress(extfvk: extfvk, isTestnet: true).address;
    final before = scanner.balance;
    final r = await PivxShield.createTransaction(
      utxos: [
        {
          "txid": fundTxid,
          "vout": utxo["vout"],
          "amount": int.parse(utxo["value"] as String),
          "private_key": key.privateKey.data.toHex,
          "script": coinlib.Address.fromString(tAddress, coin.networkParams).program.script.compiled.toHex,
        },
      ],
      extsk: extsk,
      toAddress: shieldAddress,
      changeAddress: tAddress,
      amount: 300000000,
      blockHeight: (await bridge.getBlockCount()) + 1,
      isTestnet: true,
    );
    expect(r["nullifiers"], ["$fundTxid,${utxo["vout"]}"]);
    final txid = await bridge.sendTx(r["txhex"] as String);
    await _cli(["generate", "1"]);
    await _waitFor(() async {
      await scanner.sync();
      return scanner.balance == before + 300000000;
    });
    // Transparent change came back to us.
    final t = await bridge.tx(txid);
    expect((t["vout"] as List).any((o) => (o["addresses"] as List).contains(tAddress)), isTrue);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));

  test("coin control: useAllInputs spends every selected note", () async {
    expect(scanner.notes.length, greaterThanOrEqualTo(2));
    final dest = await _cli(["getnewaddress"]);
    final change = PivxShield.defaultAddress(extfvk: extfvk, isTestnet: true).address;
    final height = (await bridge.getBlockCount()) + 1;
    Future<Map<String, dynamic>> build(bool all) => PivxShield.createTransaction(
      notes: scanner.notes,
      extsk: extsk,
      toAddress: dest,
      changeAddress: change,
      amount: 10000000,
      blockHeight: height,
      isTestnet: true,
      useAllInputs: all,
    );
    // A small amount needs one note; with coin control every note goes in.
    expect((await build(false))["nullifiers"], hasLength(1));
    final r = await build(true);
    expect(r["nullifiers"], hasLength(scanner.notes.length));
    final before = scanner.balance;
    await bridge.sendTx(r["txhex"] as String);
    await _cli(["generate", "1"]);
    await _waitFor(() async {
      await scanner.sync();
      return scanner.notes.length == 1;
    });
    expect(scanner.balance, before - 10000000 - (r["fee"] as int));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));

  test("subtractFee: the recipient pays the fee", () async {
    final dest = await _cli(["getnewaddress"]);
    final change = PivxShield.defaultAddress(extfvk: extfvk, isTestnet: true).address;
    final before = scanner.balance;
    // Sending everything without subtractFee must fail, not quietly
    // take the fee out of the amount.
    await expectLater(
      PivxShield.createTransaction(
        notes: scanner.notes,
        extsk: extsk,
        toAddress: dest,
        changeAddress: change,
        amount: before,
        blockHeight: (await bridge.getBlockCount()) + 1,
        isTestnet: true,
      ),
      throwsA(predicate((e) => e.toString().contains("Not enough balance"))),
    );
    final r = await PivxShield.createTransaction(
      notes: scanner.notes,
      extsk: extsk,
      toAddress: dest,
      changeAddress: change,
      amount: 50000000,
      blockHeight: (await bridge.getBlockCount()) + 1,
      isTestnet: true,
      subtractFee: true,
    );
    final fee = r["fee"] as int;
    final txid = await bridge.sendTx(r["txhex"] as String);
    await _cli(["generate", "1"]);
    await _waitFor(() async {
      await scanner.sync();
      return scanner.balance == before - 50000000;
    });
    final t = await bridge.tx(txid);
    final paid = (t["vout"] as List).firstWhere(
      (o) => (o["addresses"] as List).contains(dest),
    );
    expect(paid["value"], "${50000000 - fee}");
  }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));

  test("shield -> someone else's shield address: no phantom note, sent output recovered", () async {
    final dest = await _cli(["getnewshieldaddress"]);
    final change = PivxShield.defaultAddress(extfvk: extfvk, isTestnet: true).address;
    final before = scanner.balance;
    const memo = "outgoing memo test";
    final r = await PivxShield.createTransaction(
      notes: scanner.notes,
      extsk: extsk,
      toAddress: dest,
      changeAddress: change,
      amount: 20000000,
      blockHeight: (await bridge.getBlockCount()) + 1,
      isTestnet: true,
      memo: memo,
    );
    final txid = await bridge.sendTx(r["txhex"] as String);
    await _cli(["generate", "1"]);
    await _waitFor(() async {
      await scanner.sync();
      return scanner.walletTxs.any((w) => w["txid"] == txid);
    });
    // Only our change is ours; the recipient's note is not.
    expect(scanner.balance, before - 20000000 - (r["fee"] as int));
    for (final n in scanner.notes) {
      expect(n["address"], isNot(dest));
    }
    // The sender sees where it went (outgoing viewing key).
    final w = scanner.walletTxs.lastWhere((w) => w["txid"] == txid);
    final sent = (w["sent"] as List).single as Map;
    expect(sent["address"], dest);
    expect(sent["value"], 20000000);
    expect(sent["memo"], memo);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));
}
