import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../l10n/l10n.dart';
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

  try {
    final client = PivxBridgeClient.fromParts(
      host: formData.host!,
      port: formData.port ?? 0,
      useSSL: formData.useSSL ?? false,
      useTor: read(prefsChangeNotifierProvider).useTor,
    );
    final problem = await client.verifyFor(cryptoCurrency as Pivx);
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
  }
}
