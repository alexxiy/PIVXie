//ON
import 'package:flutter_libpivxshield/flutter_libpivxshield.dart';

//END_ON
import '../interfaces/lib_pivx_shield_interface.dart';

LibPivxShieldInterface get libPivxShield => _getInterface();

//OFF
LibPivxShieldInterface _getInterface() => const _Unavailable();

class _Unavailable extends LibPivxShieldInterface {
  const _Unavailable();

  static Never _no() => throw Exception("PIVX shield not enabled!");

  @override
  bool get isAvailable => false;
  @override
  String extendedSpendingKey({required List<int> seed, required int coinType, int accountIndex = 0}) => _no();
  @override
  String extendedFullViewingKey({required String extsk, required bool isTestnet}) => _no();
  @override
  ({String address, List<int> diversifierIndex}) defaultAddress({required String extfvk, required bool isTestnet}) => _no();
  @override
  ({String address, List<int> diversifierIndex}) nextAddress({required String extfvk, required List<int> diversifierIndex, required bool isTestnet}) => _no();
  @override
  bool isValidAddress(String address, {required bool isTestnet}) => false;
  @override
  ({int height, String tree}) closestCheckpoint({required int height, required bool isTestnet}) => _no();
  @override
  Future<Map<String, dynamic>> handleBlocks({required String tree, required List<List<String>> blocks, required String extfvk, required bool isTestnet, required List<Map<String, dynamic>> notes}) => _no();
  @override
  String saplingRoot(String tree) => _no();
  @override
  Future<void> loadProver({required String outputParamsPath, required String spendParamsPath}) => _no();
  @override
  bool proverIsLoaded() => false;
  @override
  Future<Map<String, dynamic>> createTransaction({List<Map<String, dynamic>>? notes, List<Map<String, dynamic>>? utxos, required String extsk, required String toAddress, required String changeAddress, required int amount, required int blockHeight, required bool isTestnet, String memo = "", bool useAllInputs = false}) => _no();
}

//END_OFF
//ON
LibPivxShieldInterface _getInterface() => const _Impl();

class _Impl extends LibPivxShieldInterface {
  const _Impl();

  @override
  bool get isAvailable => true;

  @override
  String extendedSpendingKey({required List<int> seed, required int coinType, int accountIndex = 0}) =>
      PivxShield.extendedSpendingKey(seed: seed, coinType: coinType, accountIndex: accountIndex);

  @override
  String extendedFullViewingKey({required String extsk, required bool isTestnet}) =>
      PivxShield.extendedFullViewingKey(extsk: extsk, isTestnet: isTestnet);

  @override
  ({String address, List<int> diversifierIndex}) defaultAddress({required String extfvk, required bool isTestnet}) =>
      PivxShield.defaultAddress(extfvk: extfvk, isTestnet: isTestnet);

  @override
  ({String address, List<int> diversifierIndex}) nextAddress({required String extfvk, required List<int> diversifierIndex, required bool isTestnet}) =>
      PivxShield.nextAddress(extfvk: extfvk, diversifierIndex: diversifierIndex, isTestnet: isTestnet);

  @override
  bool isValidAddress(String address, {required bool isTestnet}) =>
      PivxShield.isValidAddress(address, isTestnet: isTestnet);

  @override
  ({int height, String tree}) closestCheckpoint({required int height, required bool isTestnet}) =>
      PivxShield.closestCheckpoint(height: height, isTestnet: isTestnet);

  @override
  Future<Map<String, dynamic>> handleBlocks({required String tree, required List<List<String>> blocks, required String extfvk, required bool isTestnet, required List<Map<String, dynamic>> notes}) =>
      PivxShield.handleBlocks(tree: tree, blocks: blocks, extfvk: extfvk, isTestnet: isTestnet, notes: notes);

  @override
  String saplingRoot(String tree) => PivxShield.saplingRoot(tree);

  @override
  Future<void> loadProver({required String outputParamsPath, required String spendParamsPath}) =>
      PivxShield.loadProver(outputParamsPath: outputParamsPath, spendParamsPath: spendParamsPath);

  @override
  bool proverIsLoaded() => PivxShield.proverIsLoaded();

  @override
  Future<Map<String, dynamic>> createTransaction({List<Map<String, dynamic>>? notes, List<Map<String, dynamic>>? utxos, required String extsk, required String toAddress, required String changeAddress, required int amount, required int blockHeight, required bool isTestnet, String memo = "", bool useAllInputs = false}) =>
      PivxShield.createTransaction(notes: notes, utxos: utxos, extsk: extsk, toAddress: toAddress, changeAddress: changeAddress, amount: amount, blockHeight: blockHeight, isTestnet: isTestnet, memo: memo, useAllInputs: useAllInputs);
}

//END_ON
