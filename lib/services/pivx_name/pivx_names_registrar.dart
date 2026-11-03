import 'dart:async';
import 'dart:convert';

import '../../l10n/l10n.dart';
import '../../wallets/crypto_currency/crypto_currency.dart';
import 'pivx_name.dart';
import 'pivx_name_resolver.dart';
import 'pivx_names_protocol.dart';

/// The PIVX.name registrar: where names are registered and managed. It
/// takes the commands paid to its address, keeps the users' refund
/// balances and runs the marketplace.
class PivxNamesService {
  const PivxNamesService({
    required this.registrar,
    required this.network,
    required this.marker,
  });

  final Uri registrar;

  /// The network the registrar must report ("mainnet").
  final String network;

  /// Head of every command: tells networks apart, so a command signed for
  /// one can't be replayed on another.
  final String marker;

  static final mainnet = PivxNamesService(
    registrar: Uri.parse("https://registrar.pivx.name"),
    network: "mainnet",
    marker: "PiNS",
  );

  /// The registrar for [coin], or null where names don't exist (only
  /// mainnet has them).
  static PivxNamesService? forCoin(CryptoCurrency coin) =>
      PivxNameService.forCoin(coin) == null ? null : mainnet;
}

class PivxNamesException implements Exception {
  const PivxNamesException(this.message, {this.fromServer = false});

  final String message;

  /// [message] is the registrar's own text (cleaned): it refused the
  /// request.
  final bool fromServer;

  @override
  String toString() => message;
}

/// Where payments for commands go, and the zones names are registered in
/// (bare, "pivx", in the registrar's order).
typedef PivxNamesPaymentInfo = ({
  String address,
  int paymentConfirmations,
  int refundConfirmations,
  List<String> zones,
});

/// What a name lookup on the registrar found. [updatePrice] is what any
/// command on the name but a registration or a purchase costs.
sealed class PivxNamesAvailability {
  const PivxNamesAvailability(this.name, this.updatePrice);

  final String name;
  final BigInt updatePrice;
}

/// Free: [price] registers it. [pending]: someone's registration of it is
/// paid and on its way, and only the first one paid gets the name.
final class PivxNamesAvailable extends PivxNamesAvailability {
  const PivxNamesAvailable(
    super.name,
    super.updatePrice,
    this.price, {
    required this.pending,
  });

  final BigInt price;
  final bool pending;
}

/// Registered and not for sale.
final class PivxNamesTaken extends PivxNamesAvailability {
  const PivxNamesTaken(super.name, super.updatePrice);
}

/// Listed on the marketplace for [price], by [owner] (public key).
final class PivxNamesListed extends PivxNamesAvailability {
  const PivxNamesListed(super.name, super.updatePrice, this.price, this.owner);

  final BigInt price;
  final String? owner;
}

/// Where a paid command is in the registrar's queue.
enum PivxNamesTxStatus {
  confirmingPayment(0),
  pendingProof(1),
  queuedProof(2),
  processingProof(3),
  submittingProof(4),
  done(5),
  orphaned(6),
  pendingRefund(7),
  refunded(8),
  rejected(9);

  const PivxNamesTxStatus(this.code);

  final int code;

  static PivxNamesTxStatus? fromCode(Object? code) {
    for (final s in values) {
      if (s.code == code) return s;
    }
    return null;
  }

  /// Nothing more will happen to it.
  bool get isFinal =>
      this == done || this == orphaned || this == refunded || this == rejected;

  bool get failed => this == orphaned || this == refunded || this == rejected;

  String get label => switch (this) {
    confirmingPayment => l10n.pivxNamesTxConfirmingPayment,
    pendingProof => l10n.pivxNamesTxPendingProof,
    queuedProof => l10n.pivxNamesTxQueuedProof,
    processingProof => l10n.pivxNamesTxProcessingProof,
    submittingProof => l10n.pivxNamesTxSubmittingProof,
    done => l10n.commonDone,
    orphaned => l10n.pivxNamesTxOrphaned,
    pendingRefund => l10n.pivxNamesTxPendingRefund,
    refunded => l10n.pivxNamesTxRefunded,
    rejected => l10n.pivxNamesTxRejectedLabel,
  };
}

/// What the registrar knows of a payment: nothing yet (all null), its
/// transaction ([txId], found by its memo), or its [status].
typedef PivxNamesProgress = ({
  String? txId,
  PivxNamesTxStatus? status,
  int? confirmations,

  /// Seconds until the next proof batch starts (queued commands).
  int? seconds,
});

/// A name in a list: the user's names or the marketplace.
typedef PivxNamesDomain = ({
  String name,

  /// Listing price; zero when not for sale.
  BigInt price,

  /// Price of an update (destination, owner, listing).
  BigInt updatePrice,

  /// Where it points (the user's own names).
  String? address,

  /// The owner's key (marketplace).
  String? owner,
});

/// Which of the user's names a list holds (the marketplace holds only
/// names on sale).
enum PivxNamesStatusFilter {
  all("all"),
  onSale("listed"),
  active("not_listed");

  const PivxNamesStatusFilter(this.key);

  /// The registrar's `status`.
  final String key;
}

/// The order of a names list. Newest and oldest go by when a name last
/// changed (the user's names) or was put on sale (the marketplace).
enum PivxNamesSort {
  nameAsc,
  nameDesc,
  priceAsc,
  priceDesc,
  newest,
  oldest;

  /// The registrar's `sort`, for the user's names ([my]) or the
  /// marketplace.
  String key({required bool my}) => switch (this) {
    nameAsc || nameDesc => "name",
    priceAsc || priceDesc => "price",
    newest || oldest => my ? "updated" : "listed",
  };

  /// The registrar's `order`.
  String get order => switch (this) {
    nameAsc || priceAsc || oldest => "asc",
    nameDesc || priceDesc || newest => "desc",
  };
}

/// What a names list holds, and in which order. A null [zone] (bare,
/// "pivx") is every zone.
typedef PivxNamesFilter = ({
  PivxNamesStatusFilter status,
  String? zone,
  PivxNamesSort sort,
});

/// Everything, by name.
const PivxNamesFilter kPivxNamesNoFilter = (
  status: PivxNamesStatusFilter.all,
  zone: null,
  sort: PivxNamesSort.nameAsc,
);

/// A command paid to the registrar, from the user's history.
typedef PivxNamesIncoming = ({
  String name,
  String op,

  /// When the payment's block was made; null for payments the registrar
  /// stored before it kept the time.
  DateTime? time,

  /// What was paid.
  BigInt amount,

  /// The listing price a listing sets; zero for the other commands.
  BigInt price,
  int confirmations,
  PivxNamesTxStatus? status,
  int? rawStatus,
  String txId,
  String memo,
});

/// Where a withdrawal is (TX_REFUND_* of the registrar).
enum PivxNamesRefundStatus {
  waiting(0),
  queued(1),

  /// Being sent: still on its way, so it reads as queued, as on the web.
  sending(2),
  paid(3),

  /// The amount went back to the balance.
  error(4),

  /// Retried on its own after a payout batch the node refused: still on
  /// its way.
  solo(5);

  const PivxNamesRefundStatus(this.code);

  final int code;

  String get label => switch (this) {
    waiting => l10n.pivxNamesRefundWaiting,
    queued || sending || solo => l10n.pivxNamesRefundQueued,
    paid => l10n.pivxNamesRefundPaid,
    error => l10n.pivxNamesRefundError,
  };

  static PivxNamesRefundStatus? fromCode(Object? code) {
    for (final s in values) {
      if (s.code == code) return s;
    }
    return null;
  }
}

/// A withdrawal of the refund balance.
typedef PivxNamesRefund = ({
  DateTime? date,
  BigInt amount,

  /// Service fee, in percent.
  String fee,

  /// Where it was sent.
  String address,
  String txId,
  PivxNamesRefundStatus? status,
  int? rawStatus,
});

typedef PivxNamesPage<T> = ({int count, List<T> items});

/// A page of the marketplace: [count] names on sale in all, and [next],
/// the place after [items] to go on from (null on the last page).
typedef PivxNamesMarketPage = ({
  int count,
  List<PivxNamesDomain> items,
  String? next,
});

/// Refunded payments the user can withdraw, the service fee a withdrawal
/// pays (percent), and the least balance a withdrawal may ask for, fee
/// included (zero: no minimum).
typedef PivxNamesBalance = ({
  BigInt balance,
  double feePercent,
  BigInt minWithdrawal,
});

const kPivxNamesDefaultRefundFee = 5.0;

/// Page sizes, as the web app uses them.
const kPivxNamesListPageSize = 20;
const kPivxNamesHistoryPageSize = 10;

/// Talks to the registrar's API (`/v1.0/...`).
///
/// The answers aren't proofs: unlike name lookups for payments (checked
/// against BNB Smart Chain), what the registrar says here is taken as it
/// says it, like the web app does. Nothing it says can move funds by
/// itself: every payment is built, shown and confirmed in the wallet.
class PivxNamesRegistrar {
  PivxNamesRegistrar(this.service, {PivxNameTransport? transport})
    : _transport = transport ?? pivxNameHttpTransport;

  /// The registrar for [coin], with the app's network settings (Tor), or
  /// null when [coin] has no names.
  static PivxNamesRegistrar? forCoin(CryptoCurrency coin) {
    final service = PivxNamesService.forCoin(coin);
    if (service == null) return null;
    return _shared[service.registrar] ??= PivxNamesRegistrar(service);
  }

  static final _shared = <Uri, PivxNamesRegistrar>{};

  final PivxNamesService service;
  final PivxNameTransport _transport;

  Future<PivxNamesPaymentInfo>? _paymentInfo;

  Future<Object?> _call(String path, [Map<String, dynamic>? body]) async {
    final url = service.registrar.replace(path: "/v1.0/$path");
    final PivxNameResponse response;
    try {
      response = await _transport(
        body == null ? "GET" : "POST",
        url,
        body: body == null ? null : jsonEncode(body),
      );
    } catch (e) {
      throw PivxNamesException(l10n.pivxNamesUnreachableError(e.toString()));
    }
    Object? json;
    try {
      json = jsonDecode(response.body);
    } catch (_) {
      json = null;
    }
    if (json is Map) {
      final error = json["error"];
      if (error != null) {
        final text = cleanPivxNameServerText(
          error is Map ? error["error_message"] : error,
        );
        throw PivxNamesException(
          text ?? l10n.pivxNamesRefused,
          fromServer: true,
        );
      }
      if (json.containsKey("response")) return json["response"];
    }
    throw PivxNamesException(l10n.pivxNamesBadAnswerHttp(response.status));
  }

  static Never _malformed() =>
      throw PivxNamesException(l10n.pivxNamesBadAnswer);

  /// [_call] for the signed requests the registrar takes within a minute
  /// of their nonce: its "Request timeout" means this device's clock is
  /// off.
  Future<Object?> _timed(String path, Map<String, dynamic> body) async {
    try {
      return await _call(path, body);
    } on PivxNamesException catch (e) {
      if (e.fromServer && e.message == "Request timeout") {
        throw PivxNamesException(l10n.pivxNamesClockOff, fromServer: true);
      }
      rethrow;
    }
  }

  /// The registrar's payment address, checked against [service] (network,
  /// address rule). Asked once; a failure is asked again next time.
  Future<PivxNamesPaymentInfo> paymentInfo() async {
    final pending = _paymentInfo ??= _fetchPaymentInfo();
    try {
      return await pending;
    } catch (_) {
      if (identical(_paymentInfo, pending)) _paymentInfo = null;
      rethrow;
    }
  }

  Future<PivxNamesPaymentInfo> _fetchPaymentInfo() async {
    final r = await _call("getPaymentAddress");
    if (r is! Map) _malformed();
    final address = r["address"];
    if (r["network"] != null && r["network"] != service.network) {
      throw PivxNamesException(
        l10n.pivxNamesWrongNetwork("${r["network"]}", service.network),
      );
    }
    if (address is! String || !isValidPivxNamesTarget(address)) _malformed();
    int confirmations(Object? v, int fallback) =>
        v is int && v > 0 && v < 10000 ? v : fallback;
    return (
      address: address,
      paymentConfirmations: confirmations(
        r["payment_confirmations"],
        kPivxNamesPaymentConfirmations,
      ),
      refundConfirmations: confirmations(
        r["refund_confirmations"],
        kPivxNamesRefundConfirmations,
      ),
      zones: _zones(r["zones"]),
    );
  }

  /// The registrar's zones that the app knows. The app checks names, and
  /// their proofs, against its own zones (the circuit's), so one it doesn't
  /// know isn't offered. Without the list, the app's own.
  static List<String> _zones(Object? served) {
    if (served == null) return kPivxNameZones;
    if (served is! List) _malformed();
    final zones = [
      for (final z in served)
        if (z is String && kPivxNameZones.contains(z)) z,
    ];
    if (zones.isEmpty) _malformed();
    return List.unmodifiable(zones.toSet());
  }

  /// The zones names can be registered in, in the registrar's order.
  Future<List<String>> zones() async => (await paymentInfo()).zones;

  /// The lookup path of [name]. Names from the registrar's own lists go
  /// there too, so one that isn't a name never reaches a URL.
  static String _checkPath(String name) {
    if (!isValidPivxName(name)) {
      throw PivxNamesException(l10n.pivxNamesNotValidName(name));
    }
    return "check/$name";
  }

  /// Whether [name] is free, taken or for sale, and what updating it
  /// costs.
  Future<PivxNamesAvailability> check(String name) async {
    final r = await _call(_checkPath(name), {"with_pubkey": true});
    if (r is! Map || r["exists"] is! bool) _malformed();
    final updatePrice = _sats(r["update_price"]);
    if (updatePrice == null || updatePrice <= BigInt.zero) _malformed();
    final price = _sats(r["price"]);
    if (r["exists"] == false) {
      final pending = r["reg_pending"];
      if (price == null || price <= BigInt.zero || pending is! bool) {
        _malformed();
      }
      return PivxNamesAvailable(name, updatePrice, price, pending: pending);
    }
    if (price != null && price > BigInt.zero) {
      final owner = r["pubkey"];
      return PivxNamesListed(
        name,
        updatePrice,
        price,
        owner is String ? owner : null,
      );
    }
    return PivxNamesTaken(name, updatePrice);
  }

  /// The payment carrying [memo] for [name], once the registrar has seen
  /// it.
  Future<PivxNamesProgress> progressByMemo(String name, String memo) async {
    final r = await _call(_checkPath(name), {
      "reg_id": base64.encode(utf8.encode(memo)),
    });
    return _progress(r);
  }

  /// Where the payment [txId] for [name] is.
  Future<PivxNamesProgress> progressByTxId(String name, String txId) async {
    final r = await _call(_checkPath(name), {"tx_id": txId});
    return _progress(r);
  }

  /// Nothing known yet comes back as an empty object.
  static PivxNamesProgress _progress(Object? r) {
    if (r is! Map) _malformed();
    final txId = r["tx_id"];
    return (
      txId: txId is String && txId.isNotEmpty ? txId : null,
      status: PivxNamesTxStatus.fromCode(_int(r["status"])),
      confirmations: _int(r["confirmations"]),
      seconds: _int(r["seconds"]),
    );
  }

  /// The names [pubkey] owns that match [search] and [filter], page
  /// [page] of them.
  Future<PivxNamesPage<PivxNamesDomain>> myNames({
    required String pubkey,
    int page = 1,
    String search = "",
    PivxNamesFilter filter = kPivxNamesNoFilter,
  }) async {
    final r = await _domains(
      my: true,
      body: {"pubkey": pubkey, "page": page},
      search: search,
      filter: filter,
    );
    return (count: r.count, items: r.items);
  }

  /// Names for sale that match [search] and [filter]: the first page, or
  /// the one after [after] (the `next` of the page before, in the same
  /// order). Each comes with its owner's key, so the
  /// user's own listings can be told apart.
  Future<PivxNamesMarketPage> marketplace({
    String? after,
    String search = "",
    PivxNamesFilter filter = kPivxNamesNoFilter,
  }) => _domains(
    my: false,
    body: {"after": ?after},
    search: search,
    // Everything on the marketplace is on sale.
    filter: (
      status: PivxNamesStatusFilter.all,
      zone: filter.zone,
      sort: filter.sort,
    ),
  );

  Future<PivxNamesMarketPage> _domains({
    required bool my,
    required Map<String, dynamic> body,
    required String search,
    required PivxNamesFilter filter,
  }) async {
    final sort = filter.sort.key(my: my);
    final order = filter.sort.order;
    final zone = filter.zone ?? "";
    final status = filter.status.key;
    final r = await _call("domains", {
      "type": my ? "my" : "marketplace",
      ...body,
      "count": kPivxNamesListPageSize,
      if (search.isNotEmpty) "search": search,
      "sort": sort,
      "order": order,
      "zone": zone,
      "status": status,
    });
    if (r is! Map) _malformed();
    // The registrar says what it applied: one that doesn't know an option
    // leaves it out without a word, and its list wouldn't be the one asked
    // for.
    if (r["sort"] != sort ||
        r["order"] != order ||
        r["zone"] != zone ||
        r["status"] != status) {
      _malformed();
    }
    final list = r["domains"];
    final count = _int(r["count"]);
    if (list is! List || count == null) _malformed();
    final items = <PivxNamesDomain>[];
    for (final d in list) {
      if (d is! Map) _malformed();
      final name = d["domain"];
      if (name is! String || !isValidPivxName(name)) continue;
      final updatePrice = _sats(d["tx_price"]);
      if (updatePrice == null || updatePrice <= BigInt.zero) _malformed();
      final address = d["address"];
      final owner = d["pubkey"];
      items.add((
        name: name,
        price: _sats(d["price"]) ?? BigInt.zero,
        updatePrice: updatePrice,
        address: address is String ? address : null,
        owner: owner is String ? owner : null,
      ));
    }
    // The marketplace's place to go on from: null on the last page.
    final next = r["next"];
    if (!my &&
        (!r.containsKey("next") ||
            next != null && (next is! String || next.isEmpty))) {
      _malformed();
    }
    return (count: count, items: items, next: next is String ? next : null);
  }

  /// Refunds waiting for [pubkey], and the withdrawal fee.
  Future<PivxNamesBalance> balance(String pubkey) async {
    final r = await _call("balance", {"action": "get", "pubkey": pubkey});
    if (r is! Map) _malformed();
    final balance = _sats(r["balance"]);
    if (balance == null) _malformed();
    final fee = double.tryParse("${r["fee"]}");
    // Payouts cost the registrar a network fee each, so it refuses small
    // ones. An older registrar doesn't say: no minimum, as on the web.
    final minimum = _sats(r["min_withdrawal"]);
    return (
      balance: balance,
      feePercent: fee != null && fee >= 0 && fee < 100
          ? fee
          : kPivxNamesDefaultRefundFee,
      minWithdrawal: minimum != null && minimum > BigInt.zero
          ? minimum
          : BigInt.zero,
    );
  }

  /// Asks for [amount] of the balance to be paid to [address]. [signature]
  /// signs [pivxNamesWithdrawMessage].
  Future<void> withdraw({
    required String pubkey,
    required String address,
    required BigInt amount,
    required int nonce,
    required String signature,
  }) async {
    final r = await _timed("balance", {
      "action": "withdraw",
      "pubkey": pubkey,
      "address": address,
      "amount": "$amount",
      "nonce": nonce,
      "signature": signature,
    });
    if (r != 1) {
      throw PivxNamesException(l10n.pivxNamesWithdrawUnexpected);
    }
  }

  /// The commands [pubkey] paid for, newest first. [signature] signs
  /// [pivxNamesHistoryMessage] with type "in" and [nonce].
  Future<PivxNamesPage<PivxNamesIncoming>> incoming({
    required String pubkey,
    required int page,
    required int nonce,
    required String signature,
  }) async {
    final r = await _history("in", pubkey, page, nonce, signature);
    final items = <PivxNamesIncoming>[];
    for (final t in r.items) {
      final status = _int(t["status"]);
      final time = _int(t["time"]);
      items.add((
        name: _text(t["domain_name"]),
        op: _text(t["op"]),
        time: _utc(time),
        amount: _sats(t["amount"]) ?? BigInt.zero,
        price: _sats(t["price"]) ?? BigInt.zero,
        confirmations: _int(t["confirmations"]) ?? 0,
        status: PivxNamesTxStatus.fromCode(status),
        rawStatus: status,
        txId: _txId(t["tx_id"]),
        memo: _text(t["memo"]),
      ));
    }
    return (count: r.count, items: items);
  }

  /// The withdrawals [pubkey] asked for, newest first. [signature] signs
  /// [pivxNamesHistoryMessage] with type "ref" and [nonce].
  Future<PivxNamesPage<PivxNamesRefund>> refunds({
    required String pubkey,
    required int page,
    required int nonce,
    required String signature,
  }) async {
    final r = await _history("ref", pubkey, page, nonce, signature);
    final items = <PivxNamesRefund>[];
    for (final t in r.items) {
      final date = _int(t["date"]);
      final status = _int(t["status"]);
      items.add((
        date: _utc(date),
        amount: _sats(t["amount"]) ?? BigInt.zero,
        fee: _text(t["fee"]).replaceAll("%", ""),
        address: _text(t["address"]),
        txId: _txId(t["tx_id"]),
        status: PivxNamesRefundStatus.fromCode(status),
        rawStatus: status,
      ));
    }
    return (count: r.count, items: items);
  }

  Future<PivxNamesPage<Map<Object?, Object?>>> _history(
    String type,
    String pubkey,
    int page,
    int nonce,
    String signature,
  ) async {
    final r = await _timed("transactions", {
      "type": type,
      "pubkey": pubkey,
      "page": page,
      "count": kPivxNamesHistoryPageSize,
      "nonce": nonce,
      "signature": signature,
    });
    if (r is! Map) _malformed();
    final list = r["tx"];
    if (list is! List) _malformed();
    return (
      count: _int(r["count"]) ?? list.length,
      items: [
        for (final t in list)
          if (t is Map) t,
      ],
    );
  }
}

int? _int(Object? v) => v is int ? v : int.tryParse("${v ?? ""}");

/// Unix [seconds] as a UTC time; null for none, or for one no date can
/// hold.
DateTime? _utc(int? seconds) =>
    seconds == null || seconds <= 0 || seconds > 8640000000000
    ? null
    : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);

/// Server text of a history entry, safe to show (no control or direction
/// characters). A memo is up to 512 bytes, so nothing is cut.
String _text(Object? v) => v == null
    ? ""
    : "$v"
          .replaceAll(
            RegExp(
              r"[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e"
              r"\u2066-\u2069]",
            ),
            " ",
          )
          .trim();

/// A transaction id, or "" for anything that isn't one.
String _txId(Object? v) {
  final s = "${v ?? ""}".toLowerCase();
  return RegExp(r"^[0-9a-f]{64}$").hasMatch(s) ? s : "";
}

/// An amount in satoshis: an integer, or a decimal string the registrar's
/// database may write with a fraction (".00000000").
BigInt? _sats(Object? v) {
  if (v is int) return BigInt.from(v);
  if (v is! String) return null;
  final s = v.trim();
  final whole = RegExp(r"^(\d+)(\.0*)?$").firstMatch(s);
  return whole == null ? null : BigInt.parse(whole.group(1)!);
}
