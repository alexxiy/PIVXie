import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:socks5_proxy/socks_client.dart';

import '../../../app_config.dart';
import '../../../models/node_model.dart';
import '../../../services/tor_service.dart';
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
/// Blockbook-compatible transparent index (`/api/v2/...`). Amounts in
/// `/api/v2` responses are satoshi strings.
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
    final status = await this.status();
    final chain = (status["backend"] as Map?)?["chain"] as String?;
    final expectMain = coin.network == CryptoCurrencyNetwork.main;
    if (chain == null) return "Bridge has no address index (/api/v2)";
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

  ({InternetAddress host, int port})? get _proxy =>
      useTor ? TorService.sharedInstance.getProxyInfo() : null;

  /// One client for all requests, so connections (TLS sessions, Tor
  /// streams) are kept alive and reused instead of set up per call.
  HttpClient? _httpClient;

  /// Last request start or end (wall clock, so it also covers time the
  /// app was frozen in the background).
  DateTime _lastActivity = DateTime.now();

  /// After a pause, pooled connections may be dead (sleep, network
  /// change) and a request on one hangs until the timeout, so start a
  /// fresh client. Running requests still finish on the old one.
  HttpClient get _http {
    final now = DateTime.now();
    if (_httpClient != null &&
        now.difference(_lastActivity) > const Duration(seconds: 20)) {
      _httpClient!.close();
      _httpClient = null;
    }
    _lastActivity = now;
    return _httpClient ??= _newHttpClient(_proxy);
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

  Future<({int code, String body})> _send(
    String method,
    Uri url, {
    Map<String, String>? headers,
    String? body,
    Duration timeout = _timeout,
  }) async {
    HttpClientRequest? request;
    try {
      return await () async {
        request = await _http.openUrl(method, url);
        headers?.forEach(request!.headers.set);
        if (body != null) request!.add(utf8.encode(body));
        final response = await request!.close();
        final text = await response.transform(utf8.decoder).join();
        _lastActivity = DateTime.now();
        return (code: response.statusCode, body: text);
      }().timeout(timeout);
    } on TimeoutException {
      request?.abort();
      rethrow;
    }
  }

  Uri _uri(String path, [Map<String, String>? query]) => baseUri.replace(
    path: "${baseUri.path}$path",
    queryParameters: (query == null || query.isEmpty) ? null : query,
  );

  Future<String> _getText(String path, [Map<String, String>? query]) async {
    final response = await _send("GET", _uri(path, query));
    if (response.code != 200) {
      throw PivxBridgeException(
        _errorMessage(response.body),
        statusCode: response.code,
      );
    }
    return response.body;
  }

  Future<dynamic> _getJson(String path, [Map<String, String>? query]) async {
    return jsonDecode(await _getText(path, query));
  }

  String _errorMessage(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map && json["error"] != null) return json["error"].toString();
    } catch (_) {}
    return body;
  }

  // ---------------------------------------------------------------------------
  // Node RPC routes
  // ---------------------------------------------------------------------------

  Future<int> getBlockCount() async {
    final text = await _getText("/getblockcount");
    return int.parse(text.trim().replaceAll('"', ''));
  }

  // ---------------------------------------------------------------------------
  // /api/v2 (transparent address index)
  // ---------------------------------------------------------------------------

  /// `/api/v2/api` — index status. `blockbook.inSync` tells whether the
  /// bridge has caught up with its node.
  Future<Map<String, dynamic>> status() async {
    return Map<String, dynamic>.from(await _getJson("/api/v2/api") as Map);
  }

  Future<String> blockHash(int height) async {
    final json = await _getJson("/api/v2/block-index/$height") as Map;
    return json["blockHash"] as String;
  }

  /// One page of `/api/v2/xpub/{xpub}`.
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
      await _getJson("/api/v2/xpub/$xpub", {
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
    for (int page = 2; page <= totalPages; page++) {
      final next = await this.xpub(
        xpub,
        page: page,
        from: from,
        gap: gap,
        tokens: "used",
      );
      txs.addAll(
        ((next["transactions"] as List?) ?? const []).map(
          (e) => Map<String, dynamic>.from(e as Map),
        ),
      );
    }
    return (txs: txs, info: first);
  }

  Future<List<Map<String, dynamic>>> utxo(
    String addressOrXpub, {
    int? gap,
  }) async {
    final json = await _getJson("/api/v2/utxo/$addressOrXpub", {
      if (gap != null) "gap": "$gap",
    }) as List;
    return json.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> tx(String txid) async {
    return Map<String, dynamic>.from(await _getJson("/api/v2/tx/$txid") as Map);
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
      _uri("/api/v2/sendtx/"),
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

  /// Long-poll `POST /api/v2/watch` (bridge extension). Answers when a
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
      _uri("/api/v2/watch"),
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

  /// `getbudgetvotes` of the proposal [name], only the votes of
  /// [masternodeIds] (`txid-vout`).
  Future<List<Map<String, dynamic>>> budgetVotes(
    String name, {
    required Iterable<String> masternodeIds,
  }) async {
    final ids = masternodeIds.toList();
    if (ids.isEmpty) return const [];
    final match = ids.map((id) => ".mnId == ${jsonEncode(id)}").join(" or ");
    final json = await _getJson("/getbudgetvotes", {
      "params": _params([name]),
      "filter": "[.[] | select($match)]",
    });
    return [
      if (json is List)
        for (final e in json) Map<String, dynamic>.from(e as Map),
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
  static Future<void> downloadToFile(
    Uri url,
    File file, {
    ({InternetAddress host, int port})? proxy,
    void Function(int received, int? total)? onProgress,
  }) async {
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
      final sink = tmp.openWrite();
      int received = 0;
      await for (final chunk in response.timeout(_timeout)) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.close();
      await tmp.rename(file.path);
    } finally {
      client.close(force: true);
      if (tmp.existsSync()) await tmp.delete();
    }
  }
}
