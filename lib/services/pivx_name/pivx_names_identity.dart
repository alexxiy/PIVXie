import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as c;

/// The key that owns a wallet's names on PIVX.name and signs its commands.
///
/// It comes from the wallet's recovery phrase exactly as the PIVX.name web
/// app makes it from the same phrase: the Ed25519 private key is the
/// SHA-256 of the phrase (words in lowercase, one space apart). Opening
/// the phrase on pivx.name gives the same key, so the same names.
///
/// The BIP39 passphrase isn't part of it (the web app has none), and the
/// accounts of one phrase share the key.
class PivxNamesIdentity {
  PivxNamesIdentity._(this._keyPair, this.publicKey);

  final c.SimpleKeyPair _keyPair;

  /// The public key, 64 lowercase hex characters.
  final String publicKey;

  static final _ed25519 = c.Ed25519();

  /// The key of [mnemonic].
  static Future<PivxNamesIdentity> fromMnemonic(String mnemonic) async {
    final seed = sha256.convert(
      utf8.encode(normalizePivxNamesPhrase(mnemonic)),
    );
    final keyPair = await _ed25519.newKeyPairFromSeed(seed.bytes);
    final publicKey = await keyPair.extractPublicKey();
    return PivxNamesIdentity._(keyPair, _hex(publicKey.bytes));
  }

  /// The Ed25519 signature of [message] (UTF-8), in lowercase hex.
  Future<String> sign(String message) async {
    final signature = await _ed25519.sign(
      utf8.encode(message),
      keyPair: _keyPair,
    );
    return _hex(signature.bytes);
  }
}

/// [mnemonic] as the web app reads a phrase: lowercase, words one space
/// apart.
String normalizePivxNamesPhrase(String mnemonic) =>
    mnemonic.trim().toLowerCase().split(RegExp(r"\s+")).join(" ");

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, "0")).join();
