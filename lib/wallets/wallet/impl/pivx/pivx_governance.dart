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

/// Burnt by a proposal's fee transaction (Core's PROPOSAL_FEE_TX).
const kPivxProposalFeeSats = 50 * 100000000;

/// Smallest payment a proposal can ask for (PROPOSAL_MIN_AMOUNT).
const kPivxProposalMinSats = 10 * 100000000;

/// Core's PROP_NAME_MAX_SIZE / PROP_URL_MAX_SIZE.
const kPivxProposalNameMax = 20;
const kPivxProposalUrlMax = 64;

/// Recipient "address" of a proposal's fee output (OP_RETURN with the
/// proposal hash): `"$kPivxOpReturnPrefix<hash hex>"`.
const kPivxOpReturnPrefix = "OP_RETURN:";

/// Characters Core keeps in proposal names and links (SAFE_CHARS_DEFAULT);
/// anything else would be stripped and change the proposal's hash.
final _kSafeChars = RegExp(r"^[A-Za-z0-9 .,;\-_/:?@()]*$");

/// Core's URL check (validateURL).
final _kUrlPattern = RegExp(
  r"^(https?)://[^\s/$.?#][^\s]*[^\s/.]\.[^\s/.][^\s]*[^\s.]$",
);

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

  PivxProposal _withStatus(PivxProposalStatus status) => PivxProposal._(
    name: name,
    url: url,
    hash: hash,
    feeHash: feeHash,
    paymentAddress: paymentAddress,
    blockStart: blockStart,
    blockEnd: blockEnd,
    totalPayments: totalPayments,
    remainingPayments: remainingPayments,
    yeas: yeas,
    nays: nays,
    abstains: abstains,
    monthlyPayment: monthlyPayment,
    isEstablished: isEstablished,
    isValid: isValid,
    invalidReason: invalidReason,
    status: status,
  );

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
    required this.current,
    required this.future,
    required this.pending,
    required this.chainHeight,
    required this.cycleBlocks,
    required this.enabledMasternodes,
    required this.totalBudget,
    required this.allocated,
    required this.futureAllocated,
  });

  /// Proposals the next superblock may pay (started already or starting
  /// then), most net yes votes first.
  final List<PivxProposal> current;

  /// Proposals starting at a later superblock.
  final List<PivxProposal> future;

  /// This wallet's proposals not yet on the network (fee confirming).
  final List<PivxPendingProposal> pending;

  final int chainHeight;
  final int cycleBlocks;
  final int enabledMasternodes;

  /// Paid out at most per superblock.
  final Amount totalBudget;

  /// Taken by the passing current proposals.
  final Amount allocated;

  /// Taken by the future proposals passing now.
  final Amount futureAllocated;

  int get nextSuperblock =>
      chainHeight - chainHeight % cycleBlocks + cycleBlocks;

  int get blocksToSuperblock => nextSuperblock - chainHeight;

  /// Net yes votes a proposal needs: 10 % of the masternodes online
  /// (Core: a tenth of the enabled ones).
  int get requiredNetYes => enabledMasternodes ~/ 10;

  /// Net yes votes as a share of the masternodes online (passing at 10 %),
  /// as pivx.org shows it.
  double netYesPercent(PivxProposal p) =>
      enabledMasternodes == 0 ? 0 : p.netYes * 100 / enabledMasternodes;
}

/// A proposal whose payments are over: from the bridge's node while it
/// still knows it, or from the pivx.org archive (mainnet).
class PivxPastProposal {
  PivxPastProposal({
    required this.hash,
    required this.name,
    required this.url,
    required this.passed,
    required this.monthlyPayment,
    required this.totalPayment,
    required this.yeas,
    required this.nays,
  });

  final String hash;
  final String name;
  final String url;

  /// Whether it passed (was funded).
  final bool passed;
  final Amount monthlyPayment;
  final Amount totalPayment;
  final int yeas;
  final int nays;

  /// Yes share of the votes cast.
  double get yesPercent => yeas + nays == 0 ? 0 : yeas * 100 / (yeas + nays);
}

/// A proposal this wallet paid the fee for, submitted to the network once
/// the fee transaction has enough confirmations.
class PivxPendingProposal {
  PivxPendingProposal({
    required this.name,
    required this.url,
    required this.payments,
    required this.blockStart,
    required this.paymentAddress,
    required this.amountSats,
    required this.hash,
    required this.feeTxid,
    required this.createdAt,
    this.error,
  });

  final String name;
  final String url;
  final int payments;
  final int blockStart;
  final String paymentAddress;

  /// Per superblock.
  final BigInt amountSats;
  final String hash;
  final String feeTxid;

  /// Unix seconds.
  final int createdAt;

  /// Why submitting failed for good (the fee is lost), if it did.
  final String? error;

  PivxPendingProposal withError(String error) => PivxPendingProposal(
    name: name,
    url: url,
    payments: payments,
    blockStart: blockStart,
    paymentAddress: paymentAddress,
    amountSats: amountSats,
    hash: hash,
    feeTxid: feeTxid,
    createdAt: createdAt,
    error: error,
  );

  Map<String, dynamic> toJson() => {
    "name": name,
    "url": url,
    "payments": payments,
    "blockStart": blockStart,
    "address": paymentAddress,
    "amount": amountSats.toString(),
    "hash": hash,
    "feeTxid": feeTxid,
    "createdAt": createdAt,
    if (error != null) "error": error,
  };

  factory PivxPendingProposal.fromJson(Map<String, dynamic> json) =>
      PivxPendingProposal(
        name: json["name"] as String,
        url: json["url"] as String,
        payments: json["payments"] as int,
        blockStart: json["blockStart"] as int,
        paymentAddress: json["address"] as String,
        amountSats: BigInt.parse(json["amount"] as String),
        hash: json["hash"] as String,
        feeTxid: json["feeTxid"] as String,
        createdAt: json["createdAt"] as int,
        error: json["error"] as String?,
      );
}

/// Last superblock paying a proposal (CBudgetProposal's nBlockEnd).
int pivxProposalBlockEnd({
  required int blockStart,
  required int payments,
  required int cycleBlocks,
}) => blockStart + (cycleBlocks + 1) * payments;

/// A proposal's hash (display hex), as Core's `CBudgetProposal::GetHash`:
/// sha256d(name, url, start, end, amount, payee script).
String pivxProposalHash({
  required String name,
  required String url,
  required int blockStart,
  required int blockEnd,
  required BigInt amountSats,
  required Uint8List payeeScript,
}) {
  final w = _MnWriter()
    ..slice(utf8.encode(name))
    ..slice(utf8.encode(url))
    ..u32(blockStart)
    ..u32(blockEnd)
    ..u64(amountSats.toInt())
    ..slice(payeeScript);
  return Uint8List.fromList(coinlib.sha256DoubleHash(w.done).reversed.toList())
      .toHex;
}

/// The fee output's script: `OP_RETURN <hash>` (hash in Core's internal
/// byte order).
Uint8List pivxProposalFeeScript(String hashHex) => Uint8List.fromList([
  0x6a, // OP_RETURN
  0x20, // push 32 bytes
  ...hashHex.toUint8ListFromHex.reversed,
]);

/// Past proposals from pivx.org/proposals/past (server-rendered rows:
/// `<tr data-hash data-title>`, status, link, payment, votes).
List<PivxPastProposal> parsePivxProposalArchive(
  String html, {
  required int fractionDigits,
}) {
  String unescape(String s) => s
      .replaceAll("&amp;", "&")
      .replaceAll("&quot;", '"')
      .replaceAll("&#039;", "'")
      .replaceAll("&#39;", "'")
      .replaceAll("&lt;", "<")
      .replaceAll("&gt;", ">");

  final rows = RegExp(
    r'<tr data-hash="([0-9a-f]{64})" data-title="([^"]*)">([\s\S]*?)</tr>',
  );
  final result = <PivxPastProposal>[];
  for (final m in rows.allMatches(html)) {
    try {
      final body = m.group(3)!;
      final cells = RegExp(r"<td[^>]*>([\s\S]*?)</td>")
          .allMatches(body)
          .toList();
      if (cells.length < 4) continue;
      final status = RegExp(r"<b>([^<]+)</b>")
          .firstMatch(cells[0].group(1)!)
          ?.group(1)
          ?.trim()
          .toLowerCase();
      final link = RegExp(r'href="([^"]*)"').firstMatch(body)?.group(1);
      final monthly = RegExp(r'data-order="([0-9.]+)"')
          .allMatches(body)
          .elementAtOrNull(1)
          ?.group(1);
      final total = RegExp(r"<b>([0-9,.]+)\s*<span")
          .firstMatch(cells[2].group(1)!)
          ?.group(1)
          ?.replaceAll(",", "");
      final votes = RegExp(r"(\d+)\s*/\s*(\d+)")
          .firstMatch(cells[3].group(1)!.replaceAll(RegExp("<[^>]+>"), " "));
      if (monthly == null || votes == null) continue;
      final monthlyAmount = Decimal.parse(monthly)
          .toAmount(fractionDigits: fractionDigits);
      result.add(
        PivxPastProposal(
          hash: m.group(1)!,
          name: unescape(m.group(2)!),
          url: link == null ? "" : unescape(link),
          passed: status == "passing" || status == "passed",
          monthlyPayment: monthlyAmount,
          totalPayment: total == null
              ? monthlyAmount
              : Decimal.parse(total).toAmount(fractionDigits: fractionDigits),
          yeas: int.parse(votes.group(1)!),
          nays: int.parse(votes.group(2)!),
        ),
      );
    } catch (_) {
      // A row in another layout: skip it.
    }
  }
  return result;
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
  bool get _mainnet => cryptoCurrency.network == CryptoCurrencyNetwork.main;

  int get budgetCycleBlocks =>
      _mainnet ? kPivxBudgetCycleMain : kPivxBudgetCycleTest;

  /// Most payments a proposal can ask for (nMaxProposalPayments).
  int get maxProposalPayments => _mainnet ? 6 : 20;

  /// Confirmations the fee needs before the proposal is accepted
  /// (nBudgetFeeConfirmations).
  int get proposalFeeConfirmations => _mainnet ? 6 : 3;

  /// Most a proposal can ask per superblock.
  Amount get budgetPerSuperblock => Amount(
    rawValue: BigInt.from(_kBlockValueSats) * BigInt.from(budgetCycleBlocks),
    fractionDigits: cryptoCurrency.fractionDigits,
  );

  static const _kPendingProposals = "pivxPendingProposals";

  /// This wallet's proposals waiting to be submitted (or that failed).
  List<PivxPendingProposal> get pendingProposals => [
    for (final e in (info.otherData[_kPendingProposals] as List?) ?? const [])
      PivxPendingProposal.fromJson(Map<String, dynamic>.from(e as Map)),
  ];

  Future<void> _savePending(List<PivxPendingProposal> list) =>
      info.updateOtherData(
        newEntries: {
          _kPendingProposals: [for (final p in list) p.toJson()],
        },
        isar: mainDB.isar,
      );

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
    final cycle = budgetCycleBlocks;
    final nextSuperblock = height - height % cycle + cycle;
    final enabled = (count["enabled"] as num?)?.toInt() ?? 0;
    final required = enabled ~/ 10;
    final total = budgetPerSuperblock;

    // Current: Core's projection of the next superblock decides.
    final funded = {for (final p in projection) p["Hash"] as String};
    var allocated = Amount.zeroWith(fractionDigits: digits);
    for (final p in projection) {
      allocated += PivxProposal._amount(p["Allotted"], digits);
    }

    PivxProposalStatus byVotes(Map<String, dynamic> p) {
      final net =
          ((p["Yeas"] as num?)?.toInt() ?? 0) -
          ((p["Nays"] as num?)?.toInt() ?? 0);
      if (p["IsEstablished"] != true) return PivxProposalStatus.waiting;
      // Core: not passing below a tenth of the enabled masternodes.
      if (net >= required && net > 0) {
        return PivxProposalStatus.passingNotFunded;
      }
      return PivxProposalStatus.notPassing;
    }

    int byNetYes(PivxProposal a, PivxProposal b) {
      final c = b.netYes.compareTo(a.netYes);
      return c != 0 ? c : a.name.compareTo(b.name);
    }

    final open = info.where(
      (p) => ((p["RemainingPaymentCount"] as num?)?.toInt() ?? 0) > 0,
    );
    final current = [
      for (final p in open)
        if (((p["BlockStart"] as num?)?.toInt() ?? 0) <= nextSuperblock)
          PivxProposal._fromJson(
            p,
            fractionDigits: digits,
            status: funded.contains(p["Hash"])
                ? PivxProposalStatus.passing
                : byVotes(p),
          ),
    ]..sort(byNetYes);

    // Future: what would be funded if the votes stay, per start
    // superblock, most net yes first (like Core fills a budget).
    final futureRaw = [
      for (final p in open)
        if (((p["BlockStart"] as num?)?.toInt() ?? 0) > nextSuperblock)
          PivxProposal._fromJson(p, fractionDigits: digits, status: byVotes(p)),
    ]..sort(byNetYes);
    final usedPerStart = <int, BigInt>{};
    var futureAllocated = Amount.zeroWith(fractionDigits: digits);
    final future = [
      for (final p in futureRaw)
        () {
          if (p.status != PivxProposalStatus.passingNotFunded) return p;
          final used = usedPerStart[p.blockStart] ?? BigInt.zero;
          if (used + p.monthlyPayment.raw > total.raw) return p;
          usedPerStart[p.blockStart] = used + p.monthlyPayment.raw;
          futureAllocated += p.monthlyPayment;
          return p._withStatus(PivxProposalStatus.passing);
        }(),
    ];

    final onNetwork = {for (final p in info) p["Hash"] as String};
    return PivxGovernance(
      current: current,
      future: future,
      pending: [
        for (final p in pendingProposals)
          if (!onNetwork.contains(p.hash)) p,
      ],
      chainHeight: height,
      cycleBlocks: cycle,
      enabledMasternodes: enabled,
      totalBudget: total,
      allocated: allocated,
      futureAllocated: futureAllocated,
    );
  }

  /// Finished proposals: those the node still knows, plus (mainnet, with
  /// [includeArchive]) the pivx.org archive. Newest first as listed there.
  Future<List<PivxPastProposal>> loadPastProposals({
    required bool includeArchive,
  }) async {
    final digits = cryptoCurrency.fractionDigits;
    final result = <String, PivxPastProposal>{};
    for (final p in await bridge.budgetInfo()) {
      if (((p["RemainingPaymentCount"] as num?)?.toInt() ?? 0) > 0) continue;
      final proposal = PivxProposal._fromJson(
        p,
        fractionDigits: digits,
        status: PivxProposalStatus.finished,
      );
      result[proposal.hash] = PivxPastProposal(
        hash: proposal.hash,
        name: proposal.name,
        url: proposal.url,
        passed:
            (p["TotalPaymentCount"] as num? ?? 0) > 0 && proposal.netYes > 0,
        monthlyPayment: proposal.monthlyPayment,
        totalPayment: proposal.totalPayment,
        yeas: proposal.yeas,
        nays: proposal.nays,
      );
    }
    if (includeArchive && _mainnet) {
      final response = await const HTTP().get(
        url: Uri.parse("https://pivx.org/proposals/past"),
        proxyInfo: bridge.useTor
            ? TorService.sharedInstance.getProxyInfo()
            : null,
        connectionTimeout: const Duration(seconds: 20),
      );
      if (response.code != 200) {
        throw Exception("pivx.org answered ${response.code}");
      }
      for (final p in parsePivxProposalArchive(
        response.body,
        fractionDigits: digits,
      )) {
        result.putIfAbsent(p.hash, () => p);
      }
    }
    return result.values.toList();
  }

  // ---------------------------------------------------------------------------
  // Creating proposals

  /// Superblocks a new proposal can start at: the next one unless it's too
  /// close for the fee to confirm in time (a day on mainnet, like PIVX
  /// Core's wallet), then the following ones.
  List<int> proposalStartSuperblocks(int chainHeight, {int count = 4}) {
    final cycle = budgetCycleBlocks;
    final margin = _mainnet ? 1440 : 10;
    var next = chainHeight - chainHeight % cycle + cycle;
    if (next - margin < chainHeight) next += cycle;
    return [for (int i = 0; i < count; i++) next + i * cycle];
  }

  String? proposalNameError(String name) {
    if (name.isEmpty) return "Enter a name";
    if (name.length > kPivxProposalNameMax) {
      return "At most $kPivxProposalNameMax characters";
    }
    if (!_kSafeChars.hasMatch(name)) {
      return "Letters, digits, spaces and . , ; - _ / : ? @ ( ) only";
    }
    return null;
  }

  String? proposalUrlError(String url) {
    if (url.isEmpty) return "Enter the link to the proposal's description";
    if (url.length > kPivxProposalUrlMax) {
      return "At most $kPivxProposalUrlMax characters";
    }
    if (!_kSafeChars.hasMatch(url) || !_kUrlPattern.hasMatch(url)) {
      return "Not a valid web link (https://…)";
    }
    return null;
  }

  String? proposalAmountError(Amount? amount) {
    if (amount == null) return "Enter an amount";
    if (amount.raw < BigInt.from(kPivxProposalMinSats)) {
      return "At least ${kPivxProposalMinSats ~/ 100000000} "
          "${cryptoCurrency.ticker}";
    }
    if (amount.raw > budgetPerSuperblock.raw) {
      return "At most ${budgetPerSuperblock.decimal} "
          "${cryptoCurrency.ticker} (the whole budget)";
    }
    return null;
  }

  String? proposalAddressError(String address) {
    if (address.isEmpty) return "Enter the address to pay";
    if (!cryptoCurrency.validateAddress(address) ||
        isShieldAddress(address) ||
        cryptoCurrency.isExchangeAddress(address)) {
      return "A transparent ${cryptoCurrency.ticker} address (D…)";
    }
    return null;
  }

  /// The fee transaction of a new proposal: [kPivxProposalFeeSats] burnt
  /// in an `OP_RETURN` with the proposal's hash. Confirm with
  /// [confirmSend], then [addPendingProposal].
  Future<(TxData, PivxPendingProposal)> prepareProposal({
    required String name,
    required String url,
    required int payments,
    required int blockStart,
    required String paymentAddress,
    required Amount amount,
  }) async {
    final error =
        proposalNameError(name) ??
        proposalUrlError(url) ??
        proposalAmountError(amount) ??
        proposalAddressError(paymentAddress);
    if (error != null) throw Exception(error);
    if (payments < 1 || payments > maxProposalPayments) {
      throw Exception("Between 1 and $maxProposalPayments payments");
    }
    final payee = coinlib.Address.fromString(
      paymentAddress,
      cryptoCurrency.networkParams,
    ).program.script.compiled;
    final hash = pivxProposalHash(
      name: name,
      url: url,
      blockStart: blockStart,
      blockEnd: pivxProposalBlockEnd(
        blockStart: blockStart,
        payments: payments,
        cycleBlocks: budgetCycleBlocks,
      ),
      amountSats: amount.raw,
      payeeScript: payee,
    );
    final txData = await prepareSend(
      txData: TxData(
        note: "Proposal fee: $name",
        noteOnChain: "",
        recipients: [
          TxRecipient(
            address: "$kPivxOpReturnPrefix$hash",
            amount: Amount(
              rawValue: BigInt.from(kPivxProposalFeeSats),
              fractionDigits: cryptoCurrency.fractionDigits,
            ),
            isChange: false,
            addressType: AddressType.nonWallet,
          ),
        ],
      ),
    );
    return (
      txData,
      PivxPendingProposal(
        name: name,
        url: url,
        payments: payments,
        blockStart: blockStart,
        paymentAddress: paymentAddress,
        amountSats: amount.raw,
        hash: hash,
        feeTxid: "",
        createdAt: DateTime.timestamp().millisecondsSinceEpoch ~/ 1000,
      ),
    );
  }

  /// Remember [proposal] whose fee went out in [feeTxid]; it is submitted
  /// once the fee is confirmed (see [submitPendingProposals]).
  Future<void> addPendingProposal(
    PivxPendingProposal proposal,
    String feeTxid,
  ) => _savePending([
    ...pendingProposals.where((p) => p.hash != proposal.hash),
    PivxPendingProposal(
      name: proposal.name,
      url: proposal.url,
      payments: proposal.payments,
      blockStart: proposal.blockStart,
      paymentAddress: proposal.paymentAddress,
      amountSats: proposal.amountSats,
      hash: proposal.hash,
      feeTxid: feeTxid,
      createdAt: proposal.createdAt,
    ),
  ]);

  /// Forget a pending proposal (after it failed).
  Future<void> removePendingProposal(String hash) =>
      _savePending([...pendingProposals.where((p) => p.hash != hash)]);

  /// Confirmations of a pending proposal's fee, null while unconfirmed.
  Future<int?> feeConfirmationsOf(PivxPendingProposal p) async {
    final tx = await mainDB.isar.transactionV2s
        .where()
        .txidWalletIdEqualTo(p.feeTxid, walletId)
        .findFirst();
    final height = tx?.height;
    if (height == null || height <= 0) return null;
    return await chainHeight - height + 1;
  }

  /// Submit the pending proposals whose fee is confirmed enough; called
  /// after every sync. A proposal the network already knows is done; one
  /// whose start superblock passed before it could be submitted failed
  /// (its fee is spent).
  Future<void> submitPendingProposals() async {
    final pending = pendingProposals;
    if (pending.isEmpty) return;
    final known = {for (final p in await bridge.budgetInfo()) p["Hash"]};
    final height = await chainHeight;
    final kept = <PivxPendingProposal>[];
    for (final p in pending) {
      if (known.contains(p.hash)) continue;
      if (p.error != null) {
        kept.add(p);
        continue;
      }
      final confs = await feeConfirmationsOf(p);
      if (confs == null || confs < proposalFeeConfirmations) {
        kept.add(
          height >= p.blockStart
              ? p.withError(
                  "Its start (block ${p.blockStart}) passed before the fee "
                  "was confirmed",
                )
              : p,
        );
        continue;
      }
      try {
        final hash = await bridge.submitBudget(
          name: p.name,
          url: p.url,
          payments: p.payments,
          blockStart: p.blockStart,
          paymentAddress: p.paymentAddress,
          amount: Amount(
            rawValue: p.amountSats,
            fractionDigits: cryptoCurrency.fractionDigits,
          ).decimal.toString(),
          feeTxid: p.feeTxid,
        );
        if (hash != p.hash) {
          Logging.instance.w(
            "PIVX: proposal ${p.name} submitted as $hash, expected ${p.hash}",
          );
        }
      } catch (e) {
        Logging.instance.w("PIVX: submitting proposal ${p.name} failed: $e");
        final message = e.toString();
        kept.add(
          height >= p.blockStart || message.contains("invalid budget proposal")
              ? p.withError(message.replaceFirst("Exception: ", ""))
              : p,
        );
      }
    }
    await _savePending(kept);
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
