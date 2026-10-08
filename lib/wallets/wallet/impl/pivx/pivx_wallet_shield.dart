part of '../pivx_wallet.dart';

/// Blocks handed to the native scanner per call (MyPIVXWallet uses 200).
const _kShieldBatchBlocks = 200;

/// MyPIVXWallet's default shield start for restored wallets (its shield
/// launch); no MPW shield address can have notes before it.
const _kMainnetDefaultShieldStart = 4190531;

/// Marker in [TxData.otherData] for transactions built by the shield
/// library (anything touching a shield address or shield balance).
const _kOdShieldTx = "pivxShieldTx";
const _kOdShieldNullifiers = "pivxShieldNullifiers";

/// Set in [TxData.otherData] by the UI to spend the shield balance.
const kPivxFromShield = "pivxFromShield";

extension _PivxShield on PivxWallet {
  bool get _shieldSupported => libPivxShield.isAvailable && !isViewOnly;

  bool get _isTestnet => cryptoCurrency.network != CryptoCurrencyNetwork.main;

  int get _shieldCoinType => _isTestnet ? 1 : 119;

  int get _defaultShieldRestoreHeight =>
      _isTestnet ? 0 : _kMainnetDefaultShieldStart;

  /// ZIP32 spending key, derived like MyPIVXWallet: from the first 32
  /// bytes of the BIP39 seed.
  Future<String> _extsk() async {
    final seed = bip39.mnemonicToSeed(
      await getMnemonic(),
      passphrase: await getMnemonicPassphrase(),
    );
    return libPivxShield.extendedSpendingKey(
      seed: seed.sublist(0, 32),
      coinType: _shieldCoinType,
    );
  }

  Future<PivxShieldState> _createShieldState(int fromHeight) async {
    final extfvk = libPivxShield.extendedFullViewingKey(
      extsk: await _extsk(),
      isTestnet: _isTestnet,
    );
    final cp = libPivxShield.closestCheckpoint(
      height: fromHeight,
      isTestnet: _isTestnet,
    );
    final address = libPivxShield.defaultAddress(
      extfvk: extfvk,
      isTestnet: _isTestnet,
    );
    final state = PivxShieldState(
      extfvk: extfvk,
      isTestnet: _isTestnet,
      startHeight: cp.height,
      lastProcessedBlock: cp.height,
      commitmentTree: cp.tree,
      diversifierIndex: address.diversifierIndex,
      currentAddress: address.address,
    );
    await state.save(walletId);
    Logging.instance.i(
      "PIVX shield: new state for $walletId from checkpoint ${cp.height}",
    );
    return state;
  }

  /// Loaded (or newly created) shield state. A wallet without state was
  /// created in-app, so scanning starts near the current tip; restores
  /// reset the state in [PivxWallet.recover].
  Future<PivxShieldState> _loadShield() async {
    if (_shield != null) return _shield!;
    var state = await PivxShieldState.load(walletId);
    if (state == null) {
      int from = info.restoreHeight;
      if (from <= 0) {
        from = await chainHeight;
        if (from <= 0) from = await bridge.getBlockCount();
      }
      state = await _createShieldState(from);
    }
    return _shield = state;
  }

  Future<void> _resetShield({required int fromHeight}) async {
    await PivxShieldState.delete(walletId);
    _shield = null;
    _shield = await _createShieldState(fromHeight);
  }

  // ===========================================================================
  // Sync

  Future<void> _syncShield() async {
    if (!_shieldSupported) return;
    final state = await _loadShield();
    final walletTxids = <String>{};

    var batch = <PivxShieldBlock>[];
    await for (final block in parsePivxShieldStream(
      bridge.shieldData(state.lastProcessedBlock + 1),
    )) {
      batch.add(block);
      if (batch.length >= _kShieldBatchBlocks) {
        await _processShieldBlocks(state, batch, walletTxids);
        batch = [];
      }
    }
    if (batch.isNotEmpty) {
      await _processShieldBlocks(state, batch, walletTxids);
    }

    // Verify against the chain like MyPIVXWallet: a wrong root means a
    // bad stream or a reorg we missed — start over from the checkpoint.
    if (state.lastProcessedBlock > state.startHeight) {
      final remote = await bridge.finalSaplingRoot(state.lastProcessedBlock);
      final local = libPivxShield.saplingRoot(state.commitmentTree);
      if (remote != null && remote != local) {
        Logging.instance.e(
          "PIVX shield: sapling root mismatch at ${state.lastProcessedBlock} "
          "(local $local, chain $remote); resyncing",
        );
        await _resetShield(fromHeight: state.startHeight);
        return;
      }
    }

    if (walletTxids.isNotEmpty) {
      await _storeShieldHistory(walletTxids);
    }

    // With shield funds, fetch the proving parameters ahead of the first
    // spend so sending doesn't wait on a ~50 MB download.
    if (state.unspentNotes.isNotEmpty && !libPivxShield.proverIsLoaded()) {
      unawaited(
        _ensureProver().catchError(
          (Object e) => Logging.instance.w("PIVX: prover preload failed: $e"),
        ),
      );
    }
  }

  Future<void> _processShieldBlocks(
    PivxShieldState state,
    List<PivxShieldBlock> blocks,
    Set<String> walletTxids,
  ) async {
    final relevant = blocks
        .where((b) => b.height > state.lastProcessedBlock)
        .toList();
    if (relevant.isEmpty) return;

    final r = await libPivxShield.handleBlocks(
      tree: state.commitmentTree,
      blocks: [for (final b in relevant) b.txs],
      extfvk: state.extfvk,
      isTestnet: state.isTestnet,
      notes: state.unspentNotes,
    );

    final kept = [
      for (final n in r["decrypted_notes"] as List) Map<String, dynamic>.from(n as Map),
    ];
    final added = [
      for (final n in r["decrypted_new_notes"] as List) Map<String, dynamic>.from(n as Map),
    ];
    for (final n in added) {
      state.nullifierNotes[n["nullifier"] as String] = {
        "value": n["value"],
        "address": n["address"],
      };
    }
    final spent = Set<String>.from(r["nullifiers"] as List);
    state.unspentNotes = [
      ...kept,
      ...added,
    ].where((n) => !spent.contains(n["nullifier"])).toList();
    state.pendingSpent.removeWhere((_, nfs) => nfs.any(spent.contains));

    for (final w in r["wallet_transactions"] as List) {
      final wtx = Map<String, dynamic>.from(w as Map);
      final txid = wtx["txid"] as String;
      state.txInfo[txid] = {
        "received": [
          for (final n in wtx["received"] as List)
            {
              "value": (n as Map)["value"],
              "address": n["address"],
              "memo": n["memo"],
            },
        ],
        "spentNullifiers": [
          for (final nf in wtx["nullifiers"] as List)
            if (state.nullifierNotes.containsKey(nf)) nf,
        ],
      };
      walletTxids.add(txid);
    }

    state.commitmentTree = r["commitment_tree"] as String;
    state.lastProcessedBlock = relevant.last.height;
    await state.save(walletId);
  }

  Future<void> _storeShieldHistory(Set<String> txids) async {
    final sets = await _addressSets();
    final txns = <TransactionV2>[];
    for (final txid in txids) {
      final json = await bridge.tx(txid);
      final tx = _parseTx(
        json,
        receiving: sets.receiving,
        change: sets.change,
        all: sets.all,
        shield: _shield?.txInfo[txid],
      );
      if (tx != null) txns.add(tx);
    }
    await mainDB.updateOrPutTransactionV2s(txns);
  }

  Future<void> _updateShieldBalance() async {
    if (!_shieldSupported) return;
    final state = await _loadShield();
    final spendable = Amount(
      rawValue: BigInt.from(state.spendableBalance),
      fractionDigits: cryptoCurrency.fractionDigits,
    );
    await info.updateBalanceSecondary(
      newBalance: Balance(
        total: spendable,
        spendable: spendable,
        blockedTotal: Amount.zeroWith(fractionDigits: cryptoCurrency.fractionDigits),
        pendingSpendable: Amount.zeroWith(fractionDigits: cryptoCurrency.fractionDigits),
      ),
      isar: mainDB.isar,
    );
  }

  // ===========================================================================
  // Sapling params

  Future<void> _ensureProver({void Function(double progress)? onProgress}) async {
    if (libPivxShield.proverIsLoaded()) return;
    final root = await StackFileSystem.applicationRootDirectory();
    final dir = Directory("${root.path}/sapling-params");
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final output = File("${dir.path}/sapling-output.params");
    final spend = File("${dir.path}/sapling-spend.params");

    final proxy = bridge.useTor ? TorService.sharedInstance.getProxyInfo() : null;
    final sources = [bridge.baseUri.toString(), "https://pivxla.bz"];
    for (final (file, name, weight, base) in [
      (output, "sapling-output.params", 0.07, 0.0),
      (spend, "sapling-spend.params", 0.93, 0.07),
    ]) {
      if (file.existsSync()) continue;
      Object? lastError;
      for (final src in sources) {
        try {
          await PivxBridgeClient.downloadToFile(
            Uri.parse("$src/$name"),
            file,
            proxy: proxy,
            onProgress: (r, t) {
              if (t != null) onProgress?.call(base + weight * r / t);
            },
          );
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
        }
      }
      if (lastError != null) throw Exception("Could not download $name: $lastError");
    }
    try {
      await libPivxShield.loadProver(
        outputParamsPath: output.path,
        spendParamsPath: spend.path,
      );
    } catch (_) {
      // Corrupt download: remove so the next attempt starts fresh.
      if (output.existsSync()) await output.delete();
      if (spend.existsSync()) await spend.delete();
      rethrow;
    }
  }

  // ===========================================================================
  // Send

  Future<TxData> _prepareShieldSend({
    required TxData txData,
    required bool fromShield,
  }) async {
    final recipients = txData.recipients!;
    if (recipients.length != 1) {
      throw Exception("Shield transactions support a single recipient");
    }
    final recipient = recipients.first;
    final state = await _loadShield();
    await _ensureProver();

    final height = (await chainHeight) + 1;
    final Map<String, dynamic> result;
    List<StandardInput> usedInputs = const [];
    final String changeAddress;

    if (fromShield) {
      final next = libPivxShield.nextAddress(
        extfvk: state.extfvk,
        diversifierIndex: state.diversifierIndex,
        isTestnet: state.isTestnet,
      );
      changeAddress = next.address;
      if (state.spendableBalance < recipient.amount.raw.toInt()) {
        throw Exception("Insufficient shield balance");
      }
      result = await libPivxShield.createTransaction(
        notes: state.spendableNotes,
        extsk: await _extsk(),
        toAddress: recipient.address,
        changeAddress: changeAddress,
        amount: recipient.amount.raw.toInt(),
        blockHeight: height,
        isTestnet: state.isTestnet,
        memo: txData.memo ?? "",
      );
    } else {
      final change = (await getCurrentChangeAddress()) ??
          await _deriveAddress(chain: 1, index: 0);
      changeAddress = change.value;
      final utxos = _spendable(
        await mainDB.getUTXOs(walletId).findAll(),
        await chainHeight,
      );
      final inputs = await _withKeys(utxos);
      result = await libPivxShield.createTransaction(
        utxos: [
          for (final i in inputs)
            {
              "txid": i.utxo.txid,
              "vout": i.utxo.vout,
              "amount": i.utxo.value,
              "private_key": i.key!.privateKey!.data.toHex,
              "script": coinlib.Address.fromString(
                i.utxo.address!,
                cryptoCurrency.networkParams,
              ).program.script.compiled.toHex,
            },
        ],
        extsk: await _extsk(),
        toAddress: recipient.address,
        changeAddress: changeAddress,
        amount: recipient.amount.raw.toInt(),
        blockHeight: height,
        isTestnet: state.isTestnet,
        memo: txData.memo ?? "",
      );
      final used = Set<String>.from(result["nullifiers"] as List);
      usedInputs = inputs
          .where((i) => used.contains("${i.utxo.txid},${i.utxo.vout}"))
          .toList();
    }

    final fee = BigInt.from(result["fee"] as int);
    final amount = BigInt.from(result["amount"] as int);
    final nullifiers = List<String>.from(result["nullifiers"] as List);
    final txid = result["txid"] as String;
    final digits = cryptoCurrency.fractionDigits;

    // Temporary history entry until the tx is seen on chain.
    final own = (await mainDB.getAddresses(walletId).findAll()).map((e) => e.value).toSet();
    final inputsTotal = fromShield
        ? nullifiers.fold(BigInt.zero, (p, nf) => p + BigInt.from((state.nullifierNotes[nf]?["value"] as num?) ?? 0))
        : usedInputs.fold(BigInt.zero, (p, i) => p + BigInt.from(i.utxo.value));
    final changeValue = inputsTotal - amount - fee;
    final tempInputs = [
      if (fromShield)
        for (final nf in nullifiers)
          InputV2.isarCantDoRequiredInDefaultConstructor(
            scriptSigHex: null,
            scriptSigAsm: null,
            sequence: null,
            outpoint: null,
            addresses: [state.nullifierNotes[nf]?["address"] as String? ?? ""],
            valueStringSats: "${state.nullifierNotes[nf]?["value"] ?? 0}",
            witness: null,
            innerRedeemScriptAsm: null,
            coinbase: null,
            walletOwns: true,
          )
      else
        for (final i in usedInputs)
          InputV2.isarCantDoRequiredInDefaultConstructor(
            scriptSigHex: null,
            scriptSigAsm: null,
            sequence: null,
            outpoint: OutpointV2.isarCantDoRequiredInDefaultConstructor(
              txid: i.utxo.txid,
              vout: i.utxo.vout,
            ),
            addresses: [i.utxo.address!],
            valueStringSats: "${i.utxo.value}",
            witness: null,
            innerRedeemScriptAsm: null,
            coinbase: null,
            walletOwns: true,
          ),
    ];
    final recipientIsOurs = own.contains(recipient.address) || recipient.address == state.currentAddress;
    final tempOutputs = [
      OutputV2.isarCantDoRequiredInDefaultConstructor(
        scriptPubKeyHex: "",
        valueStringSats: amount.toString(),
        addresses: [recipient.address],
        walletOwns: recipientIsOurs,
      ),
      if (changeValue > BigInt.zero)
        OutputV2.isarCantDoRequiredInDefaultConstructor(
          scriptPubKeyHex: "",
          valueStringSats: changeValue.toString(),
          addresses: [changeAddress],
          walletOwns: true,
        ),
    ];

    final otherData = <String, dynamic>{
      if (txData.otherData != null) ...jsonDecode(txData.otherData!) as Map<String, dynamic>,
      _kOdShieldTx: true,
      _kOdShieldNullifiers: fromShield ? nullifiers : <String>[],
    };

    return txData.copyWith(
      raw: result["txhex"] as String,
      txid: txid,
      fee: Amount(rawValue: fee, fractionDigits: digits),
      vSize: (result["txhex"] as String).length ~/ 2,
      recipients: [
        recipient.copyWith(amount: Amount(rawValue: amount, fractionDigits: digits)),
      ],
      usedUTXOs: usedInputs,
      otherData: jsonEncode(otherData),
      tempTx: TransactionV2(
        walletId: walletId,
        blockHash: null,
        hash: txid,
        txid: txid,
        height: null,
        timestamp: DateTime.timestamp().millisecondsSinceEpoch ~/ 1000,
        inputs: List.unmodifiable(tempInputs),
        outputs: List.unmodifiable(tempOutputs),
        version: 3,
        type: recipientIsOurs ? TransactionType.sentToSelf : TransactionType.outgoing,
        subType: TransactionSubType.none,
        otherData: jsonEncode({
          TxV2OdKeys.overrideFee: Amount(rawValue: fee, fractionDigits: digits).toJsonString(),
        }),
      ),
    );
  }

  Future<TxData> _confirmShieldSend(TxData txData) async {
    final od = jsonDecode(txData.otherData!) as Map<String, dynamic>;
    final txid = await bridge.sendTx(txData.raw!);
    final nullifiers = List<String>.from(od[_kOdShieldNullifiers] as List? ?? const []);
    if (nullifiers.isNotEmpty) {
      final state = await _loadShield();
      state.pendingSpent[txid] = nullifiers;
      await state.save(walletId);
    }
    final used = (txData.usedUTXOs ?? const [])
        .whereType<StandardInput>()
        .map((e) => e.utxo.copyWith(used: true))
        .toList();
    if (used.isNotEmpty) await mainDB.putUTXOs(used);
    final result = await updateSentCachedTxData(
      txData: txData.copyWith(txid: txid, txHash: txid),
    );
    await updateBalance();
    return result;
  }
}
