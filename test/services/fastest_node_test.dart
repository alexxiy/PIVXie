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

  // Hive keeps adapters between tests.
  var registered = false;

  /// The node box with the default nodes in it.
  Future<NodeService> openNodes() async {
    await setUpHiveCeTest();
    if (!registered) {
      registered = true;
      DB.instance.hive.registerAdapter(NodeModelAdapter());
    }
    await DB.instance.hive.openBox<NodeModel>(DB.boxNameNodeModels);
    final service = NodeService(secureStorageInterface: FakeSecureStorage());
    await service.updateDefaults();
    return service;
  }

  BridgeHeights at(int height, [int? nodeHeight]) =>
      (height: height, nodeHeight: nodeHeight ?? height);

  group("askBridges", () {
    test("all answers, with how long each took", () async {
      final nodes = [node("slow"), node("fast"), node("broken")];
      final answers = await askBridges(nodes, (n) async {
        switch (n.id) {
          case "slow":
            await Future<void>.delayed(const Duration(milliseconds: 60));
            return at(100);
          case "fast":
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return at(99);
          default:
            throw Exception("refused");
        }
      });
      expect(answers.map((e) => e.node.id), ["fast", "slow"]);
      expect(answers.first.time, lessThan(answers.last.time));
    });

    test("the slower ones have a while after the first answer", () async {
      final answers = await askBridges([node("fast"), node("stuck")], (
        n,
      ) async {
        if (n.id == "stuck") {
          await Future<void>.delayed(const Duration(seconds: 5));
        }
        return at(100);
      }, othersTimeout: const Duration(milliseconds: 50));
      expect(answers.map((e) => e.node.id), ["fast"]);
    });

    test("none when none answers", () async {
      final answers = await askBridges([
        node("a"),
        node("b"),
      ], (n) async => null);
      expect(answers, isEmpty);
    });
  });

  group("pickBridge", () {
    BridgeAnswer answer(String id, int ms, BridgeHeights heights) =>
        (node: node(id), heights: heights, time: Duration(milliseconds: ms));

    test("the fastest one, even a few blocks behind", () {
      final picked = pickBridge([
        answer("up to date", 300, at(1000)),
        answer("fast", 40, at(1000 - maxBlocksBehind)),
      ]);
      expect(picked?.id, "fast");
    });

    test("not one further behind", () {
      final picked = pickBridge([
        answer("up to date", 300, at(1000)),
        answer("fast", 40, at(1000 - maxBlocksBehind - 1)),
      ]);
      expect(picked?.id, "up to date");
    });

    test("not one whose index lags its own node", () {
      expect(pickBridge([answer("catching up", 40, at(500, 1000))]), null);
      expect(pickBridge([answer("almost", 40, at(998, 1000))])?.id, "almost");
    });

    test("none without answers", () {
      expect(pickBridge([]), null);
    });
  });

  group("pickFastestDefaultNodes", () {
    late NodeService service;

    setUp(() async => service = await openNodes());

    tearDown(() async {
      await tearDownHiveCeTest();
    });

    Future<void> pick(Set<String> answering) => pickFastestDefaultNodes(
      nodeService: service,
      prefs: Prefs.instance,
      wallets: () => [],
      probe: (n, coin) async => answering.contains(n.id) ? at(100) : null,
      othersTimeout: Duration.zero,
    );

    test("both bridges are there, the first one is the node", () {
      final ids = service.getNodesFor(pivx).map((e) => e.id);
      expect(ids, containsAll([eu.id, us.id]));
      expect(service.getPrimaryNodeFor(currency: pivx)?.id, eu.id);
    });

    test("the faster bridge becomes the node", () async {
      Future<void> faster(String id) => pickFastestDefaultNodes(
        nodeService: service,
        prefs: Prefs.instance,
        wallets: () => [],
        probe: (n, coin) async {
          if (n.id != id) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          return at(100);
        },
      );
      await faster(us.id);
      expect(service.getPrimaryNodeFor(currency: pivx)?.id, us.id);
      await faster(eu.id);
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
  group("NodeWatch", () {
    late NodeService service;

    setUp(() async => service = await openNodes());

    tearDown(() async {
      await tearDownHiveCeTest();
    });

    /// A watch where the nodes in [answering] answer.
    (NodeWatch, List<NodeTrouble>) watch(Set<String> answering) {
      final troubles = <NodeTrouble>[];
      return (
        NodeWatch(
          nodeService: service,
          prefs: Prefs.instance,
          wallets: () => [],
          onTrouble: troubles.add,
          onNodeWorks: (_) {},
          probe: (n, coin) async => answering.contains(n.id) ? at(100) : null,
          othersTimeout: Duration.zero,
        ),
        troubles,
      );
    }

    Future<NodeModel> useOwn() async {
      final own = node("own");
      await service.save(own, false);
      await service.setPrimaryNodeFor(coin: pivx, node: own);
      return own;
    }

    test("the user is asked when their node is down", () async {
      final own = await useOwn();
      final (w, troubles) = watch({us.id});
      await w.check(pivx);
      expect(troubles, hasLength(1));
      expect(troubles.single.node.id, own.id);
      expect(troubles.single.switchTo.id, us.id);
      // Still their node until they say so.
      expect(service.getPrimaryNodeFor(currency: pivx)?.id, own.id);
    });

    test("and only once while it's down", () async {
      await useOwn();
      final (w, troubles) = watch({eu.id, us.id});
      await w.check(pivx);
      await w.check(pivx);
      expect(troubles, hasLength(1));
    });

    test("no internet: nothing answers, nobody is asked", () async {
      await useOwn();
      final (w, troubles) = watch({});
      await w.check(pivx);
      expect(troubles, isEmpty);
    });

    test("a node that answers again isn't down", () async {
      final own = await useOwn();
      final (w, troubles) = watch({own.id, us.id});
      await w.check(pivx);
      expect(troubles, isEmpty);
    });

    test("the app's bridge down: the other one takes over", () async {
      expect(service.getPrimaryNodeFor(currency: pivx)?.id, eu.id);
      final (w, troubles) = watch({us.id});
      await w.check(pivx);
      expect(service.getPrimaryNodeFor(currency: pivx)?.id, us.id);
      expect(troubles, isEmpty);
    });

    test("the app's bridge stays when there's no internet", () async {
      final (w, _) = watch({});
      await w.check(pivx);
      expect(service.getPrimaryNodeFor(currency: pivx)?.id, eu.id);
    });
  });
}
