import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:decimal/decimal.dart';
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
import '../../../networking/http.dart';
import '../../../utilities/amount/amount.dart';
import '../../../utilities/enums/derive_path_type_enum.dart';
import '../../../utilities/enums/fee_rate_type_enum.dart';
import '../../../utilities/extensions/extensions.dart';
import '../../../utilities/flutter_secure_storage_interface.dart';
import '../../../services/event_bus/events/global/refresh_percent_changed_event.dart';
import '../../../services/event_bus/global_event_bus.dart';
import '../../../services/tor_service.dart';
import '../../../utilities/logger.dart';
import '../../../utilities/stack_file_system.dart';
import '../../../utilities/ui_stall_watch.dart';
import '../../../wl_gen/interfaces/lib_pivx_shield_interface.dart';
import '../../api/pivx/pivx_bridge_client.dart';
import '../../crypto_currency/crypto_currency.dart';
import '../../models/tx_data.dart';
import '../../models/tx_recipient.dart';
import '../intermediate/bip39_hd_wallet.dart';
import '../wallet.dart';
import '../wallet_mixin_interfaces/coin_control_interface.dart';
import 'pivx/pivx_shield_state.dart';
import 'pivx/pivx_shield_stream.dart';
import 'pivx/pivx_tx_parser.dart';

part 'pivx/pivx_cold_staking.dart';
part 'pivx/pivx_governance.dart';
part 'pivx/pivx_masternodes.dart';
part 'pivx/pivx_wallet_shield.dart';

/// Which account of its recovery phrase a PIVX wallet is, in
/// [WalletInfo.otherData]. Most wallets are account 0; MyPIVXWallet's
/// "Add account" (and PIVXie's) makes accounts 1, 2, …, each a wallet of
/// its own with its own BIP44 account and shield account.
const kPivxAccountKey = "pivxAccount";

/// BIP44 path of [account] (`m/44'/119'/n'`), as MyPIVXWallet derives it.
String pivxAccountPath(Pivx coin, int account) => coin
    .constructDerivePath(
      derivePathType: DerivePathType.bip44,
      account: account,
      chain: 0,
      index: 0,
    )
    .replaceFirst(RegExp(r"/0/0$"), "");

/// Account-level xpub of [account], serialised with the network's
/// `pubHDPrefix`.
String pivxAccountXpub(coinlib.HDPrivateKey root, Pivx coin, int account) =>
    root
        .derivePath(pivxAccountPath(coin, account))
        .hdPublicKey
        .encode(coin.networkParams.pubHDPrefix);

/// The used accounts from [from] on, BIP44 style: looking stops after
/// [gap] unused accounts in a row, or [max] accounts (a bridge saying
/// every account is used can't add wallets without end). MyPIVXWallet
/// adds accounts one by one, so a skipped one or two is looked past.
Future<List<int>> pivxFindAccounts({
  required int from,
  required Future<bool> Function(int account) isUsed,
  int gap = 3,
  int max = 20,
}) async {
  final found = <int>[];
  for (int n = from, unused = 0; unused < gap && n < from + max; n++) {
    if (await isUsed(n)) {
      found.add(n);
      unused = 0;
    } else {
      unused++;
    }
  }
  return found;
}

/// Whether a bridge `/xpub` answer (any `details`) shows the account used.
bool pivxXpubIsUsed(Map<String, dynamic> json) =>
    (json["usedTokens"] as num? ?? 0) > 0 ||
    (json["txs"] as num? ?? 0) > 0 ||
    (json["unconfirmedTxs"] as num? ?? 0) > 0;

/// PIVX transparent wallet backed by pivx-bridge.
///
/// Sync works on the BIP44 account xpub like MyPIVXWallet: one `/xpub`
/// query returns the account's history and used addresses, `/utxo` its
/// spendable outputs.
///
/// The shield (Sapling) balance is kept as the wallet's secondary
/// balance; see `pivx/pivx_wallet_shield.dart`.
class PivxWallet extends Bip39HDWallet<Pivx> with CoinControlInterface<Pivx> {
  PivxWallet(CryptoCurrencyNetwork network) : super(Pivx(network));

  PivxShieldState? _shield;

  /// The first load of [_shield], which callers at the same time share:
  /// two loads would give two states, one overwriting the other's file.
  Future<PivxShieldState>? _shieldLoading;

  /// Remove what a PIVX wallet keeps outside the wallet tables: masternode
  /// private keys and the shield state file (its notes and history). For
  /// wallet deletion.
  static Future<void> deleteLocalData({
    required String walletId,
    required Map<String, dynamic> otherData,
    required SecureStorageInterface secureStorage,
  }) async {
    for (final id in pivxMasternodeIds(otherData)) {
      await secureStorage.delete(key: pivxMasternodeKeyName(walletId, id));
    }
    await PivxShieldState.delete(walletId);
  }

  /// Serialises writes of the wallet's UTXO rows (transparent outputs
  /// and shield notes share the table; see [_putUtxoRows]).
  final _utxoLock = Mutex();

  /// Blocks re-fetched below the newest confirmed tx on every sync, to
  /// pick up reorged / late-confirmed transactions.
  static const _kResyncDepth = 10;
  static const _kBridgeGap = 20;

  /// Bridge requests run at once when many are needed (previous
  /// transactions, history pages).
  static const _kParallelRequests = 6;

  /// Upper-bound serialized sizes (bytes) for fee estimation. A P2PKH
  /// input is 148 bytes, or 149 with a 73-byte DER signature.
  static const _kTxOverhead = 10;
  static const _kP2pkhInput = 149;
  static const _kP2pkhOutput = 34;
  static const _kExchangeOutput = 35;

  /// A cold staking input has one more byte (OP_FALSE); a cold staking
  /// output is value + script length + the 51-byte P2CS script.
  static const _kColdStakeInputExtra = 1;
  static const _kColdStakeOutput = 60;

  /// value + script length + OP_RETURN + push 32 + hash (proposal fee).
  static const _kOpReturnOutput = 43;

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

  /// Chain the bridge serves ("main", "test", "regtest"), once known.
  String? _bridgeChain;

  PivxBridgeClient get bridge {
    final node = getCurrentNode();
    // As the warning on opening the wallet says: such a node isn't used.
    if (prefs.useTor ? !node.torEnabled : !node.clearnetEnabled) {
      throw PivxBridgeException(
        prefs.useTor
            ? "This node is set to be used without Tor"
            : "This node is set to be used only over Tor",
      );
    }
    final key = "${node.host}|${node.port}|${node.useSSL}|${prefs.useTor}";
    if (_client == null || _clientKey != key) {
      _client?.close();
      _client = PivxBridgeClient.fromNode(node, prefs);
      _clientKey = key;
    }
    return _client!;
  }

  // ===========================================================================
  // Keys

  /// BIP39 seed. PBKDF2 (2048 rounds) is slow in Dart, so it runs on a
  /// background isolate instead of freezing the UI.
  Future<Uint8List> _seed() async {
    final mnemonic = await getMnemonic();
    final passphrase = await getMnemonicPassphrase();
    return Isolate.run(
      () => bip39.mnemonicToSeed(mnemonic, passphrase: passphrase),
    );
  }

  @override
  Future<coinlib.HDPrivateKey> getRootHDNode() async =>
      coinlib.HDPrivateKey.fromSeed(await _seed());

  /// This wallet's account of its recovery phrase ([kPivxAccountKey]).
  late final int account = info.otherData[kPivxAccountKey] as int? ?? 0;

  String? _accountXpub;
  coinlib.HDPublicKey? _accountKey;

  /// BIP44 account-level xpub (`m/44'/119'/n'`, see [pivxAccountXpub]).
  Future<String> get accountXpub async {
    if (_accountXpub != null) return _accountXpub!;
    if (isViewOnly) {
      final data = await getViewOnlyWalletData();
      if (data is! ExtendedKeysViewOnlyWalletData || data.xPubs.length != 1) {
        throw Exception("PIVX view only wallets need exactly one account xpub");
      }
      _accountXpub = data.xPubs.first.encoded;
    } else {
      _accountXpub = pivxAccountXpub(
        await getRootHDNode(),
        cryptoCurrency,
        account,
      );
    }
    return _accountXpub!;
  }

  Future<Address> _deriveAddress({
    required int chain,
    required int index,
  }) async {
    final path = cryptoCurrency.constructDerivePath(
      derivePathType: DerivePathType.bip44,
      account: account,
      chain: chain,
      index: index,
    );
    // Public derivation from the account key gives the same keys as the
    // full path, without re-deriving the seed (slow PBKDF2) per address.
    _accountKey ??= coinlib.HDPublicKey.decode(await accountXpub);
    final key = _accountKey!.derivePath("$chain/$index");
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

  /// Highest receiving index the bridge has reported as used.
  static const _kLastUsedReceive = "pivxLastUsedReceive";

  int get _lastUsedReceive => info.otherData[_kLastUsedReceive] as int? ?? -1;

  /// The receiving address after the newest one handed out, or null when
  /// it would be more than [_kBridgeGap] past the last used one: a wallet
  /// restored from the recovery phrase (here or in MPW) stops looking
  /// there, and wouldn't see payments to it. Change addresses don't count,
  /// they have their own chain.
  Future<Address?> _nextReceivingAddress() async {
    final current = await getCurrentReceivingAddress();
    final index = (current?.derivationIndex ?? -1) + 1;
    if (index > _lastUsedReceive + _kBridgeGap) return null;
    return await _deriveAddress(chain: 0, index: index);
  }

  @override
  Future<Address> generateNextReceivingAddress({
    required DerivePathType derivePathType,
  }) async {
    final address = await _nextReceivingAddress();
    if (address == null) throw Exception(pivxAddressGapMessage);
    return address;
  }

  // The base class derives these from account 0; a PIVX wallet uses its
  // own account (and its account xpub when it's watch only).

  @override
  Future<void> checkSaveInitialReceivingAddress() async {
    if (isViewOnly && viewOnlyType == ViewOnlyWalletType.addressOnly) return;
    if (await getCurrentReceivingAddress() != null) return;
    await mainDB.updateOrPutAddresses([
      await _deriveAddress(chain: 0, index: 0),
    ]);
  }

  @override
  Future<void> generateNewReceivingAddress() async {
    if (isViewOnly && viewOnlyType == ViewOnlyWalletType.addressOnly) return;
    final current = await getCurrentReceivingAddress();
    final address = await _deriveAddress(
      chain: 0,
      index: current == null ? 0 : current.derivationIndex + 1,
    );
    await mainDB.updateOrPutAddresses([address]);
    await info.updateReceivingAddress(
      newAddress: address.value,
      isar: mainDB.isar,
    );
  }

  @override
  Future<void> generateNewChangeAddress() async {
    if (isViewOnly && viewOnlyType == ViewOnlyWalletType.addressOnly) return;
    final current = await getCurrentChangeAddress();
    await mainDB.updateOrPutAddresses([
      await _deriveAddress(
        chain: 1,
        index: current == null ? 0 : current.derivationIndex + 1,
      ),
    ]);
  }

  /// Makes the next receiving address current and returns it; null when
  /// the last [_kBridgeGap] are all unused (see [_nextReceivingAddress]).
  Future<String?> generateNewTransparentAddress() async {
    final address = await _nextReceivingAddress();
    if (address == null) return null;
    await mainDB.updateOrPutAddresses([address]);
    await info.updateReceivingAddress(
      newAddress: address.value,
      isar: mainDB.isar,
    );
    return address.value;
  }

  /// Store the bridge's used addresses (`tokens`) and make sure the
  /// current receiving/change addresses are fresh ones.
  Future<void> _syncAddresses(List<dynamic>? tokens) async {
    final used = await pivxUsedAddresses(
      tokens: tokens ?? const [],
      stored: {
        for (final a in await mainDB.getAddresses(walletId).findAll())
          a.value: a,
      },
      derive: (chain, index) => _deriveAddress(chain: chain, index: index),
    );
    if (used.derived.isNotEmpty) {
      await mainDB.updateOrPutAddresses(used.derived);
    }
    final maxReceive = used.maxReceive;
    final maxChange = used.maxChange;
    if (maxReceive > _lastUsedReceive) {
      await info.updateOtherData(
        newEntries: {_kLastUsedReceive: maxReceive},
        isar: mainDB.isar,
      );
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
      final chain = (status["backend"] as Map?)?["chain"] as String?;
      if (chain != null) _bridgeChain = chain;
      if (status["backend"] == null) return false;
      // The bridge answers `/status` from its own index even when its node
      // is down; syncing needs the node.
      await bridge.getBlockCount();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The next request goes to the (new) node. Callers refresh the wallets
  /// that should sync; the others stay as they are.
  @override
  Future<void> updateNode() async {
    _client?.close();
    _client = null;
    _clientKey = null;
    _stopWatching();
    _noWatch = false;
  }

  // ===========================================================================
  // Live updates
  //
  // While auto sync is on, a long-poll on the bridge's `/watch`
  // refreshes the wallet as soon as a block is indexed or a mempool tx
  // touches one of our transparent addresses. The base class's 150 s
  // timer stays as a fallback.

  int _watchGeneration = 0;
  bool _watching = false;

  /// The bridge has no `/watch`: don't ask again until the node
  /// changes.
  bool _noWatch = false;

  @override
  Future<void> refresh() async {
    try {
      await UiStallWatch.run("PIVX ${info.name}: refresh", super.refresh);
      // Announce proposals whose fee is now confirmed (like PIVX Core's
      // wallet polls for them).
      if (pendingProposals.isNotEmpty) {
        unawaited(
          submitPendingProposals().catchError(
            (Object e) => Logging.instance.w("PIVX: proposals: $e"),
          ),
        );
      }
    } finally {
      _startWatching();
    }
  }

  @override
  Future<void> exit() async {
    _stopWatching();
    await super.exit();
    _client?.close();
    _client = null;
  }

  void _startWatching() {
    if (_watching || _noWatch || !shouldAutoSync) return;
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
    int refreshFailures = 0;
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
            Logging.instance.w("PIVX: bridge has no /watch; polling only");
            _noWatch = true;
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
          final took = await _refreshWhenIdle();
          refreshFailures = lastRefreshFailed ? refreshFailures + 1 : 0;
          if (!alive()) return;
          await Future<void>.delayed(
            _pauseAfterRefresh(took, failures: refreshFailures),
          );
        }
      }
    } finally {
      if (generation == _watchGeneration) _watching = false;
    }
  }

  /// [refresh] joins one already running, which may have started before
  /// the change: wait for it (or a rescan), then refresh again. Returns
  /// how long the refresh took.
  Future<Duration> _refreshWhenIdle() async {
    while (refreshMutex.isLocked) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final start = DateTime.now();
    try {
      await refresh();
    } catch (_) {
      // Logged by refresh(); the loop keeps going.
    }
    return DateTime.now().difference(start);
  }

  /// Pause between refreshes the long-poll triggers, so it can't keep the
  /// wallet syncing back to back: e.g. a bridge catching up on many
  /// blocks answers at each one, and a refresh slower than the block
  /// interval always finds a new block. As long as the refresh took
  /// (5 s to 1 min); after failed refreshes, 30 s doubling up to 5 min.
  /// Changes meanwhile are picked up by the next long-poll right away.
  static Duration _pauseAfterRefresh(Duration took, {required int failures}) {
    if (failures > 0) {
      return Duration(seconds: min(300, 30 * (1 << min(failures - 1, 4))));
    }
    return Duration(milliseconds: took.inMilliseconds.clamp(5000, 60000));
  }

  bool get _reparseHistory =>
      info.otherData[_kTxParseVersion] != _txParseVersion;

  Future<int?> _historyFromHeight() async {
    if (_reparseHistory) return null;
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

  Future<
    ({
      Set<String> receiving,
      Set<String> change,
      Set<String> all,
      Set<String> shield,
    })
  >
  _addressSets() async {
    final rows = await mainDB.getAddresses(walletId).findAll();
    // Shield addresses handed out (receive screen); notes to any other
    // of ours are change.
    final shield = rows
        .where((e) => e.type == AddressType.pivxShield)
        .map((e) => e.value)
        .toSet();
    // Transparent ones appear in vin/vout.
    final addresses = rows.where((e) => e.type != AddressType.pivxShield);
    final receiving = addresses
        .where((e) => e.subType == AddressSubType.receiving)
        .map((e) => e.value)
        .toSet();
    final change = addresses
        .where((e) => e.subType == AddressSubType.change)
        .map((e) => e.value)
        .toSet();
    return (
      receiving: receiving,
      change: change,
      all: {...receiving, ...change},
      shield: shield,
    );
  }

  /// Completes once [updateTransactions] has fetched the history, so
  /// [updateUTXOs] (run alongside it) can tell delegated outputs apart.
  Completer<void>? _historyFetched;

  /// Output scripts and blocks of the transactions the last history fetch
  /// returned.
  Map<String, ({List<String> scripts, String? blockHash, int? blockTime})>
  _historyTxs = const {};

  @override
  Future<void> updateTransactions() async {
    final fetched = _historyFetched = Completer<void>();
    try {
      await _updateTransactions(fetched);
    } finally {
      if (!fetched.isCompleted) fetched.complete();
    }
  }

  Future<void> _updateTransactions(Completer<void> fetched) async {
    _lastProgress = -1;
    _syncProgress(0);
    final xpub = await accountXpub;
    final result = await UiStallWatch.run(
      "PIVX ${info.name}: history",
      () async => bridge.xpubHistory(
        xpub,
        from: await _historyFromHeight(),
        gap: await _bridgeGap(),
      ),
    );
    _historyTxs = {
      for (final json in result.txs)
        json["txid"] as String: (
          scripts: pivxOutputScripts(json),
          blockHash: json["blockHash"] as String?,
          blockTime: json["blockTime"] as int?,
        ),
    };
    fetched.complete();

    await UiStallWatch.run(
      "PIVX ${info.name}: addresses",
      () => _syncAddresses(result.info["tokens"] as List?),
    );
    // The transparent history is one request: its share of the bar.
    _syncProgress(_shieldSupported ? 0.1 : 0.9);

    // Shield first: transparent txs with a shield side (shielding,
    // unshielding) are only classified right with the scan's data.
    try {
      await UiStallWatch.run("PIVX ${info.name}: shield sync", _syncShield);
    } catch (e, s) {
      Logging.instance.e("PIVX shield sync failed", error: e, stackTrace: s);
      rethrow;
    }

    final sets = await _addressSets();
    final coldStake = await _coldStakeOutpoints(result.txs);
    final txns = <TransactionV2>[
      for (final json in result.txs)
        ?_parseTx(json, sets: sets, isColdStakeOutpoint: coldStake),
    ];
    await UiStallWatch.run(
      "PIVX ${info.name}: store ${txns.length} txs",
      () => _storeTxs(txns),
    );
    try {
      await _checkUnconfirmed();
    } catch (e, s) {
      Logging.instance.w(
        "PIVX: checking unconfirmed transactions failed",
        error: e,
        stackTrace: s,
      );
    }
    _syncProgress(1);
    if (info.otherData[_kTxParseVersion] != _txParseVersion) {
      await info.updateOtherData(
        newEntries: {_kTxParseVersion: _txParseVersion},
        isar: mainDB.isar,
      );
    }
  }

  /// Bumped when parsing changes: the next sync re-parses all history.
  static const _kTxParseVersion = "pivxTxParseVersion";
  static const _txParseVersion = 1;

  /// The wallet's view of a bridge tx; see [parsePivxTx].
  TransactionV2? _parseTx(
    Map<String, dynamic> json, {
    required ({
      Set<String> receiving,
      Set<String> change,
      Set<String> all,
      Set<String> shield,
    })
    sets,
    required bool Function(OutpointV2 outpoint) isColdStakeOutpoint,
  }) => parsePivxTx(
    json,
    walletId: walletId,
    fractionDigits: cryptoCurrency.fractionDigits,
    receiving: sets.receiving,
    change: sets.change,
    shieldAddresses: sets.shield,
    shield: _shield?.txInfo[json["txid"]],
    nullifierNotes: _shield?.nullifierNotes ?? const {},
    isColdStakeOutpoint: isColdStakeOutpoint,
    masternodePayment: cryptoCurrency.masternodePaymentAt,
  );

  /// Tells cold-stake (P2CS) outputs apart while parsing [txs]: by the
  /// scripts of [txs] themselves (a delegation and its withdrawal may
  /// arrive in the same sync), else of the stored transactions, all read
  /// in one query.
  Future<bool Function(OutpointV2 outpoint)> _coldStakeOutpoints(
    List<Map<String, dynamic>> txs,
  ) async {
    final scripts = {
      for (final json in txs) json["txid"] as String: pivxOutputScripts(json),
    };
    final stored = await _storedTxs({
      for (final json in txs)
        for (final v in (json["vin"] as List? ?? const []))
          if ((v as Map)["txid"] case final String t
              when !scripts.containsKey(t))
            t,
    });
    return (OutpointV2 o) {
      final script =
          scripts[o.txid]?.elementAtOrNull(o.vout) ??
          stored[o.txid]?.outputs.elementAtOrNull(o.vout)?.scriptPubKeyHex;
      return script != null && pivxIsColdStakeScript(script);
    };
  }

  /// Store [txns] that are new or differ from the stored copy. Rewriting
  /// unchanged ones on every sync only makes the history list reload.
  Future<void> _storeTxs(List<TransactionV2> txns) async {
    final storedByTxid = await _storedTxs(txns.map((e) => e.txid));
    final changed = <TransactionV2>[];
    for (var tx in txns) {
      final stored = storedByTxid[tx.txid];
      if (stored != null && stored.isPivxOwnSend) {
        // Our own send: the bridge's unconfirmed view lacks its shield
        // side, so keep the entry we built until it confirms; then keep
        // the exact amount and change we built it with.
        if (tx.height == null) continue;
        // A burn (proposal fee) reads the same from the chain; older
        // entries may not have been labelled as one yet.
        if (tx.type == stored.type && tx.pivxKind != PivxTxKind.burn) {
          final od = {
            ...jsonDecode(tx.otherData ?? "{}") as Map<String, dynamic>,
          };
          final old = jsonDecode(stored.otherData!) as Map<String, dynamic>;
          for (final key in [
            TxV2OdKeys.pivxKind,
            TxV2OdKeys.pivxAmount,
            TxV2OdKeys.pivxChange,
          ]) {
            if (old.containsKey(key)) {
              od[key] = old[key];
            } else {
              od.remove(key);
            }
          }
          od[TxV2OdKeys.pivxOwnSend] = true;
          tx = tx.copyWith(otherData: jsonEncode(od));
        }
      }
      if (stored != null && tx.height == null && stored.height == null) {
        // Unconfirmed: keep when we first saw it (parsing uses "now").
        tx = tx.copyWith(timestamp: stored.timestamp);
      }
      if (stored == null || _txSignature(stored) != _txSignature(tx)) {
        changed.add(tx);
      }
    }
    await mainDB.updateOrPutTransactionV2s(changed);
  }

  /// Stored copies of [txids] (one query), by txid.
  Future<Map<String, TransactionV2>> _storedTxs(Iterable<String> txids) async {
    final ids = txids.toSet().toList();
    final rows = await mainDB.isar.transactionV2s.getAllByTxidWalletId(
      ids,
      List.filled(ids.length, walletId),
    );
    return {
      for (final t in rows)
        if (t != null) t.txid: t,
    };
  }

  static String _txSignature(TransactionV2 t) => [
    t.height,
    t.blockHash,
    t.timestamp,
    t.type.name,
    t.subType.name,
    t.otherData,
    for (final i in t.inputs)
      "${i.outpoint?.txid}:${i.outpoint?.vout}:${i.valueStringSats}:"
          "${i.addresses.join(",")}:${i.walletOwns}",
    for (final o in t.outputs)
      "${o.valueStringSats}:${o.addresses.join(",")}:${o.walletOwns}",
  ].join("|");

  // ===========================================================================
  // Unconfirmed transactions

  /// Unconfirmed transactions are checked with the bridge once this old.
  static const _kCheckUnconfirmedAfter = Duration(minutes: 5);

  /// One the network doesn't have, and this wallet can't send again (a
  /// payment received, or no raw transaction kept), is forgotten after
  /// this long.
  static const _kForgetUnknownAfter = Duration(hours: 1);

  /// Sends unconfirmed transactions of this wallet again when the network
  /// lost them (e.g. the bridge's node restarted), and forgets ones it no
  /// longer accepts (their coins spent elsewhere): they leave the history
  /// and their coins count again. Without this, a dropped send stayed
  /// pending forever, and its coins (shield notes above all) out of the
  /// balance.
  Future<void> _checkUnconfirmed() async {
    final now = DateTime.timestamp().millisecondsSinceEpoch ~/ 1000;
    final rows = await mainDB.isar.transactionV2s
        .where()
        .walletIdEqualTo(walletId)
        .filter()
        .heightIsNull()
        .sortByTimestamp()
        .findAll();
    // Oldest first: a parent goes out again before its child.
    final byTxid = {for (final t in rows) t.txid: t};
    final txids = {...byTxid.keys, ...?_shield?.pendingSpent.keys};
    for (final txid in txids) {
      final row = byTxid[txid];
      final age = row == null ? null : now - row.timestamp;
      if (age != null && age < _kCheckUnconfirmedAfter.inSeconds) continue;
      final raw = row?.pivxRawTx;
      if (await _stillOnNetwork(txid, raw: raw) != false) continue;
      if (raw == null && age != null && age < _kForgetUnknownAfter.inSeconds) {
        continue;
      }
      Logging.instance.w("PIVX: $txid is no longer on the network; forgot it");
      await _forgetUnconfirmed(txid, row);
    }
  }

  /// Whether unconfirmed [txid] is still on the network: true when the
  /// bridge's node has it or takes [raw] again, false when it doesn't
  /// have it and refuses [raw] (or there is none), null when that can't
  /// be told now (the bridge unreachable, ...).
  Future<bool?> _stillOnNetwork(String txid, {String? raw}) async {
    try {
      await bridge.tx(txid);
      return true;
    } on PivxBridgeException catch (e) {
      // Any other error (the node down, ...) tells nothing.
      if (e.statusCode != 404 || !e.message.contains("No such mempool")) {
        return null;
      }
    } catch (_) {
      return null;
    }
    if (raw == null) return false;
    try {
      await bridge.sendTx(raw);
      Logging.instance.i("PIVX: the network lost $txid; sent it again");
      return true;
    } on PivxBridgeException catch (e) {
      final reason = e.message;
      // "transaction already in block chain": confirmed meanwhile.
      if (reason.contains("already")) return true;
      if (e.statusCode != 400) return null;
      // A full mempool, its fee floor or a long chain of unconfirmed
      // parents may pass; a conflict or an invalid transaction won't.
      if (reason.contains("mempool") && !reason.contains("conflict")) {
        return null;
      }
      Logging.instance.w("PIVX: $txid refused: $reason");
      return false;
    } catch (_) {
      return null;
    }
  }

  /// Drop unconfirmed [txid] ([row] in the history, if any): its coins
  /// and shield notes become spendable again.
  Future<void> _forgetUnconfirmed(String txid, TransactionV2? row) async {
    if (row != null) {
      final spent = {
        for (final i in row.inputs)
          if (i.outpoint case final o?) pivxOutpointKey(o.txid, o.vout),
      };
      await _utxoLock.protect(() async {
        final freed = [
          for (final u in await mainDB.getUTXOs(walletId).findAll())
            if (u.used == true &&
                spent.contains(pivxOutpointKey(u.txid, u.vout)))
              u.copyWith(used: false),
        ];
        if (freed.isNotEmpty) await mainDB.putUTXOs(freed);
      });
      await mainDB.isar.writeTxn(
        () => mainDB.isar.transactionV2s.delete(row.id),
      );
    }
    final state = _shield;
    if (state == null) return;
    final nullifiers = state.pendingSpent.remove(txid);
    final incoming = state.pendingIncoming.remove(txid);
    if (nullifiers != null || incoming != null) {
      await state.save(walletId);
      await _writeShieldNoteRows(state);
    }
  }

  final _blockHashes = <int, String>{};

  Future<String> _blockHashAt(int height) async =>
      _blockHashes[height] ??= await bridge.blockHash(height);

  /// Script of output [vout] of [txid]: from the stored transaction, the
  /// history just fetched, or else the raw transaction.
  Future<String?> _outputScript(
    String txid,
    int vout,
    TransactionV2? stored,
  ) async {
    if (stored != null && vout < stored.outputs.length) {
      return stored.outputs[vout].scriptPubKeyHex;
    }
    final fetched = _historyTxs[txid]?.scripts;
    if (fetched != null && vout < fetched.length) return fetched[vout];
    try {
      final outputs = await _verifiedOutputs(txid);
      return vout < outputs.length ? outputs[vout].script.toHex : null;
    } catch (e) {
      Logging.instance.w("PIVX: no script for $txid:$vout: $e");
      return null;
    }
  }

  @override
  Future<bool> updateUTXOs() async {
    final xpub = await accountXpub;
    final list = await bridge.utxo(xpub, gap: await _bridgeGap());
    // Let the history arrive first: it has the scripts of new outputs.
    await _historyFetched?.future;
    final txs = await _storedTxs(list.map((u) => u["txid"] as String));

    final collaterals = _masternodeCollaterals;
    final stored = {
      for (final s in await mainDB.getUTXOs(walletId).findAll())
        pivxOutpointKey(s.txid, s.vout),
    };
    final utxos = <UTXO>[];
    for (final u in list) {
      final txid = u["txid"] as String;
      final vout = u["vout"] as int;
      final confirmations = u["confirmations"] as int? ?? 0;
      final height = confirmations > 0 ? u["height"] as int? : null;

      bool blocked = false;
      String? blockedReason;
      String? otherData;
      final tx = txs[txid];
      final script = await _outputScript(txid, vout, tx);
      if (script == null && !stored.contains(pivxOutpointKey(txid, vout))) {
        // A new coin that may be delegated, which must not be spent as an
        // ordinary one: it waits for the next sync to tell.
        continue;
      }
      final p2cs = script == null
          ? null
          : pivxParseColdStakeScript(script.toUint8ListFromHex);
      if (p2cs != null) {
        // Delegated: never picked automatically for a send.
        blocked = true;
        blockedReason = _kColdStakeFrozenReason;
        otherData = jsonEncode({
          kPivxColdStakerKey: pivxStakingAddress(
            p2cs.staker,
            cryptoCurrency.stakingAddressPrefix,
          ),
        });
      }
      if (collaterals.contains(pivxOutpointKey(txid, vout))) {
        blocked = true;
        blockedReason = _kMasternodeFrozenReason;
      }

      // UTXO.getConfirmations() treats a utxo without block hash or time
      // as unconfirmed, and the tx may not be stored yet (transactions
      // and utxos are fetched in parallel), so fill both from the bridge.
      String? blockHash;
      int? blockTime;
      if (height != null) {
        final fetched = _historyTxs[txid];
        blockHash =
            tx?.blockHash ?? fetched?.blockHash ?? await _blockHashAt(height);
        blockTime =
            tx?.timestamp ??
            fetched?.blockTime ??
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
          otherData: otherData,
        ),
      );
    }
    return await _putUtxoRows(transparent: utxos);
  }

  /// [MainDB.updateUTXOs] replaces all of a wallet's rows, so write
  /// transparent outputs and shield notes together, keeping the stored
  /// rows of whichever kind is not given.
  Future<bool> _putUtxoRows({List<UTXO>? transparent, List<UTXO>? notes}) =>
      _utxoLock.protect(() async {
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
      _recovering = true;
      _lastProgress = -1;
      try {
        await _recover(isRescan: isRescan);
      } finally {
        _recovering = false;
        _recoverCancelled = false;
      }
    });
    if (!doNotFireRefreshEvents) {
      GlobalEventBus.instance.fire(RefreshPercentChangedEvent(1, walletId));
    }
  }

  /// Set by [cancelRecover]: the running [recover] stops at the next
  /// batch of shield blocks.
  bool _recoverCancelled = false;

  /// Stop the [recover] running (the user cancelled a restore): a shield
  /// scan from the restore height can take long.
  void cancelRecover() => _recoverCancelled = true;

  Future<void> _recover({required bool isRescan}) async {
    // A rescan deletes the coin rows: the user's freezes, unfreezes and
    // coin names are put back on the coins found again.
    final kept = <String, UTXO>{};
    if (isRescan) {
      for (final u in await mainDB.getUTXOs(walletId).findAll()) {
        if (u.isBlocked || u.userUnfroze || u.name.isNotEmpty) {
          kept[pivxOutpointKey(u.txid, u.vout)] = u;
        }
      }
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
      await _resetShield(fromHeight: shieldRestoreHeight);
    }
    await updateTransactions();
    await updateUTXOs();
    if (kept.isNotEmpty) await _restoreUserCoinState(kept);
    await updateBalance();
  }

  /// The user's freezes, unfreezes and coin names, for a backup (see
  /// [restoreUserCoinFlags]).
  Future<List<Map<String, dynamic>>> userCoinFlags() async => [
    for (final u in await mainDB.getUTXOs(walletId).findAll())
      if (u.isBlocked || u.userUnfroze || u.name.isNotEmpty)
        pivxCoinFlagsToJson(u),
  ];

  /// Put the coin flags of a backup ([userCoinFlags]) back on the coins
  /// found again, e.g. once a restored wallet has synced.
  Future<void> restoreUserCoinFlags(List<dynamic> flags) async {
    final kept = pivxCoinFlagsFromJson(flags, walletId);
    if (kept.isEmpty) return;
    await _restoreUserCoinState(kept);
    await updateBalance();
  }

  Future<void> _restoreUserCoinState(Map<String, UTXO> kept) =>
      _utxoLock.protect(() async {
        final rows = <UTXO>[];
        for (final u in await mainDB.getUTXOs(walletId).findAll()) {
          final old = kept[pivxOutpointKey(u.txid, u.vout)];
          if (old == null) continue;
          rows.add(
            u.copyWith(
              // Frozen by the user, or unfrozen by the user after the
              // wallet froze it (the reason stays to tell).
              isBlocked: old.isBlocked || (u.isBlocked && !old.userUnfroze),
              blockedReason: old.blockedReason,
              name: old.name.isNotEmpty ? old.name : null,
            ),
          );
        }
        await mainDB.isar.writeTxn(() => mainDB.isar.utxos.putAll(rows));
      });

  // ===========================================================================
  // Sync progress

  /// Set while [recover] runs: progress then covers the whole 0-100 %
  /// (a rescan or restore has no refresh around it).
  bool _recovering = false;
  double _lastProgress = -1;

  /// Progress (0..1) of the history step: the bridge's transparent
  /// history, then the shield scan by block height. Throttled to whole
  /// percents.
  void _syncProgress(double fraction) {
    final f = fraction.clamp(0.0, 1.0);
    if (f < 1 && (f - _lastProgress).abs() < 0.01) return;
    _lastProgress = f;
    if (!_recovering) {
      reportSyncProgress(f);
    } else if (!doNotFireRefreshEvents) {
      GlobalEventBus.instance.fire(
        RefreshPercentChangedEvent(0.05 + 0.9 * f, walletId),
      );
    }
  }

  /// Like the default, but delegated outputs never count as spendable,
  /// even when unfrozen in coin control: sends never pick them by
  /// themselves.
  @override
  Future<void> updateBalance() async {
    final utxos = await mainDB.getUTXOs(walletId).findAll();
    final height = await chainHeight;
    final collaterals = _masternodeCollaterals;
    var total = BigInt.zero;
    var spendable = BigInt.zero;
    var pending = BigInt.zero;
    var blocked = BigInt.zero;
    for (final u in utxos) {
      if (ignoreUtxoInBalance(u)) continue;
      final value = BigInt.from(u.value);
      total += value;
      // Delegated coins and masternode collateral are never spent by an
      // ordinary send, even when unfrozen.
      if (u.isBlocked ||
          isPivxColdStakeUtxo(u) ||
          collaterals.contains(pivxOutpointKey(u.txid, u.vout))) {
        blocked += value;
      } else if (u.isConfirmed(
        height,
        cryptoCurrency.minConfirms,
        cryptoCurrency.minCoinbaseConfirms,
      )) {
        spendable += value;
      } else {
        pending += value;
      }
    }
    Amount amount(BigInt v) =>
        Amount(rawValue: v, fractionDigits: cryptoCurrency.fractionDigits);
    await info.updateBalance(
      newBalance: Balance(
        total: amount(total),
        spendable: amount(spendable),
        blockedTotal: amount(blocked),
        pendingSpendable: amount(pending),
      ),
      isar: mainDB.isar,
    );
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

  /// Where a restore starts the shield scan: the restore height, or the
  /// shield launch when there's none.
  int get shieldRestoreHeight => info.restoreHeight > 0
      ? info.restoreHeight
      : (_isTestnet ? 0 : _kMainnetDefaultShieldStart);

  /// The other accounts of this wallet's recovery phrase, after this one,
  /// that have been used: what restoring the phrase brings back. Only the
  /// transparent side is looked at (a shield-only account takes a full
  /// shield scan to find).
  Future<List<int>> findUsedAccounts() async {
    final root = await getRootHDNode();
    return pivxFindAccounts(
      from: account + 1,
      isUsed: (n) async => pivxXpubIsUsed(
        await bridge.xpub(
          pivxAccountXpub(root, cryptoCurrency, n),
          details: "basic",
          gap: _kBridgeGap,
        ),
      ),
    );
  }

  /// A wallet made in the app has no history before now: remember the tip
  /// as its birthday. The shield scan starts there, and so do a rescan and
  /// a restore from a backup (instead of the shield launch).
  Future<void> recordBirthday() async {
    if (info.restoreHeight > 0) return;
    try {
      final tip = await bridge.getBlockCount();
      if (tip > 0) {
        await info.updateRestoreHeight(
          newRestoreHeight: tip,
          isar: mainDB.isar,
        );
      }
    } catch (e) {
      Logging.instance.w("PIVX: wallet birthday not recorded: $e");
    }
  }

  /// Height the shield scan has reached.
  Future<int?> get shieldSyncedHeight async =>
      _shieldSupported ? (await _loadShield()).lastProcessedBlock : null;

  /// Move the whole spendable transparent balance to this wallet's
  /// shield address (the fee is taken from the amount).
  Future<TxData> shieldAllTransparent() async {
    final state = await _loadShield();
    final amount = info.cachedBalance.spendable;
    if (amount <=
        Amount.zeroWith(fractionDigits: cryptoCurrency.fractionDigits)) {
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
        // Privatize moves everything; the fee comes out of it.
        otherData: jsonEncode({kPivxSubtractFee: true}),
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
      values = (await _notesToSpend(
        await _loadShield(),
        picked,
      )).map((n) => (n["value"] as num).toInt()).toList();
    } else {
      values = _spendable(
        selected?.toList() ?? await mainDB.getUTXOs(walletId).findAll(),
        await chainHeight,
        collateral: selected != null,
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
      bytes =
          948 * 2 +
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
    } else if (txData.feeRateAmount != null &&
        txData.feeRateAmount! > BigInt.zero) {
      rate = (txData.feeRateAmount!.toInt() / 1000).ceil();
    } else {
      rate = cryptoCurrency.minFeePerByte;
    }
    return max(rate, cryptoCurrency.minFeePerByte);
  }

  int _estimateSize(
    int inputs,
    Iterable<String> outputAddresses, {
    int coldStakeInputs = 0,
  }) {
    int size =
        _kTxOverhead +
        inputs * _kP2pkhInput +
        coldStakeInputs * _kColdStakeInputExtra;
    for (final a in outputAddresses) {
      size += a.startsWith(kPivxOpReturnPrefix)
          ? _kOpReturnOutput
          : cryptoCurrency.isExchangeAddress(a)
          ? _kExchangeOutput
          : isStakingAddress(a)
          ? _kColdStakeOutput
          : _kP2pkhOutput;
    }
    return size;
  }

  /// Spendable transparent outputs (shield note rows excluded).
  /// Delegated outputs only when [coldStake], masternode collateral only
  /// when [collateral] (both: picked by the user).
  List<UTXO> _spendable(
    List<UTXO> utxos,
    int chainHeight, {
    bool coldStake = false,
    bool collateral = false,
  }) => pivxSpendable(
    utxos,
    chainHeight: chainHeight,
    minConfirms: cryptoCurrency.minConfirms,
    minCoinbaseConfirms: cryptoCurrency.minCoinbaseConfirms,
    collaterals: _masternodeCollaterals,
    coldStake: coldStake,
    collateral: collateral,
  );

  @override
  Future<Amount> estimateFeeFor(Amount amount, BigInt feeRate) async {
    final perByte = max(
      (feeRate.toInt() / 1000).ceil(),
      cryptoCurrency.minFeePerByte,
    );
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

  /// Where transparent change goes: the address the user picked on the
  /// send screen ([kPivxChangeAddress]) or the wallet's next change
  /// address.
  Future<String> _transparentChangeAddress(TxData txData) async {
    final custom = txData.otherData == null
        ? null
        : (jsonDecode(txData.otherData!) as Map)[kPivxChangeAddress] as String?;
    if (custom != null && custom.isNotEmpty) {
      if (!cryptoCurrency.isTransparentAddress(custom)) {
        throw Exception("Change must go to a transparent PIVX address");
      }
      return custom;
    }
    return ((await getCurrentChangeAddress()) ??
            await _deriveAddress(chain: 1, index: 0))
        .value;
  }

  coinlib.Address _parseAddress(String address) {
    if (cryptoCurrency.isExchangeAddress(address)) {
      return EXP2PKHAddress.fromString(
        address,
        cryptoCurrency.exAddressVersion,
      );
    }
    final a = coinlib.Address.fromString(address, cryptoCurrency.networkParams);
    if (a is! coinlib.P2PKHAddress && a is! coinlib.P2SHAddress) {
      throw Exception("Unsupported PIVX address: $address");
    }
    return a;
  }

  /// The output of a recipient that isn't a plain address: a proposal
  /// fee (OP_RETURN, burnt) or a delegation to a staker (a cold staking
  /// script owned by the owner address in [txData], one of [own]). Null
  /// for addresses.
  ({Uint8List script, List<String> addresses, bool ours})? _specialOutput(
    TxData txData,
    String address,
    Set<String> own,
  ) {
    if (address.startsWith(kPivxOpReturnPrefix)) {
      return (
        script: pivxProposalFeeScript(
          address.substring(kPivxOpReturnPrefix.length),
        ),
        addresses: const [],
        ours: false,
      );
    }
    final stakerHash = pivxStakingAddressHash(
      address,
      cryptoCurrency.stakingAddressPrefix,
    );
    if (stakerHash == null) return null;
    final ownerAddress = _coldStakeOwner(txData);
    final owner = ownerAddress == null ? null : _parseAddress(ownerAddress);
    if (owner is! coinlib.P2PKHAddress || !own.contains(ownerAddress)) {
      throw Exception("The owner must be an address of this wallet");
    }
    return (
      script: pivxColdStakeScript(
        stakerHash: stakerHash,
        ownerHash: owner.hash,
      ),
      addresses: [address, ownerAddress!],
      ours: true,
    );
  }

  /// Owner address of the delegation [txData] makes, if any.
  static String? _coldStakeOwner(TxData txData) => txData.otherData == null
      ? null
      : (jsonDecode(txData.otherData!) as Map)[kPivxColdStakeOwner] as String?;

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
    final coldStakeOwner = _coldStakeOwner(txData);
    for (final r in recipients) {
      // A proposal fee: OP_RETURN with the proposal hash.
      if (r.address.startsWith(kPivxOpReturnPrefix)) {
        if (r.address.length != kPivxOpReturnPrefix.length + 64) {
          throw Exception("Invalid OP_RETURN output");
        }
        continue;
      }
      // A delegation: cold staking output to this staker.
      if (isStakingAddress(r.address)) {
        if (coldStakeOwner == null) {
          throw Exception("Staker addresses are only for delegating");
        }
        if (r.amount.raw < BigInt.from(kPivxMinDelegationSats)) {
          throw Exception(
            "A delegation must be at least 1 ${cryptoCurrency.ticker}",
          );
        }
        continue;
      }
      if (!cryptoCurrency.validateAddress(r.address)) {
        throw Exception("Invalid PIVX address: ${r.address}");
      }
      if (isShieldAddress(r.address)) continue;
      if (r.amount.raw < cryptoCurrency.dustLimit.raw) {
        throw Exception("Amount is below the dust limit");
      }
    }
    if (fromShield || recipients.any((r) => isShieldAddress(r.address))) {
      if (!_shieldSupported) throw Exception("Shield is not available");
      return _prepareShieldSend(txData: txData, fromShield: fromShield);
    }

    final feePerByte = _feePerByte(txData, await fees);
    final currentHeight = await chainHeight;
    final coinControl = txData.utxos != null;

    final List<UTXO> candidates;
    if (coinControl) {
      candidates = txData.utxos!
          .whereType<StandardInput>()
          .map((e) => e.utxo)
          .toList();
      final usable = _spendable(
        candidates,
        currentHeight,
        coldStake: true,
        collateral: true,
      );
      if (usable.length != candidates.length) {
        throw Exception("Attempted to use an unavailable utxo");
      }
    } else {
      candidates = _spendable(
        await mainDB.getUTXOs(walletId).findAll(),
        currentHeight,
      )..sort((a, b) => b.value.compareTo(a.value));
    }

    final available = candidates.fold(
      BigInt.zero,
      (p, u) => p + BigInt.from(u.value),
    );
    final target = recipients.fold(BigInt.zero, (p, r) => p + r.amount.raw);
    // The fee is only ever taken out of the amount when the user asked
    // for it ("Subtract fee from amount"); spending the whole balance
    // without it fails with insufficient funds.
    final feeFromAmount = subtractFee;

    if (target > available) {
      throw Exception("Insufficient balance");
    }

    // ---- choose inputs -----------------------------------------------------
    final selected = <UTXO>[];
    BigInt inSum = BigInt.zero;
    if (coinControl) {
      selected.addAll(candidates);
      inSum = available;
    } else {
      final addrs = recipients.map((e) => e.address).toList();
      for (final u in candidates) {
        selected.add(u);
        inSum += BigInt.from(u.value);
        final feeWithChange = BigInt.from(
          _estimateSize(selected.length, [...addrs, "change"]) * feePerByte,
        );
        if (inSum >= target + (feeFromAmount ? BigInt.zero : feeWithChange)) {
          break;
        }
      }
    }

    // ---- outputs + fee ------------------------------------------------------
    final inputs = await _withKeys(selected, coldStake: coinControl);
    final cold = selected.where(isPivxColdStakeUtxo).length;
    List<TxRecipient> outputs;
    BigInt fee;

    if (subtractFee) {
      final recipient = recipients.first;
      final change = inSum - target;
      final withChange = change >= cryptoCurrency.dustLimit.raw;
      final sizeFee = BigInt.from(
        _estimateSize(inputs.length, [
              recipient.address,
              if (withChange) "change",
            ], coldStakeInputs: cold) *
            feePerByte,
      );
      final amount = target - sizeFee;
      if (amount < cryptoCurrency.dustLimit.raw) {
        throw Exception("Amount is too small to pay the transaction fee");
      }
      if (isStakingAddress(recipient.address) &&
          amount < BigInt.from(kPivxMinDelegationSats)) {
        throw Exception(
          "A delegation must be at least 1 ${cryptoCurrency.ticker} "
          "after the fee",
        );
      }
      outputs = [
        recipient.copyWith(
          amount: Amount(
            rawValue: amount,
            fractionDigits: cryptoCurrency.fractionDigits,
          ),
        ),
      ];
      if (withChange) {
        final changeAddress = await _transparentChangeAddress(txData);
        outputs.add(
          TxRecipient(
            address: changeAddress,
            amount: Amount(
              rawValue: change,
              fractionDigits: cryptoCurrency.fractionDigits,
            ),
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
      final feeNoChange = BigInt.from(
        _estimateSize(inputs.length, addrs, coldStakeInputs: cold) * feePerByte,
      );
      final feeWithChange = BigInt.from(
        _estimateSize(inputs.length, [
              ...addrs,
              "change",
            ], coldStakeInputs: cold) *
            feePerByte,
      );
      if (inSum < target + feeNoChange) {
        throw Exception(
          "Insufficient funds to pay the transaction fee. Lower the amount "
          "or tick \"Subtract fee from amount\".",
        );
      }
      final change = inSum - target - feeWithChange;
      outputs = [...recipients];
      if (change >= cryptoCurrency.dustLimit.raw) {
        await checkChangeAddressForTransactions();
        final changeAddress = await _transparentChangeAddress(txData);
        outputs.add(
          TxRecipient(
            address: changeAddress,
            amount: Amount(
              rawValue: change,
              fractionDigits: cryptoCurrency.fractionDigits,
            ),
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

    final built = await _buildSigned(
      inputs: inputs,
      outputs: outputs,
      txData: txData,
    );

    // Sizes above are upper bounds, so this only guards against bugs:
    // never broadcast below the relay minimum.
    final required = BigInt.from(built.size * cryptoCurrency.minFeePerByte);
    if (fee < required) {
      throw Exception("Fee estimate too low ($fee < $required); please retry");
    }

    // Change to an address outside the wallet leaves it like the payment.
    final change = outputs.where((o) => o.isChange).firstOrNull;
    var otherData = built.txData.otherData;
    if (change != null &&
        await mainDB.getAddress(walletId, change.address) == null) {
      otherData = _withForeignChange(
        otherData,
        change.address,
        change.amount.raw,
      );
    }

    return built.txData.copyWith(
      recipients: outputs,
      fee: Amount(rawValue: fee, fractionDigits: cryptoCurrency.fractionDigits),
      vSize: built.size,
      usedUTXOs: inputs,
      otherData: otherData,
    );
  }

  /// Outputs of previous transactions, checked against their txids.
  final _prevOuts = <String, List<PivxRawOutput>>{};

  Future<List<PivxRawOutput>> _verifiedOutputs(String txid) async =>
      _prevOuts[txid] ??= pivxVerifiedOutputs(txid, await bridge.rawTx(txid));

  /// Transparent signatures don't commit to the values they spend, so a
  /// bridge reporting a lower value than the real one would turn the
  /// difference into fee. Check each input against its previous
  /// transaction, which must hash to its txid. Its script also tells how
  /// to sign it (P2PKH or cold staking).
  Future<void> _verifyInputValues(List<UTXO> utxos) async {
    // The previous transactions, a few requests at a time.
    final txids = {for (final u in utxos) u.txid}.toList();
    for (var i = 0; i < txids.length; i += _kParallelRequests) {
      await Future.wait(
        txids.skip(i).take(_kParallelRequests).map(_verifiedOutputs),
      );
    }
    for (final u in utxos) {
      final outputs = _prevOuts[u.txid]!;
      if (u.vout >= outputs.length ||
          outputs[u.vout].value != BigInt.from(u.value)) {
        throw Exception(
          "The server reported a wrong value for ${u.txid}:${u.vout}; "
          "not signing",
        );
      }
    }
  }

  /// Verified script of the output [u] spends.
  Uint8List _prevScript(UTXO u) => _prevOuts[u.txid]![u.vout].script;

  /// Keys for [utxos], from [root] (else derived from the seed).
  /// Delegated outputs only when [coldStake]: the user picked them.
  ///
  /// With [verifyValues] (legacy signatures, which don't commit to the
  /// value spent), each value is checked against its previous transaction
  /// first; that also tells delegated outputs apart by their script.
  Future<List<StandardInput>> _withKeys(
    List<UTXO> utxos, {
    bool coldStake = false,
    coinlib.HDPrivateKey? root,
    bool verifyValues = true,
  }) async {
    if (isViewOnly) throw Exception("View only wallets cannot sign");
    root ??= await getRootHDNode();
    if (verifyValues) await _verifyInputValues(utxos);
    if (verifyValues &&
        !coldStake &&
        utxos.any((u) => pivxParseColdStakeScript(_prevScript(u)) != null)) {
      throw Exception(
        "Delegated coins are only spent when you pick them; please retry",
      );
    }
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
    var coldInputs = false;

    final tempInputs = <InputV2>[];
    for (final input in inputs) {
      final prevOut = coinlib.OutPoint(
        Uint8List.fromList(
          input.utxo.txid.toUint8ListFromHex.reversed.toList(),
        ),
        input.utxo.vout,
      );
      final script = _prevScript(input.utxo);
      final p2cs = pivxParseColdStakeScript(script);
      if (p2cs != null) {
        // Owner spend: the key must be the script's owner.
        final hash = coinlib.hash160(input.key!.publicKey.data);
        if (hash.toHex != p2cs.owner.toHex) {
          throw Exception(
            "Not the owner of delegated output ${input.utxo.txid}",
          );
        }
        coldInputs = true;
      }
      tx = tx.addInput(
        p2cs != null
            ? PivxColdStakeInput(
                prevOut: prevOut,
                publicKey: input.key!.publicKey,
                prevScript: script,
                sequence: sequence,
              )
            : coinlib.P2PKHInput(
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
      final special = _specialOutput(txData, o.address, own);
      final output = special != null
          ? coinlib.Output.fromScriptBytes(o.amount.raw, special.script)
          : coinlib.Output.fromAddress(o.amount.raw, _parseAddress(o.address));
      tx = tx.addOutput(output);
      tempOutputs.add(
        OutputV2.isarCantDoRequiredInDefaultConstructor(
          scriptPubKeyHex: output.scriptPubKey.toHex,
          valueStringSats: o.amount.raw.toString(),
          addresses: special?.addresses ?? [o.address],
          walletOwns: special?.ours ?? own.contains(o.address),
        ),
      );
    }

    for (int i = 0; i < inputs.length; i++) {
      tx = tx.signLegacy(inputN: i, key: inputs[i].key!.privateKey!);
    }
    final raw = tx.toHex();

    // Pending history entry, classified like confirmed ones.
    final changeAddresses = {
      for (final o in outputs)
        if (o.isChange) o.address,
    };
    final fee =
        tempInputs.fold(BigInt.zero, (p, e) => p + e.value) -
        tempOutputs.fold(BigInt.zero, (p, e) => p + e.value);
    final c = classifyPivxTx(
      inputs: tempInputs,
      outputs: tempOutputs,
      changeAddresses: changeAddresses,
      fee: fee,
      spendsColdStake: coldInputs,
    )!;
    return (
      size: tx.size,
      txData: txData.copyWith(
        raw: raw,
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
          type: c.type,
          subType: TransactionSubType.none,
          otherData: jsonEncode(
            pivxTxOtherData(
              c: c,
              fractionDigits: cryptoCurrency.fractionDigits,
              changeAddresses: changeAddresses,
              fee: fee,
              ownSend: true,
              rawTx: raw,
            ),
          ),
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
    final String txid;
    try {
      txid = await bridge.sendTx(txData.raw!);
    } catch (e, s) {
      Logging.instance.e("PIVX confirmSend failed", error: e, stackTrace: s);
      rethrow;
    }
    // Sent: what follows only records it. An error here must not read
    // as a failed send, or the user would pay again.
    final used = txData.usedUTXOs!
        .whereType<StandardInput>()
        .map(
          (e) => StandardInput(
            e.utxo.copyWith(used: true),
            derivePathType: e.derivePathType,
          ),
        )
        .toList();
    final sent = txData.copyWith(usedUTXOs: used, txid: txid, txHash: txid);
    try {
      await _utxoLock.protect(
        () => mainDB.putUTXOs(used.map((e) => e.utxo).toList()),
      );
      return await updateSentCachedTxData(txData: sent);
    } catch (e, s) {
      Logging.instance.e(
        "PIVX: $txid sent, but recording it failed",
        error: e,
        stackTrace: s,
      );
      return sent;
    }
  }
}

/// What deleting [wallet] loses that its recovery phrase doesn't bring
/// back; null when nothing.
String? pivxDeleteWarning(Wallet wallet) {
  if (wallet is! PivxWallet) return null;
  final warnings = [
    if (wallet.masternodes.isNotEmpty)
      "This wallet's masternode keys aren't part of the recovery phrase. "
          "Note them first (in each masternode's details), or you'll have "
          "to set the masternodes up again.",
    if (wallet.pendingProposals.any((p) => p.error == null))
      "Proposals still waiting to be submitted will be lost, along with "
          "the fees already paid for them.",
  ];
  return warnings.isEmpty ? null : warnings.join("\n\n");
}

/// Why "New address" gave none: see [PivxWallet.generateNewTransparentAddress].
const pivxAddressGapMessage =
    "You already have 20 unused addresses. Use one of them first: a wallet "
    "restored from the recovery phrase only looks 20 addresses past the "
    "last used one.";

/// Chain (0 receiving, 1 change) and index of a bridge token path such as
/// `m/44'/119'/0'/0/5`; null for any other path.
({int chain, int index})? pivxTokenPath(String? path) {
  final m = RegExp(r"/([01])/(\d{1,10})$").firstMatch(path ?? "");
  if (m == null) return null;
  final index = int.parse(m.group(2)!);
  // Hardened indices can't be derived from the account xpub.
  if (index >= 0x80000000) return null;
  return (chain: int.parse(m.group(1)!), index: index);
}

/// The used addresses a bridge reports ([tokens]: `name` and `path`), as
/// this wallet's own: [stored] rows, and new ones from [derive] whose
/// address matches the name. The highest used index per chain counts
/// these only: a path the bridge sends is never taken on trust, or a
/// lying bridge could move the next receiving address beyond what any
/// wallet scans.
Future<({List<Address> derived, int maxReceive, int maxChange})>
pivxUsedAddresses({
  required List<dynamic> tokens,
  required Map<String, Address> stored,
  required Future<Address> Function(int chain, int index) derive,
}) async {
  final derived = <Address>[];
  int maxReceive = -1;
  int maxChange = -1;
  for (final t in tokens) {
    final token = Map<String, dynamic>.from(t as Map);
    final name = token["name"] as String?;
    if (name == null) continue;
    var address = stored[name];
    if (address == null) {
      final path = pivxTokenPath(token["path"] as String?);
      if (path == null) continue;
      final candidate = await derive(path.chain, path.index);
      if (candidate.value != name) {
        Logging.instance.e(
          "PIVX: bridge address $name at ${token["path"]} does not match "
          "local derivation ${candidate.value}; ignoring",
        );
        continue;
      }
      derived.add(candidate);
      address = candidate;
    }
    if (address.type == AddressType.pivxShield) continue;
    if (address.subType == AddressSubType.receiving) {
      maxReceive = max(maxReceive, address.derivationIndex);
    } else if (address.subType == AddressSubType.change) {
      maxChange = max(maxChange, address.derivationIndex);
    }
  }
  return (derived: derived, maxReceive: maxReceive, maxChange: maxChange);
}

/// `txid:vout`, as masternode ids are written.
String pivxOutpointKey(String txid, int vout) => "$txid:$vout";

/// A coin's flags the user set in coin control (frozen, unfrozen after
/// the wallet froze it, its name), as kept in a backup.
Map<String, dynamic> pivxCoinFlagsToJson(UTXO u) => {
  "txid": u.txid,
  "vout": u.vout,
  "frozen": u.isBlocked,
  if (u.blockedReason != null) "reason": u.blockedReason,
  if (u.name.isNotEmpty) "name": u.name,
};

/// [pivxCoinFlagsToJson] read back, by outpoint, as the coin rows
/// [PivxWallet]'s rescan keeps (only the flags are set). Entries that
/// aren't readable are left out.
Map<String, UTXO> pivxCoinFlagsFromJson(List<dynamic> json, String walletId) {
  final result = <String, UTXO>{};
  for (final e in json) {
    if (e is! Map) continue;
    final txid = e["txid"], vout = e["vout"];
    if (txid is! String || vout is! int) continue;
    final reason = e["reason"], name = e["name"];
    result[pivxOutpointKey(txid, vout)] = UTXO(
      walletId: walletId,
      txid: txid,
      vout: vout,
      value: 0,
      name: name is String ? name : "",
      isBlocked: e["frozen"] == true,
      blockedReason: reason is String ? reason : null,
      isCoinbase: false,
      blockHash: null,
      blockHeight: null,
      blockTime: null,
    );
  }
  return result;
}

/// Transparent outputs a send may spend: confirmed, not already being
/// spent, not frozen, no shield note rows. Delegated outputs only with
/// [coldStake] and masternode [collaterals] only with [collateral], when
/// the user picked them: an unfrozen collateral would otherwise be the
/// first coin an ordinary send spends (largest first), stopping the
/// masternode.
List<UTXO> pivxSpendable(
  Iterable<UTXO> utxos, {
  required int chainHeight,
  required int minConfirms,
  required int minCoinbaseConfirms,
  Set<String> collaterals = const {},
  bool coldStake = false,
  bool collateral = false,
}) => [
  for (final u in utxos)
    if (!isPivxShieldNote(u) &&
        (isPivxColdStakeUtxo(u) ? coldStake : !u.isBlocked) &&
        (collateral ||
            !collaterals.contains(pivxOutpointKey(u.txid, u.vout))) &&
        u.used != true &&
        u.isConfirmed(chainHeight, minConfirms, minCoinbaseConfirms))
      u,
];
