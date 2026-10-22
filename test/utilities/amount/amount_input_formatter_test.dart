import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/utilities/amount/amount_input_formatter.dart';

void main() {
  final formatter = AmountInputFormatter(decimals: 8, locale: "en_US");

  TextEditingValue edit(String text, TextSelection selection) =>
      formatter.formatEditUpdate(
        TextEditingValue.empty,
        TextEditingValue(text: text, selection: selection),
      );

  test("groups thousands and keeps the cursor at the end", () {
    final value = edit("1234567", const TextSelection.collapsed(offset: 7));
    expect(value.text, "1,234,567");
    expect(value.selection.baseOffset, 9);
  });

  test("text set without a selection puts the cursor at the end", () {
    final value = edit("1234.5", const TextSelection.collapsed(offset: -1));
    expect(value.text, "1,234.5");
    expect(value.selection.baseOffset, 7);
  });

  test("cut fraction digits never move the cursor before the start", () {
    // Pasted with the cursor right after the separator: the fraction is
    // cut to 8 digits, less than the 12 characters right of the cursor.
    final leading = edit(
      ".123456789999",
      const TextSelection.collapsed(offset: 1),
    );
    expect(leading.text, ".12345678");
    expect(leading.selection.baseOffset, greaterThanOrEqualTo(0));

    final value = edit(
      "1.12345678999999999999",
      const TextSelection.collapsed(offset: 1),
    );
    expect(value.text, "1.12345678");
    expect(value.selection.baseOffset, greaterThanOrEqualTo(0));
    expect(value.selection.baseOffset, lessThanOrEqualTo(value.text.length));
  });
}
