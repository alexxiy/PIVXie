import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/db/hive/db.dart';
import 'package:paymint/models/node_model.dart';
import 'package:paymint/services/fastest_node.dart';
import 'package:paymint/services/node_service.dart';
import 'package:paymint/utilities/flutter_secure_storage_interface.dart';
import 'package:paymint/utilities/prefs.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';

import '../hive/hive_ce_test_utils.dart';

void main() {
  final pivx = Pivx(CryptoCurrencyNetwork.main);
  final eu = pivx.defaultNodes[0];
  final us = pivx.defaultNodes[1];

  NodeModel node(String id) => NodeModel(
    host: "https://$id.example",
    port: 443,
    name: id,
    id: id,
    useSSL: true,
    coinName: pivx.identifier,
    torEnabled: true,
    clearnetEnabled: true,
    isPrimary: false,
  );

  group("firstToAnswer", () {
    test("the first node to say yes wins", () async {
      final nodes = [node("slow"), node("fast"), node("broken")];
      final winner = await firstToAnswer(nodes, (n) async {
        switch (n.id) {
          case "slow":
            await Future<void>.delayed(const Duration(milliseconds: 60));
            return true;
          case "fast":
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return true;
          default:
            return false;
        }
      });
      expect(winner?.id, "fast");
    });

    test("a node that fails fast doesn't win", () async {
      final nodes = [node("failing"), node("working")];
      final winner = await firstToAnswer(nodes, (n) async {
        if (n.id == "failing") throw Exception("refused");
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return true;
      });
      expect(winner?.id, "working");
    });

    test("no node when none answers", () async {
      final winner = await firstToAnswer([
        node("a"),
        node("b"),
      ], (n) async => false);
      expect(winner, null);
    });
  });

  group("pickFastestDefaultNodes", () {
    bool registered = false;
    late NodeService service;

    setUp(() async {
      await setUpHiveCeTest();
      if (!registered) {
        registered = true;
        DB.instance.hive.registerAdapter(NodeModelAdapter());
      }
      await DB.instance.hive.openBox<NodeModel>(DB.boxNameNodeModels);
      service = NodeService(secureStorageInterface: FakeSecureStorage());
      await service.updateDefaults();
    });

    tearDown(() async {
      await tearDownHiveCeTest();
    });

    Future<void> pick(Set<String> answering) => pickFastestDefaultNodes(
      nodeService: service,
      prefs: Prefs.instance,
      wallets: () => [],
      probe: (n, coin) async => answering.contains(n.id),
    );

    test("both bridges are there, the first one is the node", () {
      final ids = service.getNodesFor(pivx).map((e) => e.id);
      expect(ids, containsAll([eu.id, us.id]));
      expect(service.getPrimaryNodeFor(currency: pivx)?.id, eu.id);
    });

    test("the bridge that answers becomes the node", () async {
      await pick({us.id});
      expect(service.getPrimaryNodeFor(currency: pivx)?.id, us.id);
      await pick({eu.id});
      expect(service.getPrimaryNodeFor(currency: pivx)?.id, eu.id);
    });

    test("the node stays when no bridge answers", () async {
      await pick({});
      expect(service.getPrimaryNodeFor(currency: pivx)?.id, eu.id);
    });

    test("a node the user chose stays", () async {
      final own = node("own");
      await service.save(own, false);
      await service.setPrimaryNodeFor(coin: pivx, node: own);
      await pick({eu.id, us.id});
      expect(service.getPrimaryNodeFor(currency: pivx)?.id, own.id);
    });

    test("updating the defaults keeps the chosen bridge", () async {
      await pick({us.id});
      await service.updateDefaults();
      expect(service.getPrimaryNodeFor(currency: pivx)?.id, us.id);
      expect(
        service.primaryNodes.where((e) => e.coinName == pivx.identifier),
        hasLength(1),
      );
    });
  });
}
