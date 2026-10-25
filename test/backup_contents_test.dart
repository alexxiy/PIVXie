// What a backup keeps besides the wallets' keys: favourites in their
// order, and the coins the user froze, unfroze or named. And which files
// restore: those with everything a backup from this app has.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/models/isar/models/isar_models.dart';
import 'package:paymint/pages/settings_views/global_settings_view/stack_backup_views/helpers/restore_create_backup.dart';
import 'package:paymint/wallets/wallet/impl/pivx_wallet.dart';

void main() {
  group("favourites", () {
    test("follow the backup's order, after this device's", () {
      final a = {"id": "a", "isFavorite": true, "favouriteOrderIndex": 7};
      final b = {"id": "b", "isFavorite": false, "favouriteOrderIndex": -1};
      final c = {"id": "c", "isFavorite": true, "favouriteOrderIndex": 2};
      final d = {"id": "d", "isFavorite": true, "favouriteOrderIndex": 7};
      final order = swbFavouriteOrder([a, b, c, d], after: 4);
      expect(order[c], 5);
      expect(order[a], 6);
      expect(order[d], 7); // same index: order in the file
      expect(order.containsKey(b), isFalse);
    });

    test("equal wallet maps stay apart", () {
      final a = {"id": "x", "isFavorite": true, "favouriteOrderIndex": 0};
      final b = {"id": "x", "isFavorite": true, "favouriteOrderIndex": 0};
      final order = swbFavouriteOrder([a, b], after: 0);
      expect([order[a], order[b]], [1, 2]);
    });
  });

  group("coin flags", () {
    UTXO coin({
      required int vout,
      bool frozen = false,
      String? reason,
      String name = "",
    }) => UTXO(
      walletId: "w",
      txid: "ab" * 32,
      vout: vout,
      value: 5,
      name: name,
      isBlocked: frozen,
      blockedReason: reason,
      isCoinbase: false,
      blockHash: "h",
      blockHeight: 1,
      blockTime: 1,
    );

    test("frozen, unfrozen and named coins come back", () {
      final coins = [
        coin(vout: 0, frozen: true),
        coin(vout: 1, reason: "Cold staking"), // unfrozen by the user
        coin(vout: 2, name: "Savings"),
        coin(vout: 3, frozen: true, reason: "Masternode collateral"),
      ];
      final json = [for (final u in coins) pivxCoinFlagsToJson(u)];
      expect(json[0], {"txid": "ab" * 32, "vout": 0, "frozen": true});
      expect(json[2]["name"], "Savings");

      final back = pivxCoinFlagsFromJson(json, "new");
      expect(back.keys, [for (final u in coins) "${u.txid}:${u.vout}"]);
      final unfrozen = back["${"ab" * 32}:1"]!;
      expect(unfrozen.walletId, "new");
      expect(unfrozen.isBlocked, isFalse);
      expect(unfrozen.userUnfroze, isTrue);
      expect(back["${"ab" * 32}:0"]!.isBlocked, isTrue);
      expect(back["${"ab" * 32}:0"]!.userUnfroze, isFalse);
      expect(back["${"ab" * 32}:2"]!.name, "Savings");
      expect(back["${"ab" * 32}:3"]!.blockedReason, "Masternode collateral");
    });

    test("unreadable entries are left out", () {
      final back = pivxCoinFlagsFromJson([
        "x",
        {"txid": "t"},
        {"txid": 1, "vout": 0},
        {"txid": "t", "vout": 0, "frozen": "yes", "name": 3},
      ], "w");
      expect(back.keys, ["t:0"]);
      expect(back["t:0"]!.isBlocked, isFalse);
      expect(back["t:0"]!.name, "");
    });
  });

  group("backup format", () {
    Map<String, dynamic> backup() => {
      "nodes": [
        {
          "host": "https://eu-bridge.pivxie.me",
          "port": 443,
          "name": "EU",
          "id": "default_pivx",
          "useSSL": true,
          "coinName": "pivx",
          "torEnabled": true,
          "clearEnabled": true,
          "isPrimary": true,
        },
      ],
      "prefs": {
        "currency": "USD",
        "useBiometrics": false,
        "hasPin": true,
        "language": "",
        "showFavoriteWallets": true,
        "syncType": "allWalletsOnStartup",
        "walletIdsSyncOnStartup": ["w1"],
        "showTestNetCoins": false,
        "externalCalls": true,
        "isAutoBackupEnabled": false,
        "autoBackupLocation": null,
        "backupFrequencyType": "BackupFrequencyType.everyTenMinutes",
        "lastAutoBackup": "null",
        "enableCoinControl": false,
        "amountUnits": {"pivx": "normal"},
        "maxDecimals": {"pivx": 8},
        "themeId": "light",
        "enableSystemBrightness": false,
        "systemBrightnessLightThemeId": "light",
        "systemBrightnessDarkThemeId": "dark",
        "hideBlockExplorerWarning": false,
      },
      "addressBookEntries": [
        {
          "emoji": null,
          "name": "Bob",
          "addresses": [
            {"address": "D123", "coin": "pivx"},
          ],
          "id": "c1",
          "isFavorite": false,
        },
      ],
      "wallets": [
        {
          "name": "Main",
          "id": "w1",
          "isFavorite": true,
          "favouriteOrderIndex": 0,
          "otherDataJsonString": null,
          "mnemonic": "one two three",
          "mnemonicPassphrase": "",
          "coinName": "pivx",
          "storedChainHeight": 100,
          "restoreHeight": 90,
          "notes": <String, String>{},
          "addressLabels": <String, String>{},
        },
      ],
    };

    test("this app's backup restores", () {
      expect(isSwbBackup(jsonEncode(backup())), isTrue);
      final keys = backup();
      (keys["wallets"] as List).first
        ..["pivxMasternodeKeys"] = {"mn": "key"}
        ..["coinFlags"] = <Object>[];
      (keys["prefs"] as Map)["nodesChosenByUser"] = ["pivx"];
      expect(isSwbBackup(jsonEncode(keys)), isTrue);
    });

    test("a view only wallet needs its data instead of the phrase", () {
      final b = backup();
      ((b["wallets"] as List).first as Map)
        ..remove("mnemonic")
        ..remove("mnemonicPassphrase");
      expect(isSwbBackup(jsonEncode(b)), isFalse);
      ((b["wallets"] as List).first as Map)["viewOnlyWalletDataKey"] = "{}";
      expect(isSwbBackup(jsonEncode(b)), isTrue);
    });

    test("one missing field and it doesn't", () {
      for (final (part, field) in [
        ("prefs", "externalCalls"),
        ("prefs", "hideBlockExplorerWarning"),
        ("nodes", "torEnabled"),
        ("addressBookEntries", "isFavorite"),
        ("wallets", "favouriteOrderIndex"),
        ("wallets", "addressLabels"),
        ("wallets", "restoreHeight"),
        ("wallets", "mnemonicPassphrase"),
      ]) {
        final b = backup();
        final p = b[part];
        (p is List ? p.first as Map : p as Map).remove(field);
        expect(isSwbBackup(jsonEncode(b)), isFalse, reason: "$part.$field");
      }
      final b = backup()..remove("addressBookEntries");
      expect(isSwbBackup(jsonEncode(b)), isFalse);
    });

    test("not a backup", () {
      expect(isSwbBackup("not json"), isFalse);
      expect(isSwbBackup("[]"), isFalse);
      expect(isSwbBackup("{}"), isFalse);
    });
  });
}
