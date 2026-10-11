part of '../pivx_wallet.dart';

// Governance: the network's budget proposals and voting on them with this
// wallet's (legacy) masternodes, like PIVX Core's governance tab and
// MyPIVXWallet. Votes are signed here with the masternode key and relayed
// raw (`mnbudgetrawvote`) through the bridge.

/// Blocks per budget cycle (one superblock each): about 30 days on
/// mainnet, 144 blocks on testnet and regtest.
const kPivxBudgetCycleMain = 43200;
const kPivxBudgetCycleTest = 144;

/// Time a masternode must wait before changing its vote on a proposal
/// (Core's BUDGET_VOTE_UPDATE_MIN).
const kPivxVoteUpdateMinSeconds = 60 * 60;

/// Block value since v5.5 on every network; the monthly budget is a full
/// cycle of it (Core's CBudgetManager::GetTotalBudget).
const _kBlockValueSats = 10 * 100000000;

enum PivxVote {
  yes(1),
  no(2);

  const PivxVote(this.code);

  /// CBudgetVote::VoteDirection.
  final int code;
}

enum PivxProposalStatus {
  /// In the budget the next superblock pays.
  passing("Passing"),

  /// Enough votes, but the budget is used up by proposals with more.
  passingNotFunded("Passing, not funded"),

  /// Too few net yes votes.
  notPassing("Not passing"),

  /// Too new to be funded yet (one day on mainnet).
  waiting("Waiting"),

  /// All payments made.
  finished("Finished");

  const PivxProposalStatus(this.label);

  final String label;
}

class PivxProposal {
  PivxProposal._({
    required this.name,
    required this.url,
    required this.hash,
    required this.feeHash,
    required this.paymentAddress,
    required this.blockStart,
    required this.blockEnd,
    required this.totalPayments,
    required this.remainingPayments,
    required this.yeas,
    required this.nays,
    required this.abstains,
    required this.monthlyPayment,
    required this.isEstablished,
    required this.isValid,
    required this.invalidReason,
    required this.status,
  });

  final String name;
  final String url;

  /// Proposal hash (its id).
  final String hash;
  final String feeHash;
  final String paymentAddress;

  /// First and last superblock paying it.
  final int blockStart;
  final int blockEnd;
  final int totalPayments;
  final int remainingPayments;

  final int yeas;
  final int nays;
  final int abstains;

  /// Paid each superblock.
  final Amount monthlyPayment;

  final bool isEstablished;
  final bool isValid;
  final String? invalidReason;
  final PivxProposalStatus status;

  int get netYes => yeas - nays;

  Amount get totalPayment => Amount(
    rawValue: monthlyPayment.raw * BigInt.from(totalPayments),
    fractionDigits: monthlyPayment.fractionDigits,
  );

  /// Payments made so far.
  int get paymentsMade => totalPayments - remainingPayments;

  static Amount _amount(Object? value, int fractionDigits) =>
      Decimal.parse((value ?? 0).toString())
          .toAmount(fractionDigits: fractionDigits);

  factory PivxProposal._fromJson(
    Map<String, dynamic> json, {
    required int fractionDigits,
    required PivxProposalStatus status,
  }) => PivxProposal._(
    name: json["Name"] as String? ?? "",
    url: json["URL"] as String? ?? "",
    hash: json["Hash"] as String,
    feeHash: json["FeeHash"] as String? ?? "",
    paymentAddress: json["PaymentAddress"] as String? ?? "",
    blockStart: (json["BlockStart"] as num?)?.toInt() ?? 0,
    blockEnd: (json["BlockEnd"] as num?)?.toInt() ?? 0,
    totalPayments: (json["TotalPaymentCount"] as num?)?.toInt() ?? 0,
    remainingPayments: (json["RemainingPaymentCount"] as num?)?.toInt() ?? 0,
    yeas: (json["Yeas"] as num?)?.toInt() ?? 0,
    nays: (json["Nays"] as num?)?.toInt() ?? 0,
    abstains: (json["Abstains"] as num?)?.toInt() ?? 0,
    monthlyPayment: _amount(json["MonthlyPayment"], fractionDigits),
    isEstablished: json["IsEstablished"] as bool? ?? false,
    isValid: json["IsValid"] as bool? ?? true,
    invalidReason: json["IsInvalidReason"] as String?,
    status: status,
  );
}

/// The network's budget as seen now.
class PivxGovernance {
  PivxGovernance({
    required this.proposals,
    required this.chainHeight,
    required this.cycleBlocks,
    required this.enabledMasternodes,
    required this.totalBudget,
    required this.allocated,
  });

  /// Open proposals (finished ones left out), most net yes votes first.
  final List<PivxProposal> proposals;
  final int chainHeight;
  final int cycleBlocks;
  final int enabledMasternodes;

  /// Paid out at most per superblock.
  final Amount totalBudget;

  /// Taken by the passing proposals.
  final Amount allocated;

  Amount get available => totalBudget - allocated;

  int get nextSuperblock =>
      chainHeight - chainHeight % cycleBlocks + cycleBlocks;

  int get blocksToSuperblock => nextSuperblock - chainHeight;

  /// Net yes votes a proposal needs (Core: a tenth of the enabled
  /// masternodes).
  int get requiredNetYes => enabledMasternodes ~/ 10;
}

/// A vote one of this wallet's masternodes cast.
class PivxMasternodeVote {
  PivxMasternodeVote({required this.vote, required this.time});

  final PivxVote vote;

  /// Unix seconds.
  final int time;

  /// When the vote may be changed (Core rejects earlier updates).
  DateTime get changeableAt => DateTime.fromMillisecondsSinceEpoch(
    (time + kPivxVoteUpdateMinSeconds) * 1000,
  );

  bool get canChange => DateTime.now().isAfter(changeableAt);
}

/// Core's `COutPoint::ToStringShort()`, the masternode id in vote lists.
String pivxMasternodeOutpointId(String txid, int vout) => "$txid-$vout";

/// The signature of a budget vote, as Core's `CBudgetVote` with message
/// version 1: the masternode key signs (compact, recoverable)
/// `GetHash()` = sha256d(vin, proposal hash, direction, time). Base64, as
/// `mnbudgetrawvote` takes it.
String pivxBudgetVoteSignature({
  required String collateralTxid,
  required int collateralVout,
  required String proposalHash,
  required PivxVote vote,
  required int time,
  required coinlib.ECPrivateKey masternodeKey,
}) {
  final message = _MnWriter()
    ..bytes(collateralTxid.toUint8ListFromHex.reversed)
    ..u32(collateralVout)
    ..u8(0) // empty scriptSig
    ..u32(0xffffffff)
    ..bytes(proposalHash.toUint8ListFromHex.reversed)
    ..u32(vote.code)
    ..u64(time);
  final signature = coinlib.ECDSARecoverableSignature.sign(
    masternodeKey,
    coinlib.sha256DoubleHash(message.done),
  ).compact;
  return base64Encode(signature);
}

extension PivxGovernanceWallet on PivxWallet {
  int get budgetCycleBlocks =>
      cryptoCurrency.network == CryptoCurrencyNetwork.main
      ? kPivxBudgetCycleMain
      : kPivxBudgetCycleTest;

  /// Proposals with their status, and the budget, from the bridge's node.
  Future<PivxGovernance> loadGovernance() async {
    final results = await Future.wait([
      bridge.budgetInfo(),
      bridge.budgetProjection(),
      bridge.masternodeCount(),
      bridge.getBlockCount(),
    ]);
    final info = results[0] as List<Map<String, dynamic>>;
    final projection = results[1] as List<Map<String, dynamic>>;
    final count = results[2] as Map<String, dynamic>;
    final height = results[3] as int;

    final digits = cryptoCurrency.fractionDigits;
    final enabled = (count["enabled"] as num?)?.toInt() ?? 0;
    final funded = {for (final p in projection) p["Hash"] as String};
    var allocated = Amount.zeroWith(fractionDigits: digits);
    for (final p in projection) {
      allocated += PivxProposal._amount(p["Allotted"], digits);
    }

    PivxProposalStatus statusOf(Map<String, dynamic> p) {
      final remaining = (p["RemainingPaymentCount"] as num?)?.toInt() ?? 0;
      final net =
          ((p["Yeas"] as num?)?.toInt() ?? 0) -
          ((p["Nays"] as num?)?.toInt() ?? 0);
      if (remaining <= 0) return PivxProposalStatus.finished;
      if (funded.contains(p["Hash"])) return PivxProposalStatus.passing;
      if (p["IsEstablished"] != true) return PivxProposalStatus.waiting;
      // Core: not passing below a tenth of the enabled masternodes.
      if (net >= enabled ~/ 10 && net > 0) {
        return PivxProposalStatus.passingNotFunded;
      }
      return PivxProposalStatus.notPassing;
    }

    final proposals =
        [
            for (final p in info)
              PivxProposal._fromJson(
                p,
                fractionDigits: digits,
                status: statusOf(p),
              ),
          ].where((p) => p.status != PivxProposalStatus.finished).toList()
          ..sort((a, b) {
            final byVotes = b.netYes.compareTo(a.netYes);
            return byVotes != 0 ? byVotes : a.name.compareTo(b.name);
          });

    return PivxGovernance(
      proposals: proposals,
      chainHeight: height,
      cycleBlocks: budgetCycleBlocks,
      enabledMasternodes: enabled,
      totalBudget: Amount(
        rawValue:
            BigInt.from(_kBlockValueSats) * BigInt.from(budgetCycleBlocks),
        fractionDigits: digits,
      ),
      allocated: allocated,
    );
  }

  /// The current votes of this wallet's masternodes on [proposal], by
  /// masternode id ([PivxMasternode.id]).
  Future<Map<String, PivxMasternodeVote>> masternodeVotes(
    PivxProposal proposal,
  ) async {
    final mns = masternodes;
    if (mns.isEmpty) return const {};
    final byOutpoint = {
      for (final m in mns) pivxMasternodeOutpointId(m.txid, m.vout): m.id,
    };
    final votes = await bridge.budgetVotes(
      proposal.name,
      masternodeIds: byOutpoint.keys,
    );
    final result = <String, PivxMasternodeVote>{};
    for (final v in votes) {
      final id = byOutpoint[v["mnId"]];
      if (id == null || v["fValid"] == false) continue;
      final vote = switch ((v["Vote"] as String?)?.toUpperCase()) {
        "YES" => PivxVote.yes,
        "NO" => PivxVote.no,
        _ => null,
      };
      if (vote == null) continue;
      result[id] = PivxMasternodeVote(
        vote: vote,
        time: (v["nTime"] as num?)?.toInt() ?? 0,
      );
    }
    return result;
  }

  /// Vote [vote] on [proposal] with masternode [mn]: sign with its key and
  /// relay. Throws with the node's reason when the vote is not accepted
  /// (e.g. the masternode is not running, or it voted less than an hour
  /// ago).
  Future<void> voteOnProposal({
    required PivxProposal proposal,
    required PivxMasternode mn,
    required PivxVote vote,
  }) async {
    final wif = await masternodeKey(mn);
    if (wif == null) {
      throw Exception("The private key of ${mn.label} is missing");
    }
    final key = coinlib.WIF
        .fromString(wif, version: cryptoCurrency.networkParams.wifPrefix)
        .privkey;
    final time = DateTime.timestamp().millisecondsSinceEpoch ~/ 1000;
    final answer = await bridge.budgetRawVote(
      collateralTxid: mn.txid,
      collateralVout: mn.vout,
      proposalHash: proposal.hash,
      yes: vote == PivxVote.yes,
      time: time,
      signatureBase64: pivxBudgetVoteSignature(
        collateralTxid: mn.txid,
        collateralVout: mn.vout,
        proposalHash: proposal.hash,
        vote: vote,
        time: time,
        masternodeKey: key,
      ),
    );
    if (!answer.toLowerCase().contains("voted successfully")) {
      throw Exception(_voteError(answer));
    }
  }

  /// The node's answer, readable.
  static String _voteError(String answer) {
    final a = answer.replaceFirst(RegExp(r"^Error voting\s*:\s*"), "").trim();
    if (a.contains("Failure to find masternode")) {
      return "The network doesn't know this masternode (start it first)";
    }
    return a.isEmpty ? "The vote was not accepted" : a;
  }
}
