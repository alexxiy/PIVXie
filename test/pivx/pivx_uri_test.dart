import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/utilities/address_utils.dart';

void main() {
  const address =
      "ptestsapling1e57sd7q5yuq4kyny6v35c44sjp8g8c3ah59f8r7fcaueu3w8cuj93kpfcmwgg0t9e6tc582vh66";

  test("shield memo survives a payment URI round trip", () {
    const memo = "Invoice #42: 100% paid & thanks";
    final uri = AddressUtils.buildUriString("pivx", address, {
      "amount": "1.5",
      "memo": memo,
    });
    final parsed = AddressUtils.parsePaymentUri(uri)!;
    expect(parsed.address, address);
    expect(parsed.amount, "1.5");
    expect(parsed.additionalParams["memo"], memo);
  });

  test("memo from a hand-written URI", () {
    final parsed = AddressUtils.parsePaymentUri(
      "pivx:$address?memo=coffee%20money",
    )!;
    expect(parsed.additionalParams["memo"], "coffee money");
  });
}
