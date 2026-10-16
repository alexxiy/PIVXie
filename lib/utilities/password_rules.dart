import 'package:zxcvbn/zxcvbn.dart';

/// The fewest characters a new app password or backup passphrase may have.
const kPasswordMinLength = 7;

/// The rules for a new app password or backup passphrase, in words.
const kPasswordRules =
    "Use at least $kPasswordMinLength characters, with upper- and lower-case "
    "letters, a number and a symbol.";

final _upper = RegExp(r'\p{Lu}', unicode: true);
final _lower = RegExp(r'\p{Ll}', unicode: true);
final _digit = RegExp(r'\p{Nd}', unicode: true);
final _symbol = RegExp(r'[^\p{L}\p{N}\s]', unicode: true);

/// What [password] still needs to be accepted as a new app password or
/// backup passphrase, or null when it has everything: at least
/// [kPasswordMinLength] characters, an upper-case and a lower-case letter,
/// a number and a symbol. Existing passwords are never checked, so older
/// backups still open.
String? passwordMissing(String password) {
  final add = [
    if (!_upper.hasMatch(password)) "an upper-case letter",
    if (!_lower.hasMatch(password)) "a lower-case letter",
    if (!_digit.hasMatch(password)) "a number",
    if (!_symbol.hasMatch(password)) "a symbol",
  ];
  final short = password.runes.length < kPasswordMinLength;
  if (add.isEmpty && !short) return null;
  final adding = switch (add.length) {
    0 => "",
    1 => "add ${add.first}",
    _ => "add ${add.sublist(0, add.length - 1).join(", ")} and ${add.last}",
  };
  if (!short) return "${adding[0].toUpperCase()}${adding.substring(1)}.";
  return adding.isEmpty
      ? "Use at least $kPasswordMinLength characters."
      : "Use at least $kPasswordMinLength characters and $adding.";
}

final _zxcvbn = Zxcvbn();

/// Text and strength (0 to 1) for the bar under a new password field.
/// Until the rules are met the text says what's missing and the bar stays
/// red; after that it shows how hard the password is to guess.
({String feedback, double strength}) newPasswordFeedback(String password) {
  if (password.isEmpty) return (feedback: kPasswordRules, strength: 0);
  final result = _zxcvbn.evaluate(password);
  final strength = (result.score ?? 0) / 4;
  final missing = passwordMissing(password);
  if (missing != null) {
    return (feedback: missing, strength: strength < 0.25 ? strength : 0.25);
  }
  final tips = {
    if ((result.feedback.warning ?? "").isNotEmpty) result.feedback.warning!,
    ...?result.feedback.suggestions,
  }.where((tip) => !tip.contains("No need for symbols")); // contradicts us
  return (feedback: tips.join("\n"), strength: strength);
}
