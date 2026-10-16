import 'dart:convert';
import 'dart:io';

import '../../../../utilities/stack_file_system.dart';

/// Per-wallet PIVX Shield (Sapling) state, mirroring what
/// pivx-shield's `PIVXShield.save()` keeps in MyPIVXWallet.
///
/// Stored as a JSON file next to the app data so the large witness data
/// stays out of Isar. No keys go in the file: the full viewing key
/// ([extfvk]) reveals every shield transaction, past and future, so it is
/// derived from the mnemonic when the state loads and kept in memory.
/// The notes, amounts and memos in the file are what the wallet's history
/// shows anyway.
class PivxShieldState {
  PivxShieldState({
    required this.extfvk,
    required this.isTestnet,
    required this.startHeight,
    required this.lastProcessedBlock,
    required this.commitmentTree,
    required this.diversifierIndex,
    required this.currentAddress,
    List<Map<String, dynamic>>? unspentNotes,
    Map<String, Map<String, dynamic>>? nullifierNotes,
    Map<String, List<String>>? pendingSpent,
    Map<String, int>? pendingIncoming,
    Map<String, Map<String, dynamic>>? txInfo,
  }) : unspentNotes = unspentNotes ?? [],
       nullifierNotes = nullifierNotes ?? {},
       pendingSpent = pendingSpent ?? {},
       pendingIncoming = pendingIncoming ?? {},
       txInfo = txInfo ?? {};

  static const version = 1;

  /// Not saved (see the class comment).
  final String extfvk;
  final bool isTestnet;

  /// Height the scan started from (checkpoint at or below the wallet's
  /// restore height). Used to reset after a sapling root mismatch.
  final int startHeight;

  int lastProcessedBlock;
  String commitmentTree;
  List<int> diversifierIndex;

  /// Latest generated shield address (shown as the receiving address).
  String currentAddress;

  /// Notes not yet seen spent on chain, as produced by the native lib
  /// (`note`, `witness`, `nullifier`, `memo`, `value`, `address`).
  List<Map<String, dynamic>> unspentNotes;

  /// Every note the wallet ever received: nullifier -> {value, address}.
  /// Lets history show the value of spent notes.
  Map<String, Map<String, dynamic>> nullifierNotes;

  /// Broadcast but unconfirmed shield spends: txid -> nullifiers.
  Map<String, List<String>> pendingSpent;

  /// Broadcast but unconfirmed sends paying this wallet's shield
  /// addresses (change above all): txid -> sats. They are notes only once
  /// a block has them; until then the balance counts them as pending.
  Map<String, int> pendingIncoming;

  /// Shield parts of wallet transactions: txid -> {received: [{value,
  /// address, memo}], spentNullifiers: [...]}.
  Map<String, Map<String, dynamic>> txInfo;

  Set<String> get pendingNullifiers =>
      pendingSpent.values.expand((e) => e).toSet();

  int get balance =>
      unspentNotes.fold(0, (p, n) => p + (n["value"] as num).toInt());

  List<Map<String, dynamic>> get spendableNotes {
    final pending = pendingNullifiers;
    return unspentNotes
        .where((n) => !pending.contains(n["nullifier"]))
        .toList();
  }

  Map<String, dynamic> toJson() => {
    "version": version,
    "isTestnet": isTestnet,
    "startHeight": startHeight,
    "lastProcessedBlock": lastProcessedBlock,
    "commitmentTree": commitmentTree,
    "diversifierIndex": diversifierIndex,
    "currentAddress": currentAddress,
    "unspentNotes": unspentNotes,
    "nullifierNotes": nullifierNotes,
    "pendingSpent": pendingSpent,
    "pendingIncoming": pendingIncoming,
    "txInfo": txInfo,
  };

  factory PivxShieldState.fromJson(
    Map<String, dynamic> json, {
    required String extfvk,
  }) {
    Map<String, Map<String, dynamic>> mapOfMaps(dynamic v) => {
      for (final e in Map<String, dynamic>.from(v as Map? ?? {}).entries)
        e.key: Map<String, dynamic>.from(e.value as Map),
    };
    return PivxShieldState(
      extfvk: extfvk,
      isTestnet: json["isTestnet"] as bool,
      startHeight: json["startHeight"] as int,
      lastProcessedBlock: json["lastProcessedBlock"] as int,
      commitmentTree: json["commitmentTree"] as String,
      diversifierIndex: List<int>.from(json["diversifierIndex"] as List),
      currentAddress: json["currentAddress"] as String,
      unspentNotes: [
        for (final n in json["unspentNotes"] as List? ?? [])
          Map<String, dynamic>.from(n as Map),
      ],
      nullifierNotes: mapOfMaps(json["nullifierNotes"]),
      pendingSpent: {
        for (final e in Map<String, dynamic>.from(
          json["pendingSpent"] as Map? ?? {},
        ).entries)
          e.key: List<String>.from(e.value as List),
      },
      pendingIncoming: {
        for (final e in Map<String, dynamic>.from(
          json["pendingIncoming"] as Map? ?? {},
        ).entries)
          e.key: (e.value as num).toInt(),
      },
      txInfo: mapOfMaps(json["txInfo"]),
    );
  }

  // ---------------------------------------------------------------------------
  // Persistence

  static Future<File> _file(String walletId) async {
    final root = await StackFileSystem.applicationRootDirectory();
    final dir = Directory("${root.path}/pivx_shield");
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File("${dir.path}/$walletId.json");
  }

  static Future<PivxShieldState?> load(
    String walletId, {
    required String extfvk,
  }) async {
    final f = await _file(walletId);
    if (!f.existsSync()) return null;
    final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    if (json["version"] != version) return null;
    return PivxShieldState.fromJson(json, extfvk: extfvk);
  }

  Future<void> save(String walletId) async {
    final f = await _file(walletId);
    final tmp = File("${f.path}.tmp");
    await tmp.writeAsString(jsonEncode(toJson()), flush: true);
    await tmp.rename(f.path);
  }

  static Future<void> delete(String walletId) async {
    final f = await _file(walletId);
    if (f.existsSync()) await f.delete();
  }
}
