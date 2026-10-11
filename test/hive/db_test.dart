import 'package:flutter_test/flutter_test.dart';
import 'package:hive_test/hive_test.dart';
import 'package:paymint/db/hive/db.dart';

void main() {
  group("DB box names", () {
    test("address book", () => expect(DB.boxNameAddressBook, "addressBook"));
    test("nodes", () => expect(DB.boxNameNodeModels, "nodeModels"));
    test("wallets info", () => expect(DB.boxNameAllWalletsData, "wallets"));
    test(
      "favorite wallets",
      () => expect(DB.boxNameFavoriteWallets, "favoriteWallets"),
    );
    test("preferences", () => expect(DB.boxNamePrefs, "prefs"));
    test(
      "deleted wallets to clear out on start",
      () => expect(DB.boxNameWalletsToDeleteOnStart, "walletsToDeleteOnStart"),
    );
    test(
      "price cache",
      () => expect(DB.boxNamePriceCache, "priceAPIPrice24hCache"),
    );
  });

  group("tests requiring test hive environment", () {
    setUp(() async {
      await setUpTestHive();
    });

    test("DB init", () async {});

    tearDown(() async {
      await tearDownTestHive();
    });
  });
}
