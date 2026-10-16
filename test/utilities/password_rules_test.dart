import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/utilities/password_rules.dart';

void main() {
  test("a password with everything passes", () {
    expect(passwordMissing("Pivx-2026"), isNull);
    expect(passwordMissing("aB3!xyz"), isNull); // exactly 7
    expect(passwordMissing("Ünïcode9€"), isNull);
  });

  test("says what's missing", () {
    expect(passwordMissing(""), startsWith("Use at least 7 characters and"));
    expect(passwordMissing("aB3!xy"), "Use at least 7 characters.");
    expect(
      passwordMissing("abcdefgh"),
      "Add an upper-case letter, a number and a symbol.",
    );
    expect(passwordMissing("ABCDEFG1!"), "Add a lower-case letter.");
    expect(passwordMissing("Abcdefg!"), "Add a number.");
    expect(passwordMissing("Abcdefg1"), "Add a symbol.");
    expect(passwordMissing("Ab1!"), "Use at least 7 characters.");
    expect(
      passwordMissing("ab1"),
      "Use at least 7 characters and add an upper-case letter and a symbol.",
    );
  });

  test("a space isn't a symbol", () {
    expect(passwordMissing("Abc defg1"), "Add a symbol.");
  });

  test("an emoji counts as one character", () {
    expect(passwordMissing("Ab1😀😀"), "Use at least 7 characters.");
    expect(passwordMissing("Ab1😀😀😀😀"), isNull);
  });

  test("the bar stays red until the rules are met", () {
    final weak = newPasswordFeedback("correct horse battery staple");
    expect(weak.strength, lessThanOrEqualTo(0.25));
    expect(weak.feedback, startsWith("Add"));

    final empty = newPasswordFeedback("");
    expect(empty.feedback, kPasswordRules);
    expect(empty.strength, 0);

    final good = newPasswordFeedback("Correct-horse-battery-9");
    expect(good.strength, 1);
    expect(good.feedback, isNot(contains("No need for symbols")));
  });
}
