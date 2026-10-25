import 'dart:async';

import '../app_config.dart';
import '../models/node_model.dart';
import '../utilities/logger.dart';
import '../utilities/prefs.dart';
import '../wallets/api/pivx/pivx_bridge_client.dart';
import '../wallets/crypto_currency/crypto_currency.dart';
import '../wallets/wallet/wallet.dart';
import 'node_service.dart';

/// Whether [node] can serve [coin] now.
typedef NodeProbe = Future<bool> Function(NodeModel node, CryptoCurrency coin);

/// The app runs several bridges of its own (one per region): while one of
/// them is a coin's node, the one that answers first becomes it. A node
/// the user added and chose stays. Loaded wallets move to the new node.
Future<void> pickFastestDefaultNodes({
  required NodeService nodeService,
  required Prefs prefs,
  required List<Wallet> Function() wallets,
  NodeProbe? probe,
}) async {
  probe ??= (node, coin) => _probeBridge(node, coin, prefs);
  await Future.wait([
    for (final coin in AppConfig.coins)
      _pickFor(coin, nodeService, prefs, wallets, probe).catchError(
        (Object e, StackTrace s) => Logging.instance.w(
          "Fastest node for ${coin.identifier}",
          error: e,
          stackTrace: s,
        ),
      ),
  ]);
}

/// How long a bridge has to answer.
const _probeTimeout = Duration(seconds: 15);

Future<void> _pickFor(
  CryptoCurrency coin,
  NodeService nodeService,
  Prefs prefs,
  List<Wallet> Function() wallets,
  NodeProbe probe,
) async {
  final current = nodeService.getPrimaryNodeFor(currency: coin);
  if (current != null && !current.isDefault) return;
  final candidates = nodeService
      .getNodesFor(coin)
      .where(
        (e) => e.isDefault && (prefs.useTor ? e.torEnabled : e.clearnetEnabled),
      )
      .toList();
  if (candidates.length < 2) return;

  final fastest = await firstToAnswer(candidates, (e) => probe(e, coin));
  if (fastest == null || fastest.id == current?.id) return;
  Logging.instance.i("${coin.identifier}: the fastest node is ${fastest.name}");
  await nodeService.setPrimaryNodeFor(
    coin: coin,
    node: fastest,
    shouldNotifyListeners: true,
  );

  for (final wallet in wallets().where((e) => e.info.coin == coin)) {
    unawaited(() async {
      try {
        await wallet.updateNode();
        if (!wallet.shouldAutoSync) return;
        await wallet.refresh();
        // A refresh already running on the old node may have failed.
        if (wallet.lastRefreshFailed) await wallet.refresh();
      } catch (e) {
        Logging.instance.w("${wallet.info.name}: refresh on the new node: $e");
      }
    }());
  }
}

/// The first of [nodes] whose [probe] says yes; null when none does in
/// time.
Future<NodeModel?> firstToAnswer(
  List<NodeModel> nodes,
  Future<bool> Function(NodeModel node) probe,
) {
  final done = Completer<NodeModel?>();
  var left = nodes.length;
  if (left == 0) return Future.value(null);
  for (final node in nodes) {
    () async {
      try {
        return await probe(node).timeout(_probeTimeout);
      } catch (_) {
        return false;
      }
    }().then((ok) {
      left--;
      if (done.isCompleted) return;
      if (ok) {
        done.complete(node);
      } else if (left == 0) {
        done.complete(null);
      }
    });
  }
  return done.future;
}

/// A bridge serves [coin] when its index has caught up on the right chain
/// and its node answers.
Future<bool> _probeBridge(
  NodeModel node,
  CryptoCurrency coin,
  Prefs prefs,
) async {
  final client = PivxBridgeClient.fromNode(node, prefs);
  try {
    final status = await client.status();
    final chain = (status["backend"] as Map?)?["chain"] as String?;
    final inSync = (status["index"] as Map?)?["inSync"] == true;
    if (chain == null || !inSync) return false;
    if ((chain == "main") != (coin.network == CryptoCurrencyNetwork.main)) {
      return false;
    }
    await client.getBlockCount();
    return true;
  } finally {
    client.close();
  }
}
