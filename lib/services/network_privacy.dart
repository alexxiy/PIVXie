import 'dart:async';
import 'dart:io';

import '../app_config.dart';
import '../utilities/logger.dart';
import '../utilities/prefs.dart';
import '../utilities/stack_file_system.dart';
import 'event_bus/events/global/tor_connection_status_changed_event.dart';
import 'nym_service.dart';
import 'tor_service.dart';

/// The networks that can mask the app's traffic. Only one is on at a
/// time.
enum PrivacyNetwork {
  tor("Tor"),
  nym("Nym");

  const PrivacyNetwork(this.label);

  /// The network's name; the same in every language.
  final String label;
}

/// Which network masks the app's traffic (Tor, Nym or none), and the
/// proxy every request goes through.
abstract final class NetworkPrivacy {
  static bool isAvailable(PrivacyNetwork network) =>
      AppConfig.hasFeature(switch (network) {
        PrivacyNetwork.tor => AppFeature.tor,
        PrivacyNetwork.nym => AppFeature.nym,
      });

  /// The networks this build offers.
  static List<PrivacyNetwork> get available =>
      PrivacyNetwork.values.where(isAvailable).toList();

  /// The network that's on in [prefs], or null.
  static PrivacyNetwork? activeIn(Prefs prefs) {
    if (prefs.useTor && isAvailable(PrivacyNetwork.tor)) {
      return PrivacyNetwork.tor;
    }
    if (prefs.useNym && isAvailable(PrivacyNetwork.nym)) {
      return PrivacyNetwork.nym;
    }
    return null;
  }

  static PrivacyNetwork? get active => activeIn(Prefs.instance);

  static TorConnectionStatus statusOf(PrivacyNetwork network) =>
      switch (network) {
        PrivacyNetwork.tor => TorService.sharedInstance.status,
        PrivacyNetwork.nym => NymService.sharedInstance.status,
      };

  /// [network]'s proxy; throws while it isn't connected.
  static ({InternetAddress host, int port}) proxyOf(PrivacyNetwork network) =>
      switch (network) {
        PrivacyNetwork.tor => TorService.sharedInstance.getProxyInfo(),
        PrivacyNetwork.nym => NymService.sharedInstance.getProxyInfo(),
      };

  /// The proxy for a request, or null when no network is on. Throws while
  /// the chosen network isn't connected, so nothing goes out without it.
  static ({InternetAddress host, int port})? proxyInfo() {
    final network = active;
    return network == null ? null : proxyOf(network);
  }

  /// At app start: connect the network that's on, in the background.
  /// Where it can't be reached the app must still open (to turn it off,
  /// or to read the recovery phrase); until it's connected, network
  /// calls fail instead of going around it.
  static Future<void> startOnLaunch() async {
    final network = active;
    if (network != null) unawaited(_start(network).catchError((_) {}));
  }

  /// Turns [network] on and connects it; the other one is turned off.
  ///
  /// The setting changes first, so while connecting nothing goes out
  /// directly. Completes when connected, or when cancelled by [turnOff].
  static Future<void> turnOn(Prefs prefs, PrivacyNetwork network) async {
    switch (network) {
      case PrivacyNetwork.tor:
        prefs.useTor = true;
      case PrivacyNetwork.nym:
        prefs.useNym = true;
    }
    for (final other in available) {
      if (other != network) await _stop(other);
    }
    await _start(network);
  }

  /// Turns [network] off (also cancelling a connection in progress);
  /// the app then connects directly.
  static Future<void> turnOff(Prefs prefs, PrivacyNetwork network) async {
    switch (network) {
      case PrivacyNetwork.tor:
        prefs.useTor = false;
      case PrivacyNetwork.nym:
        prefs.useNym = false;
    }
    await _stop(network);
  }

  static Future<void> _start(PrivacyNetwork network) async {
    try {
      switch (network) {
        case PrivacyNetwork.tor:
          TorService.sharedInstance.init(
            torDataDirPath:
                (await StackFileSystem.applicationTorDirectory()).path,
          );
          await TorService.sharedInstance.start();
        case PrivacyNetwork.nym:
          await NymService.sharedInstance.start();
      }
    } catch (e, s) {
      Logging.instance.e(
        "Starting ${network.label} failed: ",
        error: e,
        stackTrace: s,
      );
      rethrow;
    }
  }

  static Future<void> _stop(PrivacyNetwork network) async {
    if (!isAvailable(network)) return;
    try {
      switch (network) {
        case PrivacyNetwork.tor:
          await TorService.sharedInstance.disable();
        case PrivacyNetwork.nym:
          await NymService.sharedInstance.disable();
      }
    } catch (e, s) {
      Logging.instance.e(
        "Stopping ${network.label} failed: ",
        error: e,
        stackTrace: s,
      );
    }
  }
}
