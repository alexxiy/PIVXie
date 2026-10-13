import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:paymint/models/balance.dart';
import 'package:paymint/models/isar/models/blockchain_data/address.dart';
import 'package:paymint/utilities/amount/amount.dart';
import 'package:paymint/wallets/isar/models/wallet_info.dart';

/// Isar's native library: ISAR_LIB, else the one of a Linux build
/// (`flutter build linux`).
final _isarLib =
    Platform.environment["ISAR_LIB"] ??
    "build/linux/x64/release/bundle/lib/libisar.so";

void main() {
  late Isar isar;
  late Directory dir;

  setUpAll(() async {
    await Isar.initializeIsarCore(
      libraries: {Abi.linuxX64: File(_isarLib).absolute.path},
    );
    dir = await Directory.systemTemp.createTemp("wallet_info_test");
    isar = await Isar.open([WalletInfoSchema], directory: dir.path);
  });

  tearDownAll(() async {
    await isar.close(deleteFromDisk: true);
    await dir.delete(recursive: true);
  });

  Future<WalletInfo> stored(WalletInfo info) async =>
      (await isar.walletInfo.get(info.id))!;

  Future<WalletInfo> newWallet(String id) async {
    final info = WalletInfo(
      walletId: id,
      name: id,
      mainAddressType: AddressType.p2pkh,
      coinName: "pivx",
    );
    await isar.writeTxn(() => isar.walletInfo.put(info));
    return info;
  }

  test("updates running together keep each other's changes", () async {
    // E.g. a sync saving the balance while the UI saves a masternode.
    final info = await newWallet("together");
    Amount sats(int v) => Amount(rawValue: BigInt.from(v), fractionDigits: 8);
    final balance = Balance(
      total: sats(5),
      spendable: sats(4),
      blockedTotal: sats(1),
      pendingSpendable: sats(0),
    );
    await Future.wait([
      info.updateOtherData(newEntries: {"a": 1}, isar: isar),
      info.updateBalance(newBalance: balance, isar: isar),
      info.updateOtherData(newEntries: {"b": 2}, isar: isar),
      info.updateCachedChainHeight(newHeight: 7, isar: isar),
    ]);
    final s = await stored(info);
    expect(s.otherData["a"], 1);
    expect(s.otherData["b"], 2);
    expect(s.cachedBalanceString, balance.toJsonIgnoreCoin());
    expect(s.cachedChainHeight, 7);
  });

  test("updateOtherDataWith changes the stored value", () async {
    // Each adds to the stored list, so none is lost.
    final info = await newWallet("list");
    await Future.wait([
      for (var i = 0; i < 5; i++)
        info.updateOtherDataWith(
          isar: isar,
          change: (stored) => {
            "items": [...(stored["items"] as List?) ?? const [], i],
          },
        ),
    ]);
    final items = (await stored(info)).otherData["items"] as List;
    expect(items.toSet(), {0, 1, 2, 3, 4});
  });
}
