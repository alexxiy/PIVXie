import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../notifications/show_flush_bar.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/assets.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/stack_dialog.dart';

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

/// Yes against No as one bar, with the counts under it.
class PivxVotesBar extends StatelessWidget {
  const PivxVotesBar({
    super.key,
    required this.yeas,
    required this.nays,
    this.requiredNetYes,
  });

  final int yeas;
  final int nays;

  /// Net yes votes needed to pass, when known.
  final int? requiredNetYes;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final yes = pivxVoteColor(PivxVote.yes, colors);
    final no = pivxVoteColor(PivxVote.no, colors);
    final total = yeas + nays;
    final net = yeas - nays;
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
            Text(
              requiredNetYes == null
                  ? "Net ${net >= 0 ? "+" : ""}$net"
                  : "Net ${net >= 0 ? "+" : ""}$net of $requiredNetYes needed",
              style: label,
            ),
          ],
        ),
      ],
    );
  }
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

/// A titled value that copies itself when tapped.
class PivxCopyRow extends StatelessWidget {
  const PivxCopyRow({super.key, required this.title, required this.value});

  final String title;
  final String value;

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
                ],
              ),
            ),
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
