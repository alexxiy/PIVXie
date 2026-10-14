import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:socks5_proxy/socks_client.dart';

import '../../app_config.dart';
import '../../utilities/prefs.dart';
import '../../wallets/crypto_currency/crypto_currency.dart';
import '../tor_service.dart';
import 'pivx_name.dart';

/// Where names are looked up and checked. Constants, never stored: the
/// anchor contract and the epochs decide what counts as the registry, so a
/// new value has to arrive in a reviewed release, not linger in settings.
class PivxNameService {
  PivxNameService({
    required this.indexer,
    required this.anchor,
    required this.rpcs,
    required this.epochs,
    this.minAgreement = 2,
  });

  /// Serves records and proofs. Not trusted: every record is checked
  /// against the anchor contract's current root.
  final Uri indexer;

  /// The anchor contract on BNB Smart Chain, which holds the registry's
  /// current root.
  final String anchor;

  /// Independent BNB Smart Chain endpoints. Every contract read needs
  /// [minAgreement] of them to return the same answer.
  final List<Uri> rpcs;

  /// Epochs of the anchor contract reviewed for this release. The epoch goes
  /// up on every rules change and every rollback, and never down, so a root
  /// under any other epoch is refused until a release accepts it.
  final Set<int> epochs;

  final int minAgreement;

  static final mainnet = PivxNameService(
    indexer: Uri.parse("https://indexer.pivx.name"),
    anchor: "0xe21df741aab28c1916edb1718f18e62c08fab4bc",
    rpcs: [
      Uri.parse("https://bsc-dataseed.bnbchain.org"),
      Uri.parse("https://bsc-dataseed.defibit.io"),
      Uri.parse("https://bsc-dataseed.ninicoin.io"),
      Uri.parse("https://bsc-rpc.publicnode.com"),
      Uri.parse("https://bsc-mainnet.public.blastapi.io"),
    ],
    epochs: const {1},
  );

  /// The name service for [coin], or null where there is none: names exist
  /// on mainnet only.
  static PivxNameService? forCoin(CryptoCurrency coin) =>
      coin is Pivx && coin.network == CryptoCurrencyNetwork.main
      ? mainnet
      : null;
}

/// What a lookup found.
sealed class PivxNameLookup {
  const PivxNameLookup(this.name);

  final String name;
}

/// The name points to [address], proven against the anchor contract's
/// current root under a reviewed epoch.
final class PivxNameVerified extends PivxNameLookup {
  const PivxNameVerified(super.name, this.address);

  final String address;
}

/// The registry, in step with the chain, has no such name.
final class PivxNameNotRegistered extends PivxNameLookup {
  const PivxNameNotRegistered(super.name);
}

/// The PIVX.name server is still on an earlier (genuine) registry state.
/// Its answer may be out of date, so nothing can be sent until it catches
/// up. [nameMissing]: it doesn't know the name yet.
final class PivxNameIndexerBehind extends PivxNameLookup {
  const PivxNameIndexerBehind(super.name, {required this.nameMissing});

  final bool nameMissing;
}

enum PivxNameError {
  /// No answer from the PIVX.name server.
  indexerUnreachable,

  /// The PIVX.name server answered with an error or something malformed.
  indexerError,

  /// Too few BNB Smart Chain endpoints answered.
  chainUnavailable,

  /// BNB Smart Chain endpoints answered differently about the same block.
  chainDisagreement,

  /// The anchor contract is under an epoch this release hasn't reviewed.
  unreviewedEpoch,

  /// The server's registry state was never anchored on chain (or was rolled
  /// back).
  unanchoredRoot,

  /// The record doesn't match its proof and the chain's root.
  badRecord,

  /// No name service here (testnet), or too few endpoints configured.
  unavailable,
}

class PivxNameException implements Exception {
  const PivxNameException(this.kind, this.message, {this.detail});

  /// Decided by type, never by text: much of the text comes from the
  /// servers being judged.
  final PivxNameError kind;
  final String message;

  /// Server-supplied text, cleaned and shortened; for display only.
  final String? detail;

  /// Whether trying again later can help.
  bool get isTransient =>
      kind == PivxNameError.indexerUnreachable ||
      kind == PivxNameError.chainUnavailable;

  @override
  String toString() => detail == null ? message : "$message ($detail)";
}

typedef PivxNameResponse = ({int status, String body});

/// One HTTP request. Throws when there is no answer at all.
typedef PivxNameTransport = Future<PivxNameResponse> Function(
  String method,
  Uri url, {
  String? body,
});

/// Looks names up and checks every answer against BNB Smart Chain.
///
/// One lookup:
/// 1. Pin a block that at least [PivxNameService.minAgreement] endpoints
///    have reached, and read `anchoredState()` (root, height, epoch) at it,
///    under quorum. Pinning matters: endpoints agreeing on "latest" may both
///    be behind, and a stale root would pay a name's previous address.
/// 2. Ask the PIVX.name server for the record and proof (in parallel).
/// 3. Same root: check the proof against the chain's root. Different root:
///    ask the contract whether the server's root is a genuine earlier state
///    (it is behind: wait) or not (refuse).
///
/// Nothing is sent from here; a lookup only ever returns an address.
class PivxNameResolver {
  PivxNameResolver(
    this.service, {
    PivxNameTransport? transport,
    this.recheckDelay = const Duration(seconds: 5),
  }) : _transport = transport ?? _httpTransport;

  /// Lookups for [coin] with the app's network settings (Tor), or null when
  /// [coin] has no name service.
  static PivxNameResolver? forCoin(CryptoCurrency coin) {
    final service = PivxNameService.forCoin(coin);
    return service == null ? null : PivxNameResolver(service);
  }

  final PivxNameService service;
  final PivxNameTransport _transport;

  /// Before calling a root fabricated: reads are pinned to a block, and right
  /// after an anchoring transaction the server can be a few seconds ahead of
  /// it. A fabricated root is unknown at every block.
  final Duration recheckDelay;

  Future<PivxNameLookup> lookup(String name) => _lookup(name, recheck: true);

  /// Whether the server has caught up with the chain. A cheap check for
  /// waiting on [PivxNameIndexerBehind]; run [lookup] again once it's true.
  Future<bool> caughtUp() async {
    final chain = _anchoredState();
    unawaited(chain.then((_) {}, onError: (_) {}));
    final serverRoot = await _indexerRoot();
    return serverRoot == (await chain).root;
  }

  Future<PivxNameLookup> _lookup(String name, {required bool recheck}) async {
    if (!isValidPivxName(name)) {
      throw ArgumentError.value(name, "name", "not a valid PIVX.name name");
    }
    // Started first so the chain reads overlap the server's answer. The
    // handler only keeps an early failure from going unhandled; it is
    // still reported by the await below.
    final chainFuture = _anchoredState();
    unawaited(chainFuture.then((_) {}, onError: (_) {}));

    final record = await _resolve(name);
    final chain = await chainFuture;

    final String serverRoot;
    if (record == null) {
      serverRoot = await _indexerRoot();
    } else {
      serverRoot =
          parsePivxNameRoot(record["smt_root"]) ??
          (throw const PivxNameException(
            PivxNameError.indexerError,
            "The PIVX.name server sent a malformed registry root.",
          ));
    }

    if (serverRoot == chain.root) {
      if (record == null) return PivxNameNotRegistered(name);
      final address = verifyPivxNameRecord(record, name, chain.root);
      if (address == null) {
        throw PivxNameException(
          PivxNameError.badRecord,
          "The record the PIVX.name server sent for $name doesn't match the "
          "registry on chain.",
        );
      }
      return PivxNameVerified(name, address);
    }

    // Only the contract can tell a server that is behind from one serving
    // a registry that never existed; asked about the same block.
    if (await _isRootValid(serverRoot, chain.block)) {
      return PivxNameIndexerBehind(name, nameMissing: record == null);
    }
    if (recheck) {
      await Future<void>.delayed(recheckDelay);
      return _lookup(name, recheck: false);
    }
    throw const PivxNameException(
      PivxNameError.unanchoredRoot,
      "The PIVX.name server answered from a registry state that was never "
      "published on BNB Smart Chain. This can mean the server is "
      "misbehaving.",
    );
  }

  // --- PIVX.name server ---

  Future<PivxNameResponse> _indexer(
    String method,
    String path, {
    String? body,
  }) async {
    try {
      return await _transport(
        method,
        service.indexer.replace(path: "${service.indexer.path}$path"),
        body: body,
      );
    } on PivxNameException {
      rethrow;
    } catch (e) {
      throw PivxNameException(
        PivxNameError.indexerUnreachable,
        "Couldn't reach the PIVX.name server.",
        detail: _clean(e.toString()),
      );
    }
  }

  /// The record and proof for [name], or null when the server doesn't know
  /// it.
  Future<Map<String, dynamic>?> _resolve(String name) async {
    // [name] is valid, so it is safe in the path as is.
    final res = await _indexer("POST", "/v1.0/resolve/$name", body: "{}");
    final json = _decodeObject(res.body);
    final error = json?["error"];
    if (error is Map) {
      final text = error["error_message"];
      // The only error text acted on, compared whole.
      if (text == "Domain not found") return null;
      throw PivxNameException(
        PivxNameError.indexerError,
        "The PIVX.name server answered with an error.",
        detail: _clean(text),
      );
    }
    final record = json?["response"];
    if (res.status != 200 || record is! Map<String, dynamic>) {
      throw PivxNameException(
        PivxNameError.indexerError,
        "The PIVX.name server sent an answer PIVXie can't use.",
        detail: "HTTP ${res.status}",
      );
    }
    return record;
  }

  Future<String> _indexerRoot() async {
    final res = await _indexer("GET", "/v1.0/getRoot");
    final root = parsePivxNameRoot(_decodeObject(res.body)?["response"]);
    if (res.status != 200 || root == null) {
      throw PivxNameException(
        PivxNameError.indexerError,
        "The PIVX.name server sent a malformed registry root.",
        detail: "HTTP ${res.status}",
      );
    }
    return root;
  }

  // --- BNB Smart Chain ---

  List<Uri> get _rpcs {
    final rpcs = service.rpcs.toSet().toList();
    // Never quietly settle for fewer: one endpoint alone would decide what
    // the registry is.
    if (rpcs.length < service.minAgreement) {
      throw PivxNameException(
        PivxNameError.unavailable,
        "Checking names needs ${service.minAgreement} independent BNB Smart "
        "Chain servers, but only ${rpcs.length} is configured.",
      );
    }
    return rpcs;
  }

  /// Current root and the block it was read at, under a reviewed epoch.
  Future<({String root, int block})> _anchoredState() async {
    final block = await _pinnedBlock();
    // anchoredState() returns (bytes32 root, uint32 height, uint32 epoch)
    // from one block, so the epoch belongs to the root.
    final words = await _call("0x8d39310a", block, 3);
    final epoch = _uint32(words[2]);
    if (_uint32(words[1]) == null || epoch == null) {
      throw const PivxNameException(
        PivxNameError.chainUnavailable,
        "BNB Smart Chain servers sent a malformed registry state.",
      );
    }
    if (!service.epochs.contains(epoch)) {
      throw PivxNameException(
        PivxNameError.unreviewedEpoch,
        "The PIVX.name registry has changed its rules or rolled back (epoch "
        "$epoch). This version of PIVXie only trusts epoch "
        "${service.epochs.join(", ")}, so it won't send to names until it's "
        "updated.",
      );
    }
    return (root: words[0], block: block);
  }

  Future<bool> _isRootValid(String root, int block) async {
    final words = await _call("0x30ef41b4$root", block, 1);
    // A clean false is an answer like any other, never a reason to keep
    // asking until some endpoint says true.
    return switch (_uint32(words[0])) {
      0 => false,
      1 => true,
      _ => throw const PivxNameException(
        PivxNameError.chainUnavailable,
        "BNB Smart Chain servers sent a malformed answer.",
      ),
    };
  }

  /// The block every read of one lookup is pinned to: the highest one that
  /// [PivxNameService.minAgreement] endpoints report having reached. One
  /// lagging endpoint can't hold it back, and one claiming a future block
  /// can't push it beyond the honest ones. An endpoint that hasn't reached
  /// it fails the read and the next one is asked.
  ///
  /// Endpoints only keep a minute or so of state, so a block is used for one
  /// lookup and never kept.
  Future<int> _pinnedBlock() async {
    final rpcs = _rpcs;
    final heights = <int>[];
    Object? lastError;
    await Future.wait(
      rpcs.map((rpc) async {
        try {
          final hex = await _rpc(rpc, "eth_blockNumber", const []);
          if (!RegExp(r"^0x[0-9a-fA-F]{1,13}$").hasMatch(hex)) {
            throw const FormatException("malformed block number");
          }
          heights.add(int.parse(hex.substring(2), radix: 16));
        } catch (e) {
          lastError = e;
        }
      }),
    );
    if (heights.length < service.minAgreement) {
      throw PivxNameException(
        PivxNameError.chainUnavailable,
        "Only ${heights.length} of ${rpcs.length} BNB Smart Chain servers "
        "answered; ${service.minAgreement} are needed to check a name.",
        detail: _clean(lastError?.toString()),
      );
    }
    heights.sort((a, b) => b.compareTo(a));
    return heights[service.minAgreement - 1];
  }

  /// One `eth_call` to the anchor contract at [block], believed only once
  /// [PivxNameService.minAgreement] endpoints return the same [words] ABI
  /// words. The first ones are asked together, then one more for each that
  /// fails. Two different well-formed answers about one block mean somebody
  /// is wrong, and the lookup stops: a disagreement is never settled by
  /// asking around until a convenient answer turns up.
  Future<List<String>> _call(String data, int block, int words) async {
    final rpcs = _rpcs;
    final params = [
      {"to": service.anchor, "data": data},
      "0x${block.toRadixString(16)}",
    ];
    final shape = RegExp("^0x[0-9a-f]{${64 * words}}\$");
    final answers = <String, int>{};
    var answered = 0;
    Object? lastError;

    Future<String?> ask(Uri rpc) async {
      try {
        final result = (await _rpc(rpc, "eth_call", params)).toLowerCase();
        if (!shape.hasMatch(result)) {
          throw const FormatException("malformed answer");
        }
        return result;
      } catch (e) {
        lastError = e;
        return null;
      }
    }

    var next = service.minAgreement;
    var batch = rpcs.take(next).toList();
    while (true) {
      for (final result in await Future.wait(batch.map(ask))) {
        if (result == null) continue;
        answered++;
        answers[result] = (answers[result] ?? 0) + 1;
      }
      if (answers.length > 1) {
        throw const PivxNameException(
          PivxNameError.chainDisagreement,
          "BNB Smart Chain servers gave different answers about the PIVX.name "
          "registry, so names can't be checked right now.",
        );
      }
      if (answers.isNotEmpty && answers.values.first >= service.minAgreement) {
        final hex = answers.keys.first.substring(2);
        return [
          for (var i = 0; i < words; i++) hex.substring(64 * i, 64 * (i + 1)),
        ];
      }
      if (next >= rpcs.length) break;
      batch = [rpcs[next++]];
    }
    throw PivxNameException(
      PivxNameError.chainUnavailable,
      "Only $answered of ${rpcs.length} BNB Smart Chain servers answered; "
      "${service.minAgreement} must agree to check a name.",
      detail: _clean(lastError?.toString()),
    );
  }

  /// The `result` of one JSON-RPC call. Throws for anything else, which the
  /// caller counts as that endpoint failing.
  Future<String> _rpc(Uri rpc, String method, List<Object> params) async {
    final res = await _transport(
      "POST",
      rpc,
      body: jsonEncode({
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params,
      }),
    );
    if (res.status != 200) throw HttpException("HTTP ${res.status}");
    final json = _decodeObject(res.body);
    final error = json?["error"];
    if (error is Map) throw Exception("RPC error: ${error["message"]}");
    final result = json?["result"];
    if (result is! String || result.length < 3) {
      throw const FormatException("empty answer");
    }
    return result;
  }
}

/// A 32-byte word as a uint32, or null when it holds more than 32 bits.
int? _uint32(String word) {
  if (!word.startsWith("0" * 56)) return null;
  return int.parse(word.substring(56), radix: 16);
}

Map<String, dynamic>? _decodeObject(String body) {
  try {
    final json = jsonDecode(body);
    return json is Map<String, dynamic> ? json : null;
  } catch (_) {
    return null;
  }
}

/// Server-supplied text made safe to show: control and direction-changing
/// characters removed, and cut short (the field is sized by whoever sent it).
String? _clean(Object? text) {
  if (text is! String || text.isEmpty) return null;
  final s = text
      .replaceAll(
        RegExp(
          r"[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]",
        ),
        " ",
      )
      .trim();
  return s.length > 200 ? "${s.substring(0, 200)}…" : s;
}

/// How long one request, body included, may take.
const kPivxNameRequestTimeout = Duration(seconds: 10);

/// No legitimate answer comes near this.
const _maxBody = 256 * 1024;

/// Requests over Tor when the app uses it. With Tor on but not connected,
/// [TorService.getProxyInfo] throws, so nothing leaves without it.
Future<PivxNameResponse> _httpTransport(
  String method,
  Uri url, {
  String? body,
}) async {
  final useTor = AppConfig.hasFeature(AppFeature.tor) && Prefs.instance.useTor;
  final proxy = useTor ? TorService.sharedInstance.getProxyInfo() : null;
  final client = HttpClient()..connectionTimeout = kPivxNameRequestTimeout;
  if (proxy != null) {
    SocksTCPClient.assignToHttpClient(client, [
      ProxySettings(proxy.host, proxy.port),
    ]);
  }
  HttpClientRequest? request;
  try {
    return await () async {
      request = await client.openUrl(method, url);
      request!.headers.set(HttpHeaders.acceptHeader, "application/json");
      if (body != null) {
        final bytes = utf8.encode(body);
        // A length rather than chunks: not every JSON-RPC server takes those.
        request!.headers.contentType = ContentType.json;
        request!.contentLength = bytes.length;
        request!.add(bytes);
      }
      final response = await request!.close();
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        bytes.add(chunk);
        if (bytes.length > _maxBody) {
          throw const HttpException("answer too large");
        }
      }
      return (
        status: response.statusCode,
        body: utf8.decode(bytes.takeBytes(), allowMalformed: true),
      );
    }().timeout(kPivxNameRequestTimeout);
  } on TimeoutException {
    request?.abort();
    throw TimeoutException("No answer from ${url.host} within 10 s");
  } finally {
    client.close(force: true);
  }
}
