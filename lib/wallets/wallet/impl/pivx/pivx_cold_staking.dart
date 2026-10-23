part of '../pivx_wallet.dart';

// Cold staking, as the owner (delegator): coins go to a P2CS script that
// a staker's key may only stake, while this wallet keeps the key that
// spends them. Spending a delegated output ends its delegation.

/// Smallest delegation PIVX Core accepts (MIN_COLDSTAKING_AMOUNT).
const kPivxMinDelegationSats = 100000000;

/// Set in [TxData.otherData] by the delegate screen: the owner address.
/// Recipients with a staker address (S… / W…) then become cold staking
/// outputs owned by it.
const kPivxColdStakeOwner = "pivxColdStakeOwner";

/// [UTXO.otherData] key of a delegated output: its staker address.
const kPivxColdStakerKey = "pivxColdStaker";

const _kColdStakeFrozenReason = "Cold staking";

/// Wallet otherData: the owner address delegations are made with.
const _kOdColdStakeOwner = "pivxColdStakeOwner";

/// Whether [utxo] is a delegated (cold staking) output.
bool isPivxColdStakeUtxo(UTXO utxo) =>
    utxo.otherData?.contains(kPivxColdStakerKey) ?? false;

/// Staker address of a delegated output.
String? pivxColdStaker(UTXO utxo) {
  if (!isPivxColdStakeUtxo(utxo)) return null;
  return (jsonDecode(utxo.otherData!) as Map)[kPivxColdStakerKey] as String?;
}

/// P2CS script delegating to [stakerHash] and spendable by [ownerHash]:
/// `OP_DUP OP_HASH160 OP_ROT OP_IF OP_CHECKCOLDSTAKEVERIFY_LOF` staker
/// `OP_ELSE` owner `OP_ENDIF OP_EQUALVERIFY OP_CHECKSIG`.
///
/// The "last output free" form, as PIVX Core creates until v6.0
/// enforcement: before it, coinstakes pay masternodes in their last
/// output, which only this form allows. It stays valid after.
Uint8List pivxColdStakeScript({
  required Uint8List stakerHash,
  required Uint8List ownerHash,
}) {
  if (stakerHash.length != 20 || ownerHash.length != 20) {
    throw ArgumentError("Key hashes must be 20 bytes");
  }
  return Uint8List.fromList([
    0x76, 0xa9, 0x7b, 0x63, 0xd1, 0x14, ...stakerHash, //
    0x67, 0x14, ...ownerHash, 0x68, 0x88, 0xac,
  ]);
}

/// Staker and owner key hashes of a P2CS script, or null for any other
/// script.
({Uint8List staker, Uint8List owner})? pivxParseColdStakeScript(Uint8List s) {
  if (s.length != 51 ||
      s[0] != 0x76 ||
      s[1] != 0xa9 ||
      s[2] != 0x7b ||
      s[3] != 0x63 ||
      (s[4] != 0xd1 && s[4] != 0xd2) ||
      s[5] != 0x14 ||
      s[26] != 0x67 ||
      s[27] != 0x14 ||
      s[48] != 0x68 ||
      s[49] != 0x88 ||
      s[50] != 0xac) {
    return null;
  }
  return (staker: s.sublist(6, 26), owner: s.sublist(28, 48));
}

/// Staker address (base58check, [prefix] 63 "S" on mainnet, 73 "W" on
/// the test networks) of a key hash.
String pivxStakingAddress(Uint8List hash, int prefix) =>
    coinlib.base58Encode(Uint8List.fromList([prefix, ...hash]));

/// Key hash of a staker address, or null when [address] isn't one.
Uint8List? pivxStakingAddressHash(String address, int prefix) {
  try {
    final data = coinlib.base58Decode(address);
    if (data.length != 21 || data[0] != prefix) return null;
    return data.sublist(1);
  } catch (_) {
    return null;
  }
}

/// Spends a cold staking output as its owner: `<sig> OP_FALSE <pubkey>`;
/// OP_FALSE takes the script's owner branch. Signed like P2PKH, with
/// the P2CS script as the script code.
class PivxColdStakeInput extends coinlib.LegacyInput {
  PivxColdStakeInput({
    required super.prevOut,
    required this.publicKey,
    required this.prevScript,
    this.insig,
    super.sequence = coinlib.Input.sequenceFinal,
  }) : super(scriptSig: _scriptSig(insig, publicKey));

  final coinlib.ECPublicKey publicKey;
  final Uint8List prevScript;
  final coinlib.ECDSAInputSignature? insig;

  static Uint8List _scriptSig(
    coinlib.ECDSAInputSignature? insig,
    coinlib.ECPublicKey key,
  ) {
    final sig = insig?.bytes;
    return Uint8List.fromList([
      if (sig != null) ...[sig.length, ...sig],
      0x00,
      key.data.length,
      ...key.data,
    ]);
  }

  @override
  bool get complete => insig != null;

  /// Outpoint, script length, push of a 73-byte signature, OP_FALSE,
  /// push of a compressed key, sequence.
  @override
  int? get signedSize => 36 + 1 + 74 + 1 + 34 + 4;

  @override
  PivxColdStakeInput sign({
    required coinlib.LegacySignDetails details,
    required coinlib.ECPrivateKey key,
  }) {
    if (key.pubkey != publicKey) {
      throw Exception("Incorrect key for a cold staking input");
    }
    return _withSignature(
      createInputSignature(
        key: key,
        details: details.addScript(coinlib.Script.decompile(prevScript)),
      ),
    );
  }

  PivxColdStakeInput _withSignature(coinlib.ECDSAInputSignature? insig) =>
      PivxColdStakeInput(
        prevOut: prevOut,
        publicKey: publicKey,
        prevScript: prevScript,
        insig: insig,
        sequence: sequence,
      );

  @override
  PivxColdStakeInput filterSignatures(
    bool Function(coinlib.InputSignature insig) predicate,
  ) => insig == null || predicate(insig!) ? this : _withSignature(null);
}

/// A delegated output of this wallet.
class PivxDelegation {
  PivxDelegation._(this.utxo, this.staker);

  final UTXO utxo;
  final String staker;

  String get owner => utxo.address ?? "";

  /// A cold staking reward (the output of a stake), not a delegation.
  bool get isReward => utxo.isCoinbase;
}

extension PivxColdStakingWallet on PivxWallet {
  int get _stakingPrefix => cryptoCurrency.stakingAddressPrefix;

  bool isStakingAddress(String address) =>
      pivxStakingAddressHash(address, _stakingPrefix) != null;

  /// First letter of staker addresses on this network.
  String get stakingAddressLetter =>
      cryptoCurrency.network == CryptoCurrencyNetwork.main ? "S" : "W";

  /// Confirmations before a delegation, or a new reward, can stake
  /// (PIVX Core's nStakeMinDepth).
  int get coldStakeMinDepth =>
      cryptoCurrency.network == CryptoCurrencyNetwork.main
      ? 600
      : _isRegtest
      ? 20
      : 100;

  /// Why [address] can't be delegated to, or null when it can.
  String? stakerAddressError(String address) {
    if (address.isEmpty) return l10n.csEnterStaker;
    if (isStakingAddress(address)) return null;
    if (cryptoCurrency.validateAddress(address)) {
      return l10n.csRegularAddress(stakingAddressLetter);
    }
    return l10n.csInvalidStaker;
  }

  /// Why [amount] can't be delegated, or null when it can.
  String? delegationAmountError(Amount? amount, {required Amount available}) {
    if (amount == null) return l10n.commonEnterAmount;
    if (amount.raw < BigInt.from(kPivxMinDelegationSats)) {
      return l10n.csMinimum(cryptoCurrency.ticker);
    }
    if (amount > available) return l10n.csMoreThanAvailable;
    return null;
  }

  /// Delegated outputs among [utxos] (rows of this wallet), largest
  /// first; ones already being spent are left out.
  List<PivxDelegation> delegationsOf(Iterable<UTXO> utxos) => [
    for (final u in utxos)
      if (u.used != true && pivxColdStaker(u) != null)
        PivxDelegation._(u, pivxColdStaker(u)!),
  ]..sort((a, b) => b.utxo.value.compareTo(a.utxo.value));

  /// The reward part of each delegated output a stake created
  /// ([PivxDelegation.isReward]), by "txid:vout". A stake pays the staked
  /// coins plus the reward back to the delegation, split evenly when it
  /// splits the stake, so each output holds its share of the reward.
  /// Other payments of the block (our masternode's) are not part of it.
  Future<Map<String, BigInt>> coldStakeRewardShares(
    Iterable<PivxDelegation> delegations,
  ) async {
    final rewards = delegations.where((d) => d.isReward).toList();
    final txs = await _storedTxs(rewards.map((d) => d.utxo.txid));
    final shares = <String, BigInt>{};
    for (final d in rewards) {
      final tx = txs[d.utxo.txid];
      if (tx == null) continue;
      bool ownersOutput(OutputV2 o) =>
          o.walletOwns &&
          pivxIsColdStakeScript(o.scriptPubKeyHex) &&
          o.addresses.isNotEmpty &&
          o.addresses.last == d.owner;
      final paidBack = tx.outputs
          .where(ownersOutput)
          .fold(BigInt.zero, (p, o) => p + o.value);
      final staked = tx.inputs
          .where((i) => i.walletOwns)
          .fold(BigInt.zero, (p, i) => p + i.value);
      final reward = paidBack - staked;
      if (paidBack == BigInt.zero || reward <= BigInt.zero) continue;
      shares["${d.utxo.txid}:${d.utxo.vout}"] =
          reward * BigInt.from(d.utxo.value) ~/ paidBack;
    }
    return shares;
  }

  /// The current delegations.
  Future<List<PivxDelegation>> loadDelegations() async =>
      delegationsOf(await mainDB.getUTXOs(walletId).findAll());

  /// `pivx-cli` with the flag of this wallet's network, for commands the
  /// user runs on their own node.
  String get pivxCliCommand =>
      cryptoCurrency.network == CryptoCurrencyNetwork.main
      ? "pivx-cli"
      : _isRegtest
      ? "pivx-cli -regtest"
      : "pivx-cli -testnet";

  /// This wallet's UTXO rows, now and on every change.
  Stream<List<UTXO>> watchUtxoRows() => mainDB.isar.utxos
      .where()
      .walletIdEqualTo(walletId)
      .watch(fireImmediately: true);

  /// The address delegations are owned by. One address for all of them,
  /// so a staker only whitelists it once: the owner of the current
  /// delegations, else the one used before, else the receiving address.
  Future<String> coldStakeOwnerAddress() async {
    final current = await loadDelegations();
    if (current.isNotEmpty) return current.first.owner;
    final stored = info.otherData[_kOdColdStakeOwner] as String?;
    if (stored != null) return stored;
    final address =
        (await getCurrentReceivingAddress())?.value ??
        (await _deriveAddress(chain: 0, index: 0)).value;
    await info.updateOtherData(
      newEntries: {_kOdColdStakeOwner: address},
      isar: mainDB.isar,
    );
    return address;
  }

  /// The staker most of the current delegations use, to delegate more.
  String? currentStaker(List<PivxDelegation> delegations) {
    final counts = <String, int>{};
    for (final d in delegations) {
      counts[d.staker] = (counts[d.staker] ?? 0) + d.utxo.value;
    }
    if (counts.isEmpty) return null;
    return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        .first
        .key;
  }

  /// Delegate [amount] to [staker], owned by [owner] (an address of this
  /// wallet), paid as [funding] says. With [subtractFee] the fee comes
  /// out of the amount.
  Future<TxData> prepareDelegation({
    required String staker,
    required Amount amount,
    required String owner,
    PivxFunding funding = kPivxAutoFunding,
    bool subtractFee = false,
  }) async {
    final txData = await prepareSend(
      txData: TxData(
        note: l10n.csDelegationNote,
        noteOnChain: "",
        recipients: [
          TxRecipient(
            address: staker,
            amount: amount,
            isChange: false,
            addressType: AddressType.p2pkh,
          ),
        ],
        utxos: pivxFundingInputs(funding),
        otherData: jsonEncode({
          ...pivxFundingOtherData(funding),
          kPivxColdStakeOwner: owner,
          if (subtractFee) kPivxSubtractFee: true,
        }),
      ),
    );
    // The next delegation offers the same owner: one whitelist entry.
    if (info.otherData[_kOdColdStakeOwner] != owner) {
      await info.updateOtherData(
        newEntries: {_kOdColdStakeOwner: owner},
        isar: mainDB.isar,
      );
    }
    return txData;
  }

  /// Transparent addresses of this wallet (receiving first), e.g. to own
  /// a delegation or receive a proposal's payments.
  Future<List<Address>> ownTransparentAddresses() => mainDB
      .getAddresses(walletId)
      .filter()
      .group(
        (q) => q
            .subTypeEqualTo(AddressSubType.receiving)
            .or()
            .subTypeEqualTo(AddressSubType.change),
      )
      .and()
      .typeEqualTo(AddressType.p2pkh)
      .sortBySubType()
      .thenByDerivationIndex()
      .findAll();

  /// A receiving address never handed out before.
  Future<String> newReceivingAddress() async {
    await generateNewReceivingAddress();
    return (await getCurrentReceivingAddress())!.value;
  }

  /// Spend [delegations] back to this wallet's receiving address, which
  /// ends them. The fee comes out of the amount.
  Future<TxData> prepareWithdrawal(List<PivxDelegation> delegations) async {
    if (delegations.isEmpty) throw Exception(l10n.csNothingToWithdraw);
    final to =
        (await getCurrentReceivingAddress())?.value ??
        (await _deriveAddress(chain: 0, index: 0)).value;
    final total = delegations.fold(
      BigInt.zero,
      (p, d) => p + BigInt.from(d.utxo.value),
    );
    return prepareSend(
      txData: TxData(
        recipients: [
          TxRecipient(
            address: to,
            amount: Amount(
              rawValue: total,
              fractionDigits: cryptoCurrency.fractionDigits,
            ),
            isChange: false,
            addressType: AddressType.p2pkh,
          ),
        ],
        utxos: {for (final d in delegations) StandardInput(d.utxo)},
        note: l10n.csWithdrawNote,
        noteOnChain: "",
        otherData: jsonEncode({kPivxSubtractFee: true}),
      ),
    );
  }

  /// Cold staking rewards received so far, per owner address, and how
  /// many stakes paid them: each stake spends one delegated output and
  /// pays the stake plus the reward back to the same owner, so earlier
  /// rewards become part of the delegation. Includes rewards of coins
  /// since withdrawn.
  Future<Map<String, ({BigInt amount, int stakes})>>
  coldStakeRewardsByOwner() async {
    // The kind is in otherData (JSON): only those rows are read.
    final txs = await mainDB.isar.transactionV2s
        .where()
        .walletIdEqualTo(walletId)
        .filter()
        .otherDataContains(
          '"${TxV2OdKeys.pivxKind}":"${PivxTxKind.coldStakeReward}"',
        )
        .findAll();
    final byOwner = <String, BigInt>{};
    final stakes = <String, int>{};
    for (final tx in txs) {
      if (tx.pivxKind != PivxTxKind.coldStakeReward) continue;
      final owners = <String>{};
      // The staked delegated output comes back with the reward to the
      // same script. Other payments in the block (our masternode's) are
      // not cold staking rewards. P2CS inputs and outputs list the
      // staker, then the owner.
      void add(List<String> addresses, BigInt value) {
        if (addresses.isEmpty) return;
        final owner = addresses.last;
        owners.add(owner);
        byOwner[owner] = (byOwner[owner] ?? BigInt.zero) + value;
      }

      for (final o in tx.outputs) {
        if (o.walletOwns && pivxIsColdStakeScript(o.scriptPubKeyHex)) {
          add(o.addresses, o.value);
        }
      }
      for (final i in tx.inputs) {
        if (i.walletOwns) add(i.addresses, -i.value);
      }
      for (final owner in owners) {
        stakes[owner] = (stakes[owner] ?? 0) + 1;
      }
    }
    return {
      for (final e in byOwner.entries)
        e.key: (amount: e.value, stakes: stakes[e.key] ?? 0),
    };
  }
}
