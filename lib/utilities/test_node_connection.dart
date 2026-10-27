import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:intl/intl.dart';

import '../l10n/l10n.dart';
import '../models/node_model.dart';
import '../pages/settings_views/global_settings_view/manage_nodes_views/add_edit_node_view.dart';
import '../providers/global/prefs_provider.dart';
import '../wallets/api/pivx/pivx_bridge_client.dart';
import '../wallets/crypto_currency/crypto_currency.dart';
import 'logger.dart';
import 'tor_plain_net_option_enum.dart';

/// Null when the node passed, else why it didn't, for the user.
typedef TestNodeConnectionCallback = Future<String?> Function({
  required BuildContext context,
  required NodeFormData nodeFormData,
  required CryptoCurrency cryptoCurrency,
});

final testNodeConnectionProvider = Provider<TestNodeConnectionCallback>((ref) {
  return ({
    required BuildContext context,
    required NodeFormData nodeFormData,
    required CryptoCurrency cryptoCurrency,
  }) {
    return testNodeConnection(
      context: context,
      nodeFormData: nodeFormData,
      cryptoCurrency: cryptoCurrency,
      read: ref.read,
    );
  };
});

/// How long a node has to pass the test. A server behind a firewall never
/// answers, and the test would wait for the connection timeout (a minute).
const nodeTestTimeout = Duration(seconds: 20);

/// Test a PIVX bridge with the node form's settings: null when it passed,
/// else why it didn't, for the user.
Future<String?> testNodeConnection({
  required BuildContext context,
  required NodeFormData nodeFormData,
  required CryptoCurrency cryptoCurrency,
  required T Function<T>(ProviderListenable<T> provider) read,
}) async {
  final formData = nodeFormData;

  if (read(prefsChangeNotifierProvider).useTor) {
    if (formData.netOption! == TorPlainNetworkOption.clear) {
      Logging.instance.w(
        "This node is set to be used without Tor, and Tor is on",
      );
      return l10n.nodeUseWithoutTor;
    }
  } else {
    if (formData.netOption! == TorPlainNetworkOption.tor) {
      Logging.instance.w(
        "This node is set to be used only over Tor, and Tor is off",
      );
      return l10n.nodeUseOnlyOverTor;
    }
  }

  PivxBridgeClient? client;
  try {
    client = PivxBridgeClient.fromParts(
      host: formData.host!,
      port: formData.port ?? 0,
      useSSL: formData.useSSL ?? false,
      useTor: read(prefsChangeNotifierProvider).useTor,
    );
    final problem = await client
        .verifyFor(cryptoCurrency as Pivx)
        .timeout(nodeTestTimeout);
    if (problem != null) {
      Logging.instance.w("PIVX testNodeConnection: $problem");
    }
    return problem;
  } catch (e, s) {
    Logging.instance.w(
      "PIVX testNodeConnection failed",
      error: e,
      stackTrace: s,
    );
    return l10n.nodeUnreachable;
  } finally {
    // A request still waiting for an answer stops too.
    client?.close(force: true);
  }
}

/// What a node's test found: how long it took, and why the node failed,
/// if it did.
class NodeTestResult {
  NodeTestResult({required this.time, this.problem})
    : _outcome = switch (problem) {
        null => _Outcome.passed,
        final p when p == l10n.nodeUnreachable => _Outcome.noAnswer,
        final p when p == l10n.nodeUseWithoutTor => _Outcome.onlyWithoutTor,
        final p when p == l10n.nodeUseOnlyOverTor => _Outcome.onlyOverTor,
        _ => _Outcome.failed,
      };

  final Duration time;

  /// Null when the node passed.
  final String? problem;

  final _Outcome _outcome;

  bool get passed => problem == null;

  /// How good the connection is, 0 to [maxLevel]: by how fast the node
  /// answered; 0 when it failed.
  int get level {
    if (!passed) return 0;
    final ms = time.inMilliseconds;
    if (ms < 300) return 4;
    if (ms < 1000) return 3;
    if (ms < 3000) return 2;
    return 1;
  }

  static const maxLevel = 4;

  /// The result in a few words, for a node's row: how fast the node
  /// answered, or what kept it from passing.
  String get short => switch (_outcome) {
    _Outcome.passed => answerTime(time),
    _Outcome.noAnswer => l10n.nodeNoAnswer,
    _Outcome.onlyWithoutTor => l10n.nodeOnlyWithoutTor,
    _Outcome.onlyOverTor => l10n.nodeOnlyTor,
    _Outcome.failed => l10n.nodeCheckFailed,
  };
}

enum _Outcome { passed, noAnswer, onlyWithoutTor, onlyOverTor, failed }

/// [time] in milliseconds, or in seconds from one second on.
String answerTime(Duration time) {
  final ms = time.inMilliseconds;
  if (ms < 1000) return l10n.nodeAnswerMs(ms);
  return l10n.nodeAnswerSeconds(
    NumberFormat(ms < 10000 ? "0.0" : "0", l10n.localeName).format(ms / 1000),
  );
}

final pNodeTests = ChangeNotifierProvider<NodeTests>((_) => NodeTests());

/// The nodes' tests since the app started, for the node lists: whether one
/// is running, and the last one's result.
class NodeTests extends ChangeNotifier {
  final Map<String, Future<NodeTestResult>> _running = {};
  final Map<String, NodeTestResult> _results = {};

  bool isTesting(String nodeId) => _running.containsKey(nodeId);

  NodeTestResult? resultFor(String nodeId) => _results[nodeId];

  /// Tests [node] with [test] (null: it passed, else why not), or waits
  /// for its test already running.
  Future<NodeTestResult> run(NodeModel node, Future<String?> Function() test) {
    final running = _running[node.id];
    if (running != null) return running;
    final future = _run(node.id, test);
    _running[node.id] = future;
    notifyListeners();
    return future;
  }

  Future<NodeTestResult> _run(
    String nodeId,
    Future<String?> Function() test,
  ) async {
    final time = Stopwatch()..start();
    String? problem;
    try {
      problem = await test();
    } catch (e) {
      Logging.instance.w("Node test", error: e);
      problem = l10n.nodeUnreachable;
    }
    final result = NodeTestResult(time: time.elapsed, problem: problem);
    _results[nodeId] = result;
    // This run's own future, which completes now.
    unawaited(_running.remove(nodeId));
    notifyListeners();
    return result;
  }
}

/// The node form's data for [node] as saved.
NodeFormData nodeFormDataOf(NodeModel node) => NodeFormData()
  ..name = node.name
  ..host = node.host
  ..port = node.port
  ..useSSL = node.useSSL
  ..netOption = TorPlainNetworkOption.fromNodeData(
    node.torEnabled,
    node.clearnetEnabled,
  );

/// Tests [node] (with [formData] instead of its saved settings, if given)
/// through [pNodeTests], so the node lists show the result.
Future<NodeTestResult> testNodeOf(
  WidgetRef ref,
  BuildContext context,
  NodeModel node,
  CryptoCurrency coin, {
  NodeFormData? formData,
}) => ref
    .read(pNodeTests)
    .run(
      node,
      () => ref.read(testNodeConnectionProvider)(
        context: context,
        nodeFormData: formData ?? nodeFormDataOf(node),
        cryptoCurrency: coin,
      ),
    );
