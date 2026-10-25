import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../app_config.dart';
import '../models/node_model.dart';
import '../utilities/logger.dart';
import '../utilities/prefs.dart';
import '../wallets/api/pivx/pivx_bridge_client.dart';
import '../wallets/crypto_currency/crypto_currency.dart';
import '../wallets/wallet/wallet.dart';
import 'event_bus/events/global/node_connection_status_changed_event.dart';
import 'event_bus/events/global/wallet_sync_status_changed_event.dart';
import 'event_bus/global_event_bus.dart';
import 'node_service.dart';

/// The block heights [node] reports for [coin]: its address index's
/// ([BridgeHeights.height], what wallets sync to) and its node's. Null when
/// it isn't on that coin's chain or its node doesn't answer; throws when it
/// can't be reached.
typedef NodeProbe = Future<BridgeHeights?> Function(
  NodeModel node,
  CryptoCurrency coin,
);

typedef BridgeHeights = ({int height, int nodeHeight});

/// A bridge that answered, and how long it took.
typedef BridgeAnswer = ({NodeModel node, BridgeHeights heights, Duration time});

/// How far behind the highest bridge one may be and still be picked: it
/// catches up within minutes, and a faster connection matters more.
const maxBlocksBehind = 3;

/// How long a bridge has to answer.
const _probeTimeout = Duration(seconds: 15);

/// After the first answer, how long the slower bridges have to answer:
/// they aren't the fastest, but their heights tell whether the first one
/// is up to date.
const _othersTimeout = Duration(seconds: 3);

/// The app runs several bridges of its own (one per region): while one of
/// them is a coin's node, the fastest one that is up to date becomes it.
/// A node the user added and chose stays. Loaded wallets move to the new
/// node.
Future<void> pickFastestDefaultNodes({
  required NodeService nodeService,
  required Prefs prefs,
  required List<Wallet> Function() wallets,
  NodeProbe? probe,
  Duration othersTimeout = _othersTimeout,
}) async {
  final ask = probe ?? (node, coin) => _probeBridge(node, coin, prefs);
  await Future.wait([
    for (final coin in AppConfig.coins)
      () async {
        final current = nodeService.getPrimaryNodeFor(currency: coin);
        if (current != null && !current.isDefault) return;
        final candidates = _defaultNodes(coin, nodeService, prefs);
        if (candidates.length < 2) return;
        final fastest = pickBridge(
          await askBridges(
            candidates,
            (e) => ask(e, coin),
            othersTimeout: othersTimeout,
          ),
        );
        if (fastest == null || fastest.id == current?.id) return;
        Logging.instance.i(
          "${coin.identifier}: the fastest node is ${fastest.name}",
        );
        await useNode(coin, fastest, nodeService, wallets);
      }().catchError(
        (Object e, StackTrace s) => Logging.instance.w(
          "Fastest node for ${coin.identifier}",
          error: e,
          stackTrace: s,
        ),
      ),
  ]);
}

/// The app's own bridges for [coin] on the network in use (Tor or not).
List<NodeModel> _defaultNodes(
  CryptoCurrency coin,
  NodeService nodeService,
  Prefs prefs,
) => nodeService
    .getNodesFor(coin)
    .where(
      (e) => e.isDefault && (prefs.useTor ? e.torEnabled : e.clearnetEnabled),
    )
    .toList();

/// [node] becomes [coin]'s node, and the coin's loaded wallets move to it.
Future<void> useNode(
  CryptoCurrency coin,
  NodeModel node,
  NodeService nodeService,
  List<Wallet> Function() wallets,
) async {
  await nodeService.setPrimaryNodeFor(
    coin: coin,
    node: node,
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

/// Asks all [nodes] at once. The answers of those that answered (on the
/// right chain) in time: until all have, or [othersTimeout] after the
/// first one.
Future<List<BridgeAnswer>> askBridges(
  List<NodeModel> nodes,
  Future<BridgeHeights?> Function(NodeModel node) probe, {
  Duration othersTimeout = _othersTimeout,
}) {
  final answers = <BridgeAnswer>[];
  final done = Completer<List<BridgeAnswer>>();
  Timer? others;
  void finish() {
    others?.cancel();
    if (!done.isCompleted) done.complete(List.of(answers));
  }

  var left = nodes.length;
  if (left == 0) return Future.value(answers);
  for (final node in nodes) {
    final time = Stopwatch()..start();
    () async {
      try {
        return await probe(node).timeout(_probeTimeout);
      } catch (_) {
        return null;
      }
    }().then((heights) {
      left--;
      if (done.isCompleted) return;
      if (heights != null) {
        answers.add((node: node, heights: heights, time: time.elapsed));
        others ??= Timer(othersTimeout, finish);
      }
      if (left == 0) finish();
    });
  }
  return done.future;
}

/// The fastest of [answers] whose index is at most [maxBlocksBehind] blocks
/// behind the highest block any of them knows. Null when there's none.
NodeModel? pickBridge(List<BridgeAnswer> answers) {
  if (answers.isEmpty) return null;
  final highest = answers
      .map((e) => max(e.heights.height, e.heights.nodeHeight))
      .reduce(max);
  final upToDate = [
    for (final e in answers)
      if (e.heights.height >= highest - maxBlocksBehind) e,
  ]..sort((a, b) => a.time.compareTo(b.time));
  return upToDate.firstOrNull?.node;
}

/// The heights a bridge reports when it's on [coin]'s chain and its node
/// answers.
Future<BridgeHeights?> _probeBridge(
  NodeModel node,
  CryptoCurrency coin,
  Prefs prefs,
) async {
  final client = PivxBridgeClient.fromNode(node, prefs);
  try {
    final status = await client.status();
    final chain = (status["backend"] as Map?)?["chain"] as String?;
    final height = (status["index"] as Map?)?["bestHeight"] as int?;
    if (chain == null || height == null) return null;
    if ((chain == "main") != (coin.network == CryptoCurrencyNetwork.main)) {
      return null;
    }
    // The bridge answers `/status` from its index even when its node is
    // down.
    return (height: height, nodeHeight: await client.getBlockCount());
  } finally {
    client.close();
  }
}

/// A node the user chose stopped answering while one of the app's own
/// bridges answers.
class NodeTrouble {
  const NodeTrouble({
    required this.coin,
    required this.node,
    required this.switchTo,
  });

  final CryptoCurrency coin;

  /// The user's node.
  final NodeModel node;

  /// The fastest of the app's bridges that answered.
  final NodeModel switchTo;
}

/// Watches the wallets' nodes. When a coin's node stops answering and one
/// of the app's own bridges answers (so the internet works), one of the
/// app's bridges is swapped for the fastest that works, and for a node the
/// user chose, [onTrouble] asks them (once, until it works again). With no
/// internet nothing answers: that isn't the node's fault, and nothing
/// happens.
class NodeWatch {
  NodeWatch({
    required this.nodeService,
    required this.prefs,
    required this.wallets,
    required this.onTrouble,
    required this.onNodeWorks,
    NodeProbe? probe,
    this.othersTimeout = _othersTimeout,
  }) : _probe = probe ?? ((node, coin) => _probeBridge(node, coin, prefs));

  final NodeService nodeService;
  final Prefs prefs;
  final List<Wallet> Function() wallets;
  final void Function(NodeTrouble trouble) onTrouble;

  /// [coin]'s node synced a wallet: a question about it is moot.
  final void Function(CryptoCurrency coin) onNodeWorks;
  final NodeProbe _probe;
  final Duration othersTimeout;

  final List<StreamSubscription<void>> _subscriptions = [];

  /// The coins being checked now.
  final Set<String> _checking = {};

  /// Per coin, the user's node they were asked about, until it works.
  final Map<String, String> _asked = {};

  void start() {
    final bus = GlobalEventBus.instance;
    _subscriptions.addAll([
      bus.on<NodeConnectionStatusChangedEvent>().listen((e) {
        if (e.newStatus == NodeConnectionStatus.disconnected) {
          unawaited(check(e.coin));
        }
      }),
      bus.on<WalletSyncStatusChangedEvent>().listen((e) {
        if (e.newStatus != WalletSyncStatus.synced) return;
        if (_asked.remove(e.coin.identifier) != null) onNodeWorks(e.coin);
      }),
    ]);
  }

  void stop() {
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    _subscriptions.clear();
  }

  /// A wallet of [coin] couldn't reach its node.
  @visibleForTesting
  Future<void> check(CryptoCurrency coin) async {
    if (!_checking.add(coin.identifier)) return;
    try {
      final current = nodeService.getPrimaryNodeFor(currency: coin);
      if (current == null) return;
      final mine = !current.isDefault;
      if (mine && _asked[coin.identifier] == current.id) return;

      // A request can fail now and then: the node answers again.
      try {
        if (await _probe(current, coin).timeout(_probeTimeout) != null) return;
      } catch (_) {}

      final others = [
        for (final e in _defaultNodes(coin, nodeService, prefs))
          if (e.id != current.id) e,
      ];
      final best = pickBridge(
        await askBridges(
          others,
          (e) => _probe(e, coin),
          othersTimeout: othersTimeout,
        ),
      );
      // None answers either: no internet (or none of them works).
      if (best == null) return;
      // The user chose another node meanwhile.
      if (nodeService.getPrimaryNodeFor(currency: coin)?.id != current.id) {
        return;
      }

      if (mine) {
        Logging.instance.i(
          "${coin.identifier}: ${current.name} isn't answering, "
          "${best.name} is",
        );
        _asked[coin.identifier] = current.id;
        onTrouble(NodeTrouble(coin: coin, node: current, switchTo: best));
      } else {
        Logging.instance.i(
          "${coin.identifier}: ${current.name} isn't answering, "
          "switching to ${best.name}",
        );
        await useNode(coin, best, nodeService, wallets);
      }
    } catch (e, s) {
      Logging.instance.w(
        "Checking the node of ${coin.identifier}",
        error: e,
        stackTrace: s,
      );
    } finally {
      _checking.remove(coin.identifier);
    }
  }
}
