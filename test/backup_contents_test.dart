// What a backup keeps besides the wallets' keys: favourites in their
// order, and the coins the user froze, unfroze or named.
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

    test("older backups: in file order", () {
      final a = {"id": "a", "isFavorite": true};
      final b = {"id": "b", "isFavorite": false};
      final c = {"id": "c", "isFavorite": true};
      final order = swbFavouriteOrder([a, b, c], after: -1);
      expect(order[a], 0);
      expect(order[c], 1);
      expect(order.length, 2);
    });

    test("equal wallet maps stay apart", () {
      final a = {"id": "x", "isFavorite": true};
      final b = {"id": "x", "isFavorite": true};
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
}
