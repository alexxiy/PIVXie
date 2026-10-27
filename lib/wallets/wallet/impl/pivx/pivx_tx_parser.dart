import 'dart:convert';
import 'dart:typed_data';

import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;

import '../../../../l10n/l10n.dart';
import '../../../../models/isar/models/blockchain_data/transaction_type.dart';
import '../../../../models/isar/models/blockchain_data/v2/input_v2.dart';
import '../../../../models/isar/models/blockchain_data/v2/output_v2.dart';
import '../../../../models/isar/models/blockchain_data/v2/transaction_v2.dart';
import '../../../../utilities/amount/amount.dart';
import '../../../../utilities/extensions/extensions.dart';

/// How a PIVX transaction shows in the history: its direction, its PIVX
/// kind (see [PivxTxKind]) and the amount worth showing.
typedef PivxTxClass = ({TransactionType type, String? kind, BigInt amount});

/// Whether [scriptHex] is a cold staking (P2CS) script.
bool pivxIsColdStakeScript(String scriptHex) =>
    scriptHex.startsWith("76a97b63d1") || scriptHex.startsWith("76a97b63d2");

/// Classify a transaction from the wallet's point of view, like PIVX
/// Core's `TransactionRecord::decomposeTransaction`:
///
/// * rewards (coinbase / coinstake) show what they minted;
/// * receiving shows what came in;
/// * sending shows what left the wallet (our inputs - fee - our outputs);
/// * sending to self shows what moved, without the change: shielding
///   (transparent -> own shield), unshielding (shield -> own transparent)
///   or a plain move.
///
/// The value balance decides "to self", not the output count: shield
/// bundles carry padding outputs nobody can decrypt.
///
/// Shield spends are inputs without an outpoint; shield notes are outputs
/// without a script. Outputs to one of [changeAddresses] are change.
///
/// Someone else's stake paying us more than [masternodePayment] is a
/// budget proposal payment, the way PIVX Core tells them apart.
PivxTxClass? classifyPivxTx({
  required List<InputV2> inputs,
  required List<OutputV2> outputs,
  Set<String> changeAddresses = const {},
  BigInt? fee,
  bool coinbase = false,
  bool coinstake = false,
  bool spendsColdStake = false,
  BigInt? masternodePayment,
}) {
  BigInt sum(Iterable<BigInt> v) => v.fold(BigInt.zero, (p, e) => p + e);
  bool isChange(OutputV2 o) =>
      o.walletOwns && o.addresses.any(changeAddresses.contains);

  final ownedInputs = inputs.where((e) => e.walletOwns).toList();
  final ownedOutputs = outputs.where((e) => e.walletOwns).toList();
  if (ownedInputs.isEmpty && ownedOutputs.isEmpty) return null;

  final ownedIn = sum(ownedInputs.map((e) => e.value));
  final ownedOut = sum(ownedOutputs.map((e) => e.value));

  if (coinbase && ownedOut > BigInt.zero) {
    return (
      type: TransactionType.incoming,
      kind: PivxTxKind.blockReward,
      amount: ownedOut,
    );
  }
  if (coinstake && ownedOut > BigInt.zero) {
    if (ownedIn > BigInt.zero) {
      // Our coins (or coins delegated by us) staked.
      final cold = ownedOutputs.any(
        (e) => pivxIsColdStakeScript(e.scriptPubKeyHex),
      );
      return (
        type: TransactionType.incoming,
        kind: cold ? PivxTxKind.coldStakeReward : PivxTxKind.stakeReward,
        amount: ownedOut - ownedIn,
      );
    }
    // Someone else's stake paid one of our addresses: our masternode
    // or, above the masternode payment, our proposal.
    return (
      type: TransactionType.incoming,
      kind: masternodePayment != null && ownedOut > masternodePayment
          ? PivxTxKind.budgetPayment
          : PivxTxKind.masternodeReward,
      amount: ownedOut,
    );
  }

  if (ownedIn == BigInt.zero) {
    return (type: TransactionType.incoming, kind: null, amount: ownedOut);
  }

  // Coins burnt in OP_RETURN outputs: a budget proposal fee.
  final burnt = sum(
    outputs
        .where((e) => e.scriptPubKeyHex.startsWith("6a"))
        .map((e) => e.value),
  );
  if (burnt > BigInt.zero) {
    return (
      type: TransactionType.outgoing,
      kind: PivxTxKind.burn,
      amount: burnt,
    );
  }

  // What left the wallet, fee excluded.
  final external = fee != null
      ? ownedIn - fee - ownedOut
      : sum(outputs.where((e) => !e.walletOwns).map((e) => e.value));
  final toSelf = external <= BigInt.zero;
  final type = toSelf ? TransactionType.sentToSelf : TransactionType.outgoing;

  final coldOut = ownedOutputs.where(
    (e) => pivxIsColdStakeScript(e.scriptPubKeyHex),
  );
  if (coldOut.isNotEmpty) {
    return (
      type: type,
      kind: PivxTxKind.delegation,
      amount: sum(coldOut.map((e) => e.value)),
    );
  }
  if (spendsColdStake) {
    return (
      type: type,
      kind: PivxTxKind.undelegation,
      amount: toSelf ? ownedOut : external,
    );
  }

  if (!toSelf) {
    return (type: type, kind: null, amount: external);
  }

  /// Owned outputs that are not change, else all of them.
  BigInt moved(Iterable<OutputV2> outs) {
    final notChange = sum(outs.where((e) => !isChange(e)).map((e) => e.value));
    return notChange > BigInt.zero ? notChange : sum(outs.map((e) => e.value));
  }

  final shieldSpends = ownedInputs.where(
    (e) => e.outpoint == null && e.coinbase == null,
  );
  final notes = ownedOutputs.where((e) => e.scriptPubKeyHex.isEmpty);
  final transparent = ownedOutputs.where((e) => e.scriptPubKeyHex.isNotEmpty);

  if (shieldSpends.isEmpty && notes.isNotEmpty) {
    return (type: type, kind: PivxTxKind.shield, amount: moved(notes));
  }
  if (shieldSpends.isNotEmpty && transparent.isNotEmpty) {
    return (type: type, kind: PivxTxKind.unshield, amount: moved(transparent));
  }
  return (type: type, kind: null, amount: moved(ownedOutputs));
}

/// otherData of a classified PIVX transaction.
Map<String, dynamic> pivxTxOtherData({
  required PivxTxClass c,
  required int fractionDigits,
  required Set<String> changeAddresses,
  BigInt? fee,
  String? memo,
  bool ownSend = false,
  String? alsoKind,
  String? rawTx,
}) => {
  if (memo != null && memo.isNotEmpty) TxV2OdKeys.onChainNote: memo,
  if (c.kind != null) TxV2OdKeys.pivxKind: c.kind,
  TxV2OdKeys.pivxAlsoKind: ?alsoKind,
  TxV2OdKeys.pivxAmount: Amount(
    rawValue: c.amount,
    fractionDigits: fractionDigits,
  ).toJsonString(),
  if (changeAddresses.isNotEmpty)
    TxV2OdKeys.pivxChange: changeAddresses.toList(),
  if (ownSend) TxV2OdKeys.pivxOwnSend: true,
  TxV2OdKeys.pivxRawTx: ?rawTx,
  // Rewards create coins: no fee. Always set otherwise, as the inputs
  // may not show the fee (shield spends, unknown inputs).
  TxV2OdKeys.overrideFee: Amount(
    rawValue: PivxTxKind.rewards.contains(c.kind)
        ? BigInt.zero
        : (fee ?? BigInt.zero),
    fractionDigits: fractionDigits,
  ).toJsonString(),
};

/// The wallet's view of a bridge (Blockbook) transaction, with what the
/// shield scan knows about it ([shield]: `received` notes, our
/// `spentNullifiers`, `sent` notes recovered with our outgoing key).
///
/// [shieldAddresses] are the shield addresses handed out; notes to any
/// other address of ours are change (PIVX Core's IsNoteSaplingChange).
/// [masternodePayment] gives the masternode payment at a block height.
/// Returns null for a transaction that doesn't touch the wallet.
TransactionV2? parsePivxTx(
  Map<String, dynamic> json, {
  required String walletId,
  required int fractionDigits,
  required Set<String> receiving,
  required Set<String> change,
  required Set<String> shieldAddresses,
  Map<String, dynamic>? shield,
  Map<String, Map<String, dynamic>> nullifierNotes = const {},
  bool Function(OutpointV2 outpoint)? isColdStakeOutpoint,
  BigInt Function(int? height)? masternodePayment,
}) {
  final all = {...receiving, ...change};
  final changeAddresses = <String>{};

  final inputs = <InputV2>[];
  for (final v in (json["vin"] as List? ?? const [])) {
    final vin = Map<String, dynamic>.from(v as Map);
    final addrs = List<String>.from(vin["addresses"] as List? ?? const []);
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
        walletOwns: addrs.any(all.contains),
      ),
    );
  }

  // Shield notes this wallet spent (values from its nullifier map).
  for (final nf in (shield?["spentNullifiers"] as List?) ?? const []) {
    final note = nullifierNotes[nf];
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
  for (final v in (json["vout"] as List? ?? const [])) {
    final vout = Map<String, dynamic>.from(v as Map);
    final addrs = List<String>.from(vout["addresses"] as List? ?? const []);
    final owns = addrs.any(all.contains);
    if (owns) changeAddresses.addAll(addrs.where(change.contains));
    outputs.add(
      OutputV2.isarCantDoRequiredInDefaultConstructor(
        scriptPubKeyHex: vout["hex"] as String? ?? "",
        valueStringSats: BigInt.parse(vout["value"] as String? ?? "0")
            .toString(),
        addresses: addrs,
        walletOwns: owns,
      ),
    );
  }

  // Shield notes this wallet received.
  final receivedNotes = (shield?["received"] as List?) ?? const [];
  for (final n in receivedNotes) {
    final address = (n as Map)["address"] as String;
    if (!shieldAddresses.contains(address)) changeAddresses.add(address);
    outputs.add(
      OutputV2.isarCantDoRequiredInDefaultConstructor(
        scriptPubKeyHex: "",
        valueStringSats: "${(n["value"] as num).toInt()}",
        addresses: [address],
        walletOwns: true,
      ),
    );
  }

  // Shield outputs this wallet sent to someone else.
  final sentNotes = (shield?["sent"] as List?) ?? const [];
  for (final n in sentNotes) {
    outputs.add(
      OutputV2.isarCantDoRequiredInDefaultConstructor(
        scriptPubKeyHex: "",
        valueStringSats: "${((n as Map)["value"] as num).toInt()}",
        addresses: [n["address"] as String],
        walletOwns: false,
      ),
    );
  }

  final fee = json["fees"] == null
      ? null
      : BigInt.parse(json["fees"] as String);
  final height = json["blockHeight"] as int? ?? -1;
  final c = classifyPivxTx(
    inputs: inputs,
    outputs: outputs,
    changeAddresses: changeAddresses,
    fee: fee,
    coinbase: json["coinbase"] == true,
    coinstake: json["coinstake"] == true,
    spendsColdStake:
        isColdStakeOutpoint != null &&
        inputs.any(
          (i) =>
              i.walletOwns &&
              i.outpoint != null &&
              isColdStakeOutpoint(i.outpoint!),
        ),
    masternodePayment: masternodePayment?.call(height > 0 ? height : null),
  );
  if (c == null) return null;
  final alsoKind = pivxColdStakeAlsoKind(
    c,
    outputs,
    masternodePayment: masternodePayment?.call(height > 0 ? height : null),
  );

  // Text memos of the shield notes received or sent (the shielded memo).
  final memo = [
    for (final n in [...sentNotes, ...receivedNotes])
      if (((n as Map)["memo"] as String?)?.trim().isNotEmpty ?? false)
        (n["memo"] as String).trim(),
  ].join("\n");

  final txid = json["txid"] as String;
  return TransactionV2(
    walletId: walletId,
    blockHash: json["blockHash"] as String?,
    hash: txid,
    txid: txid,
    height: height > 0 ? height : null,
    version: json["version"] as int? ?? 1,
    timestamp:
        (json["blockTime"] as int?) ??
        DateTime.timestamp().millisecondsSinceEpoch ~/ 1000,
    inputs: List.unmodifiable(inputs),
    outputs: List.unmodifiable(outputs),
    type: c.type,
    subType: TransactionSubType.none,
    otherData: jsonEncode(
      pivxTxOtherData(
        c: c,
        fractionDigits: fractionDigits,
        changeAddresses: changeAddresses,
        fee: fee,
        memo: memo,
        alsoKind: alsoKind,
      ),
    ),
  );
}

/// The second kind of a cold staking reward: what else its block paid us
/// besides the delegated outputs. A block pays the budget or a masternode,
/// never both: above the masternode payment it is our proposal.
String? pivxColdStakeAlsoKind(
  PivxTxClass c,
  List<OutputV2> outputs, {
  BigInt? masternodePayment,
}) {
  if (c.kind != PivxTxKind.coldStakeReward) return null;
  final extra = outputs
      .where(
        (o) =>
            o.walletOwns &&
            o.scriptPubKeyHex.isNotEmpty &&
            !pivxIsColdStakeScript(o.scriptPubKeyHex),
      )
      .fold(BigInt.zero, (p, o) => p + o.value);
  if (extra == BigInt.zero) return null;
  return masternodePayment != null && extra > masternodePayment
      ? PivxTxKind.budgetPayment
      : PivxTxKind.masternodeReward;
}

/// Output scripts (hex) of a bridge transaction, by output index.
List<String> pivxOutputScripts(Map<String, dynamic> json) => [
  for (final v in (json["vout"] as List? ?? const []))
    (v as Map)["hex"] as String? ?? "",
];

/// One output of a raw transaction: its value and script.
typedef PivxRawOutput = ({BigInt value, Uint8List script});

/// Reads a raw PIVX transaction from the start: nVersion and nType
/// (int16 each), inputs, outputs, nLockTime, then for Sapling versions
/// (3 and up) an optional Sapling bundle.
class _PivxRawTxReader {
  _PivxRawTxReader(this.raw) : view = ByteData.sublistView(raw);

  final Uint8List raw;
  final ByteData view;
  int pos = 0;

  Uint8List take(int length) {
    if (length < 0 || pos + length > raw.length) {
      throw const FormatException("Truncated transaction");
    }
    return Uint8List.sublistView(raw, pos, pos += length);
  }

  int varint() {
    final first = take(1)[0];
    if (first < 0xfd) return first;
    final bytes = ByteData.sublistView(
      take(first == 0xfd ? 2 : (first == 0xfe ? 4 : 8)),
    );
    return switch (first) {
      0xfd => bytes.getUint16(0, Endian.little),
      0xfe => bytes.getUint32(0, Endian.little),
      _ => bytes.getUint64(0, Endian.little),
    };
  }

  /// Reads up to and including the outputs.
  List<PivxRawOutput> outputs() {
    pos = 4; // nVersion (+ nType)
    final inputs = varint();
    for (int i = 0; i < inputs; i++) {
      take(36); // prevout
      take(varint()); // scriptSig
      take(4); // nSequence
    }
    final count = varint();
    return [
      for (int i = 0; i < count; i++)
        (
          value: BigInt.from(
            ByteData.sublistView(take(8)).getInt64(0, Endian.little),
          ),
          script: Uint8List.fromList(take(varint())),
        ),
    ];
  }
}

/// Outputs of a raw PIVX transaction (any version: outputs come before
/// the Sapling data).
List<PivxRawOutput> pivxTxOutputs(Uint8List raw) =>
    _PivxRawTxReader(raw).outputs();

/// The Sapling parts of a transaction a shield scan sees: the nullifiers
/// its spends reveal and the note commitments (cmu) of its outputs, both
/// as hex of the wire bytes, in order.
typedef PivxShieldParts = ({List<String> nullifiers, List<String> commitments});

/// [PivxShieldParts] of a raw PIVX transaction; empty lists when it has
/// no Sapling bundle.
PivxShieldParts pivxTxShieldParts(Uint8List raw) {
  final tx = _PivxRawTxReader(raw);
  final version = tx.view.getInt16(0, Endian.little);
  tx.outputs();
  tx.take(4); // nLockTime
  if (version < 3 || tx.take(1)[0] == 0) {
    return (nullifiers: const [], commitments: const []);
  }
  tx.take(8); // valueBalance
  // Spend: cv, anchor, nullifier, rk (32 each), proof 192, signature 64.
  final spends = tx.varint();
  final nullifiers = [
    for (int i = 0; i < spends; i++)
      Uint8List.sublistView(tx.take(384), 64, 96).toHex,
  ];
  // Output: cv, cmu, epk (32 each), enc 580, out 80, proof 192.
  final outputs = tx.varint();
  final commitments = [
    for (int i = 0; i < outputs; i++)
      Uint8List.sublistView(tx.take(948), 32, 64).toHex,
  ];
  return (nullifiers: nullifiers, commitments: commitments);
}

/// Parse [rawHex] after checking that it hashes to [txid]. Throws when it
/// does not.
T _pivxVerified<T>(String txid, String rawHex, T Function(Uint8List) parse) {
  final raw = rawHex.toUint8ListFromHex;
  final id = Uint8List.fromList(coinlib.sha256DoubleHash(raw).reversed.toList())
      .toHex;
  if (id != txid) {
    throw Exception(l10n.txWrongFromServer(txid));
  }
  return parse(raw);
}

/// Outputs of the raw transaction [rawHex], after checking that it
/// hashes to [txid]. Throws when it does not.
List<PivxRawOutput> pivxVerifiedOutputs(String txid, String rawHex) =>
    _pivxVerified(txid, rawHex, pivxTxOutputs);

/// [PivxShieldParts] of the raw transaction [rawHex], after checking that
/// it hashes to [txid]. Throws when it does not.
PivxShieldParts pivxVerifiedShieldParts(String txid, String rawHex) =>
    _pivxVerified(txid, rawHex, pivxTxShieldParts);
