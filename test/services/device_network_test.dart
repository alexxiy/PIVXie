import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/services/device_network.dart';
import 'package:paymint/services/event_bus/events/global/wallet_sync_status_changed_event.dart';
import 'package:paymint/services/event_bus/global_event_bus.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';

void main() {
  late StreamController<List<ConnectivityResult>> changes;
  late DeviceNetwork network;
  late int back;

  /// Started where the system first says [first] (or throws).
  Future<void> start(Future<List<ConnectivityResult>> Function() first) async {
    changes = StreamController();
    network = DeviceNetwork(check: first, changes: changes.stream);
    back = 0;
    await network.start(onBack: () => back++);
  }

  tearDown(() async {
    network.stop();
    await changes.close();
  });

  test("Wi-Fi and mobile data off: no network", () async {
    await start(() async => [ConnectivityResult.none]);
    expect(network.online, false);
  });

  test("turning either on: back, once", () async {
    await start(() async => [ConnectivityResult.none]);
    changes.add([ConnectivityResult.mobile]);
    await pumpEventQueue();
    expect(network.online, true);
    expect(back, 1);
    changes.add([ConnectivityResult.wifi, ConnectivityResult.mobile]);
    await pumpEventQueue();
    expect(back, 1);
    changes.add([ConnectivityResult.none]);
    await pumpEventQueue();
    expect(network.online, false);
  });

  test("when the system can't tell, it's online", () async {
    await start(() async => throw Exception("no NetworkManager"));
    expect(network.online, true);
    expect(back, 0);
  });

  test("a wallet that synced reached its node: online", () async {
    await start(() async => [ConnectivityResult.none]);
    GlobalEventBus.instance.fire(
      WalletSyncStatusChangedEvent(
        WalletSyncStatus.synced,
        "wallet",
        Pivx(CryptoCurrencyNetwork.main),
      ),
    );
    await pumpEventQueue();
    expect(network.online, true);
    expect(back, 1);
  });
}
