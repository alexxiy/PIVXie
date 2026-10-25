import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/app_config.dart';
import 'package:paymint/db/hive/db.dart';
import 'package:paymint/models/node_model.dart';
import 'package:paymint/services/node_service.dart';
import 'package:paymint/utilities/flutter_secure_storage_interface.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';

import '../hive/hive_ce_test_utils.dart';

void main() {
  bool wasRegistered = false;
  final expectedPrimaryDefaults = AppConfig.coins
      .map((e) => e.defaultNode(isPrimary: true))
      .toList(growable: false);
  final expectedDefaultNodeCount = AppConfig.coins.fold(
    0,
    (n, e) => n + e.defaultNodes.length,
  );

  setUp(() async {
    await setUpHiveCeTest();
    if (!wasRegistered) {
      wasRegistered = true;
      DB.instance.hive.registerAdapter(NodeModelAdapter());
    }
    await DB.instance.hive.openBox<NodeModel>(DB.boxNameNodeModels);
  });

  group("Empty nodes DB tests", () {
    test("getPrimaryNodeFor", () {
      final fakeStore = FakeSecureStorage();
      final service = NodeService(secureStorageInterface: fakeStore);
      final node = service.getPrimaryNodeFor(
        currency: Pivx(CryptoCurrencyNetwork.main),
      );
      expect(node, null);
      expect(fakeStore.interactions, 0);
    });

    test("setPrimaryNodeFor", () async {
      final fakeStore = FakeSecureStorage();
      final service = NodeService(secureStorageInterface: fakeStore);
      final node = service.getPrimaryNodeFor(
        currency: Pivx(CryptoCurrencyNetwork.main),
      );
      expect(node, null);
      final node1 = NodeModel(
        host: "host",
        port: 42,
        name: "btcnode",
        id: "pnodeID",
        useSSL: true,
        coinName: "pivx",
        torEnabled: true,
        clearnetEnabled: true,
        isPrimary: true,
      );
      await service.setPrimaryNodeFor(
        coin: Pivx(CryptoCurrencyNetwork.main),
        node: node1,
        shouldNotifyListeners: true,
      );

      expect(
        service
            .getPrimaryNodeFor(currency: Pivx(CryptoCurrencyNetwork.main))
            .toString(),
        node1.toString(),
      );
      expect(fakeStore.interactions, 0);
    });

    test("getNodesFor", () {
      final fakeStore = FakeSecureStorage();
      final service = NodeService(secureStorageInterface: fakeStore);
      final nodes = service.getNodesFor(Pivx(CryptoCurrencyNetwork.main));
      expect(nodes.isEmpty, true);
      expect(fakeStore.interactions, 0);
    });

    test("get primary nodes", () {
      final fakeStore = FakeSecureStorage();
      final service = NodeService(secureStorageInterface: fakeStore);
      final nodes = service.primaryNodes;
      expect(nodes.isEmpty, true);
      expect(fakeStore.interactions, 0);
    });

    test("get nodes", () {
      final fakeStore = FakeSecureStorage();
      final service = NodeService(secureStorageInterface: fakeStore);
      final nodes = service.nodes;
      expect(nodes.isEmpty, true);
      expect(fakeStore.interactions, 0);
    });

    test("get non existing getNodeById", () {
      final fakeStore = FakeSecureStorage();
      final service = NodeService(secureStorageInterface: fakeStore);
      final node = service.getNodeById(id: "Some ID");
      expect(node, null);
      expect(fakeStore.interactions, 0);
    });

    test("updateDefaults", () async {
      final fakeStore = FakeSecureStorage();
      final service = NodeService(secureStorageInterface: fakeStore);
      await service.updateDefaults();
      expect(service.nodes.length, expectedDefaultNodeCount);
      expect(fakeStore.interactions, 0);
    });
  });

  group("Defaults populated tests", () {
    final nodeA = NodeModel(
      host: "host1",
      port: 421,
      name: "btcnode",
      id: "pnodeID1",
      useSSL: true,
      coinName: "pivx",
      torEnabled: true,
      clearnetEnabled: true,
      isPrimary: true,
    );
    final nodeB = NodeModel(
      host: "host2",
      port: 422,
      name: "btcnode",
      id: "pnodeID2",
      useSSL: true,
      coinName: "pivxTestNet",
      torEnabled: true,
      clearnetEnabled: true,
      isPrimary: true,
    );
    final nodeC = NodeModel(
      host: "host3",
      port: 423,
      name: "btcnode",
      id: "pnodeID3",
      useSSL: true,
      coinName: "epicCash",
      torEnabled: true,
      clearnetEnabled: true,
      isPrimary: true,
    );

    setUp(() async {
      await NodeService(secureStorageInterface: FakeSecureStorage())
          .updateDefaults();
    });

    test("setPrimaryNodeFor and getPrimaryNodeFor", () async {
      final fakeStore = FakeSecureStorage();
      final service = NodeService(secureStorageInterface: fakeStore);
      expect(
        service
            .getPrimaryNodeFor(currency: Pivx(CryptoCurrencyNetwork.main))
            ?.toString(),
        Pivx(CryptoCurrencyNetwork.main)
            .defaultNode(isPrimary: true)
            .toString(),
      );
      await service.setPrimaryNodeFor(
        coin: Pivx(CryptoCurrencyNetwork.main),
        node: Pivx(CryptoCurrencyNetwork.main).defaultNode(isPrimary: true),
      );
      expect(
        service
            .getPrimaryNodeFor(currency: Pivx(CryptoCurrencyNetwork.main))
            .toString(),
        Pivx(CryptoCurrencyNetwork.main)
            .defaultNode(isPrimary: true)
            .toString(),
      );
      expect(fakeStore.interactions, 0);
    });

    test("get primary nodes", () async {
      final fakeStore = FakeSecureStorage();
      final service = NodeService(secureStorageInterface: fakeStore);
      await service.setPrimaryNodeFor(
        coin: Pivx(CryptoCurrencyNetwork.main),
        node: Pivx(CryptoCurrencyNetwork.main).defaultNode(isPrimary: true),
      );
      await service.setPrimaryNodeFor(
        coin: Pivx(CryptoCurrencyNetwork.test),
        node: Pivx(CryptoCurrencyNetwork.test).defaultNode(isPrimary: true),
      );
      final primaryNodes = service.primaryNodes;
      final expectedPrimaryNodes = [...expectedPrimaryDefaults]
        ..sort((a, b) => a.id.compareTo(b.id));
      primaryNodes.sort((a, b) => a.id.compareTo(b.id));

      expect(primaryNodes.length, expectedPrimaryNodes.length);
      expect(primaryNodes.toString(), expectedPrimaryNodes.toString());
      expect(fakeStore.interactions, 0);
    });

    test("get nodes", () async {
      final fakeStore = FakeSecureStorage();
      final service = NodeService(secureStorageInterface: fakeStore);
      final nodes = service.nodes;
      final defaultIds = expectedPrimaryDefaults.map((e) => e.id).toSet();

      expect(nodes.length, expectedDefaultNodeCount);
      expect(nodes.map((node) => node.id).toSet(), containsAll(defaultIds));
      expect(fakeStore.interactions, 0);
    });

    test("add a node", () async {
      final fakeStore = FakeSecureStorage();
      final service = NodeService(secureStorageInterface: fakeStore);
      await service.save(nodeA, true);
      expect(service.nodes.length, expectedDefaultNodeCount + 1);
      expect(fakeStore.interactions, 0);
    });

    group("Additional nodes in storage tests", () {
      setUp(() async {
        await DB.instance.put<NodeModel>(
          boxName: DB.boxNameNodeModels,
          key: nodeA.id,
          value: nodeA,
        );
        await DB.instance.put<NodeModel>(
          boxName: DB.boxNameNodeModels,
          key: nodeB.id,
          value: nodeB,
        );
        await DB.instance.put<NodeModel>(
          boxName: DB.boxNameNodeModels,
          key: nodeC.id,
          value: nodeC,
        );
      });

      test("edit a node", () async {
        final fakeStore = FakeSecureStorage();
        final service = NodeService(secureStorageInterface: fakeStore);
        final currentLength = service.nodes.length;

        final editedNode = nodeA.copyWith(name: "Some new kind of name");

        await service.save(editedNode, true);

        expect(service.nodes.length, currentLength);

        expect(
          service.getNodeById(id: nodeA.id).toString(),
          editedNode.toString(),
        );
        expect(fakeStore.interactions, 0);
      });

      test("delete a node", () async {
        final fakeStore = FakeSecureStorage();
        final service = NodeService(secureStorageInterface: fakeStore);

        await service.delete(nodeB.id, true);

        expect(service.nodes.length, expectedDefaultNodeCount + 2);
        expect(
          service.nodes.where((element) => element.id == nodeB.id).length,
          0,
        );

        expect(fakeStore.interactions, 0);
      });
    });
  });

  tearDown(() async {
    await tearDownHiveCeTest();
  });
}
