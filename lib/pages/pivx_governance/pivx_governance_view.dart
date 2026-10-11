import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/global/wallets_provider.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/amount/amount_formatter.dart';
import '../../utilities/logger.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/rounded_white_container.dart';
import '../pivx_masternodes/pivx_masternodes_view.dart';
import 'pivx_governance_widgets.dart';
import 'pivx_proposal_view.dart';

enum _Filter {
  all("All"),
  passing("Passing"),
  notPassing("Not passing"),
  waiting("Waiting");

  const _Filter(this.label);

  final String label;

  bool shows(PivxProposalStatus s) => switch (this) {
    _Filter.all => true,
    _Filter.passing =>
      s == PivxProposalStatus.passing ||
          s == PivxProposalStatus.passingNotFunded,
    _Filter.notPassing => s == PivxProposalStatus.notPassing,
    _Filter.waiting => s == PivxProposalStatus.waiting,
  };
}

/// The network's budget proposals; vote on them with the wallet's
/// masternodes. From the wallet's "More" menu, next to Masternodes.
class PivxGovernanceView extends ConsumerStatefulWidget {
  const PivxGovernanceView({super.key, required this.walletId});

  static const routeName = "/pivxGovernance";

  final String walletId;

  @override
  ConsumerState<PivxGovernanceView> createState() => _PivxGovernanceViewState();
}

class _PivxGovernanceViewState extends ConsumerState<PivxGovernanceView> {
  late Future<PivxGovernance> _governance;

  /// This wallet's masternode votes, by proposal hash (filled in as they
  /// arrive).
  final _votes = <String, Map<String, PivxMasternodeVote>>{};
  int _generation = 0;

  _Filter _filter = _Filter.all;

  PivxWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final generation = ++_generation;
    _governance = _wallet.loadGovernance();
    _governance.then((g) => _loadVotes(g, generation), onError: (_) {});
  }

  /// One proposal at a time: a request each.
  Future<void> _loadVotes(PivxGovernance g, int generation) async {
    final wallet = _wallet;
    if (wallet.masternodes.isEmpty) return;
    for (final p in g.proposals) {
      if (!mounted || generation != _generation) return;
      try {
        final votes = await wallet.masternodeVotes(p);
        if (mounted && generation == _generation) {
          setState(() => _votes[p.hash] = votes);
        }
      } catch (e) {
        Logging.instance.w("PIVX: votes of ${p.name}: $e");
      }
    }
  }

  Future<void> _refresh() async {
    setState(_load);
    try {
      await _governance;
    } catch (_) {
      // Shown by the FutureBuilder.
    }
  }

  Future<void> _open(PivxProposal proposal, PivxGovernance governance) async {
    final changed = await Navigator.of(context).pushNamed(
      PivxProposalView.routeName,
      arguments: (
        walletId: widget.walletId,
        proposal: proposal,
        governance: governance,
      ),
    );
    if (changed == true && mounted) setState(_load);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          leading: AppBarBackButton(
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text("Governance", style: STextStyles.navBarTitle(context)),
        ),
        body: SafeArea(
          child: FutureBuilder<PivxGovernance>(
            future: _governance,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return _LoadError(
                  error: snapshot.error!,
                  onRetry: () => setState(_load),
                );
              }
              final g = snapshot.data;
              if (g == null) {
                return const Center(child: CircularProgressIndicator());
              }
              final shown = [
                for (final p in g.proposals)
                  if (_filter.shows(p.status)) p,
              ];
              return RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    _BudgetCard(wallet: _wallet, governance: g),
                    const SizedBox(height: 16),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final f in _Filter.values)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(
                                  "${f.label} "
                                  "${g.proposals.where((p) => f.shows(p.status)).length}",
                                ),
                                selected: _filter == f,
                                showCheckmark: false,
                                selectedColor: colors.accentColorBlue
                                    .withValues(alpha: 0.18),
                                backgroundColor: colors.popupBG,
                                side: BorderSide(
                                  color: _filter == f
                                      ? colors.accentColorBlue
                                      : colors.textFieldDefaultBG,
                                ),
                                labelStyle: STextStyles.w600_12(context)
                                    .copyWith(
                                      color: _filter == f
                                          ? colors.accentColorBlue
                                          : colors.textDark,
                                    ),
                                onSelected: (_) => setState(() => _filter = f),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (shown.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 40),
                        child: Text(
                          g.proposals.isEmpty
                              ? "No budget proposals right now."
                              : "No ${_filter.label.toLowerCase()} proposals.",
                          textAlign: TextAlign.center,
                          style: STextStyles.itemSubtitle(context),
                        ),
                      ),
                    for (final p in shown) ...[
                      const SizedBox(height: 10),
                      _ProposalCard(
                        wallet: _wallet,
                        proposal: p,
                        governance: g,
                        votes: _votes[p.hash],
                        onTap: () => _open(p, g),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The month's budget: what passing proposals take, and the next payout.
class _BudgetCard extends ConsumerWidget {
  const _BudgetCard({required this.wallet, required this.governance});

  final PivxWallet wallet;
  final PivxGovernance governance;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final fmt = ref.watch(pAmountFormatter(wallet.cryptoCurrency));
    final g = governance;
    final total = g.totalBudget.decimal.toDouble();
    final share = total <= 0
        ? 0.0
        : (g.allocated.decimal.toDouble() / total).clamp(0.0, 1.0);
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    final seconds =
        g.blocksToSuperblock * wallet.cryptoCurrency.targetBlockTimeSeconds;

    return RoundedWhiteContainer(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.account_balance_rounded,
                size: 18,
                color: colors.accentColorBlue,
              ),
              const SizedBox(width: 8),
              Text(
                "Budget per superblock",
                style: STextStyles.w600_14(context),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            fmt.format(g.allocated),
            style: STextStyles.pageTitleH2(context),
          ),
          Text("of ${fmt.format(g.totalBudget)} allocated", style: secondary),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: share,
              minHeight: 8,
              backgroundColor: colors.textFieldDefaultBG,
              color: colors.accentColorGreen,
            ),
          ),
          const SizedBox(height: 6),
          Text("${fmt.format(g.available)} still available", style: secondary),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(
                Icons.schedule_rounded,
                size: 16,
                color: colors.textSubtitle1,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  "Next superblock in ~${pivxDuration(seconds)} "
                  "(block ${g.nextSuperblock}, ${g.blocksToSuperblock} to go)",
                  style: secondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.dns_rounded, size: 16, color: colors.textSubtitle1),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  "${g.enabledMasternodes} masternodes vote; a proposal "
                  "needs ${g.requiredNetYes} more Yes than No",
                  style: secondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProposalCard extends ConsumerWidget {
  const _ProposalCard({
    required this.wallet,
    required this.proposal,
    required this.governance,
    required this.votes,
    required this.onTap,
  });

  final PivxWallet wallet;
  final PivxProposal proposal;
  final PivxGovernance governance;
  final Map<String, PivxMasternodeVote>? votes;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final fmt = ref.watch(pAmountFormatter(wallet.cryptoCurrency));
    final p = proposal;
    final labels = {for (final m in wallet.masternodes) m.id: m.label};
    final myVotes = [
      for (final e in (votes ?? const {}).entries)
        if (labels[e.key] != null) (label: labels[e.key]!, vote: e.value.vote),
    ];

    return RoundedWhiteContainer(
      padding: const EdgeInsets.all(14),
      onPressed: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  p.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: STextStyles.w600_14(context),
                ),
              ),
              const SizedBox(width: 8),
              PivxProposalStatusPill(status: p.status),
            ],
          ),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: fmt.format(p.monthlyPayment),
                  style: STextStyles.w600_12(context),
                ),
                TextSpan(
                  text:
                      " per superblock · "
                      "${p.remainingPayments} of ${p.totalPayments} "
                      "payment${p.totalPayments == 1 ? "" : "s"} left",
                  style: STextStyles.w500_12(context)
                      .copyWith(color: colors.textSubtitle1),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          PivxVotesBar(
            yeas: p.yeas,
            nays: p.nays,
            requiredNetYes: governance.requiredNetYes,
          ),
          if (myVotes.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final v in myVotes)
                  PivxVoteChip(label: v.label, vote: v.vote),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final text = error.toString().replaceFirst("Exception: ", "");
    final forbidden = text.contains("not allowed");
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.cloud_off_rounded, size: 48, color: colors.textSubtitle2),
          const SizedBox(height: 16),
          Text(
            "Couldn't load the proposals",
            textAlign: TextAlign.center,
            style: STextStyles.pageTitleH2(context),
          ),
          const SizedBox(height: 8),
          Text(
            forbidden
                ? "The node you are connected to doesn't offer governance "
                      "data. Try another PIVX node in the network settings."
                : text,
            textAlign: TextAlign.center,
            style: STextStyles.itemSubtitle(context),
          ),
          const SizedBox(height: 24),
          SecondaryButton(label: "Try again", onPressed: onRetry),
        ],
      ),
    );
  }
}
