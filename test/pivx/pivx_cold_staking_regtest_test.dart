// Cold staking as the owner, against a regtest node that also runs the
// staker: delegate with pivxColdStakeScript, see the bridge list the
// delegated outputs under the owner address, withdraw one with
// PivxColdStakeInput, let the node stake the other, and give it all
// back to the node.
//
// Run on the build VM:
//   PIVX_BRIDGE=http://127.0.0.1:3000 \
//   PIVX_CLI="/opt/pivx/bin/pivx-cli -datadir=/srv/pivx-regtest -conf=/srv/pivx-regtest/pivx.conf" \
//   flutter test --concurrency=1 test/pivx/pivx_cold_staking_regtest_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/models/isar/models/blockchain_data/transaction_type.dart';
import 'package:paymint/models/isar/models/blockchain_data/v2/transaction_v2.dart';
import 'package:paymint/utilities/extensions/extensions.dart';
import 'package:paymint/wallets/api/pivx/pivx_bridge_client.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';
import 'package:paymint/wallets/wallet/impl/pivx/pivx_tx_parser.dart';
import 'package:paymint/wallets/wallet/impl/pivx_wallet.dart';

const _coin = 100000000;

Future<String> _cli(List<String> args) async {
  final cli = Platform.environment["PIVX_CLI"]!.split(" ");
  final r = await Process.run(cli.first, [...cli.skip(1), ...args]);
  if (r.exitCode != 0) throw Exception("pivx-cli ${args.first}: ${r.stderr}");
  return (r.stdout as String).trim();
}

/// Wait (up to a minute) for the bridge to index what the node did.
Future<void> _waitFor(Future<bool> Function() check) async {
  for (var i = 0; i < 60; i++) {
    if (await check()) return;
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  throw Exception("Timed out waiting for the bridge");
}

coinlib.OutPoint _outpoint(String txid, int vout) => coinlib.OutPoint(
  Uint8List.fromList(txid.toUint8ListFromHex.reversed.toList()),
  vout,
);

void main() {
  final env = Platform.environment;
  final skip = env["PIVX_BRIDGE"] == null || env["PIVX_CLI"] == null
      ? "PIVX_BRIDGE or PIVX_CLI not set"
      : null;

  test(
    "delegate, withdraw as the owner, and receive a cold stake reward",
    () async {
      await coinlib.loadCoinlib();
      final bridge = PivxBridgeClient(baseUri: Uri.parse(env["PIVX_BRIDGE"]!));
      final coin = Pivx(CryptoCurrencyNetwork.test);
      final params = coin.networkParams;
      final prefix = coin.stakingAddressPrefix;

      // The owner: a key of ours. The staker: the node, which accepts
      // delegations from our owner address.
      final key = coinlib.ECPrivateKey.generate();
      final owner = coinlib.P2PKHAddress.fromPublicKey(
        key.pubkey,
        version: params.p2pkhPrefix,
      );
      final staker = await _cli(["getnewstakingaddress", "pivxie-test"]);
      final stakerHash = pivxStakingAddressHash(staker, prefix)!;
      expect(pivxStakingAddress(stakerHash, prefix), staker);
      expect(pivxStakingAddressHash(owner.toString(), prefix), isNull);
      await _cli(["delegatoradd", owner.toString()]);

      final fundTxid = await _cli(["sendtoaddress", owner.toString(), "5000"]);
      await _cli(["generate", "1"]);
      final fund =
          jsonDecode(await _cli(["getrawtransaction", fundTxid, "1"])) as Map;
      final fundVout =
          (fund["vout"] as List).cast<Map>().firstWhere(
                (o) => o["value"] == 5000,
              )["n"]
              as int;

      // Delegate 4000 (to be staked) and 2 (to be withdrawn).
      final script = pivxColdStakeScript(
        stakerHash: stakerHash,
        ownerHash: owner.hash,
      );
      expect(pivxIsColdStakeScript(script.toHex), isTrue);
      final parsed = pivxParseColdStakeScript(script)!;
      expect(parsed.staker.toHex, stakerHash.toHex);
      expect(parsed.owner.toHex, owner.hash.toHex);

      var delegation = coinlib.Transaction(
        version: 1,
        inputs: [
          coinlib.P2PKHInput(
            prevOut: _outpoint(fundTxid, fundVout),
            publicKey: key.pubkey,
          ),
        ],
        outputs: [
          coinlib.Output.fromScriptBytes(BigInt.from(4000 * _coin), script),
          coinlib.Output.fromScriptBytes(BigInt.from(2 * _coin), script),
          coinlib.Output.fromAddress(BigInt.from(998 * _coin - 100000), owner),
        ],
      );
      delegation = delegation.signLegacy(inputN: 0, key: key);
      final delegationTxid = await bridge.sendTx(delegation.toHex());
      expect(delegationTxid, delegation.txid);
      await _cli(["generate", "1"]);

      // The node sees our delegation as one it stakes for us.
      final delegators = jsonDecode(await _cli(["listdelegators"])) as List;
      expect(delegators.map((e) => (e as Map)["address"]), contains("$owner"));

      // The bridge lists delegated outputs under the owner address, with
      // the P2CS script in the transaction.
      Map<int, Object?> mine = {};
      await _waitFor(() async {
        mine = {
          for (final u in await bridge.utxo(owner.toString()))
            if (u["txid"] == delegationTxid && (u["confirmations"] as int) > 0)
              u["vout"] as int: u["value"],
        };
        return mine.length == 3;
      });
      expect(mine[0], "${4000 * _coin}");
      expect(mine[1], "${2 * _coin}");
      final outputs = pivxVerifiedOutputs(
        delegationTxid,
        await bridge.rawTx(delegationTxid),
      );
      expect(pivxParseColdStakeScript(outputs[1].script), isNotNull);

      // A wrong key can't take the owner branch.
      final other = coinlib.ECPrivateKey.generate();
      var stolen = coinlib.Transaction(
        version: 1,
        inputs: [
          PivxColdStakeInput(
            prevOut: _outpoint(delegationTxid, 1),
            publicKey: other.pubkey,
            prevScript: script,
          ),
        ],
        outputs: [
          coinlib.Output.fromAddress(BigInt.from(2 * _coin - 100000), owner),
        ],
      );
      stolen = stolen.signLegacy(inputN: 0, key: other);
      await expectLater(bridge.sendTx(stolen.toHex()), throwsA(anything));

      // Withdraw the 2 PIV as the owner.
      var withdrawal = coinlib.Transaction(
        version: 1,
        inputs: [
          PivxColdStakeInput(
            prevOut: _outpoint(delegationTxid, 1),
            publicKey: key.pubkey,
            prevScript: script,
          ),
        ],
        outputs: [
          coinlib.Output.fromAddress(BigInt.from(2 * _coin - 100000), owner),
        ],
      );
      withdrawal = withdrawal.signLegacy(inputN: 0, key: key);
      expect(withdrawal.inputs.first.complete, isTrue);
      expect(await bridge.sendTx(withdrawal.toHex()), withdrawal.txid);
      await _cli(["generate", "1"]);
      await _waitFor(
        () async =>
            (await bridge.utxo(owner.toString()))
                .every((u) => u["txid"] != delegationTxid || u["vout"] != 1),
      );

      // Let the node stake our 4000 PIV. The stake (split in several
      // outputs above the stake split threshold) and its reward stay
      // delegated to the same staker and owner. Once deep enough to stake,
      // the node's other coins (its own and delegations from earlier runs)
      // are locked for a few blocks: its staker skips locked coins, and
      // otherwise rarely picks ours among a thousand.
      Future<bool> unspent() async =>
          (await _cli(["gettxout", delegationTxid, "0"])).isNotEmpty;
      for (var i = 0; i < 25 && await unspent(); i++) {
        await _cli(["generate", "1"]);
      }
      if (await unspent()) {
        final own = (jsonDecode(await _cli(["listunspent", "0"])) as List)
            .cast<Map<String, dynamic>>();
        // In batches: the node's coins outgrow one command line.
        final locked = [
          for (var i = 0; i < own.length; i += 200)
            jsonEncode([
              for (final u in own.skip(i).take(200))
                {"txid": u["txid"], "vout": u["vout"]},
            ]),
        ];
        // Delegations of earlier runs can't be locked: take their owners
        // off the whitelist instead.
        final cold = (jsonDecode(await _cli(["listcoldutxos"])) as List)
            .cast<Map<String, dynamic>>();
        final owners = {
          for (final u in cold)
            if (u["whitelisted"] == "true" && u["coin-owner"] != "$owner")
              u["coin-owner"] as String,
        };
        for (final batch in locked) {
          await _cli(["lockunspent", "false", "true", batch]);
        }
        for (final o in owners) {
          await _cli(["delegatorremove", o]);
        }
        try {
          // With only our delegation to stake, a try can find no kernel
          // ("Couldn't create new blocks"): try again.
          for (var i = 0; i < 10 && await unspent(); i++) {
            try {
              await _cli(["generate", "1"]);
            } catch (e) {
              await Future<void>.delayed(const Duration(seconds: 2));
            }
          }
        } finally {
          for (final batch in locked) {
            await _cli(["lockunspent", "true", "true", batch]);
          }
          for (final o in owners) {
            await _cli(["delegatoradd", o]);
          }
        }
      }
      expect(
        await unspent(),
        isFalse,
        reason: "the delegation was never staked",
      );
      String? stakeTxid;
      await _waitFor(() async {
        for (final u in await bridge.utxo(owner.toString())) {
          if (u["coinstake"] == true) stakeTxid = u["txid"] as String;
        }
        return stakeTxid != null;
      });
      expect(stakeTxid, isNotNull, reason: "the delegation was never staked");
      final staked = pivxVerifiedOutputs(
        stakeTxid!,
        await bridge.rawTx(stakeTxid!),
      );
      final ours = staked.where((o) => o.script.toHex == script.toHex);
      expect(ours.length, greaterThanOrEqualTo(1));
      expect(
        ours.fold(BigInt.zero, (p, o) => p + o.value),
        greaterThan(BigInt.from(4000 * _coin)),
      );
      final listed = (await bridge.utxo(owner.toString()))
          .where((u) => u["txid"] == stakeTxid && u["coinstake"] == true);
      expect(listed.length, ours.length);

      // The history shows the three as delegation, undelegation and cold
      // staking reward.
      Future<TransactionV2> parse(String txid) async => parsePivxTx(
        await bridge.tx(txid),
        walletId: "test",
        fractionDigits: 8,
        receiving: {owner.toString()},
        change: const {},
        shieldAddresses: const {},
        isColdStakeOutpoint: (o) => o.txid == delegationTxid,
      )!;
      final delegated = await parse(delegationTxid);
      expect(delegated.type, TransactionType.sentToSelf);
      expect(delegated.pivxKind, PivxTxKind.delegation);
      expect(
        delegated.getAmountReceivedInThisWallet(fractionDigits: 8).raw,
        BigInt.from(4002 * _coin),
      );
      final withdrawn = await parse(withdrawal.txid);
      expect(withdrawn.pivxKind, PivxTxKind.undelegation);
      final rewarded = await parse(stakeTxid!);
      expect(rewarded.pivxKind, PivxTxKind.coldStakeReward);
      // Rewards are counted per owner from the delegated outputs, which
      // list the staker, then the owner.
      final rewardOut = rewarded.outputs.where(
        (o) => o.walletOwns && pivxIsColdStakeScript(o.scriptPubKeyHex),
      );
      expect(rewardOut.first.addresses, [staker, owner.toString()]);
      expect(
        rewarded.getAmountReceivedInThisWallet(fractionDigits: 8).raw,
        ours.fold(BigInt.zero, (p, o) => p + o.value) -
            BigInt.from(4000 * _coin),
      );

      // Hand the coins back to the node, or every run drains it by 5000:
      // once the stake is mature, the owner spends everything to it.
      await _cli(["delegatorremove", owner.toString()]);
      var coins = <Map<String, dynamic>>[];
      for (var i = 0; i < 20; i++) {
        await _cli(["generate", "10"]);
        coins = await bridge.utxo(owner.toString());
        if (coins.every((u) => (u["confirmations"] as int) > 100)) break;
      }
      final inputs = <coinlib.Input>[];
      var total = BigInt.zero;
      for (final u in coins) {
        final txid = u["txid"] as String;
        final vout = u["vout"] as int;
        final out = pivxVerifiedOutputs(txid, await bridge.rawTx(txid))[vout];
        total += out.value;
        inputs.add(
          pivxIsColdStakeScript(out.script.toHex)
              ? PivxColdStakeInput(
                  prevOut: _outpoint(txid, vout),
                  publicKey: key.pubkey,
                  prevScript: out.script,
                )
              : coinlib.P2PKHInput(
                  prevOut: _outpoint(txid, vout),
                  publicKey: key.pubkey,
                ),
        );
      }
      final node = coinlib.Address.fromString(
        await _cli(["getnewaddress"]),
        params,
      );
      var refund = coinlib.Transaction(
        version: 1,
        inputs: inputs,
        outputs: [
          coinlib.Output.fromAddress(
            total - BigInt.from(10000 * (inputs.length + 1)),
            node,
          ),
        ],
      );
      for (var i = 0; i < inputs.length; i++) {
        refund = refund.signLegacy(inputN: i, key: key);
      }
      expect(await bridge.sendTx(refund.toHex()), refund.txid);
      await _cli(["generate", "1"]);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
