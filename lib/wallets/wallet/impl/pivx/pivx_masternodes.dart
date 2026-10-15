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
    this.service,
  });

  final String label;

  /// Wallet address holding the collateral.
  final String address;

  /// Collateral output.
  final String txid;
  final int vout;

  /// Unix seconds.
  final int createdAt;

  /// Address of the server running it, `ip:port`, once known.
  final String? service;

  String get id => "$txid:$vout";

  PivxMasternode copyWith({String? service}) => PivxMasternode(
    label: label,
    address: address,
    txid: txid,
    vout: vout,
    createdAt: createdAt,
    service: service ?? this.service,
  );

  Map<String, dynamic> toJson() => {
    "label": label,
    "address": address,
    "txid": txid,
    "vout": vout,
    "createdAt": createdAt,
    if (service != null) "service": service,
  };

  factory PivxMasternode.fromJson(Map<String, dynamic> json) => PivxMasternode(
    label: json["label"] as String,
    address: json["address"] as String,
    txid: json["txid"] as String,
    vout: json["vout"] as int,
    createdAt: json["createdAt"] as int,
    service: json["service"] as String?,
  );
}

/// A masternode as the network sees it. [lastPaid] is unix seconds (0:
/// never paid).
typedef PivxMasternodeNetworkInfo = ({
  String status,
  int activeSeconds,
  int lastPaid,
});

const _kMasternodesKey = "pivxMasternodes";

/// Secure storage key of the private key of masternode [id] (`txid:vout`).
String pivxMasternodeKeyName(String walletId, String id) =>
    "${walletId}_pivxMasternodeKey_$id";

/// Ids (`txid:vout`) of the masternodes in a wallet's otherData.
List<String> pivxMasternodeIds(Map<String, dynamic> otherData) => [
  for (final e in (otherData[_kMasternodesKey] as List?) ?? const [])
    PivxMasternode.fromJson(Map<String, dynamic>.from(e as Map)).id,
];
const _kMasternodeFrozenReason = "Masternode collateral";

/// Default masternode P2P ports.
const kPivxMasternodePortMain = 51472;
const kPivxMasternodePortTest = 51474;
const kPivxMasternodePortRegtest = 51476;

/// Protocol version announced in masternode broadcasts when the bridge
/// doesn't tell its node's (PIVX Core 5.6). A masternode server only
/// takes a broadcast carrying its own protocol version.
const _kMasternodeProtocolVersion = 70927;

/// PIVX's message signing magic.
const _kMessageMagic = "DarkNet Signed Message:\n";

extension PivxMasternodes on PivxWallet {
  /// Regtest has its own masternode rules (100 PIV collateral, 1
  /// confirmation). Known after [loadMasternodeNetwork].
  bool get _isRegtest => _bridgeChain == "regtest";

  /// Learn which chain the bridge serves; call before using the
  /// masternode parameters below.
  Future<void> loadMasternodeNetwork() async {
    if (_bridgeChain != null) return;
    try {
      final status = await bridge.status();
      _bridgeChain = (status["backend"] as Map?)?["chain"] as String?;
    } catch (e) {
      Logging.instance.w("PIVX: bridge status failed: $e");
    }
  }

  /// Collateral of a masternode.
  Amount get masternodeCollateral => Amount(
    rawValue:
        BigInt.from(_isRegtest ? 100 : 10000) * cryptoCurrency.satsPerCoin,
    fractionDigits: cryptoCurrency.fractionDigits,
  );

  /// Confirmations the collateral needs before the masternode can start.
  int get masternodeMinConfirmations => _isRegtest ? 1 : 15;

  int get masternodePort => _isRegtest
      ? kPivxMasternodePortRegtest
      : cryptoCurrency.network == CryptoCurrencyNetwork.main
      ? kPivxMasternodePortMain
      : kPivxMasternodePortTest;

  List<PivxMasternode> get masternodes => [
    for (final e in (info.otherData[_kMasternodesKey] as List?) ?? const [])
      PivxMasternode.fromJson(Map<String, dynamic>.from(e as Map)),
  ];

  /// The first free alias "MN1", "MN2", ...
  String nextMasternodeAlias() {
    final used = {for (final m in masternodes) m.label.trim().toLowerCase()};
    for (int i = 1; ; i++) {
      if (!used.contains("mn$i")) return "MN$i";
    }
  }

  /// Whether [alias] is already used by another masternode.
  bool isMasternodeAliasTaken(String alias) {
    final a = alias.trim().toLowerCase();
    return masternodes.any((m) => m.label.trim().toLowerCase() == a);
  }

  /// PIVX Core takes any alias without whitespace or "#" (masternode.conf
  /// is space separated and "#" starts a comment); PIVXie keeps to
  /// letters, digits, "_", "-" and ".", which also read well in a file
  /// name or a URL.
  static final _aliasPattern = RegExp(r"^[A-Za-z0-9_.-]{1,32}$");

  /// Why [alias] can't name a new masternode, or null when it can.
  String? masternodeAliasError(String alias) {
    final a = alias.trim();
    if (a.isEmpty) return "Enter a masternode alias";
    if (!_aliasPattern.hasMatch(a)) {
      return a.length > 32
          ? "At most 32 characters"
          : "Only letters, digits, \"_\", \"-\" and \".\"";
    }
    if (isMasternodeAliasTaken(a)) {
      return "Another masternode is already called \"$a\"";
    }
    return null;
  }

  /// Why [text] is not a usable server address (see
  /// [normalizeMasternodeService]), or null when it is.
  String? masternodeServiceError(String text) {
    try {
      normalizeMasternodeService(text);
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  /// Collateral outputs of this wallet's masternodes (`txid:vout`).
  Set<String> get _masternodeCollaterals => {
    for (final m in masternodes) pivxOutpointKey(m.txid, m.vout),
  };

  String _masternodeKeyName(String id) => pivxMasternodeKeyName(walletId, id);

  /// A new masternode private key: uncompressed WIF, as PIVX Core's
  /// `createmasternodekey` makes.
  String generateMasternodeKey() => coinlib
      .WIF(
        privkey: coinlib.ECPrivateKey.generate(compressed: false),
        version: cryptoCurrency.networkParams.wifPrefix,
      )
      .toString();

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
    final used = _masternodeCollaterals;
    return (await mainDB.getUTXOs(walletId).findAll())
        .where(
          (u) =>
              !isPivxShieldNote(u) &&
              !isPivxColdStakeUtxo(u) &&
              u.value == raw &&
              u.used != true &&
              !used.contains(pivxOutpointKey(u.txid, u.vout)),
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
    String? addressLabel,
    String? service,
  }) async {
    if (!isValidMasternodeKey(masternodeKey)) {
      throw Exception("Invalid masternode private key");
    }
    if (label.trim().isEmpty) throw Exception("Masternode alias is required");
    final mn = PivxMasternode(
      label: label,
      address: address,
      txid: txid,
      vout: vout,
      createdAt: DateTime.timestamp().millisecondsSinceEpoch ~/ 1000,
      service: service,
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
    final newLabel = addressLabel?.trim() ?? "";
    if (newLabel.isNotEmpty) {
      final existing = mainDB.getAddressLabelSync(walletId, address);
      await mainDB.updateAddressLabel(
        existing?.copyWith(label: newLabel) ??
            AddressLabel(
              walletId: walletId,
              addressString: address,
              value: newLabel,
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
  /// [address] (a wallet address), paid as [funding] says (the shield or
  /// the transparent balance, picked coins, change address). Confirm with
  /// [confirmSend], then call [addMasternode] with [collateralVout].
  Future<TxData> prepareMasternodeCollateral({
    required String address,
    PivxFunding funding = kPivxAutoFunding,
    String note = "Create masternode",
  }) => prepareSend(
    txData: TxData(
      // The confirm screen expects both notes set, like the send screen.
      note: note,
      noteOnChain: "",
      recipients: [
        TxRecipient(
          address: address,
          amount: masternodeCollateral,
          isChange: false,
          addressType: AddressType.p2pkh,
        ),
      ],
      utxos: pivxFundingInputs(funding),
      otherData: jsonEncode(pivxFundingOtherData(funding)),
    ),
  );

  /// Output index of the collateral in a prepared collateral payment.
  /// Read from the wallet's own outputs of the transaction (coinlib
  /// can't parse every PIVX transaction back).
  int collateralVout(TxData txData, String address) {
    final outputs = txData.tempTx?.outputs ?? const <OutputV2>[];
    final raw = masternodeCollateral.raw.toString();
    for (int i = 0; i < outputs.length; i++) {
      final o = outputs[i];
      if (o.valueStringSats == raw && o.addresses.contains(address)) return i;
    }
    throw Exception("Collateral output not found");
  }

  /// The network's view of [mn] (`listmasternodes`): status such as
  /// ENABLED, PRE_ENABLED or MISSING (unknown to the network yet), and
  /// when known its active time and last payment.
  Future<PivxMasternodeNetworkInfo> masternodeNetworkInfo(
    PivxMasternode mn,
  ) async {
    try {
      final list = await bridge.listMasternodes(mn.txid);
      for (final e in list) {
        final m = Map<String, dynamic>.from(e as Map);
        if (m["txhash"] == mn.txid && m["outidx"] == mn.vout) {
          return (
            status: m["status"] as String? ?? "UNKNOWN",
            activeSeconds: (m["activetime"] as num?)?.toInt() ?? 0,
            lastPaid: (m["lastpaid"] as num?)?.toInt() ?? 0,
          );
        }
      }
      return (status: "MISSING", activeSeconds: 0, lastPaid: 0);
    } catch (e) {
      Logging.instance.w("PIVX: listmasternodes failed: $e");
      return (status: "UNKNOWN", activeSeconds: 0, lastPaid: 0);
    }
  }

  Future<String> masternodeStatus(PivxMasternode mn) async =>
      (await masternodeNetworkInfo(mn)).status;

  /// Masternode rewards paid to [mn]'s collateral address so far.
  Future<Amount> masternodeEarned(PivxMasternode mn) async {
    // The kinds are in otherData (JSON): only those rows are read.
    final txs = await mainDB.isar.transactionV2s
        .where()
        .walletIdEqualTo(walletId)
        .filter()
        .otherDataContains('"${PivxTxKind.masternodeReward}"')
        .findAll();
    var total = BigInt.zero;
    for (final tx in txs) {
      // Our delegation may stake the very block that pays our masternode:
      // that coinstake shows as a cold staking reward.
      if (tx.pivxKind != PivxTxKind.masternodeReward &&
          tx.pivxAlsoKind != PivxTxKind.masternodeReward) {
        continue;
      }
      for (final o in tx.outputs) {
        if (o.walletOwns &&
            o.addresses.contains(mn.address) &&
            !pivxIsColdStakeScript(o.scriptPubKeyHex)) {
          total += o.value;
        }
      }
    }
    return Amount(
      rawValue: total,
      fractionDigits: cryptoCurrency.fractionDigits,
    );
  }

  /// Lines for the masternode's own `pivx.conf` on a VPS.
  String masternodePivxConf(PivxMasternode mn, String key) {
    final net = _isRegtest
        ? "regtest=1\n"
        : cryptoCurrency.network == CryptoCurrencyNetwork.main
        ? ""
        : "testnet=1\n";
    final service = _confService(mn);
    final ip = service.substring(0, service.lastIndexOf(":"));
    return "# PIVX masternode: ${mn.label}\n"
        "$net"
        "server=1\n"
        "listen=1\n"
        "daemon=1\n"
        "masternode=1\n"
        "externalip=$ip\n"
        "masternodeaddr=$service\n"
        "masternodeprivkey=$key\n";
  }

  /// The matching `masternode.conf` line for a controller wallet.
  String masternodeConfLine(PivxMasternode mn, String key) =>
      "${mn.label.isEmpty ? "mn" : mn.label.replaceAll(" ", "_")} "
      "${_confService(mn)} $key ${mn.txid} ${mn.vout}";

  String _confService(PivxMasternode mn) =>
      mn.service ?? "YOUR_VPS_IP:$masternodePort";

  Future<void> _saveMasternode(PivxMasternode mn) => info.updateOtherData(
    newEntries: {
      _kMasternodesKey: [
        for (final m in masternodes) m.id == mn.id ? mn.toJson() : m.toJson(),
      ],
    },
    isar: mainDB.isar,
  );

  /// Parse a server address, `1.2.3.4:51472`, `[2001:db8::1]:51472` or a
  /// bare IP (default port). Returns `ip:port`, or throws.
  String normalizeMasternodeService(String text) {
    final s = text.trim();
    String host;
    int port = masternodePort;
    if (s.startsWith("[")) {
      final end = s.indexOf("]");
      if (end < 0) throw const FormatException("Invalid IPv6 address");
      host = s.substring(1, end);
      final rest = s.substring(end + 1);
      if (rest.isNotEmpty) {
        if (!rest.startsWith(":")) throw const FormatException("Invalid port");
        port = _parsePort(rest.substring(1));
      }
    } else if (":".allMatches(s).length == 1) {
      final i = s.indexOf(":");
      host = s.substring(0, i);
      port = _parsePort(s.substring(i + 1));
    } else {
      host = s;
    }
    final ip = InternetAddress.tryParse(host);
    if (ip == null) {
      throw const FormatException("Enter the server's IP address");
    }
    if (port <= 0 || port > 65535) throw const FormatException("Invalid port");
    // As PIVX Core checks a masternode broadcast: mainnet masternodes run
    // on 51472 and other networks never do. Testnet uses its default port;
    // regtest (several nodes on one host) any other.
    if (_isRegtest) {
      if (port == kPivxMasternodePortMain) {
        throw const FormatException(
          "Port $kPivxMasternodePortMain is for mainnet masternodes only",
        );
      }
    } else if (port != masternodePort) {
      throw FormatException("Masternodes must use port $masternodePort");
    }
    return ip.type == InternetAddressType.IPv6
        ? "[${ip.address}]:$port"
        : "${ip.address}:$port";
  }

  static int _parsePort(String text) {
    final port = int.tryParse(text.trim());
    if (port == null) throw const FormatException("Invalid port");
    return port;
  }

  /// 16-byte IP (IPv4 mapped into IPv6) and big-endian port, as PIVX
  /// serializes a `CService`.
  Uint8List _serviceBytes(String service) {
    final i = service.lastIndexOf(":");
    var host = service.substring(0, i);
    if (host.startsWith("[")) host = host.substring(1, host.length - 1);
    final port = int.parse(service.substring(i + 1));
    final raw = InternetAddress(host).rawAddress;
    return Uint8List.fromList([
      if (raw.length == 4) ...[...List.filled(10, 0), 0xff, 0xff],
      ...raw,
      (port >> 8) & 0xff,
      port & 0xff,
    ]);
  }

  /// Start [mn] on the server at [service] (`ip:port`): sign a
  /// masternode broadcast with the collateral key and the masternode
  /// key, and relay it through the bridge. The server must already run
  /// PIVX Core with this masternode's private key.
  ///
  /// Returns the node's answer.
  Future<String> startMasternode(
    PivxMasternode mn, {
    required String service,
  }) async {
    if (isViewOnly) throw Exception("View only wallets cannot sign");
    await loadMasternodeNetwork();
    service = normalizeMasternodeService(service);

    // Collateral: unspent and deep enough.
    final utxo = await mainDB.isar.utxos
        .where()
        .txidWalletIdVoutEqualTo(mn.txid, walletId, mn.vout)
        .findFirst();
    if (utxo == null || utxo.used == true) {
      throw Exception("The collateral output is not in this wallet anymore");
    }
    final height = await bridge.getBlockCount();
    final confirmations = utxo.blockHeight == null || utxo.blockHeight! <= 0
        ? 0
        : height - utxo.blockHeight! + 1;
    if (confirmations < masternodeMinConfirmations) {
      throw Exception(
        "The collateral needs $masternodeMinConfirmations confirmations "
        "($confirmations so far)",
      );
    }

    final mnWif = await masternodeKey(mn);
    if (mnWif == null) throw Exception("Masternode private key not found");
    final mnKey = coinlib.WIF
        .fromString(mnWif, version: cryptoCurrency.networkParams.wifPrefix)
        .privkey;

    final address = await mainDB.getAddress(walletId, mn.address);
    if (address?.derivationPath == null) {
      throw Exception("The collateral address is not a wallet address");
    }
    final collateralKey = (await getRootHDNode())
        .derivePath(address!.derivationPath!.value)
        .privateKey;

    // Ping block: 12 below the tip, like PIVX Core.
    final blockHash = await bridge.blockHash(max(0, height - 12));
    final sigTime = DateTime.timestamp().millisecondsSinceEpoch ~/ 1000;

    final bytes = pivxMasternodeBroadcast(
      protocolVersion:
          await bridge.protocolVersion() ?? _kMasternodeProtocolVersion,
      txid: mn.txid,
      vout: mn.vout,
      service: _serviceBytes(service),
      collateralKey: collateralKey,
      masternodeKey: mnKey,
      blockHash: blockHash,
      sigTime: sigTime,
    );
    final answer = await bridge.relayMasternodeBroadcast(bytes.toHex);
    if (!answer.contains("broadcast sent")) throw Exception(answer);
    await _saveMasternode(mn.copyWith(service: service));
    return answer;
  }
}

/// A signed masternode broadcast (`mnb`) with its first ping, serialized
/// as PIVX Core's `CMasternodeBroadcast` (message version 1, signatures
/// over hashes), like MyPIVXWallet's `Masternode.broadcastMessageToHex`.
Uint8List pivxMasternodeBroadcast({
  required String txid,
  required int vout,
  required Uint8List service,
  required coinlib.ECPrivateKey collateralKey,
  required coinlib.ECPrivateKey masternodeKey,
  required String blockHash,
  required int sigTime,
  int protocolVersion = _kMasternodeProtocolVersion,
}) {
  final collateralPub = collateralKey.pubkey.data;
  final masternodePub = masternodeKey.pubkey.data;

  final vin = _MnWriter()
    ..bytes(txid.toUint8ListFromHex.reversed)
    ..u32(vout)
    ..u8(0) // empty scriptSig
    ..u32(0xffffffff);

  // Collateral signature: message signature over the hex of
  // CMasternodeBroadcast::GetSignatureHash().
  final toSign = _MnWriter()
    ..u32(1) // nMessVersion
    ..bytes(service)
    ..u64(sigTime)
    ..slice(collateralPub)
    ..slice(masternodePub)
    ..u32(protocolVersion);
  final signHash = coinlib.sha256DoubleHash(toSign.done).reversed.toList();
  final collateralSig = coinlib.MessageSignature.sign(
    key: collateralKey,
    message: Uint8List.fromList(signHash).toHex,
    prefix: _kMessageMagic,
  ).signature.compact;

  // Ping signature: the masternode key signs CMasternodePing::GetHash().
  final ping = _MnWriter()
    ..bytes(vin.done)
    ..bytes(blockHash.toUint8ListFromHex.reversed)
    ..u64(sigTime);
  final pingSig = coinlib.ECDSARecoverableSignature.sign(
    masternodeKey,
    coinlib.sha256DoubleHash(ping.done),
  ).compact;

  return (_MnWriter()
        ..bytes(vin.done)
        ..bytes(service)
        ..slice(collateralPub)
        ..slice(masternodePub)
        ..slice(collateralSig)
        ..u64(sigTime)
        ..u32(protocolVersion)
        // lastPing
        ..bytes(ping.done)
        ..slice(pingSig)
        ..u32(1) // ping nMessVersion
        ..u32(1)) // broadcast nMessVersion
      .done;
}

class _MnWriter {
  final _b = BytesBuilder();

  void bytes(Iterable<int> v) => _b.add(v.toList());
  void u8(int v) => _b.addByte(v & 0xff);
  void u32(int v) {
    for (int i = 0; i < 4; i++) {
      _b.addByte((v >> (8 * i)) & 0xff);
    }
  }

  void u64(int v) {
    u32(v & 0xffffffff);
    u32(v >> 32);
  }

  /// Length-prefixed (all pieces here are < 253 bytes).
  void slice(List<int> v) {
    u8(v.length);
    bytes(v);
  }

  Uint8List get done => _b.toBytes();
}
