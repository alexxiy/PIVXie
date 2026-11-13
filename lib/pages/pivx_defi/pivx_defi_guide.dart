import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../db/hive/db.dart';
import '../../l10n/l10n.dart';
import '../../services/pivx_defi/pivx_defi_models.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/assets.dart';
import '../../utilities/text_styles.dart';
import '../../utilities/util.dart';
import '../../widgets/adaptive_page.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import 'pivx_defi_common.dart';

// "How it works": the web app's four slides (wrapping, unwrapping, how the
// coins are kept safe, where to ask), laid out like PIVX Name's.

const _kGuideSeenKey = "pivxDefiGuideSeen";

/// Where the web app's guide sends questions.
const kPivxDefiTelegramUrl = "https://t.me/alexxiy_lounge";
const kPivxDefiDiscordUrl = "https://discord.pivx.org";

/// Shows [showPivxDefiGuide] the first time the bridge opens.
Future<void> showPivxDefiGuideOnce(
  BuildContext context,
  String walletId,
) async {
  if (DB.instance.get<dynamic>(boxName: DB.boxNamePrefs, key: _kGuideSeenKey) ==
      true) {
    return;
  }
  await DB.instance.put<dynamic>(
    boxName: DB.boxNamePrefs,
    key: _kGuideSeenKey,
    value: true,
  );
  if (context.mounted) await showPivxDefiGuide(context, walletId);
}

/// The guide over the screen of [context]. Its reserves link closes it and
/// opens Reserves, unless that is the screen underneath.
Future<void> showPivxDefiGuide(BuildContext context, String walletId) {
  final navigator = Navigator.of(context);
  final onReserves =
      ModalRoute.of(context)?.settings.name == kPivxDefiReservesRoute
      ? null
      : () => navigator.pushNamed(kPivxDefiReservesRoute, arguments: walletId);
  return showDialog<void>(
    context: context,
    builder: (_) => _GuideDialog(onReserves: onReserves),
  );
}

typedef _Point = (IconData, String);

class _Slide {
  const _Slide({
    required this.title,
    required this.points,
    this.image,
    this.icon,
    this.chip,
    this.direction,
  });

  final String title;
  final List<_Point> points;

  /// PIVXie's side the slide is about, or [icon] for the others.
  final String? image;
  final IconData? icon;

  /// Wrap or Unwrap, over the title.
  final String? chip;

  /// Gives the slide its colour; null: the app's accent.
  final PivxDefiDirection? direction;
}

class _GuideDialog extends StatefulWidget {
  const _GuideDialog({required this.onReserves});

  final VoidCallback? onReserves;

  @override
  State<_GuideDialog> createState() => _GuideDialogState();
}

class _GuideDialogState extends State<_GuideDialog> {
  int _slide = 0;

  // One scroll view holds every slide, so a new slide starts at the top
  // rather than where the last one was scrolled to.
  final _scroll = ScrollController();

  void _go(int slide) {
    setState(() => _slide = slide);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  static List<_Slide> get _slides => [
    _Slide(
      title: l10n.defiGuideWrapTitle,
      image: Assets.persona.public,
      chip: l10n.defiTabWrap,
      direction: PivxDefiDirection.wrap,
      points: [
        (Icons.swap_horiz_rounded, l10n.defiGuideWrap1),
        (Icons.visibility_off_outlined, l10n.defiGuideWrap2),
        (Icons.apps_rounded, l10n.defiGuideWrap3),
      ],
    ),
    _Slide(
      title: l10n.defiGuideUnwrapTitle,
      image: Assets.persona.private,
      chip: l10n.defiTabUnwrap,
      direction: PivxDefiDirection.unwrap,
      points: [
        (Icons.download_rounded, l10n.defiGuideUnwrap1),
        (Icons.verified_user_outlined, l10n.defiGuideUnwrap2),
        (Icons.shopping_cart_outlined, l10n.defiGuideUnwrap3),
      ],
    ),
    _Slide(
      title: l10n.defiGuideSafeTitle,
      icon: Icons.lock_outline_rounded,
      points: [
        (Icons.key_rounded, l10n.defiGuideSafe1),
        (Icons.dns_outlined, l10n.defiGuideSafe2),
        (Icons.enhanced_encryption_outlined, l10n.defiGuideSafe3),
        (Icons.fact_check_outlined, l10n.defiGuideSafe4),
        (Icons.balance_rounded, l10n.defiGuideSafe5),
      ],
    ),
    _Slide(
      title: l10n.defiGuideHelpTitle,
      icon: Icons.forum_outlined,
      points: const [],
    ),
  ];

  Color _color(_Slide s, StackColors colors) => s.direction == null
      ? colors.accentColorBlue
      : pivxDefiColor(s.direction!, colors);

  Widget _head(_Slide s, Color color, bool short) {
    final size = short ? 48.0 : 64.0;
    return Row(
      children: [
        if (s.image != null)
          Image.asset(
            s.image!,
            width: size,
            height: size,
            filterQuality: FilterQuality.medium,
          )
        else
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(s.icon, size: size / 2, color: color),
          ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (s.chip != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    s.chip!,
                    style: STextStyles.w600_12(context).copyWith(color: color),
                  ),
                ),
                const SizedBox(height: 6),
              ],
              Text(s.title, style: STextStyles.pageTitleH2(context)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _point(_Point p, Color color, {Widget? after}) {
    final text = Text(p.$2, style: STextStyles.itemSubtitle(context));
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(p.$1, size: 20, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: after == null
                ? text
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [text, after],
                  ),
          ),
        ],
      ),
    );
  }

  /// "See the reserves", after the last point of the safety slide.
  Widget _reservesLink(Color color) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: TextButton(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: () {
        Navigator.of(context).pop();
        widget.onReserves?.call();
      },
      child: Text(
        l10n.defiGuideReservesLink,
        style: STextStyles.w600_14(context).copyWith(color: color),
      ),
    ),
  );

  Widget _link(IconData icon, String label, String url, Color color) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: colors.textFieldDefaultBG,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () =>
              launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(label, style: STextStyles.w600_14(context)),
                ),
                Icon(
                  Icons.open_in_new_rounded,
                  size: 16,
                  color: colors.textSubtitle1,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _slideBody(int i, bool short) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final s = _slides[i];
    final color = _color(s, colors);
    final last = i == _slides.length - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _head(s, color, short),
        SizedBox(height: short ? 12 : 18),
        for (var j = 0; j < s.points.length; j++)
          _point(
            s.points[j],
            color,
            // The reserves are on the safety slide's last point.
            after:
                i == 2 && j == s.points.length - 1 && widget.onReserves != null
                ? _reservesLink(color)
                : null,
          ),
        if (last) ...[
          _link(
            Icons.send_rounded,
            l10n.defiGuideTelegram,
            kPivxDefiTelegramUrl,
            color,
          ),
          _link(
            Icons.forum_rounded,
            l10n.defiGuideDiscord,
            kPivxDefiDiscordUrl,
            color,
          ),
          const SizedBox(height: 6),
          Text(
            l10n.defiGuideSlogan,
            textAlign: TextAlign.center,
            style: STextStyles.itemSubtitle(context)
                .copyWith(fontStyle: FontStyle.italic),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final last = _slide == _slides.length - 1;
    final short = ScreenFit.short(context);
    final color = _color(_slides[_slide], colors);
    return Dialog(
      backgroundColor: colors.popupBG,
      insetPadding: EdgeInsets.all(short ? 12 : 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: short ? ScreenFit.columnWidth : 480,
        ),
        child: Padding(
          padding: EdgeInsets.all(short ? 16 : 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Image.asset(kPivxDefiWpivxIcon, width: 28, height: 28),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l10n.defiTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: STextStyles.w600_16(context),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n.commonPageOf(_slide + 1, _slides.length),
                    textDirection: TextDirection.ltr,
                    style: STextStyles.w500_12(context)
                        .copyWith(color: colors.textSubtitle1),
                  ),
                ],
              ),
              SizedBox(height: short ? 8 : 18),
              // Every slide takes the tallest one's room, so the buttons
              // stay under the finger while paging.
              Flexible(
                child: SingleChildScrollView(
                  controller: _scroll,
                  child: Stack(
                    children: [
                      for (var i = 0; i < _slides.length; i++)
                        Visibility(
                          visible: i == _slide,
                          maintainSize: true,
                          maintainAnimation: true,
                          maintainState: true,
                          child: _slideBody(i, short),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // The dots also page back, as the web app's do.
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < _slides.length; i++)
                    Semantics(
                      button: true,
                      selected: i == _slide,
                      label: l10n.commonPageOf(i + 1, _slides.length),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _go(i),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 3,
                            vertical: 8,
                          ),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: i == _slide ? 18 : 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: i == _slide
                                  ? color
                                  : colors.textFieldDefaultBG,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              SizedBox(height: short ? 4 : 8),
              if (last)
                PrimaryButton(
                  label: l10n.commonFinish,
                  buttonHeight: Util.isDesktop ? ButtonHeight.m : null,
                  onPressed: () => Navigator.of(context).pop(),
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: SecondaryButton(
                        label: l10n.commonSkip,
                        buttonHeight: Util.isDesktop ? ButtonHeight.m : null,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: PrimaryButton(
                        label: l10n.commonNext,
                        buttonHeight: Util.isDesktop ? ButtonHeight.m : null,
                        onPressed: () => _go(_slide + 1),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
