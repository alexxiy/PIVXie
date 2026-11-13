import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../utilities/app_store_build.dart';
import '../../wallets/crypto_currency/crypto_currency.dart';
import '../pivx_name/pivx_name_resolver.dart';
import 'pivx_defi_models.dart';

/// Where the bridge is and what it must look like. Constants, never stored:
/// the token and the chain decide where wPIVX is sent, so a new value has
/// to come in a reviewed release, not from the bridge's own answers.
class PivxDefiConfig {
  const PivxDefiConfig({
    required this.site,
    required this.api,
    required this.pivxNetwork,
    required this.chainId,
    required this.token,
    required this.rpcs,
    this.minAgreement = 2,
  });

  /// The bridge's web app, for "open in browser".
  final Uri site;

  /// The API, `/api/v1.0`.
  final Uri api;

  /// What `info.pivx.network` must say.
  final String pivxNetwork;

  /// BNB Smart Chain.
  final int chainId;

  /// The wPIVX token, lowercase. The bridge's info must name this one: it
  /// is the contract asked for deposit addresses.
  final String token;

  /// Independent BNB Smart Chain endpoints. A deposit address counts as the
  /// token's only when [minAgreement] of them return it.
  final List<Uri> rpcs;
  final int minAgreement;

  static final mainnet = PivxDefiConfig(
    site: Uri.parse("https://defi-bridge.pivxie.me/"),
    api: Uri.parse("https://defi-bridge.pivxie.me/api/v1.0"),
    pivxNetwork: "mainnet",
    chainId: 56,
    token: "0x804850d326471123b0736e5818e91b87d49a877c",
    // The endpoints the PIVX.name checks use.
    rpcs: PivxNameService.mainnet.rpcs,
  );

  /// False in builds made with --dart-define=PIVXIE_DEFI=false: they leave
  /// the bridge out (no menu item), e.g. for a store that hasn't reviewed it.
  static const enabled = bool.fromEnvironment(
    "PIVXIE_DEFI",
    defaultValue: true,
  );

  /// The bridge for [coin], or null where there is none or the build leaves
  /// it out. Every way into the bridge asks this. Not in App Store builds
  /// for now: the first App Store release goes to review without it.
  static PivxDefiConfig? forCoin(CryptoCurrency coin) =>
      enabled && !isAppStoreBuild ? _forCoin(coin) : null;

  /// It wraps mainnet PIVX only.
  static PivxDefiConfig? _forCoin(CryptoCurrency coin) =>
      coin is Pivx && coin.network == CryptoCurrencyNetwork.main
      ? mainnet
      : null;

  Uri orderUrl(String id) => site.resolve("order/$id");
}

/// A request to the bridge failed. [status] 0: no answer at all.
class PivxDefiApiException implements Exception {
  const PivxDefiApiException(this.message, this.status);

  /// The bridge's error_message (compared whole, never shown as is), or
  /// what went wrong.
  final String message;
  final int status;

  bool get isNetwork => status == 0;

  @override
  String toString() => "PivxDefiApiException($status): $message";
}

/// The bridge's settings don't match the ones this release was made for
/// (another token, chain or network): nothing is ordered or paid.
class PivxDefiConfigMismatch implements Exception {
  const PivxDefiConfigMismatch(this.what);

  final String what;

  @override
  String toString() => "PivxDefiConfigMismatch: $what";
}

/// The bridge's API. Through Tor when the app uses it.
class PivxDefiApi {
  PivxDefiApi(this.config, {PivxNameTransport? transport})
    : _transport = transport ?? pivxNameHttpTransport;

  static PivxDefiApi? forCoin(CryptoCurrency coin) {
    final config = PivxDefiConfig.forCoin(coin);
    return config == null ? null : PivxDefiApi(config);
  }

  final PivxDefiConfig config;
  final PivxNameTransport _transport;

  Future<Object?> _call(String method, {String? arg, Object? body}) async {
    final path = "${config.api.path}/$method${arg == null ? "" : "/$arg"}";
    final PivxNameResponse res;
    try {
      res = await _transport(
        body == null ? "GET" : "POST",
        config.api.replace(path: path),
        body: body == null ? null : jsonEncode(body),
      );
    } catch (e) {
      throw PivxDefiApiException(e.toString(), 0);
    }
    Object? json;
    try {
      json = jsonDecode(res.body);
    } catch (_) {
      // not JSON: a proxy's error page
    }
    if (json is Map && json.containsKey("response") && res.status == 200) {
      return json["response"];
    }
    final error = json is Map ? json["error"] : null;
    final text = error is Map ? error["error_message"] : null;
    throw PivxDefiApiException(
      text is String ? text : "HTTP ${res.status}",
      res.status == 200 ? 500 : res.status,
    );
  }

  /// The bridge's settings, checked against [config].
  Future<PivxDefiInfo> info() async {
    final info = PivxDefiInfo.fromJson(await _call("info"));
    if (info.chainId != config.chainId) {
      throw PivxDefiConfigMismatch("chain ${info.chainId}");
    }
    if (info.tokenAddress.toLowerCase() != config.token) {
      throw PivxDefiConfigMismatch("token ${info.tokenAddress}");
    }
    if (info.pivxNetwork != config.pivxNetwork) {
      throw PivxDefiConfigMismatch("network ${info.pivxNetwork}");
    }
    if (info.tokenDecimals != 8) {
      throw PivxDefiConfigMismatch("decimals ${info.tokenDecimals}");
    }
    return info;
  }

  Future<PivxDefiOrder> createOrder(PivxDefiSwap swap) async {
    final answer = await _call(
      "createOrder",
      body: {
        "direction": swap.direction.name,
        "amount": formatPivxDefiAmount(swap.amount),
        if (swap.isWrap) "evm_address": swap.evmAddress,
        if (!swap.isWrap) "pivx_address": swap.pivxAddress,
        // For the bridge's record only: it can't check a name, and the
        // order goes by the address.
        if (!swap.isWrap && swap.pivxName != null) "pivx_name": swap.pivxName,
      },
    );
    return PivxDefiOrder.fromJson(answer);
  }

  Future<PivxDefiOrder> order(String id) async {
    if (!isPivxDefiOrderId(id)) {
      throw const PivxDefiApiException("Order not found", 404);
    }
    final order = PivxDefiOrder.fromJson(await _call("order", arg: id));
    if (order.id != id) throw const PivxDefiFormatException("id");
    return order;
  }

  Future<PivxDefiReserves> reserves() async =>
      PivxDefiReserves.fromJson(await _call("reserves"));
}

/// Why a deposit address could not be confirmed.
enum PivxDefiChainError {
  /// Too few endpoints answered: try again later.
  unavailable,

  /// Endpoints gave different answers about the same block.
  disagreement,
}

class PivxDefiChainException implements Exception {
  const PivxDefiChainException(this.kind, [this.detail]);

  final PivxDefiChainError kind;
  final String? detail;

  @override
  String toString() => "PivxDefiChainException(${kind.name}): $detail";
}

/// Reads the wPIVX token on BNB Smart Chain the way the PIVX.name checks
/// read the anchor contract: every read pinned to a block that
/// [PivxDefiConfig.minAgreement] endpoints have reached, and believed only
/// once that many return the same answer. One lying endpoint can't change
/// what the app shows; two that disagree stop it.
class PivxDefiChain {
  PivxDefiChain(this.config, {PivxNameTransport? transport})
    : _transport = transport ?? pivxNameHttpTransport;

  final PivxDefiConfig config;
  final PivxNameTransport _transport;

  /// The deposit address the token gives for [pivxAddress], lowercase.
  Future<String> depositAddress(String pivxAddress) async {
    final block = await _pinnedBlock();
    final word = await _call(pivxDefiDepositAddressCall(pivxAddress), block);
    return decodeEvmAddressWord(word) ??
        (throw const PivxDefiChainException(
          PivxDefiChainError.unavailable,
          "malformed address",
        ));
  }

  List<Uri> get _rpcs {
    final rpcs = config.rpcs.toSet().toList();
    if (rpcs.length < config.minAgreement) {
      throw const PivxDefiChainException(
        PivxDefiChainError.unavailable,
        "too few endpoints",
      );
    }
    return rpcs;
  }

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
    if (heights.length < config.minAgreement) {
      throw PivxDefiChainException(
        PivxDefiChainError.unavailable,
        lastError?.toString(),
      );
    }
    heights.sort((a, b) => b.compareTo(a));
    return heights[config.minAgreement - 1];
  }

  /// One `eth_call` to the token at [block] returning one ABI word.
  Future<String> _call(String data, int block) async {
    final rpcs = _rpcs;
    final params = [
      {"to": config.token, "data": data},
      "0x${block.toRadixString(16)}",
    ];
    final shape = RegExp(r"^0x[0-9a-f]{64}$");
    final answers = <String, int>{};
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

    var next = config.minAgreement;
    var batch = rpcs.take(next).toList();
    while (true) {
      for (final result in await Future.wait(batch.map(ask))) {
        if (result == null) continue;
        answers[result] = (answers[result] ?? 0) + 1;
      }
      if (answers.length > 1) {
        throw const PivxDefiChainException(PivxDefiChainError.disagreement);
      }
      if (answers.isNotEmpty && answers.values.first >= config.minAgreement) {
        return answers.keys.first;
      }
      if (next >= rpcs.length) break;
      batch = [rpcs[next++]];
    }
    throw PivxDefiChainException(
      PivxDefiChainError.unavailable,
      lastError?.toString(),
    );
  }

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
    final json = jsonDecode(res.body);
    if (json is! Map) throw const FormatException("not an object");
    final error = json["error"];
    if (error is Map) throw Exception("RPC error: ${error["message"]}");
    final result = json["result"];
    if (result is! String || result.length < 3) {
      throw const FormatException("empty answer");
    }
    return result;
  }
}
