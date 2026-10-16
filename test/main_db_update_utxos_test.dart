import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:paymint/db/isar/main_db.dart';
import 'package:paymint/models/isar/models/blockchain_data/utxo.dart';

/// Isar's native library: ISAR_LIB, else the one of a Linux build
/// (`flutter build linux`).
final _isarLib =
    Platform.environment["ISAR_LIB"] ??
    "build/linux/x64/release/bundle/lib/libisar.so";

void main() {
  late Isar isar;
  late Directory dir;
  final db = MainDB.instance;

  setUpAll(() async {
    await Isar.initializeIsarCore(
      libraries: {Abi.linuxX64: File(_isarLib).absolute.path},
    );
    dir = await Directory.systemTemp.createTemp("update_utxos_test");
    isar = await Isar.open([UTXOSchema], directory: dir.path);
    await db.initMainDB(mock: isar);
  });

  tearDownAll(() async {
    await isar.close(deleteFromDisk: true);
    await dir.delete(recursive: true);
  });

  UTXO coin(
    String walletId,
    String txid, {
    int vout = 0,
    int value = 1000,
    int? height,
    bool isBlocked = false,
    String? blockedReason,
    String name = "",
  }) => UTXO(
    walletId: walletId,
    txid: txid,
    vout: vout,
    value: value,
    name: name,
    isBlocked: isBlocked,
    blockedReason: blockedReason,
    isCoinbase: false,
    blockHash: height == null ? null : "hash$height",
    blockHeight: height,
    blockTime: height == null ? null : 1000 + height,
  );

  Future<Map<String, UTXO>> stored(String walletId) async => {
    for (final u in await db.getUTXOs(walletId).findAll())
      "${u.txid}:${u.vout}": u,
  };

  /// Writes to the coin table while [action] runs.
  Future<int> writesDuring(Future<void> Function() action) async {
    var writes = 0;
    final sub = isar.utxos.watchLazy().listen((_) => writes++);
    await action();
    // Watchers hear about a commit asynchronously.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await sub.cancel();
    return writes;
  }

  test("adds new coins, then writes nothing when nothing changed", () async {
    final list = [
      for (var i = 0; i < 50; i++) coin("w1", "tx$i", height: 10 + i),
    ];
    expect(await db.updateUTXOs("w1", list), isTrue);
    expect((await stored("w1")).length, 50);

    final ids = {
      for (final e in (await stored("w1")).entries) e.key: e.value.id,
    };
    final again = [
      for (var i = 0; i < 50; i++) coin("w1", "tx$i", height: 10 + i),
    ];
    var result = true;
    final writes = await writesDuring(() async {
      result = await db.updateUTXOs("w1", again);
    });
    expect(result, isFalse);
    expect(writes, 0);
    expect({
      for (final e in (await stored("w1")).entries) e.key: e.value.id,
    }, ids);
  });

  test("removes coins no longer listed, keeps other wallets'", () async {
    await db.updateUTXOs("w2", [
      coin("w2", "a"),
      coin("w2", "b"),
      coin("w2", "b", vout: 1),
    ]);
    await db.updateUTXOs("w3", [coin("w3", "a")]);

    expect(await db.updateUTXOs("w2", [coin("w2", "b", vout: 1)]), isFalse);
    expect((await stored("w2")).keys, ["b:1"]);
    expect((await stored("w3")).keys, ["a:0"]);

    await db.updateUTXOs("w2", []);
    expect(await stored("w2"), isEmpty);
    expect((await stored("w3")).keys, ["a:0"]);
  });

  test("updates changed coins and keeps the user's flags", () async {
    await db.updateUTXOs("w4", [
      coin("w4", "frozen"),
      coin("w4", "named"),
      coin("w4", "unfrozen"),
      coin("w4", "fresh"),
      coin("w4", "pending"),
    ]);
    final rows = await stored("w4");
    await isar.writeTxn(
      () => isar.utxos.putAll([
        // Frozen by the user.
        rows["frozen:0"]!.copyWith(isBlocked: true),
        rows["named:0"]!.copyWith(name: "Savings"),
        // Frozen by the wallet, then unfrozen by the user.
        rows["unfrozen:0"]!.copyWith(blockedReason: "collateral"),
        // Taken by a send not confirmed yet.
        rows["pending:0"]!.copyWith(used: true),
      ]),
    );

    await db.updateUTXOs("w4", [
      coin("w4", "frozen", height: 20),
      coin("w4", "named"),
      coin("w4", "unfrozen", isBlocked: true, blockedReason: "collateral"),
      coin("w4", "fresh", isBlocked: true, blockedReason: "collateral"),
      coin("w4", "pending"),
    ]);
    final after = await stored("w4");
    expect(after["frozen:0"]!.isBlocked, isTrue);
    expect(after["frozen:0"]!.blockHeight, 20);
    expect(after["frozen:0"]!.blockHash, "hash20");
    expect(after["named:0"]!.name, "Savings");
    // Never frozen again by the wallet once the user unfroze it...
    expect(after["unfrozen:0"]!.isBlocked, isFalse);
    // ...but a coin the user never touched is.
    expect(after["fresh:0"]!.isBlocked, isTrue);
    expect(after["fresh:0"]!.blockedReason, "collateral");
    expect(after["pending:0"]!.used, isTrue);
  });

  test("a coin listed twice is stored once", () async {
    expect(
      await db.updateUTXOs("w5", [coin("w5", "a"), coin("w5", "a")]),
      isTrue,
    );
    expect((await stored("w5")).keys, ["a:0"]);
  });
}
