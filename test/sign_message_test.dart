import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/pages/settings_views/wallet_settings_view/sign_message_view.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';

void main() {
  setUpAll(() async => coinlib.loadCoinlib());

  final coin = Pivx(CryptoCurrencyNetwork.test);

  // From a PIVX Core 5.6.1 regtest node: dumpprivkey, then signmessage
  // (verifymessage accepts it).
  const wif = "cVc13QmbLXfjCiQMFrZGn1aJ7qnadGUaUNyvqEgESnyNjihANFJL";
  const address = "y89jADiyG3234ipEREabdszZnGJqAfZ4ix";
  const message = "Sign me: Astronaut ✓\nline two";
  const signature =
      "H6JXC2diCh1QGpmneDiyM7qf4r/d/df14rU/s4pKCNLhZ7nmxP1fdYlrTzpWPhqPwz1hGsVPs3HwzyrNKNymrFc=";

  test("PIVX signs messages with Core's prefix", () {
    expect(signedMessageMagic(coin), "DarkNet Signed Message:\n");
  });

  test("a signature matches PIVX Core's", () {
    final key = coinlib.WIF.fromString(wif).privkey;
    final signed = coinlib.MessageSignature.sign(
      key: key,
      message: message,
      prefix: signedMessageMagic(coin),
    );
    expect(signed.toString(), signature);
  });

  test("PIVX Core's signature verifies, a changed message doesn't", () {
    final a = coinlib.Address.fromString(address, coin.networkParams);
    final s = coinlib.MessageSignature.fromBase64(signature);
    final prefix = signedMessageMagic(coin);
    expect(s.verifyAddress(address: a, message: message, prefix: prefix), true);
    expect(
      s.verifyAddress(address: a, message: "$message ", prefix: prefix),
      false,
    );
  });
}
