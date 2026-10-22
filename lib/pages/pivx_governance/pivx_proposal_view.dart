import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/global/wallets_provider.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/amount/amount_formatter.dart';
import '../../utilities/block_explorers.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/isar/providers/wallet_info_provider.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/block_explorer_link.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/page_app_bar.dart';
import '../../widgets/rounded_white_container.dart';
import '../pivx_masternodes/pivx_masternodes_view.dart';
import 'pivx_governance_widgets.dart';

/// One budget proposal: what it asks for, how the network votes, and this
/// wallet's masternodes' votes. Pops `true` after a vote.
class PivxProposalView extends ConsumerStatefulWidget {
  const PivxProposalView({
    super.key,
    required this.walletId,
    required this.proposal,
    required this.governance,
  });

  static const routeName = "/pivxProposal";

  final String walletId;
  final PivxProposal proposal;
  final PivxGovernance governance;

  @override
  ConsumerState<PivxProposalView> createState() => _PivxProposalViewState();
}

class _PivxProposalViewState extends ConsumerState<PivxProposalView> {
  late Future<Map<String, PivxMasternodeVote>> _votes;
  late Future<List<PivxProposalPayout>> _payouts;
  late PivxProposal _proposal = widget.proposal;
  late PivxGovernance _governance = widget.governance;
  bool _voted = false;

  PivxWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;

  @override
  void initState() {
    super.initState();
    _votes = _wallet.masternodeVotes(
      widget.proposal,
      governance: widget.governance,
    );
    _payouts = _wallet.proposalPayouts(
      widget.proposal,
      chainHeight: ref.read(pWalletChainHeight(widget.walletId)),
    );
  }

  Future<void> _vote(PivxVote vote) async {
    Map<String, PivxMasternodeVote> current;
    try {
      current = await _votes;
    } catch (_) {
      current = const {};
    }
    if (!mounted) return;
    final done = await showPivxSheet<bool>(
      context,
      (_) => _VoteSheet(
        wallet: _wallet,
        proposal: _proposal,
        vote: vote,
        current: current,
      ),
    );
    if (done == true && mounted) {
      _voted = true;
      // The new tally first: it tells whose votes the node answers with.
      await _reloadTally();
      if (!mounted) return;
      setState(
        () => _votes = _wallet.masternodeVotes(
          _proposal,
          governance: _governance,
        ),
      );
    }
  }

  /// The vote counts as the network has them now (Core counts a relayed
  /// vote right away).
  Future<void> _reloadTally() async {
    try {
      final governance = await _wallet.loadGovernance();
      final proposal = [
        ...governance.current,
        ...governance.future,
      ].where((p) => p.hash == _proposal.hash).firstOrNull;
      if (proposal == null || !mounted) return;
      setState(() {
        _governance = governance;
        _proposal = proposal;
      });
    } catch (_) {
      // The list refreshes when this page closes.
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final fmt = ref.watch(pAmountFormatter(wallet.cryptoCurrency));
    final p = _proposal;
    final g = _governance;
    final masternodes = wallet.masternodes;
    // The last superblock paying it (Core's end block lies past it).
    final lastSuperblock =
        p.blockStart + (p.totalPayments - 1) * wallet.budgetCycleBlocks;
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);

    Widget fact(String title, String value) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: secondary),
          const SizedBox(height: 2),
          Text(value, style: STextStyles.w600_14(context)),
        ],
      ),
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_voted);
      },
      child: Background(
        child: Scaffold(
          backgroundColor: colors.background,
          appBar: PageAppBar(
            onBack: () => Navigator.of(context).pop(_voted),
            title: Text("Proposal", style: STextStyles.navBarTitle(context)),
          ),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    children: [
                      RoundedWhiteContainer(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: SelectableText(
                                    p.name,
                                    style: STextStyles.pageTitleH2(context),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                PivxProposalStatusPill(status: p.status),
                              ],
                            ),
                            if (p.url.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () =>
                                    openPivxProposalUrl(context, p.url),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.open_in_new_rounded,
                                        size: 16,
                                        color: colors.accentColorBlue,
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          p.url,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: STextStyles.w500_12(context)
                                              .copyWith(
                                                color: colors.accentColorBlue,
                                              ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                            if (!p.isValid) ...[
                              const SizedBox(height: 8),
                              Text(
                                "Invalid: ${p.invalidReason ?? "unknown reason"}",
                                style: STextStyles.w500_12(context)
                                    .copyWith(color: colors.textError),
                              ),
                            ],
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                fact(
                                  "Per superblock",
                                  fmt.format(p.monthlyPayment),
                                ),
                                fact("In total", fmt.format(p.totalPayment)),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: FutureBuilder<List<PivxProposalPayout>>(
                                    future: _payouts,
                                    builder: (context, snapshot) {
                                      final payouts = snapshot.data;
                                      final paid = payouts
                                          ?.where(
                                            (e) =>
                                                e.state == PivxPayoutState.paid,
                                          )
                                          .length;
                                      return Row(
                                        children: [
                                          fact(
                                            "Paid",
                                            paid == null
                                                ? "…"
                                                : "$paid of ${p.totalPayments}",
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                ),
                                if (p.totalPayments > 1)
                                  fact(
                                    "Superblocks",
                                    "${p.blockStart} – $lastSuperblock",
                                  )
                                else
                                  fact("Superblock", "${p.blockStart}"),
                              ],
                            ),
                            if (p.status == PivxProposalStatus.waiting) ...[
                              const SizedBox(height: 12),
                              Text(
                                "New proposals can only be funded once "
                                "they are a day old (5 minutes on testnet).",
                                style: secondary,
                              ),
                            ],
                            if (p.status ==
                                PivxProposalStatus.passingNotFunded) ...[
                              const SizedBox(height: 12),
                              Text(
                                "Enough votes, but the budget is used up by "
                                "proposals with more votes.",
                                style: secondary,
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      RoundedWhiteContainer(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text("Votes", style: STextStyles.w600_14(context)),
                            const SizedBox(height: 10),
                            PivxVotesBar(
                              yeas: p.yeas,
                              nays: p.nays,
                              netYesPercent: g.netYesPercent(p),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              "Passes with ${g.requiredNetYes} net Yes "
                              "${g.requiredNetYes == 1 ? "vote" : "votes"} "
                              "(more than 10% of ${g.enabledMasternodes} "
                              "masternodes online)",
                              style: secondary,
                            ),
                            if (p.abstains > 0) ...[
                              const SizedBox(height: 4),
                              Text("${p.abstains} abstained", style: secondary),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      RoundedWhiteContainer(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              "Payouts",
                              style: STextStyles.w600_14(context),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              "One per superblock, if the proposal passes "
                              "then. Checked on the blockchain.",
                              style: secondary,
                            ),
                            const SizedBox(height: 4),
                            FutureBuilder<List<PivxProposalPayout>>(
                              future: _payouts,
                              builder: (context, snapshot) {
                                if (snapshot.hasError) {
                                  return Text(
                                    "Couldn't check the payouts",
                                    style: secondary,
                                  );
                                }
                                final payouts = snapshot.data;
                                if (payouts == null) {
                                  return const Padding(
                                    padding: EdgeInsets.all(8),
                                    child: Center(
                                      child: CircularProgressIndicator(),
                                    ),
                                  );
                                }
                                final height = ref.watch(
                                  pWalletChainHeight(widget.walletId),
                                );
                                return Column(
                                  children: [
                                    for (final payout in payouts)
                                      PivxPayoutRow(
                                        payout: payout,
                                        amount: payout.amount == null
                                            ? null
                                            : fmt.format(payout.amount!),
                                        chainHeight: height,
                                        blockSeconds: wallet
                                            .cryptoCurrency
                                            .targetBlockTimeSeconds,
                                        onOpen: payout.txid == null
                                            ? null
                                            : () => openInBlockExplorer(
                                                context,
                                                ref,
                                                getBlockExplorerTransactionUrlFor(
                                                  coin: wallet.cryptoCurrency,
                                                  txid: payout.txid!,
                                                ),
                                              ),
                                      ),
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      RoundedWhiteContainer(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              "Your masternodes",
                              style: STextStyles.w600_14(context),
                            ),
                            const SizedBox(height: 8),
                            if (masternodes.isEmpty)
                              Text(
                                "Voting takes a masternode. This wallet has "
                                "none; add one under Masternodes.",
                                style: secondary,
                              )
                            else
                              FutureBuilder<Map<String, PivxMasternodeVote>>(
                                future: _votes,
                                builder: (context, snapshot) {
                                  if (snapshot.hasError) {
                                    return Text(
                                      "Couldn't load your votes",
                                      style: secondary,
                                    );
                                  }
                                  final votes = snapshot.data;
                                  final ordered = votes == null
                                      ? masternodes
                                      : pivxByLatestVote(masternodes, votes);
                                  final shown = pivxVotesShownOf(
                                    ordered.length,
                                  );
                                  final more =
                                      votes != null && shown < ordered.length;
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (more) ...[
                                        PivxVoteCounts(
                                          masternodes: masternodes,
                                          votes: votes,
                                        ),
                                        const SizedBox(height: 4),
                                      ],
                                      for (final mn in ordered.take(shown))
                                        PivxMasternodeVoteRow(
                                          wallet: wallet,
                                          masternode: mn,
                                          vote: votes?[mn.id],
                                          loading: votes == null,
                                        ),
                                      if (more)
                                        Align(
                                          alignment: Alignment.centerLeft,
                                          child: Padding(
                                            padding: const EdgeInsets.only(
                                              top: 6,
                                            ),
                                            child: PivxShowAllChip(
                                              count: ordered.length,
                                              onTap: () =>
                                                  showPivxMasternodeVotesSheet(
                                                    context,
                                                    wallet: wallet,
                                                    proposalName: p.name,
                                                    votes: votes,
                                                  ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      RoundedWhiteContainer(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            PivxCopyRow(
                              title: "Payment address",
                              value: p.paymentAddress,
                              openTooltip: "Open in the block explorer",
                              onOpen: () => openInBlockExplorer(
                                context,
                                ref,
                                getBlockExplorerAddressUrlFor(
                                  coin: wallet.cryptoCurrency,
                                  address: p.paymentAddress,
                                ),
                                what: "address",
                              ),
                            ),
                            PivxCopyRow(title: "Proposal hash", value: p.hash),
                            if (p.feeHash.isNotEmpty)
                              PivxCopyRow(
                                title: "Fee transaction",
                                value: p.feeHash,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (masternodes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: SecondaryButton(
                            label: "Vote No",
                            onPressed: () => _vote(PivxVote.no),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: PrimaryButton(
                            label: "Vote Yes",
                            onPressed: () => _vote(PivxVote.yes),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _Result { pending, running, done, failed }

/// Pick the masternodes that vote [vote], then sign and relay one vote
/// each. Pops `true` when at least one vote went through.
class _VoteSheet extends StatefulWidget {
  const _VoteSheet({
    required this.wallet,
    required this.proposal,
    required this.vote,
    required this.current,
  });

  final PivxWallet wallet;
  final PivxProposal proposal;
  final PivxVote vote;
  final Map<String, PivxMasternodeVote> current;

  @override
  State<_VoteSheet> createState() => _VoteSheetState();
}

class _VoteSheetState extends State<_VoteSheet> {
  late final List<PivxMasternode> _masternodes = widget.wallet.masternodes;
  late final Set<String> _selected = {
    for (final m in _masternodes)
      if (_blockedReason(m) == null) m.id,
  };
  final _results = <String, (_Result, String?)>{};
  bool _running = false;
  String _query = "";

  bool get _finished =>
      _results.isNotEmpty &&
      _results.values.every(
        (r) => r.$1 == _Result.done || r.$1 == _Result.failed,
      );

  int _count(_Result result) =>
      _results.values.where((r) => r.$1 == result).length;

  /// Why [m] can't cast this vote now, or null.
  String? _blockedReason(PivxMasternode m) {
    final v = widget.current[m.id];
    if (v == null) return null;
    if (v.vote == widget.vote) {
      return "Already voted ${widget.vote == PivxVote.yes ? "Yes" : "No"}";
    }
    if (!v.canChange) {
      final wait = v.changeableAt.difference(DateTime.now()).inSeconds;
      return "Can change its vote in ~${pivxDuration(wait)}";
    }
    return null;
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      for (final id in _selected) {
        _results[id] = (_Result.pending, null);
      }
    });
    for (final m in _masternodes.where((m) => _selected.contains(m.id))) {
      if (!mounted) return;
      setState(() => _results[m.id] = (_Result.running, null));
      try {
        await widget.wallet.voteOnProposal(
          proposal: widget.proposal,
          mn: m,
          vote: widget.vote,
        );
        if (mounted) setState(() => _results[m.id] = (_Result.done, null));
      } catch (e) {
        if (mounted) {
          setState(
            () => _results[m.id] = (
              _Result.failed,
              e.toString().replaceFirst("Exception: ", ""),
            ),
          );
        }
      }
    }
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final yes = widget.vote == PivxVote.yes;
    final voteColor = pivxVoteColor(widget.vote, colors);
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    final done = _count(_Result.done);
    final failed = _count(_Result.failed);
    final many = _masternodes.length > kPivxManyMasternodes;
    final shown = [
      for (final m in _masternodes)
        if (pivxMasternodeMatches(m, _query)) m,
    ];
    // What "Select all" picks: the listed ones that can cast this vote.
    final selectable = [
      for (final m in shown)
        if (_blockedReason(m) == null) m.id,
    ];
    final allSelected = selectable.every(_selected.contains);

    return PivxSheetLayout(
      fullHeight: many,
      header: [
        Row(
          children: [
            Icon(
              yes ? Icons.thumb_up_alt_rounded : Icons.thumb_down_alt_rounded,
              color: voteColor,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                "Vote ${yes ? "Yes" : "No"}",
                style: STextStyles.pageTitleH2(context),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          widget.proposal.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: secondary,
        ),
        if (many) ...[
          const SizedBox(height: 12),
          PivxMasternodeSearchField(
            onChanged: (q) => setState(() => _query = q),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  "${_selected.length} of ${_masternodes.length} selected",
                  style: secondary,
                ),
              ),
              if (_results.isEmpty && selectable.isNotEmpty)
                CustomTextButton(
                  text: allSelected ? "Select none" : "Select all",
                  onTap: () => setState(
                    () => allSelected
                        ? _selected.removeAll(selectable)
                        : _selected.addAll(selectable),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 12),
      ],
      list: shown.isEmpty
          ? pivxNoMasternodeMatches(context, _query)
          : ListView.builder(
              shrinkWrap: !many,
              itemCount: shown.length,
              itemBuilder: (context, i) => _row(context, shown[i], many),
            ),
      footer: [
        const SizedBox(height: 8),
        if (many && _results.isNotEmpty) ...[
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: "$done of ${_results.length} accepted"),
                if (failed > 0)
                  TextSpan(
                    text: " · $failed failed",
                    style: TextStyle(color: colors.textError),
                  ),
              ],
            ),
            style: STextStyles.w600_12(context),
          ),
          const SizedBox(height: 4),
        ],
        Text(
          "Each masternode signs its vote with its private key. A vote "
          "can be changed once an hour.",
          style: secondary,
        ),
        const SizedBox(height: 16),
        if (_finished)
          PrimaryButton(
            label: "Done",
            onPressed: () => Navigator.of(context).pop(done > 0),
          )
        else
          PrimaryButton(
            label: _running
                ? "Voting… ${done + failed} of ${_results.length}"
                : _selected.isEmpty
                ? "Select a masternode"
                : "Vote ${yes ? "Yes" : "No"} with ${_selected.length} "
                      "masternode${_selected.length == 1 ? "" : "s"}",
            enabled: !_running && _selected.isNotEmpty,
            onPressed: _run,
          ),
      ],
    );
  }

  /// [showService]: the server's address too (a long list, searched by it).
  Widget _row(BuildContext context, PivxMasternode m, bool showService) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final blocked = _blockedReason(m);
    final result = _results[m.id];
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);

    final Widget trailing;
    String? subtitle = blocked;
    Color? subtitleColor;
    switch (result?.$1) {
      case null:
        trailing = Checkbox(
          value: _selected.contains(m.id),
          activeColor: colors.checkboxBGChecked,
          checkColor: colors.checkboxIconChecked,
          onChanged: blocked != null || _running
              ? null
              : (on) => setState(
                  () =>
                      on == true ? _selected.add(m.id) : _selected.remove(m.id),
                ),
        );
      case _Result.pending:
        trailing = Icon(Icons.more_horiz_rounded, color: colors.textSubtitle2);
        subtitle = "Waiting";
      case _Result.running:
        trailing = const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
        subtitle = "Signing and sending…";
      case _Result.done:
        trailing = Icon(
          Icons.check_circle_rounded,
          color: pivxVoteColor(PivxVote.yes, colors),
        );
        subtitle = "Vote accepted";
      case _Result.failed:
        trailing = Icon(Icons.error_rounded, color: colors.textError);
        subtitle = result!.$2;
        subtitleColor = colors.textError;
    }
    if (showService && m.service != null) {
      subtitle = subtitle == null ? m.service : "${m.service} · $subtitle";
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(m.label, style: STextStyles.w600_14(context)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: subtitleColor == null
                        ? secondary
                        : secondary.copyWith(color: subtitleColor),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(width: 40, child: Center(child: trailing)),
        ],
      ),
    );
  }
}
