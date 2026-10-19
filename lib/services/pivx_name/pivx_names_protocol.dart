import 'dart:convert';
import 'dart:typed_data';

import 'package:decimal/decimal.dart';

import 'pivx_name.dart';

/// The commands of the PIVX.name registrar (https://pivx.name), as its
/// web app (pivx-name-front) and the indexer's `Protocol` spell them.
///
/// A command is the shielded memo of a payment to the registrar's
/// address: `PiNS:1:<OP>:<name>:<args…>:<nonce>:<signature>`. The amount
/// is the price of the operation, and must be exact (a purchase pays the
/// listing price). The signature is an Ed25519 signature, in lowercase
/// hex, of everything before it.

/// One operation on a name.
enum PivxNamesOp {
  /// Register a free name.
  reg("REG"),

  /// Point a name to another address.
  upd("UPD"),

  /// Give a name to another owner (public key).
  chg("CHG"),

  /// List a name on the marketplace, or change its price.
  lst("LST"),

  /// Take a name off the marketplace.
  ult("ULT"),

  /// Buy a listed name.
  buy("BUY");

  const PivxNamesOp(this.code);

  final String code;

  static PivxNamesOp? fromCode(Object? code) {
    for (final op in values) {
      if (op.code == code) return op;
    }
    return null;
  }

  /// Whether the command carries a target address (the address the name
  /// will point to).
  bool get hasTarget => this == reg || this == upd || this == buy;
}

/// A shielded memo is 512 bytes.
const kPivxNamesMemoMaxBytes = 512;

const _pubkeyHexLength = 64;
const _signatureHexLength = 128;

/// Confirmations the registrar waits for before it acts on a payment, and
/// before a refund is final (NET_TX_CONFIRMATION_THRESHOLD and
/// NET_TX_REFUND_THRESHOLD of the registrar). Defaults for a registrar
/// that doesn't serve them.
const kPivxNamesPaymentConfirmations = 40;
const kPivxNamesRefundConfirmations = 120;

/// Highest listing price, in PIVX. Not a protocol limit: it keeps prices
/// to sane amounts, as the web app does.
const kPivxNamesMaxListingPrice = 50000000;

const _pivxDecimals = 8;
const _satsPerPivx = 100000000;

/// Seconds since the epoch: the nonce of a command or request. The
/// registrar refuses a command whose nonce is ahead of the block that
/// carries it (beyond a few minutes), and one not above the name's last
/// nonce.
int pivxNamesNonce([DateTime? now]) =>
    (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;

/// A command without its signature: what gets signed. [marker] is the
/// registrar's protocol marker ("PiNS" on mainnet).
///
/// - [PivxNamesOp.reg], [PivxNamesOp.upd], [PivxNamesOp.buy]:
///   [target] is the address the name points to, [pubkey] the signer's key.
/// - [PivxNamesOp.chg]: [newOwner] is the new owner's key (the current
///   owner signs).
/// - [PivxNamesOp.lst]: [pubkey] is the owner's key, [priceSats] the price.
/// - [PivxNamesOp.ult]: [pubkey] is the owner's key.
String pivxNamesCommand({
  required String marker,
  required PivxNamesOp op,
  required String name,
  required int nonce,
  String? pubkey,
  String? target,
  String? newOwner,
  BigInt? priceSats,
}) {
  final head = "$marker:1:${op.code}:$name";
  switch (op) {
    case PivxNamesOp.reg:
    case PivxNamesOp.upd:
    case PivxNamesOp.buy:
      return "$head:${target!}:${pubkey!}:$nonce";
    case PivxNamesOp.chg:
      return "$head:${newOwner!}:$nonce";
    case PivxNamesOp.lst:
      return "$head:${pubkey!}:${priceSats!}:$nonce";
    case PivxNamesOp.ult:
      return "$head:${pubkey!}:$nonce";
  }
}

/// The message a withdrawal of the registrar balance signs. Its head
/// matches the commands, with an operation (WDR) no memo can carry, so a
/// withdrawal and a command can never be taken for each other.
String pivxNamesWithdrawMessage({
  required String marker,
  required String pubkey,
  required String address,
  required BigInt amountSats,
  required int nonce,
}) => "$marker:1:WDR:$pubkey:$address:$amountSats:$nonce";

/// The message that proves the history request ([type] "in" or "ref")
/// comes from the key's owner. Shaped like a withdrawal (TXS, no memo's
/// operation), and with the time: the registrar takes it within a minute,
/// so a request somebody has seen can't be replayed later.
String pivxNamesHistoryMessage({
  required String marker,
  required String type,
  required String pubkey,
  required int page,
  required int count,
  required int nonce,
}) => "$marker:1:TXS:$type:$pubkey:$page:$count:$nonce";

/// Whether [command] plus its signature fits a shielded memo.
bool pivxNamesCommandFits(String command) =>
    utf8.encode(command).length + 1 + _signatureHexLength <=
    kPivxNamesMemoMaxBytes;

/// The longest target address a command for [name] can carry: the rest of
/// the memo is fixed. A Sapling address (78 characters) always fits.
int pivxNamesMaxTargetLength({
  required String marker,
  required String name,
  required PivxNamesOp op,
  int? nonce,
}) {
  final overhead =
      "$marker:1:${op.code}:".length +
      name.length +
      1 +
      1 +
      _pubkeyHexLength +
      1 +
      "${nonce ?? pivxNamesNonce()}".length +
      1 +
      _signatureHexLength;
  return kPivxNamesMemoMaxBytes - overhead;
}

/// The command and signature of a full memo, or null when [memo] isn't
/// one.
({String op, String name})? parsePivxNamesMemo(String memo) {
  final parts = memo.split(":");
  if (parts.length < 6 || parts[1] != "1") return null;
  if (PivxNamesOp.fromCode(parts[2]) == null) return null;
  return (op: parts[2], name: parts[3]);
}

/// A listing price typed in PIVX ("12.5"), or in the unit [shift] decimal
/// places below it (3: mPIV), in satoshis; null when it isn't a positive
/// number of whole satoshis, up to [kPivxNamesMaxListingPrice] PIVX.
BigInt? parsePivxNamesPrice(String input, {int shift = 0}) {
  final s = input.trim();
  if (!RegExp(r"^\d+(\.\d+)?$").hasMatch(s)) return null;
  final sats = Decimal.parse(s).shift(_pivxDecimals - shift);
  if (!sats.isInteger ||
      sats <= Decimal.zero ||
      sats > Decimal.fromInt(kPivxNamesMaxListingPrice * _satsPerPivx)) {
    return null;
  }
  return sats.toBigInt();
}

/// [sats] in PIVX, or in the unit [shift] decimal places below it, without
/// trailing zeros: "12.5".
String pivxNamesPivx(BigInt sats, {int shift = 0}) =>
    Decimal.fromBigInt(sats).shift(shift - _pivxDecimals).toString();

/// The name a user typed, as the search field keeps it: lowercase
/// letters, digits and single hyphens, never a leading hyphen.
String sanitizePivxNamesLabel(String input) {
  var s = input.toLowerCase().replaceAll(RegExp(r"[^a-z0-9-]"), "");
  s = s.replaceAll(RegExp(r"-{2,}"), "-");
  while (s.startsWith("-")) {
    s = s.substring(1);
  }
  return s;
}

/// Whether [label] (the part before the zone) is a valid label: letters,
/// digits and inner single hyphens.
bool isValidPivxNamesLabel(String label) =>
    RegExp(r"^[a-z0-9]+(-[a-z0-9]+)*$").hasMatch(label);

/// The label of [name] and its zone (".pivx").
({String label, String zone}) splitPivxName(String name) {
  final dot = name.indexOf(".");
  return dot < 0
      ? (label: name, zone: "")
      : (label: name.substring(0, dot), zone: name.substring(dot));
}

/// Whether [address] can be the target of a name: the registry's address
/// rule (mainnet Sapling, canonical lowercase, exact length).
bool isValidPivxNamesTarget(String address) => isStrictPivxNameTarget(address);

// =============================================================================
// Ed25519 public keys

final _p = (BigInt.one << 255) - BigInt.from(19);
final _d = (-BigInt.from(121665) * _inv(BigInt.from(121666))) % _p;
final _l =
    (BigInt.one << 252) +
    BigInt.parse("27742317777372353535851937790883648493");
final _sqrtM1 = BigInt.two.modPow((_p - BigInt.one) ~/ BigInt.from(4), _p);

BigInt _inv(BigInt x) => x.modPow(_p - BigInt.two, _p);

/// A point in extended coordinates (X, Y, Z, T).
typedef _Point = (BigInt, BigInt, BigInt, BigInt);

_Point _add(_Point a, _Point b) {
  final (x1, y1, z1, t1) = a;
  final (x2, y2, z2, t2) = b;
  final aa = ((y1 - x1) * (y2 - x2)) % _p;
  final bb = ((y1 + x1) * (y2 + x2)) % _p;
  final c = (BigInt.two * t1 * t2 * _d) % _p;
  final dd = (BigInt.two * z1 * z2) % _p;
  final e = bb - aa;
  final f = dd - c;
  final g = dd + c;
  final h = bb + aa;
  return ((e * f) % _p, (g * h) % _p, (f * g) % _p, (e * h) % _p);
}

_Point _mul(_Point p, BigInt k) {
  _Point r = (BigInt.zero, BigInt.one, BigInt.one, BigInt.zero);
  var q = p;
  var n = k;
  while (n > BigInt.zero) {
    if (n.isOdd) r = _add(r, q);
    q = _add(q, q);
    n >>= 1;
  }
  return r;
}

bool _isIdentity(_Point p) {
  final (x, y, z, _) = p;
  return x % _p == BigInt.zero && (y - z) % _p == BigInt.zero;
}

/// Whether [hex] is a public key the registrar accepts as a new owner:
/// 64 lowercase hex characters, a canonical encoding of a point on the
/// curve, of the prime order subgroup (libsodium's
/// `crypto_sign_ed25519_pk_to_curve25519` checks, which the registrar
/// runs).
bool isValidPivxNamesPublicKey(String hex) {
  if (!RegExp(r"^[0-9a-f]{64}$").hasMatch(hex)) return false;
  final bytes = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  final sign = bytes[31] >> 7;
  bytes[31] &= 0x7f;
  var y = BigInt.zero;
  for (var i = 31; i >= 0; i--) {
    y = (y << 8) | BigInt.from(bytes[i]);
  }
  if (y >= _p) return false;
  // x² = (y² - 1) / (d y² + 1)
  final y2 = (y * y) % _p;
  final u = (y2 - BigInt.one) % _p;
  final v = (_d * y2 + BigInt.one) % _p;
  final x2 = (u * _inv(v)) % _p;
  var x = x2.modPow((_p + BigInt.from(3)) ~/ BigInt.from(8), _p);
  if ((x * x - x2) % _p != BigInt.zero) {
    x = (x * _sqrtM1) % _p;
    if ((x * x - x2) % _p != BigInt.zero) return false;
  }
  if (x == BigInt.zero && sign == 1) return false;
  if ((x.isOdd ? 1 : 0) != sign) x = _p - x;
  final point = (x, y, BigInt.one, (x * y) % _p);
  // Small order points (and the identity) are refused, and so are points
  // with a small order component.
  if (_isIdentity(_mul(point, BigInt.from(8)))) return false;
  return _isIdentity(_mul(point, _l));
}
