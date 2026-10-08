import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:isar_community/isar.dart';
import 'package:mutex/mutex.dart';

import '../../../models/balance.dart';
import '../../../models/coinlib/exp2pkh_address.dart';
import '../../../models/input.dart';
import '../../../models/isar/models/blockchain_data/v2/input_v2.dart';
import '../../../models/isar/models/blockchain_data/v2/output_v2.dart';
import '../../../models/isar/models/blockchain_data/v2/transaction_v2.dart';
import '../../../models/isar/models/isar_models.dart';
import '../../../models/keys/view_only_wallet_data.dart';
import '../../../models/paymint/fee_object_model.dart';
import '../../../utilities/amount/amount.dart';
import '../../../utilities/enums/derive_path_type_enum.dart';
import '../../../utilities/enums/fee_rate_type_enum.dart';
import '../../../utilities/extensions/extensions.dart';
import '../../../services/tor_service.dart';
import '../../../utilities/logger.dart';
import '../../../utilities/stack_file_system.dart';
import '../../../wl_gen/interfaces/lib_pivx_shield_interface.dart';
import '../../api/pivx/pivx_bridge_client.dart';
import '../../crypto_currency/crypto_currency.dart';
import '../../models/tx_data.dart';
import '../../models/tx_recipient.dart';
import '../intermediate/bip39_hd_wallet.dart';
import '../wallet_mixin_interfaces/coin_control_interface.dart';
import 'pivx/pivx_shield_state.dart';
import 'pivx/pivx_shield_stream.dart';

part 'pivx/pivx_wallet_shield.dart';

/// PIVX transparent wallet backed by pivx-bridge.
///
/// Sync works on the BIP44 account xpub like MyPIVXWallet: one
/// `/api/v2/xpub` query returns the account's history and used
/// addresses, `/api/v2/utxo` its spendable outputs.
///
/// The shield (Sapling) balance is kept as the wallet's secondary
/// balance; see `pivx/pivx_wallet_shield.dart`.
class PivxWallet extends Bip39HDWallet<Pivx> with CoinControlInterface<Pivx> {
  PivxWallet(CryptoCurrencyNetwork network) : super(Pivx(network));

  PivxShieldState? _shield;

  /// Serialises writes of the wallet's UTXO rows (transparent outputs
  /// and shield notes share the table; see [_putUtxoRows]).
  final _utxoLock = Mutex();

  /// Blocks re-fetched below the newest confirmed tx on every sync, to
  /// pick up reorged / late-confirmed transactions.
  static const _kResyncDepth = 10;
  static const _kBridgeGap = 20;

  /// Upper-bound serialized sizes (bytes) for fee estimation. A P2PKH
  /// input is 148 bytes, or 149 with a 73-byte DER signature.
  static const _kTxOverhead = 10;
  static const _kP2pkhInput = 149;
  static const _kP2pkhOutput = 34;
  static const _kExchangeOutput = 35;

  @override
  int get isarTransactionVersion => 2;

  @override
  FilterOperation? get changeAddressFilterOperation =>
      FilterGroup.and(standardChangeAddressFilters);

  @override
  FilterOperation? get receivingAddressFilterOperation =>
      FilterGroup.and(standardReceivingAddressFilters);

  // ===========================================================================
  // Bridge client

  PivxBridgeClient? _client;
  String? _clientKey;

  PivxBridgeClient get bridge {
    final node = getCurrentNode();
    final key = "${node.host}|${node.port}|${node.useSSL}|${prefs.useTor}";
    if (_client == null || _clientKey != key) {
      _client = PivxBridgeClient.fromNode(node, prefs);
      _clientKey = key;
    }
    return _client!;
  }

  // ===========================================================================
  // Keys

  String get _accountPath => cryptoCurrency
      .constructDerivePath(
        derivePathType: DerivePathType.bip44,
        chain: 0,
        index: 0,
      )
      .replaceFirst(RegExp(r"/0/0$"), "");

  String? _accountXpub;

  /// BIP44 account-level xpub (`m/44'/119'/0'`), serialised with the
  /// network's `pubHDPrefix`.
  Future<String> get accountXpub async {
    if (_accountXpub != null) return _accountXpub!;
    if (isViewOnly) {
      final data = await getViewOnlyWalletData();
      if (data is! ExtendedKeysViewOnlyWalletData || data.xPubs.length != 1) {
        throw Exception("PIVX view only wallets need exactly one account xpub");
      }
      _accountXpub = data.xPubs.first.encoded;
    } else {
      final root = await getRootHDNode();
      _accountXpub = root
          .derivePath(_accountPath)
          .hdPublicKey
          .encode(cryptoCurrency.networkParams.pubHDPrefix);
    }
    return _accountXpub!;
  }

  Future<Address> _deriveAddress({required int chain, required int index}) async {
    final path = cryptoCurrency.constructDerivePath(
      derivePathType: DerivePathType.bip44,
      chain: chain,
      index: index,
    );
    final coinlib.HDKey key;
    if (isViewOnly) {
      key = coinlib.HDPublicKey.decode(
        await accountXpub,
      ).derivePath("$chain/$index");
    } else {
      key = (await getRootHDNode()).derivePath(path);
    }
    final data = cryptoCurrency.getAddressForPublicKey(
      publicKey: key.publicKey,
      derivePathType: DerivePathType.bip44,
    );
    return Address(
      walletId: walletId,
      value: data.address.toString(),
      publicKey: key.publicKey.data,
      derivationIndex: index,
      derivationPath: isViewOnly ? null : (DerivationPath()..value = path),
      type: data.addressType,
      subType: chain == 0 ? AddressSubType.receiving : AddressSubType.change,
    );
  }

  /// Highest derivation index stored per chain (receiving, change).
  Future<(int, int)> _highestStoredIndices() async {
    final receive = await getCurrentReceivingAddress();
    final change = await getCurrentChangeAddress();
    return (receive?.derivationIndex ?? -1, change?.derivationIndex ?? -1);
  }

  /// Gap limit for the bridge's xpub walk: large enough to reach every
  /// address this wallet has handed out.
  Future<int> _bridgeGap() async {
    final (r, c) = await _highestStoredIndices();
    return min(1000, max(_kBridgeGap, max(r, c) + 1));
  }

  /// Store the bridge's used addresses (`tokens`) and make sure the
  /// current receiving/change addresses are fresh ones.
  Future<void> _syncAddresses(List<dynamic>? tokens) async {
    final pathRe = RegExp(r"/(\d+)/(\d+)$");
    int maxReceive = -1;
    int maxChange = -1;
    final toStore = <Address>[];
    final existing = (await mainDB.getAddresses(walletId).findAll())
        .map((e) => e.value)
        .toSet();

    for (final t in tokens ?? const []) {
      final token = Map<String, dynamic>.from(t as Map);
      final name = token["name"] as String;
      final m = pathRe.firstMatch(token["path"] as String? ?? "");
      if (m == null) continue;
      final chain = int.parse(m.group(1)!);
      final index = int.parse(m.group(2)!);
      if (chain == 0) maxReceive = max(maxReceive, index);
      if (chain == 1) maxChange = max(maxChange, index);
      if (existing.contains(name)) continue;

      final address = await _deriveAddress(chain: chain, index: index);
      if (address.value != name) {
        Logging.instance.e(
          "PIVX: bridge address $name at ${token["path"]} does not match "
          "local derivation ${address.value}; ignoring",
        );
        continue;
      }
      toStore.add(address);
    }
    if (toStore.isNotEmpty) {
      await mainDB.updateOrPutAddresses(toStore);
    }

    // Next unused receiving address.
    final (storedReceive, storedChange) = await _highestStoredIndices();
    if (storedReceive <= maxReceive) {
      final next = await _deriveAddress(chain: 0, index: maxReceive + 1);
      await mainDB.updateOrPutAddresses([next]);
      await info.updateReceivingAddress(
        newAddress: next.value,
        isar: mainDB.isar,
      );
    }
    if (storedChange <= maxChange) {
      await mainDB.updateOrPutAddresses([
        await _deriveAddress(chain: 1, index: maxChange + 1),
      ]);
    }
  }

  // ===========================================================================
  // Sync

  @override
  Future<void> updateChainHeight() async {
    final height = await bridge.getBlockCount();
    await info.updateCachedChainHeight(newHeight: height, isar: mainDB.isar);
  }

  @override
  Future<bool> pingCheck() async {
    try {
      final status = await bridge.status();
      return status["backend"] != null;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> updateNode() async {
    _client = null;
    _clientKey = null;
    _stopWatching();
    await refresh();
  }

  // ===========================================================================
  // Live updates
  //
  // While auto sync is on, a long-poll on the bridge's `/api/v2/watch`
  // refreshes the wallet as soon as a block is indexed or a mempool tx
  // touches one of our transparent addresses. The base class's 150 s
  // timer stays as a fallback.

  int _watchGeneration = 0;
  bool _watching = false;

  @override
  Future<void> refresh() async {
    try {
      await super.refresh();
    } finally {
      _startWatching();
    }
  }

  @override
  Future<void> exit() async {
    _stopWatching();
    await super.exit();
  }

  void _startWatching() {
    if (_watching || !shouldAutoSync) return;
    _watching = true;
    unawaited(_watchLoop(++_watchGeneration));
  }

  void _stopWatching() {
    _watchGeneration++;
    _watching = false;
  }

  Future<void> _watchLoop(int generation) async {
    bool alive() => generation == _watchGeneration && shouldAutoSync;
    int height = info.cachedChainHeight;
    String? hash;
    int? seq;
    int failures = 0;
    try {
      while (alive()) {
        PivxBridgeWatch? r;
        try {
          final addresses = (await mainDB.getAddresses(walletId).findAll())
              .where((e) => e.type != AddressType.pivxShield)
              .map((e) => e.value)
              .toList();
          r = await bridge.watch(
            height: height,
            hash: hash,
            mempoolSeq: seq,
            addresses: addresses,
          );
          failures = 0;
        } on PivxBridgeException catch (e) {
          if (e.statusCode == 404 || e.statusCode == 405) {
            Logging.instance.w("PIVX: bridge has no /api/v2/watch; polling only");
            return;
          }
          failures++;
        } catch (e) {
          failures++;
          Logging.instance.d("PIVX: watch failed: $e");
        }
        if (r == null) {
          await Future<void>.delayed(
            Duration(seconds: min(60, 5 * (1 << min(failures, 4)))),
          );
          continue;
        }
        if (!alive()) return;
        height = r.height;
        hash = r.hash;
        seq = r.mempoolSeq;
        if (r.changed) {
          Logging.instance.i(
            "PIVX: bridge reports ${r.newBlock ? "block $height" : ""}"
            "${r.txids.isNotEmpty ? " txs ${r.txids}" : ""}"
            "${r.reset ? " reset" : ""}; refreshing",
          );
          await _refreshWhenIdle();
        }
      }
    } finally {
      if (generation == _watchGeneration) _watching = false;
    }
  }

  /// [refresh] skips when one is already running, which may have
  /// started before the change; wait for it, then refresh again.
  Future<void> _refreshWhenIdle() async {
    while (refreshMutex.isLocked) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    try {
      await refresh();
    } catch (_) {
      // Logged by refresh(); the loop keeps going.
    }
  }

  Future<int?> _historyFromHeight() async {
    final newest = await mainDB.isar.transactionV2s
        .where()
        .walletIdEqualTo(walletId)
        .filter()
        .heightIsNotNull()
        .heightGreaterThan(0)
        .sortByHeightDesc()
        .heightProperty()
        .findFirst();
    if (newest == null) return null;
    return max(0, newest - _kResyncDepth);
  }

  Future<({Set<String> receiving, Set<String> change, Set<String> all})>
  _addressSets() async {
    // Transparent only; shield addresses never appear in vin/vout.
    final addresses = (await mainDB.getAddresses(walletId).findAll())
        .where((e) => e.type != AddressType.pivxShield);
    final receiving = addresses
        .where((e) => e.subType == AddressSubType.receiving)
        .map((e) => e.value)
        .toSet();
    final change = addresses
        .where((e) => e.subType == AddressSubType.change)
        .map((e) => e.value)
        .toSet();
    return (receiving: receiving, change: change, all: {...receiving, ...change});
  }

  @override
  Future<void> updateTransactions() async {
    final xpub = await accountXpub;
    final result = await bridge.xpubHistory(
      xpub,
      from: await _historyFromHeight(),
      gap: await _bridgeGap(),
    );

    await _syncAddresses(result.info["tokens"] as List?);

    final sets = await _addressSets();
    final Map<String, Map<String, dynamic>> shieldInfo =
        _shieldSupported ? (await _loadShield()).txInfo : const {};
    final txns = <TransactionV2>[];
    for (final json in result.txs) {
      final tx = _parseTx(
        json,
        receiving: sets.receiving,
        change: sets.change,
        all: sets.all,
        shield: shieldInfo[json["txid"]],
      );
      if (tx != null) txns.add(tx);
    }
    await mainDB.updateOrPutTransactionV2s(txns);

    try {
      await _syncShield();
    } catch (e, s) {
      Logging.instance.e("PIVX shield sync failed", error: e, stackTrace: s);
      rethrow;
    }
  }

  TransactionV2? _parseTx(
    Map<String, dynamic> json, {
    required Set<String> receiving,
    required Set<String> change,
    required Set<String> all,
    Map<String, dynamic>? shield,
  }) {
    bool sentFromWallet = false;
    bool receivedInWallet = false;
    BigInt receivedAmount = BigInt.zero;
    BigInt changeAmount = BigInt.zero;

    final inputs = <InputV2>[];
    for (final v in (json["vin"] as List? ?? const [])) {
      final vin = Map<String, dynamic>.from(v as Map);
      final addrs = List<String>.from(vin["addresses"] as List? ?? const []);
      final owns = addrs.any(all.contains);
      sentFromWallet |= owns;
      final coinbase = vin["coinbase"] as String?;
      inputs.add(
        InputV2.isarCantDoRequiredInDefaultConstructor(
          scriptSigHex: null,
          scriptSigAsm: null,
          sequence: vin["sequence"] as int?,
          outpoint: coinbase != null
              ? null
              : OutpointV2.isarCantDoRequiredInDefaultConstructor(
                  txid: vin["txid"] as String,
                  vout: vin["vout"] as int,
                ),
          addresses: addrs,
          valueStringSats: vin["value"] as String? ?? "0",
          witness: null,
          innerRedeemScriptAsm: null,
          coinbase: coinbase,
          walletOwns: owns,
        ),
      );
    }

    // Shield notes this wallet spent (values from its nullifier map).
    for (final nf in (shield?["spentNullifiers"] as List?) ?? const []) {
      final note = _shield?.nullifierNotes[nf];
      sentFromWallet = true;
      inputs.add(
        InputV2.isarCantDoRequiredInDefaultConstructor(
          scriptSigHex: null,
          scriptSigAsm: null,
          sequence: null,
          outpoint: null,
          addresses: [note?["address"] as String? ?? ""],
          valueStringSats: "${note?["value"] ?? 0}",
          witness: null,
          innerRedeemScriptAsm: null,
          coinbase: null,
          walletOwns: true,
        ),
      );
    }

    final outputs = <OutputV2>[];
    BigInt totalOut = BigInt.zero;
    for (final v in (json["vout"] as List? ?? const [])) {
      final vout = Map<String, dynamic>.from(v as Map);
      final addrs = List<String>.from(vout["addresses"] as List? ?? const []);
      final value = BigInt.parse(vout["value"] as String? ?? "0");
      totalOut += value;
      bool owns = false;
      if (addrs.any(receiving.contains)) {
        owns = true;
        receivedAmount += value;
      } else if (addrs.any(change.contains)) {
        owns = true;
        changeAmount += value;
      }
      receivedInWallet |= owns;
      outputs.add(
        OutputV2.isarCantDoRequiredInDefaultConstructor(
          scriptPubKeyHex: vout["hex"] as String? ?? "",
          valueStringSats: value.toString(),
          addresses: addrs,
          walletOwns: owns,
        ),
      );
    }

    // Shield notes this wallet received.
    final receivedNotes = (shield?["received"] as List?) ?? const [];
    for (final n in receivedNotes) {
      final value = BigInt.from(((n as Map)["value"] as num).toInt());
      receivedInWallet = true;
      changeAmount += value;
      totalOut += value;
      outputs.add(
        OutputV2.isarCantDoRequiredInDefaultConstructor(
          scriptPubKeyHex: "",
          valueStringSats: value.toString(),
          addresses: [n["address"] as String],
          walletOwns: true,
        ),
      );
    }

    TransactionType type;
    if (sentFromWallet) {
      type = TransactionType.outgoing;
      // Shield outputs we could not decrypt belong to someone else.
      final shieldOutputs = json["shieldOutputs"] as int? ?? 0;
      if (receivedInWallet &&
          receivedAmount + changeAmount == totalOut &&
          shieldOutputs <= receivedNotes.length) {
        type = TransactionType.sentToSelf;
      }
    } else if (receivedInWallet) {
      type = TransactionType.incoming;
    } else {
      Logging.instance.w("PIVX: unrelated tx ${json["txid"]} ignored");
      return null;
    }

    final height = json["blockHeight"] as int? ?? -1;
    final txid = json["txid"] as String;
    return TransactionV2(
      walletId: walletId,
      blockHash: json["blockHash"] as String?,
      hash: txid,
      txid: txid,
      height: height > 0 ? height : null,
      version: json["version"] as int? ?? 1,
      timestamp: (json["blockTime"] as int?) ??
          DateTime.timestamp().millisecondsSinceEpoch ~/ 1000,
      inputs: List.unmodifiable(inputs),
      outputs: List.unmodifiable(outputs),
      type: type,
      subType: TransactionSubType.none,
      // Shield value is invisible in inputs/outputs, so the fee comes
      // from the bridge (transparent in + value balance - transparent out).
      otherData: jsonEncode({
        if (json["fees"] != null)
          TxV2OdKeys.overrideFee: Amount(
            rawValue: BigInt.parse(json["fees"] as String),
            fractionDigits: cryptoCurrency.fractionDigits,
          ).toJsonString(),
      }),
    );
  }

  /// Cold-stake (P2CS) script: `OP_DUP OP_HASH160 OP_ROT OP_IF
  /// OP_CHECKCOLDSTAKEVERIFY[_LOF] ...`. Spending it needs the owner
  /// flag in the scriptSig, so such outputs are frozen until staking
  /// support lands.
  final _blockHashes = <int, String>{};

  Future<String> _blockHashAt(int height) async =>
      _blockHashes[height] ??= await bridge.blockHash(height);

  static bool _isColdStakeScript(String hex) =>
      hex.startsWith("76a97b63d1") || hex.startsWith("76a97b63d2");

  @override
  Future<bool> updateUTXOs() async {
    final xpub = await accountXpub;
    final list = await bridge.utxo(xpub, gap: await _bridgeGap());

    final utxos = <UTXO>[];
    for (final u in list) {
      final txid = u["txid"] as String;
      final vout = u["vout"] as int;
      final confirmations = u["confirmations"] as int? ?? 0;
      final height = confirmations > 0 ? u["height"] as int? : null;

      bool blocked = false;
      String? blockedReason;
      final tx = await mainDB.isar.transactionV2s
          .where()
          .txidWalletIdEqualTo(txid, walletId)
          .findFirst();
      final out = tx?.outputs.length != null && vout < tx!.outputs.length
          ? tx.outputs[vout]
          : null;
      if (out != null && _isColdStakeScript(out.scriptPubKeyHex)) {
        blocked = true;
        blockedReason = "Delegated to a cold staker";
      }

      // UTXO.getConfirmations() treats a utxo without block hash or time
      // as unconfirmed, and the tx may not be stored yet (transactions
      // and utxos are fetched in parallel), so fill both from the bridge.
      String? blockHash;
      int? blockTime;
      if (height != null) {
        blockHash = tx?.blockHash ?? await _blockHashAt(height);
        blockTime = tx?.timestamp ??
            DateTime.timestamp().millisecondsSinceEpoch ~/ 1000;
      }

      utxos.add(
        UTXO(
          walletId: walletId,
          txid: txid,
          vout: vout,
          value: int.parse(u["value"] as String),
          name: "",
          isBlocked: blocked,
          blockedReason: blockedReason,
          isCoinbase: u["coinbase"] == true || u["coinstake"] == true,
          blockHash: blockHash,
          blockHeight: height,
          blockTime: blockTime,
          address: u["address"] as String?,
        ),
      );
    }
    return await _putUtxoRows(transparent: utxos);
  }

  /// [MainDB.updateUTXOs] replaces all of a wallet's rows, so write
  /// transparent outputs and shield notes together, keeping the stored
  /// rows of whichever kind is not given.
  Future<bool> _putUtxoRows({
    List<UTXO>? transparent,
    List<UTXO>? notes,
  }) => _utxoLock.protect(() async {
    final stored = await mainDB.getUTXOs(walletId).findAll();
    return await mainDB.updateUTXOs(walletId, [
      ...transparent ?? stored.where((u) => !isPivxShieldNote(u)),
      ...notes ?? stored.where(isPivxShieldNote),
    ]);
  });

  /// Shield notes count towards the private (secondary) balance only.
  @override
  bool ignoreUtxoInBalance(UTXO utxo) => isPivxShieldNote(utxo);

  @override
  Future<void> checkReceivingAddressForTransactions() async {
    // Handled by _syncAddresses() during updateTransactions(): the bridge
    // reports used addresses and the next unused one becomes current.
  }

  @override
  Future<void> checkChangeAddressForTransactions() async {}

  @override
  Future<void> recover({required bool isRescan}) async {
    await refreshMutex.protect(() async {
      if (isRescan) {
        await mainDB.deleteWalletBlockchainData(walletId);
      }
      await checkSaveInitialReceivingAddress();
      final (_, change) = await _highestStoredIndices();
      if (change < 0) {
        await mainDB.updateOrPutAddresses([
          await _deriveAddress(chain: 1, index: 0),
        ]);
      }
      await updateChainHeight();
      if (_shieldSupported) {
        await _resetShield(
          fromHeight: info.restoreHeight > 0
              ? info.restoreHeight
              : _defaultShieldRestoreHeight,
        );
      }
      await updateTransactions();
      await updateUTXOs();
      await updateBalance();
    });
  }

  @override
  Future<void> updateBalance() async {
    await super.updateBalance();
    await _updateShieldBalance();
  }

  // ===========================================================================
  // Shield (public API for the UI)

  bool get supportsShield => _shieldSupported;

  /// Current shield receiving address.
  Future<String?> getCurrentShieldAddress() async =>
      _shieldSupported ? (await _loadShield()).currentAddress : null;

  /// Generate and remember a fresh diversified shield address.
  Future<String> generateNewShieldAddress() async {
    final state = await _loadShield();
    final next = libPivxShield.nextAddress(
      extfvk: state.extfvk,
      diversifierIndex: state.diversifierIndex,
      isTestnet: state.isTestnet,
    );
    state
      ..diversifierIndex = next.diversifierIndex
      ..currentAddress = next.address;
    await state.save(walletId);
    await mainDB.updateOrPutAddresses([_shieldAddressRow(next)]);
    return next.address;
  }

  bool isShieldAddress(String address) =>
      libPivxShield.isAvailable &&
      libPivxShield.isValidAddress(address, isTestnet: _isTestnet);

  /// Height the shield scan has reached.
  Future<int?> get shieldSyncedHeight async =>
      _shieldSupported ? (await _loadShield()).lastProcessedBlock : null;

  /// Move the whole spendable transparent balance to this wallet's
  /// shield address (the fee is taken from the amount).
  Future<TxData> shieldAllTransparent() async {
    final state = await _loadShield();
    final amount = info.cachedBalance.spendable;
    if (amount <= Amount.zeroWith(fractionDigits: cryptoCurrency.fractionDigits)) {
      throw Exception("No transparent funds to shield");
    }
    final prepared = await prepareSend(
      txData: TxData(
        recipients: [
          TxRecipient(
            address: state.currentAddress,
            amount: amount,
            isChange: false,
            addressType: AddressType.pivxShield,
          ),
        ],
      ),
    );
    return confirmSend(txData: prepared);
  }

  /// Fee the shield library will charge (same rule as the Rust core:
  /// 1000 sat per estimated byte), choosing inputs the same way it does
  /// (smallest first until the amount plus fee is covered).
  Future<Amount> estimateShieldFee({
    required Amount amount,
    required bool fromShield,
    required bool toShield,
    Set<UTXO>? selected,
    bool subtractFee = false,
  }) async {
    int fee(int tIn, int tOut, int sIn, int sOut) =>
        1000 * (948 * sOut + 384 * sIn + 150 * tIn + 34 * tOut + 85);
    final target = amount.raw.toInt();
    final picked = TxData(
      utxos: selected?.map((e) => StandardInput(e)).toSet(),
    );
    final List<int> values;
    if (fromShield) {
      values = (await _notesToSpend(await _loadShield(), picked))
          .map((n) => (n["value"] as num).toInt())
          .toList();
    } else {
      values = _spendable(
        selected?.toList() ?? await mainDB.getUTXOs(walletId).findAll(),
        await chainHeight,
      ).map((u) => u.value).toList();
    }
    values.sort();
    final tOut = (toShield ? 0 : 1) + (fromShield ? 0 : 1);
    // A coin-control selection is spent in full.
    final useAll = selected?.isNotEmpty ?? false;
    int count = 0;
    int total = 0;
    int f = fee(0, tOut, 0, 2);
    for (final v in values) {
      count++;
      total += v;
      f = fromShield ? fee(0, tOut, count, 2) : fee(count, tOut, 0, 2);
      if (!useAll && total >= target + (subtractFee ? 0 : f)) break;
    }
    return Amount(
      rawValue: BigInt.from(f),
      fractionDigits: cryptoCurrency.fractionDigits,
    );
  }

  /// PIVX Core-style coin control figures for spending [selected]
  /// (all transparent outputs or all shield notes) to a transparent or
  /// shield recipient. [amount] is what the user is sending, if known.
  ({
    int quantity,
    Amount selected,
    int bytes,
    Amount fee,
    Amount afterFee,
    Amount? change,
  })
  coinControlSummary({
    required Iterable<UTXO> selected,
    required bool toShield,
    Amount? amount,
    bool subtractFee = false,
  }) {
    final count = selected.length;
    final fromShield = selected.any(isPivxShieldNote);
    final int bytes;
    final int fee;
    if (fromShield || toShield) {
      // Same estimate as the shield library: 1000 sat per byte; it always
      // budgets two shield outputs, plus a transparent recipient and/or
      // transparent change.
      final tOut = (toShield ? 0 : 1) + (fromShield ? 0 : 1);
      bytes = 948 * 2 +
          384 * (fromShield ? count : 0) +
          150 * (fromShield ? 0 : count) +
          34 * tOut +
          85;
      fee = bytes * 1000;
    } else {
      bytes = _estimateSize(count, const ["recipient", "change"]);
      fee = bytes * cryptoCurrency.minFeePerByte;
    }
    final total = selected.fold<int>(0, (p, u) => p + u.value);
    Amount a(int v) => Amount(
      rawValue: BigInt.from(v),
      fractionDigits: cryptoCurrency.fractionDigits,
    );
    return (
      quantity: count,
      selected: a(total),
      bytes: bytes,
      fee: a(fee),
      afterFee: a(total - fee),
      change: amount == null
          ? null
          : a(total - amount.raw.toInt() - (subtractFee ? 0 : fee)),
    );
  }

  /// Download (once, ~50 MB) and load the Sapling proving parameters.
  Future<void> prepareShieldProver({void Function(double)? onProgress}) =>
      _ensureProver(onProgress: onProgress);

  @override
  Future<void> recoverViewOnly() => recover(isRescan: false);

  // ===========================================================================
  // Fees

  @override
  Future<FeeObject> get fees async {
    // PIVX has no fee market in practice; every wallet pays the relay
    // minimum. Rates are sat per kB.
    final rate = BigInt.from(cryptoCurrency.minFeePerByte * 1000);
    return FeeObject(
      numberOfBlocksFast: 1,
      numberOfBlocksAverage: 1,
      numberOfBlocksSlow: 1,
      fast: rate,
      medium: rate,
      slow: rate,
    );
  }

  int _feePerByte(TxData txData, FeeObject feeObject) {
    int rate;
    if (txData.satsPerVByte != null) {
      rate = txData.satsPerVByte!;
    } else if (txData.feeRateType != null &&
        txData.feeRateType != FeeRateType.custom) {
      final perKb = switch (txData.feeRateType!) {
        FeeRateType.fast => feeObject.fast,
        FeeRateType.slow => feeObject.slow,
        _ => feeObject.medium,
      };
      rate = (perKb.toInt() / 1000).ceil();
    } else if (txData.feeRateAmount != null && txData.feeRateAmount! > BigInt.zero) {
      rate = (txData.feeRateAmount!.toInt() / 1000).ceil();
    } else {
      rate = cryptoCurrency.minFeePerByte;
    }
    return max(rate, cryptoCurrency.minFeePerByte);
  }

  int _estimateSize(int inputs, Iterable<String> outputAddresses) {
    int size = _kTxOverhead + inputs * _kP2pkhInput;
    for (final a in outputAddresses) {
      size += cryptoCurrency.isExchangeAddress(a) ? _kExchangeOutput : _kP2pkhOutput;
    }
    return size;
  }

  /// Spendable transparent outputs (shield note rows excluded).
  List<UTXO> _spendable(List<UTXO> utxos, int chainHeight) => utxos
      .where(
        (u) =>
            !isPivxShieldNote(u) &&
            !u.isBlocked &&
            u.used != true &&
            u.isConfirmed(
              chainHeight,
              cryptoCurrency.minConfirms,
              cryptoCurrency.minCoinbaseConfirms,
            ),
      )
      .toList();

  @override
  Future<Amount> estimateFeeFor(Amount amount, BigInt feeRate) async {
    final perByte = max((feeRate.toInt() / 1000).ceil(), cryptoCurrency.minFeePerByte);
    final utxos = _spendable(
      await mainDB.getUTXOs(walletId).findAll(),
      await chainHeight,
    )..sort((a, b) => b.value.compareTo(a.value));
    int inputs = 0;
    BigInt sum = BigInt.zero;
    for (final u in utxos) {
      inputs++;
      sum += BigInt.from(u.value);
      if (sum > amount.raw) break;
    }
    final size =
        _kTxOverhead + max(1, inputs) * _kP2pkhInput + 2 * _kP2pkhOutput;
    return Amount(
      rawValue: BigInt.from(size * perByte),
      fractionDigits: cryptoCurrency.fractionDigits,
    );
  }

  // ===========================================================================
  // Send

  coinlib.Address _parseAddress(String address) {
    if (cryptoCurrency.isExchangeAddress(address)) {
      return EXP2PKHAddress.fromString(address, cryptoCurrency.exAddressVersion);
    }
    final a = coinlib.Address.fromString(address, cryptoCurrency.networkParams);
    if (a is! coinlib.P2PKHAddress && a is! coinlib.P2SHAddress) {
      throw Exception("Unsupported PIVX address: $address");
    }
    return a;
  }

  @override
  Future<TxData> prepareSend({required TxData txData}) async {
    final recipients = txData.recipients;
    if (recipients == null || recipients.isEmpty) {
      throw Exception("No recipients in attempted transaction!");
    }
    final fromShield = _otherDataFlag(txData, kPivxFromShield);
    final subtractFee = _otherDataFlag(txData, kPivxSubtractFee);
    if (subtractFee && recipients.length != 1) {
      throw Exception("Subtracting the fee needs a single recipient");
    }
    if (fromShield || recipients.any((r) => isShieldAddress(r.address))) {
      if (!_shieldSupported) throw Exception("Shield is not available");
      return _prepareShieldSend(txData: txData, fromShield: fromShield);
    }
    for (final r in recipients) {
      if (!cryptoCurrency.validateAddress(r.address)) {
        throw Exception("Invalid PIVX address: ${r.address}");
      }
      if (r.amount.raw < cryptoCurrency.dustLimit.raw) {
        throw Exception("Amount is below the dust limit");
      }
    }

    final feePerByte = _feePerByte(txData, await fees);
    final currentHeight = await chainHeight;
    final coinControl = txData.utxos != null;

    final List<UTXO> candidates;
    if (coinControl) {
      candidates = txData.utxos!.whereType<StandardInput>().map((e) => e.utxo).toList();
      final usable = _spendable(candidates, currentHeight);
      if (usable.length != candidates.length) {
        throw Exception("Attempted to use an unavailable utxo");
      }
    } else {
      candidates = _spendable(
        await mainDB.getUTXOs(walletId).findAll(),
        currentHeight,
      )..sort((a, b) => b.value.compareTo(a.value));
    }

    final available = candidates.fold(BigInt.zero, (p, u) => p + BigInt.from(u.value));
    final target = recipients.fold(BigInt.zero, (p, r) => p + r.amount.raw);
    final isSendAll = recipients.length == 1 &&
        (coinControl
            ? target == available
            : target == info.cachedBalance.spendable.raw);
    // The recipient pays the fee: inputs only need to cover the amount.
    final feeFromAmount = isSendAll || subtractFee;

    if (target > available) {
      throw Exception("Insufficient balance");
    }

    // ---- choose inputs -----------------------------------------------------
    final selected = <UTXO>[];
    BigInt inSum = BigInt.zero;
    if (isSendAll || coinControl) {
      selected.addAll(candidates);
      inSum = available;
    } else {
      final addrs = recipients.map((e) => e.address).toList();
      for (final u in candidates) {
        selected.add(u);
        inSum += BigInt.from(u.value);
        final feeWithChange =
            BigInt.from(_estimateSize(selected.length, [...addrs, "change"]) * feePerByte);
        if (inSum >= target + (feeFromAmount ? BigInt.zero : feeWithChange)) {
          break;
        }
      }
    }

    // ---- outputs + fee ------------------------------------------------------
    final inputs = await _withKeys(selected);
    List<TxRecipient> outputs;
    BigInt fee;

    if (isSendAll) {
      fee = BigInt.from(_estimateSize(inputs.length, [recipients.first.address]) * feePerByte);
      final amount = inSum - fee;
      if (amount < cryptoCurrency.dustLimit.raw) {
        throw Exception("Insufficient balance to pay transaction fee");
      }
      outputs = [
        recipients.first.copyWith(
          amount: Amount(rawValue: amount, fractionDigits: cryptoCurrency.fractionDigits),
        ),
      ];
    } else if (subtractFee) {
      final recipient = recipients.first;
      final change = inSum - target;
      final withChange = change >= cryptoCurrency.dustLimit.raw;
      final sizeFee = BigInt.from(
        _estimateSize(inputs.length, [
          recipient.address,
          if (withChange) "change",
        ]) *
            feePerByte,
      );
      final amount = target - sizeFee;
      if (amount < cryptoCurrency.dustLimit.raw) {
        throw Exception("Amount is too small to pay the transaction fee");
      }
      outputs = [
        recipient.copyWith(
          amount: Amount(rawValue: amount, fractionDigits: cryptoCurrency.fractionDigits),
        ),
      ];
      if (withChange) {
        final changeAddress = (await getCurrentChangeAddress()) ??
            await _deriveAddress(chain: 1, index: 0);
        outputs.add(
          TxRecipient(
            address: changeAddress.value,
            amount: Amount(rawValue: change, fractionDigits: cryptoCurrency.fractionDigits),
            isChange: true,
            addressType: AddressType.p2pkh,
          ),
        );
        fee = sizeFee;
      } else {
        // Dust change is left to the fee.
        fee = sizeFee + change;
      }
    } else {
      final addrs = recipients.map((e) => e.address).toList();
      final feeNoChange = BigInt.from(_estimateSize(inputs.length, addrs) * feePerByte);
      final feeWithChange =
          BigInt.from(_estimateSize(inputs.length, [...addrs, "change"]) * feePerByte);
      if (inSum < target + feeNoChange) {
        throw Exception("Insufficient balance to pay transaction fee");
      }
      final change = inSum - target - feeWithChange;
      outputs = [...recipients];
      if (change >= cryptoCurrency.dustLimit.raw) {
        await checkChangeAddressForTransactions();
        final changeAddress = (await getCurrentChangeAddress()) ??
            await _deriveAddress(chain: 1, index: 0);
        outputs.add(
          TxRecipient(
            address: changeAddress.value,
            amount: Amount(rawValue: change, fractionDigits: cryptoCurrency.fractionDigits),
            isChange: true,
            addressType: AddressType.p2pkh,
          ),
        );
        fee = feeWithChange;
      } else {
        // Dust change is left to the fee.
        fee = inSum - target;
      }
    }

    final built = await _buildSigned(inputs: inputs, outputs: outputs, txData: txData);

    // Sizes above are upper bounds, so this only guards against bugs:
    // never broadcast below the relay minimum.
    final required = BigInt.from(built.size * cryptoCurrency.minFeePerByte);
    if (fee < required) {
      throw Exception("Fee estimate too low ($fee < $required); please retry");
    }

    return built.txData.copyWith(
      recipients: outputs,
      fee: Amount(rawValue: fee, fractionDigits: cryptoCurrency.fractionDigits),
      vSize: built.size,
      usedUTXOs: inputs,
    );
  }

  Future<List<StandardInput>> _withKeys(List<UTXO> utxos) async {
    final root = isViewOnly ? null : await getRootHDNode();
    if (root == null) throw Exception("View only wallets cannot sign");
    final result = <StandardInput>[];
    for (final u in utxos) {
      final address = await mainDB.getAddress(walletId, u.address!);
      if (address?.derivationPath == null) {
        throw Exception(
          "Failed to fetch signing data. Local db corrupt. Rescan wallet.",
        );
      }
      result.add(
        StandardInput(
          u,
          derivePathType: DerivePathType.bip44,
          key: root.derivePath(address!.derivationPath!.value),
        ),
      );
    }
    return result;
  }

  Future<({TxData txData, int size})> _buildSigned({
    required List<StandardInput> inputs,
    required List<TxRecipient> outputs,
    required TxData txData,
  }) async {
    const sequence = 0xffffffff;
    var tx = coinlib.Transaction(version: 1, inputs: [], outputs: []);

    final tempInputs = <InputV2>[];
    for (final input in inputs) {
      final prevOut = coinlib.OutPoint(
        Uint8List.fromList(input.utxo.txid.toUint8ListFromHex.reversed.toList()),
        input.utxo.vout,
      );
      tx = tx.addInput(
        coinlib.P2PKHInput(
          prevOut: prevOut,
          publicKey: input.key!.publicKey,
          sequence: sequence,
        ),
      );
      tempInputs.add(
        InputV2.isarCantDoRequiredInDefaultConstructor(
          scriptSigHex: null,
          scriptSigAsm: null,
          sequence: sequence,
          outpoint: OutpointV2.isarCantDoRequiredInDefaultConstructor(
            txid: input.utxo.txid,
            vout: input.utxo.vout,
          ),
          addresses: [input.utxo.address!],
          valueStringSats: input.utxo.value.toString(),
          witness: null,
          innerRedeemScriptAsm: null,
          coinbase: null,
          walletOwns: true,
        ),
      );
    }

    final own = (await mainDB.getAddresses(walletId).findAll())
        .map((e) => e.value)
        .toSet();
    final tempOutputs = <OutputV2>[];
    for (final o in outputs) {
      final address = _parseAddress(o.address);
      final output = coinlib.Output.fromAddress(o.amount.raw, address);
      tx = tx.addOutput(output);
      tempOutputs.add(
        OutputV2.isarCantDoRequiredInDefaultConstructor(
          scriptPubKeyHex: output.scriptPubKey.toHex,
          valueStringSats: o.amount.raw.toString(),
          addresses: [o.address],
          walletOwns: own.contains(o.address),
        ),
      );
    }

    for (int i = 0; i < inputs.length; i++) {
      tx = tx.signLegacy(inputN: i, key: inputs[i].key!.privateKey!);
    }

    final allToSelf = tempOutputs.every((e) => e.walletOwns);
    return (
      size: tx.size,
      txData: txData.copyWith(
        raw: tx.toHex(),
        txid: tx.txid,
        tempTx: TransactionV2(
          walletId: walletId,
          blockHash: null,
          hash: tx.txid,
          txid: tx.txid,
          height: null,
          timestamp: DateTime.timestamp().millisecondsSinceEpoch ~/ 1000,
          inputs: List.unmodifiable(tempInputs),
          outputs: List.unmodifiable(tempOutputs),
          version: 1,
          type: allToSelf ? TransactionType.sentToSelf : TransactionType.outgoing,
          subType: TransactionSubType.none,
          otherData: null,
        ),
      ),
    );
  }

  @override
  Future<TxData> confirmSend({required TxData txData}) async {
    if (txData.otherData != null &&
        (jsonDecode(txData.otherData!) as Map)[_kOdShieldTx] == true) {
      return _confirmShieldSend(txData);
    }
    try {
      final txid = await bridge.sendTx(txData.raw!);
      final used = txData.usedUTXOs!
          .whereType<StandardInput>()
          .map((e) => StandardInput(e.utxo.copyWith(used: true), derivePathType: e.derivePathType))
          .toList();
      await mainDB.putUTXOs(used.map((e) => e.utxo).toList());
      return await updateSentCachedTxData(
        txData: txData.copyWith(usedUTXOs: used, txid: txid, txHash: txid),
      );
    } catch (e, s) {
      Logging.instance.e("PIVX confirmSend failed", error: e, stackTrace: s);
      rethrow;
    }
  }
}
