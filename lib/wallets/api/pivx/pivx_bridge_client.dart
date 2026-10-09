import 'dart:convert';
import 'dart:io';

import 'package:socks5_proxy/socks_client.dart';

import '../../../app_config.dart';
import '../../../models/node_model.dart';
import '../../../networking/http.dart';
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

  Uri _uri(String path, [Map<String, String>? query]) => baseUri.replace(
    path: "${baseUri.path}$path",
    queryParameters: (query == null || query.isEmpty) ? null : query,
  );

  Future<String> _getText(String path, [Map<String, String>? query]) async {
    final response = await HTTP()
        .get(url: _uri(path, query), proxyInfo: _proxy)
        .timeout(_timeout);
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

  Future<List<Map<String, dynamic>>> utxo(String addressOrXpub, {int? gap}) async {
    final json = await _getJson("/api/v2/utxo/$addressOrXpub", {
      if (gap != null) "gap": "$gap",
    }) as List;
    return json.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> tx(String txid) async {
    return Map<String, dynamic>.from(await _getJson("/api/v2/tx/$txid") as Map);
  }

  /// Broadcast a raw transaction; returns its txid.
  Future<String> sendTx(String rawTxHex) async {
    final response = await HTTP()
        .post(
          url: _uri("/api/v2/sendtx/"),
          headers: {"Content-Type": "text/plain"},
          body: rawTxHex,
          proxyInfo: _proxy,
        )
        .timeout(_timeout);
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
    final response = await HTTP()
        .post(
          url: _uri("/api/v2/watch"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({
            "height": height,
            if (hash != null) "hash": hash,
            if (mempoolSeq != null) "mempoolSeq": mempoolSeq,
            "addresses": addresses,
            "timeout": timeoutSeconds,
          }),
          proxyInfo: _proxy,
        )
        .timeout(Duration(seconds: timeoutSeconds + 20));
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

  HttpClient _streamingClient() {
    final client = HttpClient()..connectionTimeout = _timeout;
    final proxy = _proxy;
    if (proxy != null) {
      SocksTCPClient.assignToHttpClient(client, [
        ProxySettings(proxy.host, proxy.port),
      ]);
    }
    return client;
  }

  /// Raw byte stream of `/getshielddata?startBlock=N` (bridge `pivx`
  /// format: length-prefixed raw v3 txs, each block closed by a 0x5d
  /// footer carrying height and time).
  Stream<List<int>> shieldData(int startBlock) async* {
    final client = _streamingClient();
    try {
      final request = await client.getUrl(
        _uri("/getshielddata", {"startBlock": "$startBlock"}),
      );
      final response = await request.close();
      if (response.statusCode != 200) {
        throw PivxBridgeException(
          "getshielddata failed",
          statusCode: response.statusCode,
        );
      }
      yield* response;
    } finally {
      client.close(force: true);
    }
  }

  /// `finalsaplingroot` of the block at [height] (display hex), via the
  /// bridge's RPC proxy.
  Future<String?> finalSaplingRoot(int height) async {
    final hash = (await _getText("/getblockhash", {"params": "$height"}))
        .trim()
        .replaceAll('"', '');
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

  /// Download [url] into [file], reporting `(received, total)`.
  static Future<void> downloadToFile(
    Uri url,
    File file, {
    ({InternetAddress host, int port})? proxy,
    void Function(int received, int? total)? onProgress,
  }) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    if (proxy != null) {
      SocksTCPClient.assignToHttpClient(client, [
        ProxySettings(proxy.host, proxy.port),
      ]);
    }
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
      await for (final chunk in response) {
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
