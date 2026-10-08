export '../generated/lib_pivx_shield_interface_impl.dart';

/// PIVX Shield (Sapling) wallet core. Implemented by the
/// `flutter_libpivxshield` plugin when the app is configured with the
/// PIVX marker; otherwise every call throws.
///
/// Notes are opaque JSON maps produced by the native library; each
/// carries `value` (sat), `address`, `nullifier` and `memo`.
abstract class LibPivxShieldInterface {
  const LibPivxShieldInterface();

  bool get isAvailable;

  String extendedSpendingKey({
    required List<int> seed,
    required int coinType,
    int accountIndex = 0,
  });

  String extendedFullViewingKey({required String extsk, required bool isTestnet});

  ({String address, List<int> diversifierIndex}) defaultAddress({
    required String extfvk,
    required bool isTestnet,
  });

  ({String address, List<int> diversifierIndex}) nextAddress({
    required String extfvk,
    required List<int> diversifierIndex,
    required bool isTestnet,
  });

  bool isValidAddress(String address, {required bool isTestnet});

  ({int height, String tree}) closestCheckpoint({
    required int height,
    required bool isTestnet,
  });

  Future<Map<String, dynamic>> handleBlocks({
    required String tree,
    required List<List<String>> blocks,
    required String extfvk,
    required bool isTestnet,
    required List<Map<String, dynamic>> notes,
  });

  /// Display-order hex (comparable to a block's `finalsaplingroot`).
  String saplingRoot(String tree);

  Future<void> loadProver({
    required String outputParamsPath,
    required String spendParamsPath,
  });

  bool proverIsLoaded();

  Future<Map<String, dynamic>> createTransaction({
    List<Map<String, dynamic>>? notes,
    List<Map<String, dynamic>>? utxos,
    required String extsk,
    required String toAddress,
    required String changeAddress,
    required int amount,
    required int blockHeight,
    required bool isTestnet,
    String memo = "",
    // Spend every given note/UTXO (coin control selection).
    bool useAllInputs = false,
  });
}
