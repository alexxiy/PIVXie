import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../providers/global/wallets_provider.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/amount/amount_formatter.dart';
import '../../utilities/block_explorers.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
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
  bool _voted = false;

  PivxWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;

  @override
  void initState() {
    super.initState();
    _votes = _wallet.masternodeVotes(widget.proposal);
  }

  Future<void> _vote(PivxVote vote) async {
    Map<String, PivxMasternodeVote> current;
    try {
      current = await _votes;
    } catch (_) {
      current = const {};
    }
    if (!mounted) return;
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).extension<StackColors>()!.popupBG,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _VoteSheet(
        wallet: _wallet,
        proposal: widget.proposal,
        vote: vote,
        current: current,
      ),
    );
    if (done == true && mounted) {
      _voted = true;
      setState(() => _votes = _wallet.masternodeVotes(widget.proposal));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final fmt = ref.watch(pAmountFormatter(wallet.cryptoCurrency));
    final p = widget.proposal;
    final g = widget.governance;
    final masternodes = wallet.masternodes;
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
          appBar: AppBar(
            leading: AppBarBackButton(
              onPressed: () => Navigator.of(context).pop(_voted),
            ),
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
                                fact(
                                  "Payments",
                                  "${p.paymentsMade} of ${p.totalPayments} made",
                                ),
                                fact(
                                  "Superblocks",
                                  "${p.blockStart} – ${p.blockEnd}",
                                ),
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
                              "Passes at 10% net Yes: ${g.requiredNetYes} of "
                              "${g.enabledMasternodes} masternodes online",
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
                                  return Column(
                                    children: [
                                      for (final mn in masternodes)
                                        _MasternodeVoteRow(
                                          wallet: wallet,
                                          masternode: mn,
                                          vote: votes?[mn.id],
                                          loading: votes == null,
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
                              onOpen: () => launchUrl(
                                getBlockExplorerAddressUrlFor(
                                  coin: wallet.cryptoCurrency,
                                  address: p.paymentAddress,
                                ),
                                mode: LaunchMode.externalApplication,
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

class _MasternodeVoteRow extends StatelessWidget {
  const _MasternodeVoteRow({
    required this.wallet,
    required this.masternode,
    required this.vote,
    required this.loading,
  });

  final PivxWallet wallet;
  final PivxMasternode masternode;
  final PivxMasternodeVote? vote;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final v = vote;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(masternode.label, style: STextStyles.w600_14(context)),
                const SizedBox(height: 2),
                Text(
                  loading
                      ? "Checking…"
                      : v == null
                      ? "Not voted"
                      : v.canChange
                      ? "Voted ${_ago(v.time)}"
                      : "Voted ${_ago(v.time)} · can change in "
                            "~${pivxDuration(v.changeableAt.difference(DateTime.now()).inSeconds)}",
                  style: STextStyles.w500_12(context)
                      .copyWith(color: colors.textSubtitle1),
                ),
              ],
            ),
          ),
          if (v != null)
            PivxPill(
              text: v.vote == PivxVote.yes ? "Yes" : "No",
              color: pivxVoteColor(v.vote, colors),
            )
          else
            PivxMasternodeStatusTag(wallet: wallet, masternode: masternode),
        ],
      ),
    );
  }
}

String _ago(int time) {
  final seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000 - time;
  return "${pivxDuration(seconds < 0 ? 0 : seconds)} ago";
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

  bool get _finished =>
      _results.isNotEmpty &&
      _results.values.every(
        (r) => r.$1 == _Result.done || r.$1 == _Result.failed,
      );

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
    final anyDone = _results.values.any((r) => r.$1 == _Result.done);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 60,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.textFieldDefaultBG,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  yes
                      ? Icons.thumb_up_alt_rounded
                      : Icons.thumb_down_alt_rounded,
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
            const SizedBox(height: 16),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [for (final m in _masternodes) _row(context, m)],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              "Each masternode signs its vote with its private key. A vote "
              "can be changed once an hour.",
              style: secondary,
            ),
            const SizedBox(height: 16),
            if (_finished)
              PrimaryButton(
                label: "Done",
                onPressed: () => Navigator.of(context).pop(anyDone),
              )
            else
              PrimaryButton(
                label: _running
                    ? "Voting…"
                    : _selected.isEmpty
                    ? "Select a masternode"
                    : "Vote ${yes ? "Yes" : "No"} with ${_selected.length} "
                          "masternode${_selected.length == 1 ? "" : "s"}",
                enabled: !_running && _selected.isNotEmpty,
                onPressed: _run,
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, PivxMasternode m) {
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
