import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/utilities/amount/amount.dart';
import 'package:paymint/utilities/amount/amount_unit.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';

void main() {
  test("displayAmount PIV", () {
    final Amount amount = Amount(
      rawValue: BigInt.from(1012345678),
      fractionDigits: 8,
    );

    expect(
      AmountUnit.normal.displayAmount(
        amount: amount,
        locale: "en_US",
        coin: Pivx(CryptoCurrencyNetwork.main),
        maxDecimalPlaces: 8,
      ),
      "10.12345678 PIV",
    );

    expect(
      AmountUnit.milli.displayAmount(
        amount: amount,
        locale: "en_US",
        coin: Pivx(CryptoCurrencyNetwork.main),
        maxDecimalPlaces: 8,
      ),
      "10,123.45678 mPIV",
    );

    expect(
      AmountUnit.micro.displayAmount(
        amount: amount,
        locale: "en_US",
        coin: Pivx(CryptoCurrencyNetwork.main),
        maxDecimalPlaces: 8,
      ),
      "10,123,456.78 µPIV",
    );

    expect(
      AmountUnit.nano.displayAmount(
        amount: amount,
        locale: "en_US",
        coin: Pivx(CryptoCurrencyNetwork.main),
        maxDecimalPlaces: 8,
      ),
      "1,012,345,678 sats",
    );
    final dec = Decimal.parse("10.123456789123456789");

    expect(dec.toString(), "10.123456789123456789");
  });

  test("parse piv string to amount", () {
    final Amount amount = Amount(
      rawValue: BigInt.from(1012345678),
      fractionDigits: 8,
    );

    expect(
      AmountUnit.normal.tryParse(
        "10.12345678 PIV",
        locale: "en_US",
        coin: Pivx(CryptoCurrencyNetwork.main),
      ),
      amount,
    );

    expect(
      AmountUnit.milli.tryParse(
        "10,123.45678 mPIV",
        locale: "en_US",
        coin: Pivx(CryptoCurrencyNetwork.main),
      ),
      amount,
    );

    expect(
      AmountUnit.micro.tryParse(
        "10,123,456.7822 µPIV",
        locale: "en_US",
        coin: Pivx(CryptoCurrencyNetwork.main),
      ),
      amount,
    );

    expect(
      AmountUnit.nano.tryParse(
        "1,012,345,678 sats",
        locale: "en_US",
        coin: Pivx(CryptoCurrencyNetwork.main),
      ),
      amount,
    );
  });
}
