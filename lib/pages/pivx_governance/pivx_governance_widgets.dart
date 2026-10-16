import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../notifications/show_flush_bar.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/assets.dart';
import '../../utilities/constants.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/icon_widgets/x_icon.dart';
import '../../widgets/stack_dialog.dart';
import '../../widgets/stack_text_field.dart';
import '../../widgets/textfield_icon_button.dart';
import '../pivx_masternodes/pivx_masternodes_view.dart';

/// Readable on light themes too (deepens light accents such as yellow).
Color _readable(Color color, StackColors colors) {
  if (colors.brightness == Brightness.dark) return color;
  final hsl = HSLColor.fromColor(color);
  return hsl.lightness > 0.45 ? hsl.withLightness(0.42).toColor() : color;
}

Color pivxProposalStatusColor(PivxProposalStatus status, StackColors colors) =>
    _readable(switch (status) {
      PivxProposalStatus.passing => colors.accentColorGreen,
      PivxProposalStatus.passingNotFunded => colors.accentColorYellow,
      PivxProposalStatus.notPassing => colors.accentColorRed,
      PivxProposalStatus.waiting => colors.accentColorBlue,
      PivxProposalStatus.finished => colors.textSubtitle1,
    }, colors);

Color pivxVoteColor(PivxVote vote, StackColors colors) => _readable(
  vote == PivxVote.yes ? colors.accentColorGreen : colors.accentColorRed,
  colors,
);

/// A small tinted pill.
class PivxPill extends StatelessWidget {
  const PivxPill({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(100),
    ),
    child: Text(
      text,
      style: STextStyles.w600_12(context).copyWith(color: color),
    ),
  );
}

class PivxProposalStatusPill extends StatelessWidget {
  const PivxProposalStatusPill({super.key, required this.status});

  final PivxProposalStatus status;

  @override
  Widget build(BuildContext context) => PivxPill(
    text: status.label,
    color: pivxProposalStatusColor(
      status,
      Theme.of(context).extension<StackColors>()!,
    ),
  );
}

/// Yes against No as one bar; under it the counts and, when known, the
/// net Yes share of the masternodes online, as pivx.org shows it (a
/// proposal passes from [kPivxPassPercent]).
class PivxVotesBar extends StatelessWidget {
  const PivxVotesBar({
    super.key,
    required this.yeas,
    required this.nays,
    this.netYesPercent,
  });

  final int yeas;
  final int nays;
  final double? netYesPercent;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final yes = pivxVoteColor(PivxVote.yes, colors);
    final no = pivxVoteColor(PivxVote.no, colors);
    final total = yeas + nays;
    final percent = netYesPercent;
    final label = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 6,
            child: total == 0
                ? ColoredBox(color: colors.textFieldDefaultBG)
                : Row(
                    // Childless ColoredBoxes take the smallest height.
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (yeas > 0)
                        Expanded(
                          flex: yeas,
                          child: ColoredBox(color: yes),
                        ),
                      if (yeas > 0 && nays > 0) const SizedBox(width: 2),
                      if (nays > 0)
                        Expanded(
                          flex: nays,
                          child: ColoredBox(color: no),
                        ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              "$yeas Yes",
              style: STextStyles.w600_12(context).copyWith(color: yes),
            ),
            Text("  ·  ", style: label),
            Text(
              "$nays No",
              style: STextStyles.w600_12(context).copyWith(color: no),
            ),
            const Spacer(),
            if (percent != null)
              Text(
                "${pivxPercent(percent)} net Yes",
                style: STextStyles.w600_12(context).copyWith(
                  color: percent >= kPivxPassPercent
                      ? yes
                      : colors.textSubtitle1,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Net Yes share needed to pass: 10 % of the masternodes online.
const kPivxPassPercent = 10.0;

/// "60.5%", "100%", "-3%".
String pivxPercent(double value) {
  final rounded = (value * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? "${rounded.toInt()}%"
      : "${rounded.toStringAsFixed(1)}%";
}

/// "MN1 · Yes": how one of the wallet's masternodes voted.
class PivxVoteChip extends StatelessWidget {
  const PivxVoteChip({super.key, required this.label, required this.vote});

  final String label;
  final PivxVote vote;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final color = pivxVoteColor(vote, colors);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            vote == PivxVote.yes
                ? Icons.thumb_up_alt_rounded
                : Icons.thumb_down_alt_rounded,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            "$label · ${vote == PivxVote.yes ? "Yes" : "No"}",
            style: STextStyles.w600_12(context).copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// Votes of the wallet's masternodes listed on a proposal before "Show
/// all".
const kPivxVotesShown = 2;

/// More masternodes than this: their sheets take the whole screen and
/// can be searched.
const kPivxManyMasternodes = 6;

/// How many of [count] votes a proposal lists: all of them, or
/// [kPivxVotesShown] and "Show all" (which never hides just one).
int pivxVotesShownOf(int count) =>
    count <= kPivxVotesShown + 1 ? count : kPivxVotesShown;

/// Whether masternode [m] matches the search [query]: by its alias or
/// its server's address.
bool pivxMasternodeMatches(PivxMasternode m, String query) {
  final q = query.trim().toLowerCase();
  return q.isEmpty ||
      m.label.toLowerCase().contains(q) ||
      (m.service?.toLowerCase().contains(q) ?? false);
}

/// [masternodes] as their [votes] are listed: the latest vote first, then
/// those that haven't voted, in the wallet's order.
List<PivxMasternode> pivxByLatestVote(
  List<PivxMasternode> masternodes,
  Map<String, PivxMasternodeVote> votes,
) {
  final order = {for (final (i, m) in masternodes.indexed) m.id: i};
  final voted =
      [
        for (final m in masternodes)
          if (votes[m.id] != null) m,
      ]..sort((a, b) {
        final c = votes[b.id]!.time.compareTo(votes[a.id]!.time);
        return c != 0 ? c : order[a.id]!.compareTo(order[b.id]!);
      });
  return [
    ...voted,
    for (final m in masternodes)
      if (votes[m.id] == null) m,
  ];
}

/// "Show all 1000", after the votes a proposal lists: opens all of the
/// wallet's masternodes and their votes.
class PivxShowAllChip extends StatelessWidget {
  const PivxShowAllChip({super.key, required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).extension<StackColors>()!.accentColorBlue;
    return Material(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(100),
      child: InkWell(
        borderRadius: BorderRadius.circular(100),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.unfold_more_rounded, size: 12, color: color),
              const SizedBox(width: 4),
              Text(
                "Show all $count",
                style: STextStyles.w600_12(context).copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "3 Yes · 1 No · 2 not voted": the wallet's masternodes on a proposal.
class PivxVoteCounts extends StatelessWidget {
  const PivxVoteCounts({
    super.key,
    required this.masternodes,
    required this.votes,
  });

  final List<PivxMasternode> masternodes;
  final Map<String, PivxMasternodeVote> votes;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    var yes = 0;
    var no = 0;
    for (final m in masternodes) {
      switch (votes[m.id]?.vote) {
        case PivxVote.yes:
          yes++;
        case PivxVote.no:
          no++;
        case null:
      }
    }
    final label = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: "$yes Yes",
            style: STextStyles.w600_12(context)
                .copyWith(color: pivxVoteColor(PivxVote.yes, colors)),
          ),
          TextSpan(text: "  ·  ", style: label),
          TextSpan(
            text: "$no No",
            style: STextStyles.w600_12(context)
                .copyWith(color: pivxVoteColor(PivxVote.no, colors)),
          ),
          TextSpan(
            text: "  ·  ${masternodes.length - yes - no} not voted",
            style: label,
          ),
        ],
      ),
    );
  }
}

/// One of the wallet's masternodes and its vote on a proposal.
class PivxMasternodeVoteRow extends StatelessWidget {
  const PivxMasternodeVoteRow({
    super.key,
    required this.wallet,
    required this.masternode,
    required this.vote,
    this.loading = false,
    this.inList = false,
  });

  final PivxWallet wallet;
  final PivxMasternode masternode;
  final PivxMasternodeVote? vote;
  final bool loading;

  /// In a sheet listing them all: shows the server's address (searched
  /// by), but not the network status (a request per row).
  final bool inList;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final v = vote;
    final status = loading
        ? "Checking…"
        : v == null
        ? "Not voted"
        : v.canChange
        ? "Voted ${_ago(v.time)}"
        : "Voted ${_ago(v.time)} · can change in "
              "~${pivxDuration(v.changeableAt.difference(DateTime.now()).inSeconds)}";
    final service = masternode.service;
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
                  inList && service != null ? "$service · $status" : status,
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
          else if (!inList)
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

/// Search the wallet's masternodes by alias or server address.
class PivxMasternodeSearchField extends StatefulWidget {
  const PivxMasternodeSearchField({super.key, required this.onChanged});

  final ValueChanged<String> onChanged;

  @override
  State<PivxMasternodeSearchField> createState() =>
      _PivxMasternodeSearchFieldState();
}

class _PivxMasternodeSearchFieldState extends State<PivxMasternodeSearchField> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // The fill colour follows the focus.
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(Constants.size.circularBorderRadius),
    child: TextField(
      controller: _controller,
      focusNode: _focus,
      autocorrect: false,
      enableSuggestions: false,
      style: STextStyles.field(context),
      onChanged: (value) {
        setState(() {});
        widget.onChanged(value);
      },
      decoration:
          standardInputDecoration(
            "Search by alias or IP",
            _focus,
            context,
          ).copyWith(
            prefixIcon: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
              child: SvgPicture.asset(Assets.svg.search, width: 16, height: 16),
            ),
            suffixIcon: _controller.text.isEmpty
                ? null
                : UnconstrainedBox(
                    child: TextFieldIconButton(
                      child: const XIcon(),
                      onTap: () {
                        _controller.clear();
                        setState(() {});
                        widget.onChanged("");
                      },
                    ),
                  ),
          ),
    ),
  );
}

/// A bottom sheet about the wallet's masternodes, laid out with
/// [PivxSheetLayout].
Future<T?> showPivxSheet<T>(BuildContext context, WidgetBuilder builder) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).extension<StackColors>()!.popupBG,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: builder,
    );

/// A sheet's handle, [header], scrolling [list] and [footer]. With
/// [fullHeight] (a long list) it fills the screen, else it is as tall as
/// its content.
class PivxSheetLayout extends StatelessWidget {
  const PivxSheetLayout({
    super.key,
    required this.fullHeight,
    required this.header,
    required this.list,
    this.footer = const [],
  });

  final bool fullHeight;
  final List<Widget> header;

  /// Shrink-wrapped unless [fullHeight].
  final Widget list;
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return SafeArea(
      child: Padding(
        // Above the keyboard while searching.
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: fullHeight ? MainAxisSize.max : MainAxisSize.min,
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
            ...header,
            if (fullHeight) Expanded(child: list) else Flexible(child: list),
            ...footer,
          ],
        ),
      ),
    );
  }
}

/// "No masternode matches …", for a search that finds none.
Widget pivxNoMasternodeMatches(BuildContext context, String query) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 24),
  child: Text(
    "No masternode matches \"${query.trim()}\".",
    textAlign: TextAlign.center,
    style: STextStyles.itemSubtitle(context),
  ),
);

/// All of the wallet's masternodes and their [votes] on the proposal
/// [proposalName], latest vote first.
Future<void> showPivxMasternodeVotesSheet(
  BuildContext context, {
  required PivxWallet wallet,
  required String proposalName,
  required Map<String, PivxMasternodeVote> votes,
}) => showPivxSheet<void>(
  context,
  (_) => _MasternodeVotesSheet(
    wallet: wallet,
    proposalName: proposalName,
    votes: votes,
  ),
);

class _MasternodeVotesSheet extends StatefulWidget {
  const _MasternodeVotesSheet({
    required this.wallet,
    required this.proposalName,
    required this.votes,
  });

  final PivxWallet wallet;
  final String proposalName;
  final Map<String, PivxMasternodeVote> votes;

  @override
  State<_MasternodeVotesSheet> createState() => _MasternodeVotesSheetState();
}

class _MasternodeVotesSheetState extends State<_MasternodeVotesSheet> {
  late final _masternodes = pivxByLatestVote(
    widget.wallet.masternodes,
    widget.votes,
  );
  String _query = "";

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final many = _masternodes.length > kPivxManyMasternodes;
    final shown = [
      for (final m in _masternodes)
        if (pivxMasternodeMatches(m, _query)) m,
    ];
    return PivxSheetLayout(
      fullHeight: many,
      header: [
        Text("Your masternodes", style: STextStyles.pageTitleH2(context)),
        const SizedBox(height: 4),
        Text(
          widget.proposalName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: STextStyles.w500_12(context)
              .copyWith(color: colors.textSubtitle1),
        ),
        const SizedBox(height: 10),
        PivxVoteCounts(masternodes: _masternodes, votes: widget.votes),
        if (many) ...[
          const SizedBox(height: 12),
          PivxMasternodeSearchField(
            onChanged: (q) => setState(() => _query = q),
          ),
        ],
        const SizedBox(height: 8),
      ],
      list: shown.isEmpty
          ? pivxNoMasternodeMatches(context, _query)
          : ListView.builder(
              shrinkWrap: !many,
              itemCount: shown.length,
              itemBuilder: (_, i) => PivxMasternodeVoteRow(
                wallet: widget.wallet,
                masternode: shown[i],
                vote: widget.votes[shown[i].id],
                inList: true,
              ),
            ),
    );
  }
}

/// A titled value that copies itself when tapped.
class PivxCopyRow extends StatelessWidget {
  const PivxCopyRow({
    super.key,
    required this.title,
    required this.value,
    this.onOpen,
    this.openTooltip,
    this.footer,
  });

  final String title;
  final String value;

  /// Shown under the value.
  final Widget? footer;

  /// Shows a link button (e.g. to the block explorer).
  final VoidCallback? onOpen;
  final String? openTooltip;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: value));
        if (context.mounted) {
          await showFloatingFlushBar(
            type: FlushBarType.info,
            message: "$title copied",
            iconAsset: Assets.svg.copy,
            context: context,
          );
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: STextStyles.w500_12(context)
                        .copyWith(color: colors.textSubtitle1),
                  ),
                  const SizedBox(height: 2),
                  SelectableText(value, style: STextStyles.w500_14(context)),
                  if (footer != null) ...[const SizedBox(height: 2), footer!],
                ],
              ),
            ),
            if (onOpen != null)
              IconButton(
                tooltip: openTooltip,
                visualDensity: VisualDensity.compact,
                onPressed: onOpen,
                icon: Icon(
                  Icons.open_in_new_rounded,
                  size: 18,
                  color: colors.accentColorBlue,
                ),
              )
            else
              const SizedBox(width: 8),
            Icon(Icons.copy_rounded, size: 16, color: colors.textSubtitle1),
          ],
        ),
      ),
    );
  }
}

/// Open a proposal's link after showing where it goes (links come from
/// whoever submitted the proposal).
Future<void> openPivxProposalUrl(BuildContext context, String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.scheme == "https" || uri.scheme == "http")) {
    await showFloatingFlushBar(
      type: FlushBarType.warning,
      message: "Not a web link: $url",
      context: context,
    );
    return;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StackDialog(
      title: "Open link?",
      message:
          "$url\n\nThe proposal's author set this link. Check it before "
          "you trust what it shows.",
      leftButton: TextButton(
        style: Theme.of(context)
            .extension<StackColors>()!
            .getSecondaryEnabledButtonStyle(context),
        onPressed: () => Navigator.of(context).pop(false),
        child: Text(
          "Cancel",
          style: STextStyles.button(context).copyWith(
            color: Theme.of(context).extension<StackColors>()!.accentColorDark,
          ),
        ),
      ),
      rightButton: TextButton(
        style: Theme.of(context)
            .extension<StackColors>()!
            .getPrimaryEnabledButtonStyle(context),
        onPressed: () => Navigator.of(context).pop(true),
        child: Text("Open", style: STextStyles.button(context)),
      ),
    ),
  );
  if (ok == true) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

/// How long until block [height], e.g. "~2 h".
String pivxTimeUntilBlock(int height, int chainHeight, int blockSeconds) =>
    "~${pivxDuration((height - chainHeight).clamp(0, 1 << 30) * blockSeconds)}";

/// One line on where a proposal's payouts stand, for its card: being
/// paid, missed, the next one, or all made.
class PivxPayoutStatusLine extends StatelessWidget {
  const PivxPayoutStatusLine({
    super.key,
    required this.payouts,
    required this.chainHeight,
    required this.blockSeconds,
  });

  final List<PivxProposalPayout> payouts;
  final int chainHeight;
  final int blockSeconds;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    PivxProposalPayout? first(PivxPayoutState state) =>
        payouts.where((e) => e.state == state).firstOrNull;
    final paying = first(PivxPayoutState.paying);
    final next = first(PivxPayoutState.upcoming);
    final settled = payouts.where(
      (e) =>
          e.state == PivxPayoutState.paid || e.state == PivxPayoutState.notPaid,
    );
    final last = settled.isEmpty ? null : settled.last;
    String until(PivxProposalPayout p) =>
        pivxTimeUntilBlock(p.superblock, chainHeight, blockSeconds);

    final (String, IconData, Color)? line = paying != null
        ? (
            "Being paid now, from block ${paying.superblock}",
            Icons.hourglass_top_rounded,
            colors.accentColorBlue,
          )
        : last?.state == PivxPayoutState.notPaid
        ? (
            "Not paid at block ${last!.superblock}"
                "${next == null ? "" : " · next payout in ${until(next)}"}",
            Icons.error_outline_rounded,
            _readable(colors.accentColorRed, colors),
          )
        : next != null
        ? (
            "Next payout at block ${next.superblock}, in ${until(next)}",
            Icons.schedule_rounded,
            colors.textSubtitle1,
          )
        : last != null
        ? (
            "All payouts made",
            Icons.check_circle_outline_rounded,
            _readable(colors.accentColorGreen, colors),
          )
        : null;
    if (line == null) return const SizedBox.shrink();
    return Row(
      children: [
        Icon(line.$2, size: 14, color: line.$3),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            line.$1,
            style: STextStyles.w500_12(context).copyWith(color: line.$3),
          ),
        ),
      ],
    );
  }
}

/// One payout in a proposal's details: its block and where it stands.
/// A paid one opens its transaction.
class PivxPayoutRow extends StatelessWidget {
  const PivxPayoutRow({
    super.key,
    required this.payout,
    required this.amount,
    required this.chainHeight,
    required this.blockSeconds,
    this.onOpen,
  });

  final PivxProposalPayout payout;

  /// The paid amount, formatted.
  final String? amount;
  final int chainHeight;
  final int blockSeconds;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final p = payout;
    final (text, color) = switch (p.state) {
      PivxPayoutState.paid => (
        "Paid${amount == null ? "" : " $amount"}",
        _readable(colors.accentColorGreen, colors),
      ),
      PivxPayoutState.notPaid => (
        "Not paid",
        _readable(colors.accentColorRed, colors),
      ),
      PivxPayoutState.paying => ("Being paid", colors.accentColorBlue),
      PivxPayoutState.upcoming => (
        "In ${pivxTimeUntilBlock(p.superblock, chainHeight, blockSeconds)}",
        colors.textSubtitle1,
      ),
    };
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                "Block ${p.superblock}",
                style: STextStyles.w500_14(context),
              ),
            ),
            PivxPill(text: text, color: color),
            if (onOpen != null) ...[
              const SizedBox(width: 6),
              Icon(
                Icons.open_in_new_rounded,
                size: 16,
                color: colors.accentColorBlue,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
