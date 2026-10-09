part of '../pivx_wallet.dart';

/// A masternode controlled by this wallet: its collateral output and the
/// label the user gave it. The masternode private key lives in secure
/// storage ([PivxMasternodes.masternodeKey]).
class PivxMasternode {
  PivxMasternode({
    required this.label,
    required this.address,
    required this.txid,
    required this.vout,
    required this.createdAt,
  });

  final String label;

  /// Wallet address holding the collateral.
  final String address;

  /// Collateral output.
  final String txid;
  final int vout;

  /// Unix seconds.
  final int createdAt;

  String get id => "$txid:$vout";

  Map<String, dynamic> toJson() => {
    "label": label,
    "address": address,
    "txid": txid,
    "vout": vout,
    "createdAt": createdAt,
  };

  factory PivxMasternode.fromJson(Map<String, dynamic> json) => PivxMasternode(
    label: json["label"] as String,
    address: json["address"] as String,
    txid: json["txid"] as String,
    vout: json["vout"] as int,
    createdAt: json["createdAt"] as int,
  );
}

const _kMasternodesKey = "pivxMasternodes";
const _kMasternodeFrozenReason = "Masternode collateral";

/// Default masternode P2P ports.
const kPivxMasternodePortMain = 51472;
const kPivxMasternodePortTest = 51474;

extension PivxMasternodes on PivxWallet {
  /// Collateral of a masternode (mainnet and testnet).
  Amount get masternodeCollateral => Amount(
    rawValue: BigInt.from(10000) * cryptoCurrency.satsPerCoin,
    fractionDigits: cryptoCurrency.fractionDigits,
  );

  int get masternodePort => cryptoCurrency.network == CryptoCurrencyNetwork.main
      ? kPivxMasternodePortMain
      : kPivxMasternodePortTest;

  List<PivxMasternode> get masternodes => [
    for (final e in (info.otherData[_kMasternodesKey] as List?) ?? const [])
      PivxMasternode.fromJson(Map<String, dynamic>.from(e as Map)),
  ];

  bool _isMasternodeCollateral(String txid, int vout) =>
      masternodes.any((m) => m.txid == txid && m.vout == vout);

  String _masternodeKeyName(String id) => "${walletId}_pivxMasternodeKey_$id";

  /// A new masternode private key: uncompressed WIF, as PIVX Core's
  /// `createmasternodekey` makes.
  String generateMasternodeKey() => coinlib.WIF(
    privkey: coinlib.ECPrivateKey.generate(compressed: false),
    version: cryptoCurrency.networkParams.wifPrefix,
  ).toString();

  /// Whether [key] is a WIF private key of this network.
  bool isValidMasternodeKey(String key) {
    try {
      coinlib.WIF.fromString(
        key.trim(),
        version: cryptoCurrency.networkParams.wifPrefix,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> masternodeKey(PivxMasternode mn) =>
      secureStorageInterface.read(key: _masternodeKeyName(mn.id));

  /// Unspent outputs of exactly the collateral amount not used by a
  /// masternode yet (e.g. a collateral sent before, or after a restore).
  Future<List<UTXO>> availableCollaterals() async {
    final raw = masternodeCollateral.raw.toInt();
    return (await mainDB.getUTXOs(walletId).findAll())
        .where(
          (u) =>
              !isPivxShieldNote(u) &&
              u.value == raw &&
              u.used != true &&
              !_isMasternodeCollateral(u.txid, u.vout),
        )
        .toList();
  }

  /// Remember a masternode and freeze its collateral.
  Future<PivxMasternode> addMasternode({
    required String label,
    required String address,
    required String txid,
    required int vout,
    required String masternodeKey,
  }) async {
    if (!isValidMasternodeKey(masternodeKey)) {
      throw Exception("Invalid masternode private key");
    }
    final mn = PivxMasternode(
      label: label,
      address: address,
      txid: txid,
      vout: vout,
      createdAt: DateTime.timestamp().millisecondsSinceEpoch ~/ 1000,
    );
    await secureStorageInterface.write(
      key: _masternodeKeyName(mn.id),
      value: masternodeKey.trim(),
    );
    await info.updateOtherData(
      newEntries: {
        _kMasternodesKey: [
          for (final m in masternodes)
            if (m.id != mn.id) m.toJson(),
          mn.toJson(),
        ],
      },
      isar: mainDB.isar,
    );
    if (label.isNotEmpty) {
      final existing = mainDB.getAddressLabelSync(walletId, address);
      await mainDB.updateAddressLabel(
        existing?.copyWith(label: label) ??
            AddressLabel(
              walletId: walletId,
              addressString: address,
              value: label,
              tags: null,
            ),
      );
    }
    await _freezeCollateral(mn, frozen: true);
    return mn;
  }

  /// Forget a masternode; its collateral becomes spendable again.
  Future<void> removeMasternode(PivxMasternode mn) async {
    await info.updateOtherData(
      newEntries: {
        _kMasternodesKey: [
          for (final m in masternodes)
            if (m.id != mn.id) m.toJson(),
        ],
      },
      isar: mainDB.isar,
    );
    await secureStorageInterface.delete(key: _masternodeKeyName(mn.id));
    await _freezeCollateral(mn, frozen: false);
  }

  Future<void> _freezeCollateral(
    PivxMasternode mn, {
    required bool frozen,
  }) async {
    final utxo = await mainDB.isar.utxos
        .where()
        .txidWalletIdVoutEqualTo(mn.txid, walletId, mn.vout)
        .findFirst();
    if (utxo == null) return; // frozen by updateUTXOs once it is seen
    await mainDB.putUTXO(
      utxo.copyWith(
        isBlocked: frozen,
        blockedReason: frozen ? _kMasternodeFrozenReason : null,
      ),
    );
    await updateBalance();
  }

  /// Build the collateral payment: exactly [masternodeCollateral] to
  /// [address] (a wallet address). Confirm with [confirmSend], then call
  /// [addMasternode] with [collateralVout].
  Future<TxData> prepareMasternodeCollateral({required String address}) =>
      prepareSend(
        txData: TxData(
          recipients: [
            TxRecipient(
              address: address,
              amount: masternodeCollateral,
              isChange: false,
              addressType: AddressType.p2pkh,
            ),
          ],
        ),
      );

  /// Output index of the collateral in a prepared collateral payment.
  int collateralVout(TxData txData, String address) {
    final tx = coinlib.Transaction.fromHex(txData.raw!);
    final script = coinlib.Address.fromString(
      address,
      cryptoCurrency.networkParams,
    ).program.script.compiled.toHex;
    final raw = masternodeCollateral.raw;
    for (int i = 0; i < tx.outputs.length; i++) {
      final o = tx.outputs[i];
      if (o.value == raw && o.scriptPubKey.toHex == script) return i;
    }
    throw Exception("Collateral output not found");
  }

  /// Masternode status from the node (`listmasternodes`), e.g. ENABLED,
  /// PRE_ENABLED or MISSING when the network does not know it yet.
  Future<String> masternodeStatus(PivxMasternode mn) async {
    try {
      final list = await bridge.listMasternodes(mn.txid);
      for (final e in list) {
        final m = Map<String, dynamic>.from(e as Map);
        if (m["txhash"] == mn.txid && m["outidx"] == mn.vout) {
          return m["status"] as String? ?? "UNKNOWN";
        }
      }
      return "MISSING";
    } catch (e) {
      Logging.instance.w("PIVX: listmasternodes failed: $e");
      return "UNKNOWN";
    }
  }

  /// Lines for the masternode's own `pivx.conf` on a VPS.
  String masternodePivxConf(PivxMasternode mn, String key) {
    final net = cryptoCurrency.network == CryptoCurrencyNetwork.main
        ? ""
        : "testnet=1\n";
    return "# PIVX masternode: ${mn.label}\n"
        "$net"
        "server=1\n"
        "listen=1\n"
        "daemon=1\n"
        "masternode=1\n"
        "externalip=YOUR_VPS_IP\n"
        "masternodeaddr=YOUR_VPS_IP:$masternodePort\n"
        "masternodeprivkey=$key\n";
  }

  /// The matching `masternode.conf` line for a controller wallet.
  String masternodeConfLine(PivxMasternode mn, String key) =>
      "${mn.label.isEmpty ? "mn" : mn.label.replaceAll(" ", "_")} "
      "YOUR_VPS_IP:$masternodePort $key ${mn.txid} ${mn.vout}";
}
