import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/global/prefs_provider.dart';
import '../../providers/global/wallets_provider.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/amount/amount.dart';
import '../../utilities/amount/amount_formatter.dart';
import '../../utilities/logger.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/crypto_currency/crypto_currency.dart';
import '../../wallets/isar/providers/wallet_info_provider.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/page_app_bar.dart';
import '../../widgets/rounded_white_container.dart';
import '../pivx_masternodes/pivx_masternodes_view.dart';
import 'pivx_create_proposal_view.dart';
import 'pivx_governance_widgets.dart';
import 'pivx_proposal_view.dart';

enum _Tab {
  past,
  current,
  future;

  String get label => switch (this) {
    past => l10n.govTabPast,
    current => l10n.govTabCurrent,
    future => l10n.govTabFuture,
  };
}

enum _Filter {
  all,
  passing,
  notPassing,
  waiting;

  String get label => switch (this) {
    all => l10n.govFilterAll,
    passing => l10n.govFilterPassing,
    notPassing => l10n.govFilterNotPassing,
    waiting => l10n.govFilterWaiting,
  };

  /// "No … proposals." for this filter.
  String get empty => switch (this) {
    all => l10n.govNoneNext,
    passing => l10n.govNonePassing,
    notPassing => l10n.govNoneNotPassing,
    waiting => l10n.govNoneWaiting,
  };

  bool shows(PivxProposalStatus s) => switch (this) {
    _Filter.all => true,
    _Filter.passing =>
      s == PivxProposalStatus.passing ||
          s == PivxProposalStatus.passingNotFunded,
    _Filter.notPassing => s == PivxProposalStatus.notPassing,
    _Filter.waiting => s == PivxProposalStatus.waiting,
  };
}

/// The network's budget proposals, as on pivx.org/proposals: Past,
/// Current (the next payout) and Future (later payouts). Vote with the
/// wallet's masternodes and create proposals. From the wallet's "More"
/// menu, next to Masternodes.
class PivxGovernanceView extends ConsumerStatefulWidget {
  const PivxGovernanceView({super.key, required this.walletId});

  static const routeName = "/pivxGovernance";

  final String walletId;

  @override
  ConsumerState<PivxGovernanceView> createState() => _PivxGovernanceViewState();
}

class _PivxGovernanceViewState extends ConsumerState<PivxGovernanceView> {
  late Future<PivxGovernance> _governance;
  Future<List<PivxPastProposal>>? _past;

  /// This wallet's masternode votes, by proposal hash (filled in as they
  /// arrive).
  final _votes = <String, Map<String, PivxMasternodeVote>>{};

  /// Where each proposal's payouts stand, by proposal hash (filled in as
  /// they arrive).
  final _payouts = <String, List<PivxProposalPayout>>{};
  int _generation = 0;

  /// Our proposals waiting for their fee to confirm: the list follows
  /// new blocks (their confirmations, then the submission).
  bool _hasPending = false;

  _Tab _tab = _Tab.current;
  _Filter _filter = _Filter.all;

  PivxWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;

  bool get _archiveAllowed =>
      ref.read(prefsChangeNotifierProvider).externalCalls;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final generation = ++_generation;
    final wallet = _wallet;
    _governance = () async {
      // Submit proposals whose fee confirmed meanwhile, then show them.
      if (wallet.pendingProposals.isNotEmpty) {
        try {
          await wallet.submitPendingProposals();
        } catch (e) {
          Logging.instance.w("PIVX: proposals: $e");
        }
      }
      return wallet.loadGovernance();
    }();
    _governance.then((g) {
      _hasPending = g.pending.isNotEmpty;
      _loadPayouts(g, generation);
      _loadVotes(g, generation);
    }, onError: (_) {});
    if (_past != null) _loadPast();
  }

  void _loadPast() {
    _past = _wallet
        .loadPastProposals(includeArchive: _archiveAllowed)
        .then(
          (list) => list
            ..sort((a, b) {
              if (a.passed != b.passed) return a.passed ? -1 : 1;
              return b.yeas.compareTo(a.yeas);
            }),
        );
  }

  /// One proposal at a time: a request each.
  Future<void> _loadVotes(PivxGovernance g, int generation) async {
    final wallet = _wallet;
    if (wallet.masternodes.isEmpty) return;
    for (final p in [...g.current, ...g.future]) {
      if (!mounted || generation != _generation) return;
      try {
        final votes = await wallet.masternodeVotes(p, governance: g);
        if (mounted && generation == _generation) {
          setState(() => _votes[p.hash] = votes);
        }
      } catch (e) {
        Logging.instance.w("PIVX: votes of ${p.name}: $e");
      }
    }
  }

  /// One proposal at a time: a request per payout due (settled ones are
  /// cached).
  Future<void> _loadPayouts(PivxGovernance g, int generation) async {
    final wallet = _wallet;
    for (final p in g.current) {
      if (!mounted || generation != _generation) return;
      try {
        final payouts = await wallet.proposalPayouts(
          p,
          chainHeight: g.chainHeight,
        );
        if (mounted && generation == _generation) {
          setState(() => _payouts[p.hash] = payouts);
        }
      } catch (e) {
        Logging.instance.w("PIVX: payouts of ${p.name}: $e");
      }
    }
  }

  Future<void> _refresh() async {
    setState(_load);
    try {
      await (_tab == _Tab.past ? _past : _governance);
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

  Future<void> _create() async {
    await Navigator.of(
      context,
    ).pushNamed(PivxCreateProposalView.routeName, arguments: widget.walletId);
    if (mounted) setState(_load);
  }

  Future<void> _removePending(PivxPendingProposal p) async {
    await _wallet.removePendingProposal(p.hash);
    if (mounted) setState(_load);
  }

  @override
  Widget build(BuildContext context) {
    // A new block: follow our waiting proposals without a pull.
    ref.listen(pWalletChainHeight(widget.walletId), (previous, next) {
      if (_hasPending && previous != next) setState(_load);
    });
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final canCreate = !wallet.isViewOnly;
    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: PageAppBar(
          title: Text(l10n.govTitle, style: STextStyles.navBarTitle(context)),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: _Tabs(
                  selected: _tab,
                  onSelected: (t) => setState(() {
                    _tab = t;
                    if (t == _Tab.past && _past == null) _loadPast();
                  }),
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _refresh,
                  child: _tab == _Tab.past ? _pastList() : _proposalList(),
                ),
              ),
              if (canCreate)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: PrimaryButton(
                    label: l10n.govCreateProposal,
                    onPressed: _create,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _proposalList() => FutureBuilder<PivxGovernance>(
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
      final future = _tab == _Tab.future;
      final all = future ? g.future : g.current;
      final shown = [
        for (final p in all)
          if (future || _filter.shows(p.status)) p,
      ];
      final pending = [
        for (final p in g.pending)
          if ((p.blockStart > g.nextSuperblock) == future) p,
      ];
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          _BudgetCard(wallet: _wallet, governance: g, future: future),
          if (!future) ...[const SizedBox(height: 14), _filterChips(g)],
          for (final p in pending) ...[
            const SizedBox(height: 10),
            _PendingCard(
              wallet: _wallet,
              proposal: p,
              onRemove: () => _removePending(p),
            ),
          ],
          if (shown.isEmpty && pending.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Text(
                future
                    ? l10n.govNoneLater
                    : all.isEmpty
                    ? l10n.govNoneNext
                    : _filter.empty,
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
              payouts: _payouts[p.hash],
              onTap: () => _open(p, g),
            ),
          ],
        ],
      );
    },
  );

  Widget _filterChips(PivxGovernance g) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final f in _Filter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(
                  "${f.label} "
                  "${g.current.where((p) => f.shows(p.status)).length}",
                ),
                selected: _filter == f,
                showCheckmark: false,
                selectedColor: colors.accentColorBlue.withValues(alpha: 0.18),
                backgroundColor: colors.popupBG,
                side: BorderSide(
                  color: _filter == f
                      ? colors.accentColorBlue
                      : colors.textFieldDefaultBG,
                ),
                labelStyle: STextStyles.w600_12(context).copyWith(
                  color: _filter == f
                      ? colors.accentColorBlue
                      : colors.textDark,
                ),
                onSelected: (_) => setState(() => _filter = f),
              ),
            ),
        ],
      ),
    );
  }

  Widget _pastList() => FutureBuilder<List<PivxPastProposal>>(
    future: _past,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return _LoadError(
          error: snapshot.error!,
          onRetry: () => setState(_loadPast),
        );
      }
      final past = snapshot.data;
      if (past == null) {
        return const Center(child: CircularProgressIndicator());
      }
      final wallet = _wallet;
      final mainnet =
          wallet.cryptoCurrency.network == CryptoCurrencyNetwork.main;
      final note = !mainnet
          ? l10n.govPastNetwork
          : _archiveAllowed
          ? l10n.govPastArchive
          : l10n.govPastIncognito;
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          Text(note, style: STextStyles.itemSubtitle(context)),
          if (past.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Text(
                l10n.govNoneFinished,
                textAlign: TextAlign.center,
                style: STextStyles.itemSubtitle(context),
              ),
            ),
          for (final p in past) ...[
            const SizedBox(height: 10),
            _PastCard(wallet: wallet, proposal: p),
          ],
        ],
      );
    },
  );
}

/// Past · Current · Future, like pivx.org/proposals.
class _Tabs extends StatelessWidget {
  const _Tabs({required this.selected, required this.onSelected});

  final _Tab selected;
  final ValueChanged<_Tab> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.textFieldDefaultBG,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          for (final t in _Tab.values)
            Expanded(
              child: GestureDetector(
                onTap: () => onSelected(t),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: t == selected ? colors.popupBG : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    t.label,
                    textAlign: TextAlign.center,
                    style: STextStyles.w600_14(context).copyWith(
                      color: t == selected
                          ? colors.textDark
                          : colors.textSubtitle1,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The budget per payout: what passing proposals take, the next payout
/// and what a proposal needs to pass.
class _BudgetCard extends ConsumerWidget {
  const _BudgetCard({
    required this.wallet,
    required this.governance,
    required this.future,
  });

  final PivxWallet wallet;
  final PivxGovernance governance;

  /// The Future tab: what later payouts would pay if votes hold.
  final bool future;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final fmt = ref.watch(pAmountFormatter(wallet.cryptoCurrency));
    final g = governance;
    final allocated = future ? g.futureAllocated : g.allocated;
    final total = g.totalBudget.decimal.toDouble();
    final share = total <= 0
        ? 0.0
        : (allocated.decimal.toDouble() / total).clamp(0.0, 1.0);
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    final seconds =
        g.blocksToSuperblock * wallet.cryptoCurrency.targetBlockTimeSeconds;

    Widget line(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: colors.textSubtitle1),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: secondary)),
        ],
      ),
    );

    return RoundedWhiteContainer(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      future ||
                              wallet.cryptoCurrency.network !=
                                  CryptoCurrencyNetwork.main
                          ? l10n.govBudgetPerPayout
                          : l10n.govMonthlyBudget,
                      style: secondary,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      fmt.format(g.totalBudget),
                      style: STextStyles.w600_14(context),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      future ? l10n.govAllocatedIfHold : l10n.govAllocated,
                      style: secondary,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      fmt.format(allocated),
                      style: STextStyles.w600_14(context)
                          .copyWith(color: colors.accentColorGreen),
                    ),
                  ],
                ),
              ),
            ],
          ),
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
          const SizedBox(height: 4),
          Text(
            l10n.govAvailable(fmt.format(g.totalBudget - allocated)),
            style: secondary,
          ),
          const SizedBox(height: 6),
          line(
            Icons.schedule_rounded,
            l10n.govNextPayoutIn(pivxDuration(seconds), g.nextSuperblock),
          ),
          line(
            Icons.how_to_vote_rounded,
            l10n.govToPass(g.requiredNetYes, g.enabledMasternodes),
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
    required this.payouts,
    required this.onTap,
  });

  final PivxWallet wallet;
  final PivxProposal proposal;
  final PivxGovernance governance;
  final Map<String, PivxMasternodeVote>? votes;

  /// Checked on chain; null until loaded.
  final List<PivxProposalPayout>? payouts;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final fmt = ref.watch(pAmountFormatter(wallet.cryptoCurrency));
    final p = proposal;
    final masternodes = wallet.masternodes;
    final myVotes = votes ?? const <String, PivxMasternodeVote>{};
    // Latest first: a few of them, the rest behind "Show all".
    final voted = [
      for (final m in pivxByLatestVote(masternodes, myVotes))
        if (myVotes[m.id] != null) m,
    ];
    final votesShown = pivxVotesShownOf(voted.length);
    final startsLater = p.blockStart > governance.nextSuperblock;
    int paid(List<PivxProposalPayout> payouts) =>
        payouts.where((e) => e.state == PivxPayoutState.paid).length;

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
                  text: startsLater
                      ? " × ${p.totalPayments} · ${l10n.govFromBlock(p.blockStart)}"
                      : payouts != null
                      ? " · ${l10n.govPaidOf(paid(payouts!), p.totalPayments)}"
                      : " · ${l10n.govPaymentsLeft(p.remainingPayments, p.totalPayments)}",
                  style: STextStyles.w500_12(context)
                      .copyWith(color: colors.textSubtitle1),
                ),
              ],
            ),
          ),
          if (payouts != null) ...[
            const SizedBox(height: 6),
            PivxPayoutStatusLine(
              payouts: payouts!,
              chainHeight: governance.chainHeight,
              blockSeconds: wallet.cryptoCurrency.targetBlockTimeSeconds,
            ),
          ],
          const SizedBox(height: 12),
          PivxVotesBar(
            yeas: p.yeas,
            nays: p.nays,
            netYesPercent: governance.netYesPercent(p),
          ),
          if (voted.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final m in voted.take(votesShown))
                  PivxVoteChip(label: m.label, vote: myVotes[m.id]!.vote),
                if (votesShown < voted.length)
                  PivxShowAllChip(
                    count: masternodes.length,
                    onTap: () => showPivxMasternodeVotesSheet(
                      context,
                      wallet: wallet,
                      proposalName: p.name,
                      votes: myVotes,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// One of this wallet's proposals before the network knows it.
class _PendingCard extends ConsumerWidget {
  const _PendingCard({
    required this.wallet,
    required this.proposal,
    required this.onRemove,
  });

  final PivxWallet wallet;
  final PivxPendingProposal proposal;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final fmt = ref.watch(pAmountFormatter(wallet.cryptoCurrency));
    final p = proposal;
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    final failed = p.error != null;
    final amount = Amount(
      rawValue: p.amountSats,
      fractionDigits: wallet.cryptoCurrency.fractionDigits,
    );

    return RoundedWhiteContainer(
      padding: const EdgeInsets.all(14),
      borderColor: failed ? colors.textError : colors.accentColorBlue,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(p.name, style: STextStyles.w600_14(context)),
              ),
              PivxPill(
                text: failed ? l10n.govFailed : l10n.govYourProposal,
                color: failed ? colors.textError : colors.accentColorBlue,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            "${fmt.format(amount)} × ${p.payments} · "
            "${l10n.govFromBlock(p.blockStart)}",
            style: secondary,
          ),
          const SizedBox(height: 8),
          if (failed) ...[
            Text(p.error!, style: secondary.copyWith(color: colors.textError)),
            Align(
              alignment: Alignment.centerRight,
              child: CustomTextButton(text: l10n.commonRemove, onTap: onRemove),
            ),
          ] else
            FutureBuilder<int?>(
              future: wallet.feeConfirmationsOf(p),
              builder: (context, snapshot) {
                final confs = snapshot.data;
                final need = wallet.proposalFeeConfirmations;
                final text = confs == null
                    ? l10n.govFeeSent
                    : confs < need
                    ? l10n.govFeeConfirming(confs, need)
                    : l10n.govSubmitting;
                return Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: confs == null ? null : confs / need,
                        color: colors.accentColorBlue,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(text, style: secondary)),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

class _PastCard extends ConsumerWidget {
  const _PastCard({required this.wallet, required this.proposal});

  final PivxWallet wallet;
  final PivxPastProposal proposal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final fmt = ref.watch(pAmountFormatter(wallet.cryptoCurrency));
    final p = proposal;
    return RoundedWhiteContainer(
      padding: const EdgeInsets.all(14),
      onPressed: p.url.isEmpty
          ? null
          : () => openPivxProposalUrl(context, p.url),
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
              if (p.url.isNotEmpty) ...[
                const SizedBox(width: 6),
                Icon(
                  Icons.open_in_new_rounded,
                  size: 16,
                  color: colors.accentColorBlue,
                ),
              ],
              const SizedBox(width: 8),
              PivxPill(
                text: p.passed ? l10n.govPassed : l10n.govFailed,
                color: pivxProposalStatusColor(
                  p.passed
                      ? PivxProposalStatus.passing
                      : PivxProposalStatus.notPassing,
                  colors,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            l10n.govTotalYes(
              fmt.format(p.totalPayment),
              pivxPercent(p.yesPercent),
            ),
            style: STextStyles.w500_12(context)
                .copyWith(color: colors.textSubtitle1),
          ),
          const SizedBox(height: 10),
          PivxVotesBar(yeas: p.yeas, nays: p.nays),
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
    // Scrollable, so pull to refresh works here too.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 40),
        Icon(Icons.cloud_off_rounded, size: 48, color: colors.textSubtitle2),
        const SizedBox(height: 16),
        Text(
          l10n.govLoadFailed,
          textAlign: TextAlign.center,
          style: STextStyles.pageTitleH2(context),
        ),
        const SizedBox(height: 8),
        Text(
          forbidden ? l10n.govNodeNoData : text,
          textAlign: TextAlign.center,
          style: STextStyles.itemSubtitle(context),
        ),
        const SizedBox(height: 24),
        SecondaryButton(label: l10n.commonTryAgain, onPressed: onRetry),
      ],
    );
  }
}
