/// PIVX Shield (Sapling) wallet core via dart:ffi.
///
/// The native library exposes one JSON entry point; this file wraps it
/// in typed helpers. Heavy calls (block scanning, proving) should go
/// through the `*Async` variants, which run on a background isolate.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

class PivxShieldException implements Exception {
  PivxShieldException(this.method, this.message);

  final String method;
  final String message;

  @override
  String toString() => "PivxShieldException($method): $message";
}

typedef _CallNative = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

/// Override to load the library from a custom path (e.g. host tests).
String? pivxShieldLibraryPathOverride;

DynamicLibrary _open() {
  final override =
      pivxShieldLibraryPathOverride ?? Platform.environment["PIVX_SHIELD_LIB"];
  if (override != null) return DynamicLibrary.open(override);
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open("libpivx_shield_ffi.so");
  }
  if (Platform.isIOS || Platform.isMacOS) return DynamicLibrary.process();
  if (Platform.isWindows) return DynamicLibrary.open("pivx_shield_ffi.dll");
  throw UnsupportedError("Unsupported platform");
}

DynamicLibrary? _lib;
_CallNative? _call;
_FreeDart? _free;

void _ensureLoaded() {
  if (_call != null) return;
  _lib = _open();
  _call = _lib!.lookupFunction<_CallNative, _CallNative>("pivx_shield_call");
  _free = _lib!.lookupFunction<_FreeNative, _FreeDart>("pivx_shield_free");
}

/// Synchronous call into the native library. Returns the decoded `ok`
/// value or throws [PivxShieldException].
dynamic pivxShieldCall(String method, Map<String, dynamic> args) {
  _ensureLoaded();
  final m = method.toNativeUtf8();
  final a = jsonEncode(args).toNativeUtf8();
  try {
    final r = _call!(m, a);
    final text = r.toDartString();
    _free!(r);
    final json = jsonDecode(text) as Map<String, dynamic>;
    if (json.containsKey("err")) {
      throw PivxShieldException(method, json["err"].toString());
    }
    return json["ok"];
  } finally {
    malloc.free(m);
    malloc.free(a);
  }
}

/// [pivxShieldCall] on a background isolate.
Future<dynamic> pivxShieldCallAsync(String method, Map<String, dynamic> args) {
  final libOverride = pivxShieldLibraryPathOverride;
  return Isolate.run(() {
    pivxShieldLibraryPathOverride = libOverride;
    return pivxShieldCall(method, args);
  });
}

/// Typed helpers. Notes are opaque JSON maps produced by the library;
/// each carries `value` (sat), `address`, `nullifier`, `memo`.
abstract final class PivxShield {
  static String version() => pivxShieldCall("version", {}) as String;

  /// ZIP32 spending key for [seed] (MyPIVXWallet passes the first 32
  /// bytes of the BIP39 seed). Coin type 1 selects testnet encoding.
  static String extendedSpendingKey({
    required List<int> seed,
    required int coinType,
    int accountIndex = 0,
  }) =>
      pivxShieldCall("generate_extsk", {
            "seed_hex": _hex(seed),
            "coin_type": coinType,
            "account_index": accountIndex,
          })
          as String;

  static String extendedFullViewingKey({
    required String extsk,
    required bool isTestnet,
  }) =>
      pivxShieldCall("generate_extfvk", {"key": extsk, "is_testnet": isTestnet})
          as String;

  static ({String address, List<int> diversifierIndex}) defaultAddress({
    required String extfvk,
    required bool isTestnet,
  }) => _address(
    pivxShieldCall("default_address", {"key": extfvk, "is_testnet": isTestnet}),
  );

  static ({String address, List<int> diversifierIndex}) nextAddress({
    required String extfvk,
    required List<int> diversifierIndex,
    required bool isTestnet,
  }) => _address(
    pivxShieldCall("next_address", {
      "extfvk": extfvk,
      "diversifier_index": diversifierIndex,
      "is_testnet": isTestnet,
    }),
  );

  static bool isValidAddress(String address, {required bool isTestnet}) =>
      pivxShieldCall("validate_address", {
            "address": address,
            "is_testnet": isTestnet,
          })
          as bool;

  static ({int height, String tree}) closestCheckpoint({
    required int height,
    required bool isTestnet,
  }) {
    final r =
        pivxShieldCall("closest_checkpoint", {
              "height": height,
              "is_testnet": isTestnet,
            })
            as Map;
    return (height: r["height"] as int, tree: r["tree"] as String);
  }

  /// Scan [blocks] (lists of raw tx hex) on a background isolate.
  /// Returns `decrypted_notes` (still-tracked notes, witnesses updated),
  /// `decrypted_new_notes`, `nullifiers` (all spent in these blocks),
  /// `commitment_tree` and `wallet_transactions`.
  static Future<Map<String, dynamic>> handleBlocks({
    required String tree,
    required List<List<String>> blocks,
    required String extfvk,
    required bool isTestnet,
    required List<Map<String, dynamic>> notes,
  }) async {
    final r = await pivxShieldCallAsync("handle_blocks", {
      "tree": tree,
      "blocks": [
        for (final b in blocks) {"txs": b},
      ],
      "extfvk": extfvk,
      "is_testnet": isTestnet,
      "notes": notes,
    });
    return Map<String, dynamic>.from(r as Map);
  }

  /// Display-order hex of the tree root (comparable to `finalsaplingroot`).
  static String saplingRoot(String tree) {
    final raw = pivxShieldCall("sapling_root", {"tree": tree}) as String;
    final bytes = <String>[];
    for (int i = 0; i < raw.length; i += 2) {
      bytes.add(raw.substring(i, i + 2));
    }
    return bytes.reversed.join();
  }

  static Future<void> loadProver({
    required String outputParamsPath,
    required String spendParamsPath,
  }) async {
    await pivxShieldCallAsync("load_prover", {
      "output_path": outputParamsPath,
      "spend_path": spendParamsPath,
    });
  }

  static bool proverIsLoaded() =>
      pivxShieldCall("prover_is_loaded", {}) as bool;

  /// Build and prove a transaction on a background isolate. Exactly one
  /// of [notes] or [utxos] is given. Each utxo: `txid`, `vout`, `amount`,
  /// `private_key` (hex), `script` (hex). If the inputs only cover
  /// [amount], the fee is subtracted from it (send-all). With [toScript]
  /// (hex; [notes] only) the amount goes to that output script instead of
  /// [toAddress], e.g. a proposal fee's OP_RETURN or a cold staking
  /// delegation.
  /// Returns `txid`, `txhex`, `nullifiers`, `fee`, `amount`.
  static Future<Map<String, dynamic>> createTransaction({
    List<Map<String, dynamic>>? notes,
    List<Map<String, dynamic>>? utxos,
    required String extsk,
    required String toAddress,
    required String changeAddress,
    required int amount,
    required int blockHeight,
    required bool isTestnet,
    String memo = "",
    bool useAllInputs = false,
    bool subtractFee = false,
    String? toScript,
  }) async {
    final r = await pivxShieldCallAsync("create_transaction", {
      "notes": notes,
      "utxos": utxos,
      "extsk": extsk,
      "to_address": toAddress,
      "change_address": changeAddress,
      "amount": amount,
      "block_height": blockHeight,
      "is_testnet": isTestnet,
      "memo": memo,
      "use_all_inputs": useAllInputs,
      "subtract_fee": subtractFee,
      if (toScript != null) "to_script": toScript,
    });
    return Map<String, dynamic>.from(r as Map);
  }

  static ({String address, List<int> diversifierIndex}) _address(dynamic r) {
    final m = r as Map;
    return (
      address: m["address"] as String,
      diversifierIndex: List<int>.from(m["diversifier_index"] as List),
    );
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, "0")).join();
}
