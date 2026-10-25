import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../utilities/logger.dart';
import 'event_bus/events/global/wallet_sync_status_changed_event.dart';
import 'event_bus/global_event_bus.dart';

final pDeviceNetwork = ChangeNotifierProvider<DeviceNetwork>(
  (_) => DeviceNetwork.instance,
);

/// Whether the device is on a network (Wi-Fi, mobile data, Ethernet, ...),
/// as the system tells. When it can't tell, the device counts as online.
///
/// Being on a network doesn't mean the internet answers through it: when
/// it doesn't, none of the nodes answers either (see NodeWatch).
class DeviceNetwork extends ChangeNotifier {
  DeviceNetwork({
    Future<List<ConnectivityResult>> Function()? check,
    Stream<List<ConnectivityResult>>? changes,
  }) : _check = check ?? (() => Connectivity().checkConnectivity()),
       _changes = changes == null
           ? (() => Connectivity().onConnectivityChanged)
           : (() => changes);

  static final instance = DeviceNetwork();

  final Future<List<ConnectivityResult>> Function() _check;
  final Stream<List<ConnectivityResult>> Function() _changes;
  final List<StreamSubscription<void>> _subscriptions = [];
  void Function()? _onBack;

  bool _online = true;
  bool get online => _online;

  /// Follows the system's network state. [onBack]: the device is on a
  /// network again.
  Future<void> start({required void Function() onBack}) async {
    _onBack = onBack;
    _subscriptions.addAll([
      _changes().listen(
        _update,
        onError: (Object e) =>
            Logging.instance.w("The device's network state", error: e),
      ),
      // A wallet that synced reached its node: the system's "no network"
      // was wrong (a network it doesn't manage, on a desktop).
      GlobalEventBus.instance.on<WalletSyncStatusChangedEvent>().listen((e) {
        if (e.newStatus == WalletSyncStatus.synced) _set(true);
      }),
    ]);
    try {
      _update(await _check().timeout(const Duration(seconds: 3)));
    } catch (e) {
      Logging.instance.w("The device's network state", error: e);
    }
  }

  void stop() {
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    _subscriptions.clear();
    _onBack = null;
  }

  void _update(List<ConnectivityResult> results) =>
      _set(results.isEmpty || results.any((e) => e != ConnectivityResult.none));

  void _set(bool online) {
    if (online == _online) return;
    _online = online;
    Logging.instance.i(
      online ? "The device is on a network" : "The device has no network",
    );
    notifyListeners();
    if (online) _onBack?.call();
  }
}
