import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:paymint/db/isar/main_db.dart';
import 'package:paymint/models/isar/models/address_label.dart';
import 'package:paymint/models/isar/models/blockchain_data/address.dart';
import 'package:paymint/models/isar/models/blockchain_data/transaction_type.dart';
import 'package:paymint/models/isar/models/blockchain_data/utxo.dart';
import 'package:paymint/models/isar/models/blockchain_data/v2/transaction_v2.dart';
import 'package:paymint/models/isar/models/transaction_note.dart';

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
    dir = await Directory.systemTemp.createTemp("delete_wallet_data_test");
    isar = await Isar.open([
      TransactionV2Schema,
      AddressSchema,
      UTXOSchema,
      AddressLabelSchema,
      TransactionNoteSchema,
    ], directory: dir.path);
    await db.initMainDB(mock: isar);
  });

  tearDownAll(() async {
    await isar.close(deleteFromDisk: true);
    await dir.delete(recursive: true);
  });

  // More than the old page sizes (100 and 50), which skipped every other
  // page as the rows before them were deleted.
  const n = 250;

  Future<void> fill(String walletId) => isar.writeTxn(() async {
    await isar.transactionV2s.putAll([
      for (var i = 0; i < n; i++)
        TransactionV2(
          walletId: walletId,
          blockHash: null,
          hash: "$walletId-tx$i",
          txid: "$walletId-tx$i",
          timestamp: i,
          height: null,
          inputs: const [],
          outputs: const [],
          version: 1,
          type: TransactionType.incoming,
          subType: TransactionSubType.none,
          otherData: null,
        ),
    ]);
    await isar.addresses.putAll([
      for (var i = 0; i < n; i++)
        Address(
          walletId: walletId,
          value: "$walletId-addr$i",
          publicKey: const [],
          derivationIndex: i,
          derivationPath: null,
          type: AddressType.p2pkh,
          subType: AddressSubType.receiving,
        ),
    ]);
    await isar.utxos.putAll([
      for (var i = 0; i < n; i++)
        UTXO(
          walletId: walletId,
          txid: "$walletId-tx$i",
          vout: 0,
          value: 1000,
          name: "",
          isBlocked: false,
          blockedReason: null,
          isCoinbase: false,
          blockHash: null,
          blockHeight: null,
          blockTime: null,
        ),
    ]);
    await isar.addressLabels.putAll([
      for (var i = 0; i < n; i++)
        AddressLabel(
          walletId: walletId,
          addressString: "$walletId-addr$i",
          value: "label $i",
          tags: null,
        ),
    ]);
    await isar.transactionNotes.putAll([
      for (var i = 0; i < n; i++)
        TransactionNote(
          walletId: walletId,
          txid: "$walletId-tx$i",
          value: "note $i",
        ),
    ]);
  });

  Future<List<int>> counts(String walletId) async => [
    await isar.transactionV2s.where().walletIdEqualTo(walletId).count(),
    await db.getAddresses(walletId).count(),
    await db.getUTXOs(walletId).count(),
    await db.getAddressLabels(walletId).count(),
    await db.getTransactionNotes(walletId).count(),
  ];

  test("deleting a wallet's data removes all of it, and only it", () async {
    await fill("w1");
    await fill("w2");

    await db.deleteWalletBlockchainData("w1");
    await db.deleteAddressLabels("w1");
    await db.deleteTransactionNotes("w1");

    expect(await counts("w1"), [0, 0, 0, 0, 0]);
    expect(await counts("w2"), [n, n, n, n, n]);
  });
}
