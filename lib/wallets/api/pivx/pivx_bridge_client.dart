import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:socks5_proxy/socks_client.dart';

import '../../../app_config.dart';
import '../../../models/node_model.dart';
import '../../../services/tor_service.dart';
import '../../../utilities/local_network_access.dart';
import '../../../utilities/prefs.dart';
import '../../crypto_currency/crypto_currency.dart';

/// Answer of [PivxBridgeClient.watch].
typedef PivxBridgeWatch = ({
  int height,
  String hash,
  int mempoolSeq,
  bool newBlock,
  List<String> txids,
  bool reset,
  bool changed,
});

/// [text] decoded on a short-lived isolate. Top level, so the closure
/// carries nothing but the text.
Future<dynamic> _decodeApart(String text) =>
    Isolate.run(() => jsonDecode(text));

class PivxBridgeException implements Exception {
  PivxBridgeException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => "PivxBridgeException($statusCode): $message";
}

/// HTTP client for a pivx-bridge instance.
///
/// Uses the bridge's RPC routes (`/getblockcount`, ...) and its
/// transparent address index (`/xpub`, `/utxo`, ...). Index answers follow
/// Blockbook's format: amounts are satoshi strings.
class PivxBridgeClient {
  PivxBridgeClient({required this.baseUri, this.useTor = false});

  factory PivxBridgeClient.fromNode(NodeModel node, Prefs prefs) =>
      PivxBridgeClient.fromParts(
        host: node.host,
        port: node.port,
        useSSL: node.useSSL,
        useTor: prefs.useTor,
      );

  /// [host] may be a bare hostname or a full base URL including scheme
  /// and path (e.g. `https://rpc.example.org/mainnet`).
  factory PivxBridgeClient.fromParts({
    required String host,
    required int port,
    required bool useSSL,
    required bool useTor,
  }) {
    var uri = Uri.parse(host.trim());
    if (!uri.hasScheme) {
      uri = Uri.parse("${useSSL ? "https" : "http"}://${host.trim()}");
    }
    if (!uri.hasPort && port > 0 && port != 80 && port != 443) {
      uri = uri.replace(port: port);
    }
    // Normalise: no trailing slash on the base path.
    final path = uri.path.endsWith("/")
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    return PivxBridgeClient(
      baseUri: uri.replace(path: path),
      useTor: AppConfig.hasFeature(AppFeature.tor) && useTor,
    );
  }

  /// Checks the bridge is reachable, serves the address index and runs
  /// on a chain matching [coin]. Returns null on success, else a reason.
  Future<String?> verifyFor(Pivx coin) async {
    final Map<String, dynamic> status;
    try {
      status = await this.status();
    } on PivxBridgeException catch (e) {
      // Without the index, `/status` falls through to the RPC proxy.
      if (e.statusCode == 403 || e.statusCode == 404) {
        return "This bridge has no address index: it's older than "
            "pivx-bridge 0.5, or runs without ADDR_INDEX";
      }
      rethrow;
    }
    final chain = (status["backend"] as Map?)?["chain"] as String?;
    final expectMain = coin.network == CryptoCurrencyNetwork.main;
    if (chain == null) return "This bridge has no address index (ADDR_INDEX)";
    try {
      await getBlockCount();
    } catch (e) {
      return "The bridge's PIVX node is not reachable ($e)";
    }
    if (expectMain != (chain == "main")) {
      return "Bridge serves \"$chain\", wallet expects ${coin.network.name}";
    }
    final genesis = await blockHash(0);
    if (!coin.acceptedGenesisHashes.contains(genesis)) {
      return "Unexpected genesis block $genesis";
    }
    return null;
  }

  final Uri baseUri;
  final bool useTor;

  static const _timeout = Duration(seconds: 60);

  /// Tor's proxy for this client, read for every request: it throws while
  /// Tor is on but not connected, so nothing goes out without it.
  ({InternetAddress host, int port})? get _proxy {
    if (useTor) return TorService.sharedInstance.getProxyInfo();
    _refuseDirectUnderTor();
    return null;
  }

  /// A client made before Tor was turned on (still held by a running sync)
  /// must not go on without it.
  static void _refuseDirectUnderTor() {
    if (AppConfig.hasFeature(AppFeature.tor) && Prefs.instance.useTor) {
      throw PivxBridgeException("Tor was turned on");
    }
  }

  /// One client for all requests, so connections (TLS sessions, Tor
  /// streams) are kept alive and reused instead of set up per call.
  HttpClient? _httpClient;
  ({InternetAddress host, int port})? _httpProxy;

  /// Last request start or end (wall clock, so it also covers time the
  /// app was frozen in the background).
  DateTime _lastActivity = DateTime.now();

  /// After a pause, pooled connections may be dead (sleep, network
  /// change) and a request on one hangs until the timeout, so start a
  /// fresh client; likewise when Tor restarted on another port. Running
  /// requests still finish on the old one.
  HttpClient get _http {
    final now = DateTime.now();
    final proxy = _proxy;
    if (_httpClient != null &&
        (proxy != _httpProxy ||
            now.difference(_lastActivity) > const Duration(seconds: 20))) {
      _httpClient!.close();
      _httpClient = null;
    }
    _lastActivity = now;
    _httpProxy = proxy;
    return _httpClient ??= _newHttpClient(proxy);
  }

  static HttpClient _newHttpClient(({InternetAddress host, int port})? proxy) {
    final client = HttpClient()
      ..connectionTimeout = _timeout
      ..idleTimeout = const Duration(seconds: 30);
    if (proxy != null) {
      SocksTCPClient.assignToHttpClient(client, [
        ProxySettings(proxy.host, proxy.port),
      ]);
    }
    return client;
  }

  /// Close the connections; pending requests still finish.
  void close() {
    _httpClient?.close();
    _httpClient = null;
  }

  /// Android 17 needs the user's permission to reach a bridge on the
  /// local network (over Tor the proxy connects, not the app, and the
  /// host isn't looked up).
  Future<void> _localNetworkReady() async {
    if (_proxy == null) await LocalNetworkAccess.ensure(baseUri.host);
  }

  Future<({int code, String body})> _send(
    String method,
    Uri url, {
    Map<String, String>? headers,
    String? body,
    Duration timeout = _timeout,
  }) async {
    await _localNetworkReady();
    HttpClientRequest? request;
    try {
      return await () async {
        request = await _http.openUrl(method, url);
        headers?.forEach(request!.headers.set);
        if (body != null) {
          final bytes = utf8.encode(body);
          // A length rather than chunked encoding, which some servers and
          // proxies refuse.
          request!.contentLength = bytes.length;
          request!.add(bytes);
        }
        final response = await request!.close();
        final text = await response.transform(utf8.decoder).join();
        _lastActivity = DateTime.now();
        return (code: response.statusCode, body: text);
      }().timeout(timeout);
    } on TimeoutException {
      request?.abort();
      rethrow;
    } on HttpException catch (e) {
      // Its text names the URL, which may hold the wallet's xpub.
      throw HttpException(redactXpubs(e.message));
    }
  }

  /// [text] without extended public keys: error messages end up in the
  /// logs, and an xpub reveals every address of a wallet.
  static String redactXpubs(String text) =>
      text.replaceAll(RegExp(r"[xt]pub[1-9A-HJ-NP-Za-km-z]{100,}"), "<xpub>");

  Uri _uri(String path, [Map<String, String>? query]) => baseUri.replace(
    path: "${baseUri.path}$path",
    queryParameters: (query == null || query.isEmpty) ? null : query,
  );

  Future<String> _getText(String path, [Map<String, String>? query]) async {
    final response = await _send("GET", _uri(path, query));
    if (response.code == 404 && response.body.trim().isEmpty) {
      // No such route: a bridge older than 0.5 (index under /api/v2), or
      // one without the address index.
      final route = path.split("/").firstWhere((e) => e.isNotEmpty);
      throw PivxBridgeException(
        "This bridge has no /$route: it's older than pivx-bridge 0.5, or "
        "runs without the address index (ADDR_INDEX)",
        statusCode: 404,
      );
    }
    if (response.code != 200) {
      throw PivxBridgeException(
        _errorMessage(response.body),
        statusCode: response.code,
      );
    }
    return response.body;
  }

  Future<dynamic> _getJson(String path, [Map<String, String>? query]) async {
    final text = await _getText(path, query);
    // A large answer (a page of history) is decoded off the UI isolate.
    return text.length < 256 * 1024 ? jsonDecode(text) : _decodeApart(text);
  }

  String _errorMessage(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map && json["error"] != null) {
        return redactXpubs(json["error"].toString());
      }
    } catch (_) {}
    return redactXpubs(body);
  }

  // ---------------------------------------------------------------------------
  // Node RPC routes
  // ---------------------------------------------------------------------------

  Future<int> getBlockCount() async {
    final text = await _getText("/getblockcount");
    return int.parse(text.trim().replaceAll('"', ''));
  }

  // ---------------------------------------------------------------------------
  // Transparent address index
  // ---------------------------------------------------------------------------

  /// `/status` — index status. `index.inSync` tells whether the bridge
  /// has caught up with its node.
  Future<Map<String, dynamic>> status() async {
    return Map<String, dynamic>.from(await _getJson("/status") as Map);
  }

  Future<String> blockHash(int height) async {
    final json = await _getJson("/block-index/$height") as Map;
    return json["blockHash"] as String;
  }

  /// Transactions of [address] between blocks [from] and [to] (newest
  /// first, at most [pageSize]).
  Future<List<Map<String, dynamic>>> addressTxs(
    String address, {
    int? from,
    int? to,
    int pageSize = 1000,
  }) async {
    final json = await _getJson("/address/$address", {
      "details": "txs",
      "pageSize": "$pageSize",
      if (from != null) "from": "$from",
      if (to != null) "to": "$to",
    }) as Map;
    return [
      for (final t in (json["transactions"] as List?) ?? const [])
        Map<String, dynamic>.from(t as Map),
    ];
  }

  /// One page of `/xpub/{xpub}`.
  Future<Map<String, dynamic>> xpub(
    String xpub, {
    String details = "txs",
    String tokens = "used",
    int page = 1,
    int pageSize = 1000,
    int? from,
    int? gap,
  }) async {
    return Map<String, dynamic>.from(
      await _getJson("/xpub/$xpub", {
        "details": details,
        "tokens": tokens,
        "page": "$page",
        "pageSize": "$pageSize",
        if (from != null) "from": "$from",
        if (gap != null) "gap": "$gap",
      }) as Map,
    );
  }

  /// All history of an xpub from height [from] (newest first) plus the
  /// list of used addresses (`tokens`) and balances of the first page.
  Future<({List<Map<String, dynamic>> txs, Map<String, dynamic> info})>
  xpubHistory(String xpub, {int? from, int? gap}) async {
    final first = await this.xpub(xpub, from: from, gap: gap);
    final txs = <Map<String, dynamic>>[
      ...((first["transactions"] as List?) ?? const []).map(
        (e) => Map<String, dynamic>.from(e as Map),
      ),
    ];
    final totalPages = first["totalPages"] as int? ?? 1;
    // The other pages, a few at a time, kept in page order.
    const parallel = 4;
    for (int page = 2; page <= totalPages; page += parallel) {
      final pages = await Future.wait([
        for (int p = page; p < page + parallel && p <= totalPages; p++)
          this.xpub(xpub, page: p, from: from, gap: gap, tokens: "used"),
      ]);
      for (final next in pages) {
        txs.addAll(
          ((next["transactions"] as List?) ?? const []).map(
            (e) => Map<String, dynamic>.from(e as Map),
          ),
        );
      }
    }
    // A tx arriving between two page requests shifts the pages: the same
    // tx may come twice.
    final seen = <String>{};
    txs.retainWhere((t) => seen.add(t["txid"] as String));
    return (txs: txs, info: first);
  }

  Future<List<Map<String, dynamic>>> utxo(
    String addressOrXpub, {
    int? gap,
  }) async {
    final json = await _getJson("/utxo/$addressOrXpub", {
      if (gap != null) "gap": "$gap",
    }) as List;
    return json.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> tx(String txid) async {
    return Map<String, dynamic>.from(await _getJson("/tx/$txid") as Map);
  }

  /// Raw hex of a transaction.
  Future<String> rawTx(String txid) async {
    final hex = (await tx(txid))["hex"] as String?;
    if (hex != null && hex.isNotEmpty) return hex;
    return (await _getText("/getrawtransaction", {
      "params": txid,
    })).trim().replaceAll('"', '');
  }

  /// Broadcast a raw transaction; returns its txid.
  Future<String> sendTx(String rawTxHex) async {
    final response = await _send(
      "POST",
      _uri("/sendtx"),
      headers: {"Content-Type": "text/plain"},
      body: rawTxHex,
    );
    if (response.code != 200) {
      throw PivxBridgeException(
        _errorMessage(response.body),
        statusCode: response.code,
      );
    }
    final json = jsonDecode(response.body) as Map;
    return json["result"] as String;
  }

  /// Long-poll `POST /watch`. Answers when a
  /// block other than [height]/[hash] is indexed, when a mempool tx
  /// touching one of [addresses] arrives after [mempoolSeq], or after
  /// [timeoutSeconds].
  Future<PivxBridgeWatch> watch({
    required int height,
    String? hash,
    int? mempoolSeq,
    List<String> addresses = const [],
    int timeoutSeconds = 25,
  }) async {
    final response = await _send(
      "POST",
      _uri("/watch"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "height": height,
        if (hash != null) "hash": hash,
        if (mempoolSeq != null) "mempoolSeq": mempoolSeq,
        "addresses": addresses,
        "timeout": timeoutSeconds,
      }),
      timeout: Duration(seconds: timeoutSeconds + 20),
    );
    if (response.code != 200) {
      throw PivxBridgeException(
        _errorMessage(response.body),
        statusCode: response.code,
      );
    }
    final json = jsonDecode(response.body) as Map;
    return (
      height: json["height"] as int,
      hash: json["hash"] as String,
      mempoolSeq: json["mempoolSeq"] as int,
      newBlock: json["newBlock"] as bool,
      txids: List<String>.from(json["txids"] as List),
      reset: json["reset"] as bool,
      changed: json["changed"] as bool,
    );
  }

  // ---------------------------------------------------------------------------
  // Streaming (shield data, sapling params)
  // ---------------------------------------------------------------------------

  /// Raw byte stream of `/getshielddata?startBlock=N` (bridge `pivx`
  /// format: length-prefixed raw v3 txs, each block closed by a 0x5d
  /// footer carrying height and time).
  ///
  /// Fails when no data arrives for [_timeout], so a stalled stream
  /// can't hold up the sync forever.
  Stream<List<int>> shieldData(int startBlock) async* {
    await _localNetworkReady();
    final request = await _http
        .getUrl(_uri("/getshielddata", {"startBlock": "$startBlock"}))
        .timeout(_timeout);
    final response = await request.close().timeout(_timeout);
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw PivxBridgeException(
        "getshielddata failed",
        statusCode: response.statusCode,
      );
    }
    yield* response.timeout(_timeout);
  }

  /// `finalsaplingroot` of the block at [height] (display hex), via the
  /// bridge's RPC proxy.
  Future<String?> finalSaplingRoot(int height) async {
    final hash = (await _getText("/getblockhash", {
      "params": "$height",
    })).trim().replaceAll('"', '');
    final block = await _getJson("/getblock", {"params": "$hash,1"}) as Map;
    return block["finalsaplingroot"] as String?;
  }

  /// `listmasternodes` (via the RPC proxy) filtered by [filter], e.g. a
  /// collateral txid.
  Future<List<dynamic>> listMasternodes(String filter) async {
    final json = await _getJson("/listmasternodes", {"params": filter});
    return json is List ? json : const [];
  }

  /// Protocol version of the bridge's node (`getnetworkinfo`), or null
  /// when the bridge does not allow that call.
  Future<int?> protocolVersion() async {
    try {
      final json = await _getJson("/getnetworkinfo") as Map;
      return json["protocolversion"] as int?;
    } catch (_) {
      return null;
    }
  }

  /// `relaymasternodebroadcast` (via the RPC proxy): relay a signed
  /// masternode broadcast ([mnbHex]). Returns the node's answer, e.g.
  /// "Masternode broadcast sent (service ..., vin ...)".
  Future<String> relayMasternodeBroadcast(String mnbHex) async {
    final json = await _getJson("/relaymasternodebroadcast", {
      "params": mnbHex,
    });
    return json.toString();
  }

  // ---------------------------------------------------------------------------
  // Governance (budget proposals), via the RPC proxy
  // ---------------------------------------------------------------------------

  /// `getbudgetinfo`: every known budget proposal.
  Future<List<Map<String, dynamic>>> budgetInfo() async {
    final json = await _getJson("/getbudgetinfo");
    return [
      if (json is List)
        for (final e in json) Map<String, dynamic>.from(e as Map),
    ];
  }

  /// `getbudgetprojection`: the proposals the next superblock would pay.
  Future<List<Map<String, dynamic>>> budgetProjection() async {
    final json = await _getJson("/getbudgetprojection");
    return [
      if (json is List)
        for (final e in json) Map<String, dynamic>.from(e as Map),
    ];
  }

  /// `getmasternodecount`: `{total, stable, enabled, ...}`.
  Future<Map<String, dynamic>> masternodeCount() async =>
      Map<String, dynamic>.from(await _getJson("/getmasternodecount") as Map);

  /// RPC proxy params: comma separated (every bridge), or a JSON array
  /// when a value contains a comma (e.g. a proposal name; newer bridges).
  static String _params(List<Object> values) =>
      values.any((v) => v is String && v.contains(","))
      ? jsonEncode(values)
      : values.join(",");

  /// Most masternodes picked by the bridge's filter: each adds ~100
  /// bytes to the query string, and a request line over 8 KB is refused
  /// by reverse proxies such as nginx.
  static const _kVoteFilterMax = 50;

  /// `getbudgetvotes` of the proposal [name], only the votes of
  /// [masternodeIds] (`txid-vout`).
  Future<List<Map<String, dynamic>>> budgetVotes(
    String name, {
    required Iterable<String> masternodeIds,
  }) async {
    final ids = masternodeIds.toSet();
    if (ids.isEmpty) return const [];
    final json = await _getJson("/getbudgetvotes", {
      "params": _params([name]),
      // More masternodes: all the proposal's votes (one per masternode
      // that voted), ours picked here.
      if (ids.length <= _kVoteFilterMax)
        "filter":
            "[.[] | select("
            "${ids.map((id) => ".mnId == ${jsonEncode(id)}").join(" or ")})]",
    });
    return [
      if (json is List)
        for (final e in json)
          if (ids.contains((e as Map)["mnId"])) Map<String, dynamic>.from(e),
    ];
  }

  /// `submitbudget`: announce a proposal whose fee transaction [feeTxid]
  /// is confirmed. Returns the proposal hash. Always JSON params: exact
  /// types (the amount as a decimal string), names may contain commas.
  Future<String> submitBudget({
    required String name,
    required String url,
    required int payments,
    required int blockStart,
    required String paymentAddress,
    required String amount,
    required String feeTxid,
  }) async {
    final text = await _getText("/submitbudget", {
      "params": jsonEncode([
        name,
        url,
        payments,
        blockStart,
        paymentAddress,
        amount,
        feeTxid,
      ]),
    });
    return text.trim().replaceAll('"', '');
  }

  /// `mnbudgetrawvote`: relay a budget vote signed with the masternode
  /// key. Returns the node's answer ("Voted successfully" or why not).
  Future<String> budgetRawVote({
    required String collateralTxid,
    required int collateralVout,
    required String proposalHash,
    required bool yes,
    required int time,
    required String signatureBase64,
  }) async {
    final json = await _getJson("/mnbudgetrawvote", {
      "params": _params([
        collateralTxid,
        collateralVout,
        proposalHash,
        yes ? "yes" : "no",
        time,
        signatureBase64,
      ]),
    });
    return json.toString();
  }

  /// Download [url] into [file], reporting `(received, total)`.
  /// Download [url] to [file]; more than [maxBytes] is refused (a server
  /// that never stops sending would fill the disk).
  static Future<void> downloadToFile(
    Uri url,
    File file, {
    required int maxBytes,
    ({InternetAddress host, int port})? proxy,
    void Function(int received, int? total)? onProgress,
  }) async {
    if (proxy == null) {
      _refuseDirectUnderTor();
      await LocalNetworkAccess.ensure(url.host);
    }
    final client = _newHttpClient(proxy);
    final tmp = File("${file.path}.part");
    try {
      final response = await (await client.getUrl(url)).close();
      if (response.statusCode != 200) {
        throw PivxBridgeException(
          "download failed: $url",
          statusCode: response.statusCode,
        );
      }
      final total = response.contentLength > 0 ? response.contentLength : null;
      if (total != null && total > maxBytes) {
        throw PivxBridgeException("download too large: $url");
      }
      final sink = tmp.openWrite();
      int received = 0;
      try {
        await for (final chunk in response.timeout(_timeout)) {
          received += chunk.length;
          if (received > maxBytes) {
            throw PivxBridgeException("download too large: $url");
          }
          sink.add(chunk);
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }
      await tmp.rename(file.path);
    } finally {
      client.close(force: true);
      if (tmp.existsSync()) await tmp.delete();
    }
  }
}
