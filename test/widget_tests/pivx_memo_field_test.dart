import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/widgets/pivx_memo_field.dart';

TextEditingValue _v(String text) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: text.length),
);

void main() {
  final f = Utf8LengthLimitingFormatter(10);

  test("counts UTF-8 bytes, not characters", () {
    expect(utf8Length("abc"), 3);
    expect(utf8Length("é"), 2);
    expect(utf8Length("Ж"), 2);
    expect(utf8Length("€"), 3);
    expect(utf8Length("😀"), 4);
  });

  test("text within the limit is kept", () {
    final v = f.formatEditUpdate(_v("abc"), _v("abcé"));
    expect(v.text, "abcé");
  });

  test("typing past the limit does nothing", () {
    final v = f.formatEditUpdate(_v("abcdefghi"), _v("abcdefghi😀"));
    expect(v.text, "abcdefghi");
  });

  test("a paste is cut at the last whole character that fits", () {
    final v = f.formatEditUpdate(_v("ab"), _v("ab😀😀😀"));
    // 2 + 4 + 4 = 10 bytes; the third emoji doesn't fit.
    expect(v.text, "ab😀😀");
    expect(v.selection.baseOffset, v.text.length);
  });

  test("an insert in the middle keeps the text after it", () {
    final old = const TextEditingValue(
      text: "abcd",
      selection: TextSelection.collapsed(offset: 2),
    );
    final edited = const TextEditingValue(
      text: "abЖЖЖЖcd",
      selection: TextSelection.collapsed(offset: 6),
    );
    final v = f.formatEditUpdate(old, edited);
    // 4 bytes kept around it leave 6 for the insert: three Ж.
    expect(v.text, "abЖЖЖcd");
    expect(v.selection.baseOffset, 5);
  });

  test("truncateUtf8 never splits a character", () {
    expect(truncateUtf8("😀😀", 7), "😀");
    expect(truncateUtf8("👍🏽x", 8), "👍🏽");
    expect(truncateUtf8("👍🏽x", 7), "");
  });
}
