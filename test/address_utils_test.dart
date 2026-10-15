import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/utilities/address_utils.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';

void main() {
  const String firoAddress = "a6ESWKz7szru5syLtYAPRhHLdKvMq3Yt1j";

  test("condense address", () {
    final condensedAddress = AddressUtils.condenseAddress(firoAddress);
    expect(condensedAddress, "a6ESW...3Yt1j");
  });

  test("parse a valid uri string A", () {
    const uri = "dogecoin:$firoAddress?amount=50&label=eggs";
    final result = AddressUtils.parsePaymentUri(uri);
    expect(result, isNotNull);
    expect(result!.scheme, "dogecoin");
    expect(result.address, firoAddress);
    expect(result.amount, "50");
    expect(result.label, "eggs");
  });

  test("parse a valid uri string B", () {
    const uri = "pivx:$firoAddress?amount=50&message=eggs+are+good";
    final result = AddressUtils.parsePaymentUri(uri);
    expect(result, isNotNull);
    expect(result!.scheme, "pivx");
    expect(result.address, firoAddress);
    expect(result.amount, "50");
    expect(result.message, "eggs are good");
  });

  test("parse a valid uri string C", () {
    const uri = "bitcoin:$firoAddress?amount=50.1&message=eggs%20are%20good%21";
    final result = AddressUtils.parsePaymentUri(uri);
    expect(result, isNotNull);
    expect(result!.scheme, "bitcoin");
    expect(result.address, firoAddress);
    expect(result.amount, "50.1");
    expect(result.message, "eggs are good!");
  });

  test("parse an invalid uri string", () {
    const uri = "firo$firoAddress?amount=50&label=eggs";
    final result = AddressUtils.parsePaymentUri(uri);
    expect(result, isNull);
  });

  test("parse an invalid string", () {
    const uri = "$firoAddress?amount=50&label=eggs";
    final result = AddressUtils.parsePaymentUri(uri);
    expect(result, isNull);
  });

  test("parse an invalid uri string", () {
    const uri = ":::  8 \\ %23";
    expect(AddressUtils.parsePaymentUri(uri), isNull);
  });

  test("parse double prefix type address", () {
    const uri =
        "bitcoin:xel:$firoAddress?amount=50.1&message=eggs%20are%20good%21";
    final result = AddressUtils.parsePaymentUri(uri);
    expect(result, isNotNull);
    expect(result!.scheme, "bitcoin");
    expect(result.address, "xel:$firoAddress");
    expect(result.amount, "50.1");
    expect(result.message, "eggs are good!");
  });

  test("encode a list of (mnemonic) words/strings as a json object", () {
    final List<String> list = [
      "hello",
      "word",
      "something",
      "who",
      "green",
      "seven",
    ];
    final result = AddressUtils.encodeQRSeedData(list);
    expect(
      result,
      '{"mnemonic":["hello","word","something","who","green","seven"]}',
    );
  });

  test("decode a valid json string to Map<String, dynamic>", () {
    const jsonString =
        '{"mnemonic":["hello","word","something","who","green","seven"]}';
    final result = AddressUtils.decodeQRSeedData(jsonString);
    expect(result, {
      "mnemonic": ["hello", "word", "something", "who", "green", "seven"],
    });
  });

  test("decode an invalid json string to Map<String, dynamic>", () {
    const jsonString =
        '{"mnemonic":"hello","word","something","who","green","seven"]}';

    expect(AddressUtils.decodeQRSeedData(jsonString), {});
  });

  test("build a uri string with empty params", () {
    expect(
      AddressUtils.buildUriString(
        Pivx(CryptoCurrencyNetwork.main).uriScheme,
        firoAddress,
        {},
      ),
      "pivx:$firoAddress",
    );
  });

  test("build a uri string with one param", () {
    expect(
      AddressUtils.buildUriString(
        Pivx(CryptoCurrencyNetwork.main).uriScheme,
        firoAddress,
        {"amount": "10.0123"},
      ),
      "pivx:$firoAddress?amount=10.0123",
    );
  });

  test("build a uri string with some params", () {
    expect(
      AddressUtils.buildUriString(
        Pivx(CryptoCurrencyNetwork.main).uriScheme,
        firoAddress,
        {"amount": "10.0123", "message": "Some kind of message!"},
      ),
      "pivx:$firoAddress?amount=10.0123&message=Some+kind+of+message%21",
    );
  });

  test("text that '%' is part of survives", () {
    final result = AddressUtils.parsePaymentUri(
      "pivx:$firoAddress?amount=1&message=100%25%20sure&label=a%2520b",
    )!;
    expect(result.amount, "1");
    expect(result.message, "100% sure");
    expect(result.label, "a%20b");
  });

  test("an amount that isn't a plain number is left out", () {
    for (final amount in ["1e3", "1,5", "-1", "1.2.3", "abc"]) {
      expect(
        AddressUtils.parsePaymentUri("pivx:$firoAddress?amount=$amount")!
            .amount,
        isNull,
        reason: amount,
      );
    }
    expect(
      AddressUtils.parsePaymentUri("pivx:$firoAddress?amount=.5")!.amount,
      ".5",
    );
  });

  test("seed QR codes: JSON, or the words on their own", () {
    const words =
        "abandon abandon abandon abandon abandon abandon abandon abandon "
        "abandon abandon abandon about";
    expect(
      AddressUtils.decodeQRSeedData(
        AddressUtils.encodeQRSeedData(words.split(" ")),
      )["mnemonic"],
      words.split(" "),
    );
    expect(
      AddressUtils.decodeQRSeedData("  ${words.toUpperCase()}\n")["mnemonic"],
      words.split(" "),
    );
    expect(AddressUtils.decodeQRSeedData("pivx:$firoAddress"), isEmpty);
    expect(AddressUtils.decodeQRSeedData("too few words here"), isEmpty);
  });
}
