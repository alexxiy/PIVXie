import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/keccak.dart';

/// PIVXie DeFi Bridge (https://defi-bridge.pivxie.me): shielded PIVX
/// wrapped into wPIVX on BNB Smart Chain, and back, 1:1 less a fee.
///
/// This file holds the parts that need no network: amounts, the fee, EVM
/// addresses, and what the bridge's answers look like. The rules mirror the
/// bridge's web app (public/js/app.js, pivx.js and chain.js) and its server
/// (include/Orders.php), so the app shows the same numbers as the site.

/// Satoshi per coin; PIVX and wPIVX both have 8 decimals.
const kPivxDefiCoin = 100000000;

/// Digits the amount fields take: 9 before the point, 8 after.
const kPivxDefiMaxWholeDigits = 9;
const kPivxDefiMaxDecimals = 8;

/// Minutes per PIVX block, for the time a wrap takes.
const kPivxDefiBlockMinutes = 1;

enum PivxDefiDirection {
  /// PIVX to wPIVX.
  wrap,

  /// wPIVX to PIVX.
  unwrap;

  static PivxDefiDirection? parse(Object? value) => switch (value) {
    "wrap" => wrap,
    "unwrap" => unwrap,
    _ => null,
  };
}

// --- amounts ------------------------------------------------------------

/// [text] as satoshi, or null when it isn't a plain decimal amount with at
/// most 9 digits before the point and 8 after.
int? parsePivxDefiAmount(String text) {
  final m = RegExp(r"^(\d{1,9})(?:\.(\d{0,8}))?$").firstMatch(text.trim());
  if (m == null) return null;
  final frac = (m.group(2) ?? "").padRight(kPivxDefiMaxDecimals, "0");
  return int.parse(m.group(1)!) * kPivxDefiCoin + int.parse(frac);
}

/// What the amount fields keep of [value]: digits and one point (a comma
/// counts as one), at most 8 decimals and 9 whole digits.
String sanitizePivxDefiAmount(String value) {
  var v = value.replaceAll(",", ".").replaceAll(RegExp(r"[^\d.]"), "");
  final dot = v.indexOf(".");
  if (dot >= 0) {
    final frac = v.substring(dot + 1).replaceAll(".", "");
    v =
        "${v.substring(0, dot + 1)}"
        "${frac.length > kPivxDefiMaxDecimals ? frac.substring(0, kPivxDefiMaxDecimals) : frac}";
  }
  final parts = v.split(".");
  var whole = parts[0].replaceFirst(RegExp(r"^0+(?=\d)"), "");
  if (whole.length > kPivxDefiMaxWholeDigits) {
    whole = whole.substring(0, kPivxDefiMaxWholeDigits);
  }
  return parts.length > 1
      ? "${whole.isEmpty ? "0" : whole}.${parts[1]}"
      : whole;
}

/// [sat] as a plain decimal without trailing zeros: 1250000000 is "12.5".
/// What goes to the server and into the fields.
String formatPivxDefiAmount(int sat) {
  final negative = sat < 0;
  final abs = negative ? -sat : sat;
  final whole = abs ~/ kPivxDefiCoin;
  final frac = (abs % kPivxDefiCoin)
      .toString()
      .padLeft(kPivxDefiMaxDecimals, "0")
      .replaceFirst(RegExp(r"0+$"), "");
  return "${negative ? "-" : ""}$whole${frac.isEmpty ? "" : ".$frac"}";
}

/// [sat] for reading: thousands grouped with commas, and a point for the
/// decimals in every language, so a copied amount is never misread.
String showPivxDefiAmount(int sat) {
  final text = formatPivxDefiAmount(sat);
  final negative = text.startsWith("-");
  final parts = (negative ? text.substring(1) : text).split(".");
  final grouped = parts[0].replaceAllMapped(
    RegExp(r"\B(?=(\d{3})+(?!\d))"),
    (_) => ",",
  );
  return "${negative ? "-" : ""}$grouped${parts.length > 1 ? ".${parts[1]}" : ""}";
}

// --- EVM addresses ---------------------------------------------------------

Uint8List keccak256(List<int> data) =>
    KeccakDigest(256).process(Uint8List.fromList(data));

final _evmAddress = RegExp(r"^0x[0-9a-fA-F]{40}$");

/// [address] with the capitals of EIP-55, or null when it isn't an address.
String? evmChecksumAddress(String address) {
  if (!_evmAddress.hasMatch(address)) return null;
  final lower = address.substring(2).toLowerCase();
  final hash = keccak256(ascii.encode(lower));
  final out = StringBuffer("0x");
  for (var i = 0; i < 40; i++) {
    final nibble = (hash[i >> 1] >> (i.isEven ? 4 : 0)) & 0xf;
    out.write(nibble >= 8 ? lower[i].toUpperCase() : lower[i]);
  }
  return out.toString();
}

/// Whether [address] is an EVM address the bridge mints to: 0x and 40 hex
/// digits, with the EIP-55 capitals right when it has mixed case (all
/// lowercase or all uppercase carries no checksum), and not the zero
/// address.
bool isValidEvmAddress(String address) {
  if (!_evmAddress.hasMatch(address)) return false;
  final digits = address.substring(2);
  if (RegExp(r"^0+$").hasMatch(digits)) return false;
  if (digits == digits.toLowerCase() || digits == digits.toUpperCase()) {
    return true;
  }
  return evmChecksumAddress(address) == address;
}

/// The EVM address in [input]: a bare address, or one in an `ethereum:`
/// link as wallets put in QR codes (EIP-681), or null.
String? evmAddressFromText(String input) {
  var s = input.trim();
  if (s.toLowerCase().startsWith("ethereum:")) s = s.substring(9);
  if (s.toLowerCase().startsWith("pay-")) return null;
  final m = RegExp(r"^(0x[0-9a-fA-F]{40})(?=$|[@/?])").firstMatch(s);
  return m?.group(1);
}

/// [address] shortened for a line: 0x1234…abcd.
String shortEvmAddress(String address) => address.length > 12
    ? "${address.substring(0, 6)}…${address.substring(address.length - 4)}"
    : address;

/// `depositAddress(string)` of the wPIVX token: the address an unwrap to
/// [pivxAddress] takes its wPIVX at.
const kPivxDefiDepositAddressSelector = "e2e944b8";

/// The call data of `depositAddress(pivxAddress)`, ABI encoded.
String pivxDefiDepositAddressCall(String pivxAddress) {
  final bytes = utf8.encode(pivxAddress);
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, "0")).join();
  final padded = hex.padRight(((bytes.length + 31) ~/ 32) * 64, "0");
  return "0x$kPivxDefiDepositAddressSelector"
      "${0x20.toRadixString(16).padLeft(64, "0")}"
      "${bytes.length.toRadixString(16).padLeft(64, "0")}"
      "$padded";
}

/// The address in one ABI word, lowercase, or null when the word holds
/// anything else.
String? decodeEvmAddressWord(String word) {
  final m = RegExp(r"^(?:0x)?0{24}([0-9a-fA-F]{40})$").firstMatch(word);
  return m == null ? null : "0x${m.group(1)!.toLowerCase()}";
}

// --- answers -------------------------------------------------------------

/// The answer could not be read as the bridge's: a field missing or of the
/// wrong kind.
class PivxDefiFormatException implements Exception {
  const PivxDefiFormatException(this.field);

  final String field;

  @override
  String toString() => "PivxDefiFormatException: $field";
}

Map<String, dynamic> _map(Object? value, String field) => value is Map
    ? value.cast<String, dynamic>()
    : throw PivxDefiFormatException(field);

Map<String, dynamic>? _mapOrNull(Object? value, String field) =>
    value == null ? null : _map(value, field);

String _str(Object? value, String field) =>
    value is String ? value : throw PivxDefiFormatException(field);

String? _strOrNull(Object? value, String field) =>
    value == null ? null : _str(value, field);

bool _bool(Object? value, String field) =>
    value is bool ? value : throw PivxDefiFormatException(field);

/// A whole number: amounts are satoshi, in JSON numbers (or digit strings).
int _int(Object? value, String field) {
  if (value is int) return value;
  if (value is String && RegExp(r"^-?\d{1,18}$").hasMatch(value)) {
    return int.parse(value);
  }
  throw PivxDefiFormatException(field);
}

int? _intOrNull(Object? value, String field) =>
    value == null ? null : _int(value, field);

List<Object?> _list(Object? value, String field) =>
    value is List ? value : throw PivxDefiFormatException(field);

/// `GET info`: the bridge's settings and whether it takes orders.
class PivxDefiInfo {
  PivxDefiInfo._(this.json);

  factory PivxDefiInfo.fromJson(Object? json) {
    final i = PivxDefiInfo._(_map(json, "info"));
    i._parse();
    return i;
  }

  final Map<String, dynamic> json;

  late final bool available;
  late final bool paused;
  late final int feeBps;
  late final String? supportUrl;

  late final String pivxNetwork;
  late final String? explorerTxUrl;

  /// The bridge's own PIVX addresses: never a payout address.
  late final List<String> bridgeAddresses;

  /// Whether the bridge takes PIVX names (it never looks them up: the app
  /// does, with its own resolver).
  late final bool names;

  late final int chainId;
  late final String chainName;
  late final String? explorerUrl;

  late final String tokenAddress;
  late final String tokenSymbol;
  late final int tokenDecimals;

  late final int wrapMin;
  late final int wrapMinFee;

  /// The token's mint limit: the most one wrap mints.
  late final int wrapMax;

  /// What the token can mint right now (24-hour limit).
  late final int wrapAvailable;
  late final int wrapConfirmations;

  late final int unwrapMin;
  late final int unwrapMinFee;

  void _parse() {
    available = _bool(json["available"], "available");
    paused = _bool(json["paused"], "paused");
    feeBps = _int(json["fee_bps"], "fee_bps");
    if (feeBps < 0 || feeBps >= 10000) {
      throw const PivxDefiFormatException("fee_bps");
    }
    supportUrl = _strOrNull(json["support_url"], "support_url");

    final pivx = _map(json["pivx"], "pivx");
    pivxNetwork = _str(pivx["network"], "pivx.network");
    explorerTxUrl = _strOrNull(pivx["explorer_tx_url"], "explorer_tx_url");
    bridgeAddresses = [
      for (final a in _list(pivx["bridge_addresses"], "bridge_addresses"))
        _str(a, "bridge_addresses"),
    ];
    names = pivx["names"] != null;

    final evm = _map(json["evm"], "evm");
    chainId = _int(evm["chain_id"], "chain_id");
    chainName = _str(evm["chain_name"], "chain_name");
    explorerUrl = _strOrNull(evm["explorer_url"], "explorer_url");

    final token = _map(json["token"], "token");
    tokenAddress = _str(token["address"], "token.address");
    tokenSymbol = _str(token["symbol"], "token.symbol");
    tokenDecimals = _int(token["decimals"], "token.decimals");

    final wrap = _map(json["wrap"], "wrap");
    wrapMin = _int(wrap["min"], "wrap.min");
    wrapMinFee = _int(wrap["min_fee"], "wrap.min_fee");
    wrapMax = _int(wrap["max"], "wrap.max");
    wrapAvailable = _int(wrap["available"], "wrap.available");
    wrapConfirmations = _int(wrap["confirmations"], "wrap.confirmations");

    final unwrap = _map(json["unwrap"], "unwrap");
    unwrapMin = _int(unwrap["min"], "unwrap.min");
    unwrapMinFee = _int(unwrap["min_fee"], "unwrap.min_fee");
  }

  int minFee(PivxDefiDirection d) =>
      d == PivxDefiDirection.wrap ? wrapMinFee : unwrapMinFee;

  int min(PivxDefiDirection d) =>
      d == PivxDefiDirection.wrap ? wrapMin : unwrapMin;

  /// The percentage part of the fee of [amount], rounded up.
  int percentFee(int amount) =>
      ((BigInt.from(amount) * BigInt.from(feeBps) + BigInt.from(9999)) ~/
              BigInt.from(10000))
          .toInt();

  /// The fee of [amount] (= serviceFee() of the server): the percentage,
  /// at least the direction's minimum, and never more than [amount].
  int feeOf(int amount, PivxDefiDirection d) {
    final percent = percentFee(amount);
    final fee = percent > minFee(d) ? percent : minFee(d);
    return fee < amount ? fee : amount;
  }

  /// The largest amount whose net (after the fee) still fits [net].
  int grossFor(int net, PivxDefiDirection d) {
    final floored = net + minFee(d);
    final percent =
        (BigInt.from(net) * BigInt.from(10000) ~/ BigInt.from(10000 - feeBps))
            .toInt();
    var a = percent > floored ? percent : floored;
    while (a > 0 && a - feeOf(a, d) > net) {
      a--;
    }
    while (a + 1 - feeOf(a + 1, d) <= net) {
      a++;
    }
    return a;
  }

  /// The smallest amount to send for [receive] to arrive. The fee grows by
  /// at most one unit per unit sent, so every amount can be hit exactly.
  int sendFor(int receive, PivxDefiDirection d) =>
      receive > 0 ? grossFor(receive - 1, d) + 1 : 0;

  /// The wrap maximum as shown and enforced: what mints the token's limit,
  /// rounded down to 0.01 PIVX.
  int get wrapMaxSend {
    final exact = grossFor(wrapMax, PivxDefiDirection.wrap);
    const cent = 1000000;
    return exact >= cent ? exact - exact % cent : exact;
  }

  /// Minutes a wrap takes after the payment.
  int get wrapMinutes => wrapConfirmations * kPivxDefiBlockMinutes + 2;

  /// The explorer page of a PIVX transaction, as the bridge links it.
  Uri? pivxTxUrl(String? txid) {
    final tpl = explorerTxUrl;
    if (tpl == null || txid == null) return null;
    if (!RegExp(r"^[0-9a-f]{64}$").hasMatch(txid)) return null;
    return _webUrl(tpl.replaceAll("{tx_id}", txid));
  }

  Uri? evmTxUrl(String? hash) {
    if (hash == null || !RegExp(r"^0x[0-9a-fA-F]{64}$").hasMatch(hash)) {
      return null;
    }
    return _evmUrl("tx/$hash");
  }

  Uri? evmAddressUrl(String? address) =>
      address == null || !_evmAddress.hasMatch(address)
      ? null
      : _evmUrl("address/$address");

  Uri? evmTokenUrl(String address) =>
      _evmAddress.hasMatch(address) ? _evmUrl("token/$address") : null;

  Uri? _evmUrl(String path) {
    final base = explorerUrl;
    if (base == null) return null;
    return _webUrl("${base.replaceFirst(RegExp(r"/+$"), "")}/$path");
  }

  /// The support link, when it is a web or mail link.
  Uri? get supportUri {
    final url = supportUrl;
    if (url == null) return null;
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    return uri.scheme == "https" || uri.scheme == "mailto" ? uri : null;
  }
}

Uri? _webUrl(String url) {
  final uri = Uri.tryParse(url);
  return uri != null && (uri.scheme == "https" || uri.scheme == "http")
      ? uri
      : null;
}

/// One PIVX payment a wrap received.
class PivxDefiDeposit {
  PivxDefiDeposit._({
    required this.txid,
    required this.amount,
    required this.receive,
    required this.confirmations,
    required this.status,
    required this.mintTx,
  });

  factory PivxDefiDeposit.fromJson(Object? value) {
    final d = _map(value, "deposit");
    return PivxDefiDeposit._(
      txid: _str(d["txid"], "deposit.txid"),
      amount: _int(d["amount"], "deposit.amount"),
      receive: _int(d["receive"], "deposit.receive"),
      confirmations: _int(d["confirmations"], "deposit.confirmations"),
      status: _str(d["status"], "deposit.status"),
      mintTx: _strOrNull(d["mint_tx"], "deposit.mint_tx"),
    );
  }

  final String txid;
  final int amount;
  final int receive;
  final int confirmations;

  /// confirming | minting | completed | closed | attention
  final String status;
  final String? mintTx;
}

/// The burn of an unwrap, and its payout.
class PivxDefiBurn {
  const PivxDefiBurn({
    required this.payoutTxid,
    required this.payoutConfirmations,
    required this.payoutFinal,
  });

  final String? payoutTxid;
  final int payoutConfirmations;

  /// Past the reach of a reorg.
  final bool payoutFinal;
}

/// `GET order/{id}`: an order and how far it got.
class PivxDefiOrder {
  PivxDefiOrder._(this.json);

  factory PivxDefiOrder.fromJson(Object? json) {
    final o = PivxDefiOrder._(_map(json, "order"));
    o._parse();
    return o;
  }

  /// The answer as it came, to tell a changed order from the same one.
  final Map<String, dynamic> json;

  late final String id;
  late final PivxDefiDirection direction;
  late final int created;
  late final int amount;
  late final int fee;
  late final int receive;
  late final String status;
  late final int confirmationsRequired;

  /// Wrap: who gets the mint.
  late final String? evmAddress;

  /// Wrap: when an unpaid order expires.
  late final int? expires;
  late final List<PivxDefiDeposit> deposits;
  late final String? seenTxid;

  /// Wrap: where to pay, while nothing has arrived.
  late final ({String address, int amount, String memo})? payment;

  /// Unwrap: where the PIVX goes, and where the wPIVX is sent.
  late final String? pivxAddress;
  late final String? depositAddress;
  late final String? evmTxHash;
  late final PivxDefiBurn? burn;
  late final ({int count, int amount, int receive})? laterBurns;
  late final int depositLeft;
  late final int depositBalance;

  bool get isWrap => direction == PivxDefiDirection.wrap;

  void _parse() {
    id = _str(json["id"], "id");
    if (!isPivxDefiOrderId(id)) throw const PivxDefiFormatException("id");
    direction =
        PivxDefiDirection.parse(json["direction"]) ??
        (throw const PivxDefiFormatException("direction"));
    created = _int(json["created"], "created");
    amount = _int(json["amount"], "amount");
    fee = _int(json["fee"], "fee");
    receive = _int(json["receive"], "receive");
    status = _str(json["status"], "status");
    confirmationsRequired = _int(
      json["confirmations_required"],
      "confirmations_required",
    );
    if (confirmationsRequired <= 0) {
      throw const PivxDefiFormatException("confirmations_required");
    }
    evmAddress = _strOrNull(json["evm_address"], "evm_address");
    expires = _intOrNull(json["expires"], "expires");
    deposits = [
      for (final d
          in json["deposits"] == null
              ? const []
              : _list(json["deposits"], "deposits"))
        PivxDefiDeposit.fromJson(d),
    ];
    final seen = _mapOrNull(json["seen"], "seen");
    seenTxid = seen == null ? null : _str(seen["txid"], "seen.txid");
    final pay = _mapOrNull(json["payment"], "payment");
    payment = pay == null
        ? null
        : (
            address: _str(pay["address"], "payment.address"),
            amount: _int(pay["amount"], "payment.amount"),
            memo: _str(pay["memo"], "payment.memo"),
          );
    pivxAddress = _strOrNull(json["pivx_address"], "pivx_address");
    depositAddress = _strOrNull(json["deposit_address"], "deposit_address");
    evmTxHash = _strOrNull(json["evm_tx_hash"], "evm_tx_hash");
    final b = _mapOrNull(json["burn"], "burn");
    burn = b == null
        ? null
        : PivxDefiBurn(
            payoutTxid: _strOrNull(b["payout_txid"], "burn.payout_txid"),
            payoutConfirmations: _int(
              b["payout_confirmations"] ?? 0,
              "burn.payout_confirmations",
            ),
            payoutFinal: b["payout_final"] == true,
          );
    final later = _mapOrNull(json["later_burns"], "later_burns");
    laterBurns = later == null
        ? null
        : (
            count: _int(later["count"], "later_burns.count"),
            amount: _int(later["amount"], "later_burns.amount"),
            receive: _int(later["receive"], "later_burns.receive"),
          );
    depositLeft = _int(json["deposit_left"] ?? 0, "deposit_left");
    depositBalance = _int(json["deposit_balance"] ?? 0, "deposit_balance");
  }

  /// The PIVX received for a wrap, all payments together.
  int get received => deposits.fold(0, (s, d) => s + d.amount);

  /// The wPIVX minted for a wrap.
  int get minted => deposits.fold(0, (s, d) => s + d.receive);

  String? get mintTx {
    for (final d in deposits) {
      if (d.mintTx != null) return d.mintTx;
    }
    return null;
  }

  /// Wrap confirmations so far: those of the least confirmed payment
  /// (payments past "confirming" count as fully confirmed).
  int get wrapConfirmations {
    if (deposits.isEmpty) return 0;
    var least = confirmationsRequired;
    for (final d in deposits) {
      final c = d.status == "confirming"
          ? (d.confirmations < confirmationsRequired
                ? d.confirmations
                : confirmationsRequired)
          : confirmationsRequired;
      if (c < least) least = c;
    }
    return least;
  }

  /// Whether the order page still has news to wait for.
  bool get isSettled =>
      status == "completed" && (isWrap || (burn?.payoutFinal ?? false));
}

/// Order ids: 12 characters of lowercase base32 (no i, l, o, u).
bool isPivxDefiOrderId(String id) =>
    RegExp(r"^[0-9a-hjkmnp-tv-z]{12}$").hasMatch(id);

/// `GET reserves`: the wPIVX supply beside the PIVX the vault holds.
class PivxDefiReserves {
  PivxDefiReserves._(this.json);

  factory PivxDefiReserves.fromJson(Object? json) {
    final r = PivxDefiReserves._(_map(json, "reserves"));
    r._parse();
    return r;
  }

  final Map<String, dynamic> json;

  /// The parts between the supply and the balance, in the order shown.
  static const parts = [
    "moving_to_vault",
    "burns_in_flight",
    "burns_held",
    "surplus",
    "unbacked",
    "unexplained",
  ];

  /// match | in_process | mismatch | unavailable
  late final String status;
  late final int supply;
  late final int balance;
  late final int difference;
  late final Map<String, int> amounts;
  late final String token;
  late final String vaultWallet;
  late final String? viewingKey;
  late final int? startBlock;
  late final int? updated;

  void _parse() {
    status = _str(json["status"], "status");
    supply = _int(json["supply"], "supply");
    balance = _int(json["balance"], "balance");
    difference = _int(json["difference"] ?? 0, "difference");
    amounts = {for (final p in parts) p: _int(json[p] ?? 0, p)};
    token = _str(json["token"], "token");
    vaultWallet = _str(json["vault_wallet"], "vault_wallet");
    viewingKey = _strOrNull(json["viewing_key"], "viewing_key");
    startBlock = _intOrNull(json["start_block"], "start_block");
    updated = _intOrNull(json["updated"], "updated");
  }
}

/// What the user asked for, to hold the order the server made against.
class PivxDefiSwap {
  const PivxDefiSwap({
    required this.direction,
    required this.amount,
    this.evmAddress,
    this.pivxAddress,
    this.pivxName,
  });

  final PivxDefiDirection direction;
  final int amount;

  /// Wrap: who gets the mint, as typed.
  final String? evmAddress;

  /// Unwrap: where the PIVX goes, and the name it was found by.
  final String? pivxAddress;
  final String? pivxName;

  bool get isWrap => direction == PivxDefiDirection.wrap;
}

/// Whether [order] is the order [swap] asked for. The app pays on the
/// server's answer, so the amount and where the coins go must be what the
/// user entered; a wrap's memo must name the order and the recipient
/// exactly as the bridge's agent reads it (EIP-55 capitals), or the
/// payment would be held instead of minted.
bool pivxDefiOrderMatches(PivxDefiOrder order, PivxDefiSwap swap) {
  if (order.direction != swap.direction || order.amount != swap.amount) {
    return false;
  }
  if (!swap.isWrap) {
    return order.pivxAddress != null && order.pivxAddress == swap.pivxAddress;
  }
  final account = swap.evmAddress;
  final payment = order.payment;
  if (account == null || payment == null) return false;
  final checksummed = evmChecksumAddress(account);
  return checksummed != null &&
      order.evmAddress?.toLowerCase() == account.toLowerCase() &&
      payment.amount == swap.amount &&
      payment.memo == "${order.id}:$checksummed";
}

/// How often the order screen asks about [order]: null when there is
/// nothing more to wait for. A payout counted as done can still be taken
/// back by a reorg until it is final.
Duration? pivxDefiPollDelay(PivxDefiOrder order, {required bool paid}) {
  if (order.status == "completed") {
    return order.isSettled ? null : const Duration(seconds: 60);
  }
  const slow = {
    "attention",
    "closed",
    "expired",
    "tx_failed",
    "below_minimum",
    "payout_held",
  };
  if (slow.contains(order.status)) return const Duration(seconds: 30);
  if (order.status == "awaiting_payment" && !paid) {
    return const Duration(seconds: 10);
  }
  return const Duration(seconds: 4);
}
