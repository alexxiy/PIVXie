// Masternode keys are uncompressed WIF, as PIVX Core's createmasternodekey.
// With PIVX_CLI set (regtest), the node must accept the key.
import 'dart:io';

import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';

void main() {
  setUpAll(() async => coinlib.loadCoinlib());

  // Same construction as PivxMasternodes.generateMasternodeKey.
  String generate(Pivx coin) => coinlib
      .WIF(
        privkey: coinlib.ECPrivateKey.generate(compressed: false),
        version: coin.networkParams.wifPrefix,
      )
      .toString();

  test("uncompressed WIF with the network prefix", () {
    final main = generate(Pivx(CryptoCurrencyNetwork.main));
    expect(main.length, 51); // uncompressed: no 0x01 suffix
    expect(main.startsWith("8"), isTrue); // PIVX Core masternode keys
    final decoded = coinlib.WIF.fromString(main, version: 212);
    expect(decoded.privkey.compressed, isFalse);
    expect(
      () => coinlib.WIF.fromString(main, version: 239),
      throwsA(isA<coinlib.WifVersionMismatch>()),
    );
  });

  test(
    "PIVX Core accepts the key",
    () async {
      final cli = Platform.environment["PIVX_CLI"]!.split(" ");
      final key = generate(Pivx(CryptoCurrencyNetwork.test));
      final r = await Process.run(cli.first, [
        ...cli.skip(1),
        "importprivkey",
        key,
        "pivxie-mn-key-test",
        "false",
      ]);
      expect(r.exitCode, 0, reason: "${r.stderr}");
    },
    skip: Platform.environment["PIVX_CLI"] == null ? "PIVX_CLI not set" : null,
  );
}
