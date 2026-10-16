// Importing PIVX Core's masternode.conf: which lines are added, and why
// the others are skipped.
import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/models/isar/models/isar_models.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';
import 'package:paymint/wallets/wallet/impl/pivx_wallet.dart';

void main() {
  setUpAll(() async => coinlib.loadCoinlib());

  final coin = Pivx(CryptoCurrencyNetwork.main);
  const collateral = 10000 * 100000000;

  String key() => coinlib
      .WIF(
        privkey: coinlib.ECPrivateKey.generate(compressed: false),
        version: coin.networkParams.wifPrefix,
      )
      .toString();

  bool isValidKey(String k) {
    try {
      coinlib.WIF.fromString(k, version: coin.networkParams.wifPrefix);
      return true;
    } catch (_) {
      return false;
    }
  }

  String txid(int n) => n.toRadixString(16).padLeft(64, "0");

  UTXO output(int n, {int vout = 0, int value = collateral, bool? used}) =>
      UTXO(
        walletId: "w",
        txid: txid(n),
        vout: vout,
        value: value,
        name: "",
        isBlocked: false,
        blockedReason: null,
        isCoinbase: false,
        blockHash: "b",
        blockHeight: 100,
        blockTime: 1,
        address: "Daddr$n",
        used: used,
      );

  PivxMasternode existing(String label, int n, {String? service}) =>
      PivxMasternode(
        label: label,
        address: "Daddr$n",
        txid: txid(n),
        vout: 0,
        createdAt: 1,
        service: service,
      );

  List<PivxMasternodeConfImport> plan(
    String text, {
    List<PivxMasternode> mns = const [],
    List<UTXO> outputs = const [],
  }) => pivxPlanMasternodeConfImport(
    text,
    existing: mns,
    outputs: {for (final u in outputs) pivxOutpointKey(u.txid, u.vout): u},
    collateral: collateral,
    collateralText: "10000 PIV",
    normalizeService: (s) => pivxNormalizeMasternodeService(
      s,
      port: kPivxMasternodePortMain,
      regtest: false,
    ),
    isValidKey: isValidKey,
    now: 1000,
  );

  test("lines as PIVX Core reads them", () {
    final lines = pivxMasternodeConfLines(
      "﻿# Masternode config file\r\n"
      "\n"
      "   \t \n"
      "mn1 1.2.3.4:51472 key txid 0\r\n"
      "  # indented comment\n"
      "mn2\t5.6.7.8:51472  key txid 1 # trailing words\n"
      "#mn3 9.9.9.9:51472 key txid 0\n",
    );
    expect([for (final l in lines) l.line], [4, 6]);
    expect(lines[0].words, ["mn1", "1.2.3.4:51472", "key", "txid", "0"]);
    expect(lines[1].words.take(5), [
      "mn2",
      "5.6.7.8:51472",
      "key",
      "txid",
      "1",
    ]);
  });

  test("adds the masternodes whose collateral is in the wallet", () {
    final k1 = key(), k2 = key();
    final result = plan(
      "# Masternode config file\n"
      "mn1 203.0.113.5:51472 $k1 ${txid(1)} 0\n"
      "MN2 [2001:DB8::1]:51472 $k2 ${txid(2)} 1\n",
      outputs: [output(1), output(2, vout: 1)],
    );
    expect(result.map((r) => r.skipped), [null, null]);
    final mn1 = result[0].masternode!;
    expect(mn1.label, "mn1");
    expect(mn1.service, "203.0.113.5:51472");
    expect(mn1.address, "Daddr1");
    expect(mn1.id, "${txid(1)}:0");
    expect(mn1.createdAt, 1000);
    expect(result[0].key, k1);
    expect(result[1].masternode!.service, "[2001:db8::1]:51472");
    expect(result[1].masternode!.vout, 1);
    expect(result[1].key, k2);
    expect(result[1].line, 3);
  });

  test("keeps the wallet's masternodes and skips what they use", () {
    final result = plan(
      "same 1.1.1.1:51472 ${key()} ${txid(1)} 0\n"
      "sameip 2.2.2.2:51472 ${key()} ${txid(3)} 0\n"
      "ok 3.3.3.3:51472 ${key()} ${txid(4)} 0\n",
      mns: [
        existing("MN1", 1, service: "9.9.9.9:51472"),
        existing("MN2", 2, service: "2.2.2.2:51472"),
      ],
      outputs: [output(1), output(2), output(3), output(4)],
    );
    expect(result.map((r) => r.skipped), [
      "Already added as MN1",
      "This IP is already used by MN2",
      null,
    ]);
    expect(result.map((r) => r.collateralInWallet), [true, true, true]);
  });

  test("skips lines that aren't masternodes of this wallet", () {
    final testnetKey = coinlib.WIF(
      privkey: coinlib.ECPrivateKey.generate(compressed: false),
      version: Pivx(CryptoCurrencyNetwork.test).networkParams.wifPrefix,
    );
    final result = plan(
      "short 1.1.1.1:51472 ${key()}\n"
      "badtx 1.1.1.2:51472 ${key()} nothex 0\n"
      "badindex 1.1.1.3:51472 ${key()} ${txid(1)} x\n"
      "port 1.1.1.4:51474 ${key()} ${txid(1)} 0\n"
      "host pivx.org:51472 ${key()} ${txid(1)} 0\n"
      "key 1.1.1.6:51472 notakey ${txid(1)} 0\n"
      "testkey 1.1.1.7:51472 $testnetKey ${txid(1)} 0\n"
      "elsewhere 1.1.1.8:51472 ${key()} ${txid(9)} 0\n"
      "amount 1.1.1.9:51472 ${key()} ${txid(2)} 0\n"
      "spending 1.1.1.10:51472 ${key()} ${txid(3)} 0\n",
      outputs: [
        output(1),
        output(2, value: collateral - 1),
        output(3, used: true),
      ],
    );
    expect(result.map((r) => r.skipped), [
      startsWith("Not a masternode line"),
      "The collateral isn't a transaction id and index",
      "The collateral isn't a transaction id and index",
      "Masternodes must use port 51472",
      "Not an IP address",
      "The masternode private key isn't valid",
      "The masternode private key isn't valid",
      "Its collateral isn't in this wallet",
      "Its collateral isn't 10000 PIV",
      "Its collateral is being spent",
    ]);
    expect(result.map((r) => r.collateralInWallet), [
      null,
      null,
      null,
      true,
      true,
      true,
      true,
      false,
      true,
      true,
    ]);
    expect(result.every((r) => !r.imported), isTrue);
    expect(result.first.alias, "short");
    expect(result.first.line, 1);
    expect(result.first.service, "");
    expect(result[3].service, "1.1.1.4:51474");
    expect(result[3].collateral, "${txid(1)}:0");
  });

  test("a collateral or IP twice in the file: the first line wins", () {
    final result = plan(
      "a 1.1.1.1:51472 ${key()} ${txid(1)} 0\n"
      "b 1.1.1.2:51472 ${key()} ${txid(1)} 0\n"
      "c 1.1.1.1:51472 ${key()} ${txid(2)} 0\n"
      "d 1.1.1.3:51472 ${key()} ${txid(2)} 0\n",
      outputs: [output(1), output(2)],
    );
    expect(result.map((r) => r.skipped), [
      null,
      "Same collateral as line 1",
      "Same IP as line 1",
      null,
    ]);
  });

  test("a skipped line doesn't block a later one", () {
    final result = plan(
      "a 1.1.1.1:51472 ${key()} ${txid(9)} 0\n"
      "b 1.1.1.1:51472 ${key()} ${txid(1)} 0\n",
      outputs: [output(1)],
    );
    expect(result.map((r) => r.skipped), [
      "Its collateral isn't in this wallet",
      null,
    ]);
  });

  test("aliases are made unique and use PIVXie's characters", () {
    final long = "x" * 40;
    final result = plan(
      "MN1 1.1.1.1:51472 ${key()} ${txid(1)} 0\n"
      "mn1 1.1.1.2:51472 ${key()} ${txid(2)} 0\n"
      "my/node:1 1.1.1.3:51472 ${key()} ${txid(3)} 0\n"
      "$long 1.1.1.4:51472 ${key()} ${txid(4)} 0\n"
      "$long 1.1.1.5:51472 ${key()} ${txid(5)} 0\n"
      "ok 1.1.1.6:51472 ${key()} ${txid(6)} 0\n",
      mns: [existing("mn1", 7)],
      outputs: [for (int n = 1; n <= 6; n++) output(n)],
    );
    expect(result.map((r) => r.masternode!.label), [
      "MN1-2",
      "mn1-3",
      "my_node_1",
      "x" * 32,
      "${"x" * 30}-2",
      "ok",
    ]);
    expect(result.map((r) => r.renamed), [true, true, true, true, true, false]);
  });

  test("server addresses", () {
    String main(String s) => pivxNormalizeMasternodeService(
      s,
      port: kPivxMasternodePortMain,
      regtest: false,
    );
    String regtest(String s) => pivxNormalizeMasternodeService(
      s,
      port: kPivxMasternodePortRegtest,
      regtest: true,
    );
    expect(main(" 203.0.113.5 "), "203.0.113.5:51472");
    expect(main("[::1]"), "[::1]:51472");
    expect(main("2001:db8::1"), "[2001:db8::1]:51472");
    expect(main("[2001:DB8:0:0:0:0:0:1]:51472"), "[2001:db8::1]:51472");
    expect(() => main("203.0.113.5:51474"), throwsFormatException);
    expect(regtest("127.0.0.11"), "127.0.0.11:51476");
    expect(regtest("127.0.0.11:6000"), "127.0.0.11:6000");
    expect(() => regtest("127.0.0.11:51472"), throwsFormatException);
  });
}
