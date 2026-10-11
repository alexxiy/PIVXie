// Creates a budget proposal like the wallet does: a fee transaction with
// pivxProposalFeeScript (50 PIV burnt in OP_RETURN <hash>), broadcast and
// submitted through pivx-bridge, against a regtest node.
//
// Run on the build VM:
//   PIVX_BRIDGE=http://127.0.0.1:3000 \
//   PIVX_CLI="/opt/pivx/bin/pivx-cli -datadir=/srv/pivx-regtest -conf=/srv/pivx-regtest/pivx.conf" \
//   flutter test --concurrency=1 test/pivx/pivx_proposal_regtest_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/models/isar/models/blockchain_data/v2/transaction_v2.dart';
import 'package:paymint/utilities/extensions/extensions.dart';
import 'package:paymint/wallets/api/pivx/pivx_bridge_client.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';
import 'package:paymint/wallets/wallet/impl/pivx/pivx_tx_parser.dart';
import 'package:paymint/wallets/wallet/impl/pivx_wallet.dart';

Future<String> _cli(List<String> args) async {
  final cli = Platform.environment["PIVX_CLI"]!.split(" ");
  final r = await Process.run(cli.first, [...cli.skip(1), ...args]);
  if (r.exitCode != 0) throw Exception("pivx-cli ${args.first}: ${r.stderr}");
  return (r.stdout as String).trim();
}

void main() {
  final env = Platform.environment;
  final skip = env["PIVX_BRIDGE"] == null || env["PIVX_CLI"] == null
      ? "PIVX_BRIDGE or PIVX_CLI not set"
      : null;

  test(
    "a proposal paid with an OP_RETURN fee is accepted with our hash",
    () async {
      await coinlib.loadCoinlib();
      final bridge = PivxBridgeClient(baseUri: Uri.parse(env["PIVX_BRIDGE"]!));
      final params = Pivx(CryptoCurrencyNetwork.test).networkParams;

      // Coins on a key of ours.
      final key = coinlib.ECPrivateKey.generate();
      final address = coinlib.P2PKHAddress.fromPublicKey(
        key.pubkey,
        version: params.p2pkhPrefix,
      );
      final fundTxid = await _cli(["sendtoaddress", address.toString(), "60"]);
      await _cli(["generate", "1"]);
      final fund =
          jsonDecode(await _cli(["getrawtransaction", fundTxid, "1"])) as Map;
      final vout =
          (fund["vout"] as List).cast<Map>().firstWhere(
                (o) => o["value"] == 60,
              )["n"]
              as int;

      // The proposal: next superblock unless the fee couldn't confirm in
      // time, as proposalStartSuperblocks picks.
      final height = await bridge.getBlockCount();
      var start = height - height % kPivxBudgetCycleTest + kPivxBudgetCycleTest;
      if (start - 10 < height) start += kPivxBudgetCycleTest;
      final name = "PX new ${Random().nextInt(1 << 30)}";
      const url = "https://pivxie.me/proposal";
      final payee = await _cli(["getnewaddress"]);
      final amount = BigInt.from(25 * 100000000);
      final hash = pivxProposalHash(
        name: name,
        url: url,
        blockStart: start,
        blockEnd: pivxProposalBlockEnd(
          blockStart: start,
          payments: 2,
          cycleBlocks: kPivxBudgetCycleTest,
        ),
        amountSats: amount,
        payeeScript: coinlib.Address.fromString(
          payee,
          params,
        ).program.script.compiled,
      );

      // Fee transaction: OP_RETURN 50 PIV + change.
      var tx = coinlib.Transaction(
        version: 1,
        inputs: [
          coinlib.P2PKHInput(
            prevOut: coinlib.OutPoint(
              Uint8List.fromList(fundTxid.toUint8ListFromHex.reversed.toList()),
              vout,
            ),
            publicKey: key.pubkey,
          ),
        ],
        outputs: [
          coinlib.Output.fromScriptBytes(
            BigInt.from(kPivxProposalFeeSats),
            pivxProposalFeeScript(hash),
          ),
          coinlib.Output.fromAddress(
            BigInt.from(60 * 100000000 - kPivxProposalFeeSats - 100000),
            address,
          ),
        ],
      );
      tx = tx.signLegacy(inputN: 0, key: key);
      final feeTxid = await bridge.sendTx(tx.toHex());
      expect(feeTxid, tx.txid);

      Future<String> submit() => bridge.submitBudget(
        name: name,
        url: url,
        payments: 2,
        blockStart: start,
        paymentAddress: payee,
        amount: "25",
        feeTxid: feeTxid,
      );

      // Too few confirmations (regtest needs 3).
      await _cli(["generate", "1"]);
      await expectLater(submit(), throwsA(anything));

      await _cli(["generate", "2"]);
      expect(await submit(), hash);

      // The history shows the fee as burned (once the bridge has the
      // block: its mempool view has no input details).
      var json = await bridge.tx(feeTxid);
      for (var i = 0; (json["blockHeight"] as int? ?? -1) <= 0; i++) {
        if (i == 40) throw Exception("$feeTxid not confirmed on the bridge");
        await Future<void>.delayed(const Duration(milliseconds: 500));
        json = await bridge.tx(feeTxid);
      }
      final parsed = parsePivxTx(
        json,
        walletId: "test",
        fractionDigits: 8,
        receiving: {address.toString()},
        change: const {},
        shieldAddresses: const {},
      )!;
      expect(parsed.pivxKind, PivxTxKind.burn);
      expect(
        parsed.getAmountReceivedInThisWallet(fractionDigits: 8).raw,
        BigInt.from(kPivxProposalFeeSats),
      );

      final info = await bridge.budgetInfo();
      final p = info.firstWhere((e) => e["Hash"] == hash);
      expect(p["Name"], name);
      expect(p["FeeHash"], feeTxid);
      expect(p["BlockStart"], start);
      expect(p["TotalPaymentCount"], 2);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
