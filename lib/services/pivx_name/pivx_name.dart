import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// PIVX.name (https://pivx.name): human readable names for shield
/// addresses, such as `alice.pivx`.
///
/// This file holds the parts that need no network: what a name is, and how
/// a record from the indexer is checked against a state root. Every rule
/// here mirrors `pins_core` (pivx-name-prover), which the registry's circuit
/// runs, byte for byte.

/// Zones the registry accepts, after the single dot.
const kPivxNameZones = ["pivx", "private", "secure", "safe"];

/// Longest name, in bytes, zone included.
const kPivxNameMaxLength = 64;

/// A key is 128 bits, so no proof is deeper than this.
const kPivxNameMaxProofDepth = 128;

/// Shield addresses a name can point to: mainnet Sapling only.
const _targetHrp = "ps";

/// Decoded Sapling address: 11-byte diversifier + 32-byte pk_d.
const _saplingPayloadLength = 43;

/// 43 bytes are 69 bech32 characters, plus the separator and 6 of checksum.
const _targetLength = 2 + 1 + 69 + 6;

/// Whether [input] is meant as a name rather than an address: it ends with
/// one of the zones. It may still be malformed (see [normalizePivxName]).
bool looksLikePivxName(String input) {
  final s = input.trim().toLowerCase();
  return kPivxNameZones.any((zone) => s.endsWith(".$zone"));
}

/// [input] as the registry spells it (trimmed, lowercase), or null when it
/// is not a valid name.
String? normalizePivxName(String input) {
  final name = input.trim().toLowerCase();
  return isValidPivxName(name) ? name : null;
}

/// `pins_core::is_domain_valid`: one label of lowercase letters, digits and
/// inner single hyphens, a dot, and a zone; 64 bytes at most.
///
/// These rules make the set of names prefix free (no valid name is the start
/// of another), which keeps the name's place in a record's hash fixed.
bool isValidPivxName(String name) {
  if (name.isEmpty || name.length > kPivxNameMaxLength) return false;
  final parts = name.split(".");
  if (parts.length != 2) return false;
  final label = parts[0];
  if (label.isEmpty || label.startsWith("-") || label.endsWith("-")) {
    return false;
  }
  if (label.contains("--")) return false;
  if (!RegExp(r"^[a-z0-9-]+$").hasMatch(label)) return false;
  return kPivxNameZones.contains(parts[1]);
}

/// `pins_core::is_address_valid`, the address rule of the registry: one
/// mainnet Sapling address in canonical lowercase, of the exact length, with
/// a bech32 (not bech32m) checksum and a 43-byte payload.
///
/// Stricter than checking that a typed address decodes: here the address is
/// a field of a hashed record from a remote party, and fixing its length is
/// part of what keeps the record's fields from sliding into each other.
bool isStrictPivxNameTarget(String address) {
  if (address.length != _targetLength) return false;
  // Bech32 also accepts the uppercase spelling; one address spelt two ways
  // would be two different records.
  if (address != address.toLowerCase()) return false;
  final payload = _bech32Decode(address, _targetHrp);
  return payload != null && payload.length == _saplingPayloadLength;
}

/// A 32-byte root as 64 lowercase hex characters, from [value] with or
/// without a `0x` prefix; null for anything else.
String? parsePivxNameRoot(Object? value) {
  if (value is! String) return null;
  var s = value;
  if (s.startsWith("0x") || s.startsWith("0X")) s = s.substring(2);
  if (!_hex32.hasMatch(s)) return null;
  return s.toLowerCase();
}

/// Checks one resolution record from the indexer (`response` of
/// `/v1.0/resolve/{name}`) against [trustedRoot], and returns the address
/// the name points to, or null if anything is off.
///
/// [trustedRoot] must be the anchor contract's current root. It is never
/// taken from the record: a record that only agrees with its own root
/// proves nothing (a depth 0 proof whose root is its own leaf would pass).
///
/// The record's hash is a plain concatenation without length prefixes (fixed
/// by the registry), so every field is checked to an exact shape first: the
/// owner key 32 bytes, the address one fixed length, price and nonce 8 bytes
/// each, and the name valid. With all of those fixed, no byte can move from
/// one field into its neighbour while the hash stays the same.
String? verifyPivxNameRecord(Object? record, String name, String trustedRoot) {
  final root = parsePivxNameRoot(trustedRoot);
  if (root == null || record is! Map) return null;
  if (!isValidPivxName(name)) return null;

  if (record["domain_name"] != name) return null;

  final target = record["target_address"];
  if (target is! String || !isStrictPivxNameTarget(target)) return null;

  final ownerKey = record["owner_pubkey"];
  if (ownerKey is! String || !_hex32.hasMatch(ownerKey)) return null;

  final price = _u64(record["price"]);
  final nonce = _u64(record["nonce"]);
  if (price == null || nonce == null) return null;

  // A resolution proves inclusion: the name's own record is at the end of
  // the path. "Vacant" and "Blocked" are absence proofs.
  if (record["proof_terminal"] != "Occupied") return null;

  final depth = record["proof_depth"];
  final siblings = record["merkle_proof"];
  if (depth is! int || siblings is! List || siblings.length != depth) {
    return null;
  }
  if (depth > kPivxNameMaxProofDepth) return null;
  final siblingBytes = <Uint8List>[];
  for (final s in siblings) {
    if (s is! String || !_hex32.hasMatch(s)) return null;
    siblingBytes.add(_hexBytes(s));
  }

  // The root the indexer folded to must be the chain's, or the two are
  // talking about different trees.
  if (parsePivxNameRoot(record["smt_root"]) != root) return null;

  final leaf = _hashLeaf(name, _hexBytes(ownerKey), target, price, nonce);
  final folded = _fold(_key(name), leaf, siblingBytes);
  return _toHex(folded) == root ? target : null;
}

final _hex32 = RegExp(r"^[0-9a-fA-F]{64}$");

final _u64Max = (BigInt.one << 64) - BigInt.one;

/// Price and nonce are u64. The indexer sends JSON numbers, or decimal
/// strings once they outgrow a double. Anything else would need coercing,
/// and a coercion is a second spelling of the same value.
BigInt? _u64(Object? value) {
  if (value is int) return value < 0 ? null : BigInt.from(value);
  if (value is String && RegExp(r"^[0-9]{1,20}$").hasMatch(value)) {
    final v = BigInt.parse(value);
    return v > _u64Max ? null : v;
  }
  return null;
}

/// `pins_core::hash_leaf`: SHA-256 of 0x00 ‖ name ‖ owner key ‖ address ‖
/// price (u64 LE) ‖ nonce (u64 LE).
Uint8List _hashLeaf(
  String name,
  Uint8List ownerKey,
  String target,
  BigInt price,
  BigInt nonce,
) {
  final b = BytesBuilder(copy: false)
    ..addByte(0x00)
    ..add(utf8.encode(name))
    ..add(ownerKey)
    ..add(utf8.encode(target))
    ..add(_u64le(price))
    ..add(_u64le(nonce));
  return Uint8List.fromList(sha256.convert(b.takeBytes()).bytes);
}

/// `pins_core::hash_node`: SHA-256 of 0x01 ‖ left ‖ right.
Uint8List _hashNode(Uint8List left, Uint8List right) {
  final b = BytesBuilder(copy: false)
    ..addByte(0x01)
    ..add(left)
    ..add(right);
  return Uint8List.fromList(sha256.convert(b.takeBytes()).bytes);
}

/// The 128-bit path of a name: the first 16 bytes of SHA-256(name).
Uint8List _key(String name) =>
    Uint8List.fromList(sha256.convert(utf8.encode(name)).bytes.sublist(0, 16));

/// Folds a proof from its depth up to the root. Siblings come deepest
/// first, so step i turns on path bit (depth - 1 - i); bit 0 is the most
/// significant bit of byte 0, and a set bit means the right child.
Uint8List _fold(Uint8List key, Uint8List leaf, List<Uint8List> siblings) {
  var h = leaf;
  final n = siblings.length;
  for (var i = 0; i < n; i++) {
    final bit = n - 1 - i;
    final right = (key[bit >> 3] >> (7 - (bit & 7))) & 1 == 1;
    h = right ? _hashNode(siblings[i], h) : _hashNode(h, siblings[i]);
  }
  return h;
}

Uint8List _u64le(BigInt v) {
  final out = Uint8List(8);
  var x = v;
  for (var i = 0; i < 8; i++) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x >>= 8;
  }
  return out;
}

Uint8List _hexBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, "0")).join();

const _bech32Charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

/// Payload of a lowercase bech32 string with human-readable part [hrp], or
/// null. Rejects bech32m and nonzero padding, as the registry does.
Uint8List? _bech32Decode(String s, String hrp) {
  final sep = s.lastIndexOf("1");
  if (sep != hrp.length || s.substring(0, sep) != hrp) return null;
  final data = <int>[];
  for (final c in s.substring(sep + 1).split("")) {
    final v = _bech32Charset.indexOf(c);
    if (v < 0) return null;
    data.add(v);
  }
  if (data.length < 6) return null;

  final values = [
    for (final c in hrp.codeUnits) c >> 5,
    0,
    for (final c in hrp.codeUnits) c & 31,
    ...data,
  ];
  if (_bech32Polymod(values) != 1) return null;

  // 5-bit groups to bytes, without padding: leftover bits must be fewer
  // than 5 and all zero.
  var acc = 0;
  var bits = 0;
  final out = <int>[];
  for (final v in data.sublist(0, data.length - 6)) {
    acc = (acc << 5) | v;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.add((acc >> bits) & 0xff);
    }
    acc &= (1 << bits) - 1;
  }
  if (bits >= 5 || acc != 0) return null;
  return Uint8List.fromList(out);
}

int _bech32Polymod(List<int> values) {
  const gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  var chk = 1;
  for (final v in values) {
    final top = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (var i = 0; i < 5; i++) {
      if ((top >> i) & 1 == 1) chk ^= gen[i];
    }
  }
  return chk;
}
