import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../db/hive/db.dart';
import '../../l10n/l10n.dart';
import '../../notifications/show_flush_bar.dart';
import '../../services/pivx_name/pivx_names_protocol.dart';
import '../../services/pivx_name/pivx_names_registrar.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/amount/amount.dart';
import '../../utilities/amount/amount_formatter.dart';
import '../../utilities/assets.dart';
import '../../utilities/constants.dart';
import '../../utilities/text_styles.dart';
import '../../utilities/util.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/icon_widgets/x_icon.dart';
import '../../widgets/page_app_bar.dart';
import '../../widgets/stack_dialog.dart';
import '../../widgets/stack_text_field.dart';
import '../../widgets/textfield_icon_button.dart';

// =============================================================================
// The PIVX.name mark (pivx-name-front, images/favicon*.svg)

const _shield =
    '<path fill="#ffffff" d="M408 67.5c0-5.9-4.3-10.9-10.1-11.8L221.8 '
    '27.5c-.6-.1-1.3-.2-1.9-.2h-.1c-.5 0-1.6.1-1.8.1L58.7 52.9l-17.1 '
    '2.7c-5.8.9-10.1 5.9-10.1 11.8v257.1c0 60.2 126.2 124 183.8 147.3 1.1.4 '
    '2.2.7 3.3.8.4 0 .8.1 1.1.1 1.5 0 3-.3 4.4-.9 32.9-13.2 88-39.6 '
    '129.2-71 3.2-2.5 6.6-5 9.6-7.5 11.6-9.5 21.7-19.4 29.4-29.5 2.3-3.1 '
    '6.6-9.8 7.7-11.7 2-3.6 3.6-7.2 4.9-10.8 1.9-5.4 2.9-10.9 '
    '2.9-16.4V67.5h.2zM393.6 319c0 1.3-.1 2.5-.2 3.8-.4 3.8-1.2 7.6-2.5 '
    '11.3-1.2 3.4-2.7 6.7-4.5 10-1 1.8-5 8-7.1 10.8-7.1 9.3-16.4 18.5-27.2 '
    '27.3-2.7 2.3-5.9 4.6-8.9 7-38 29-89 53.4-119.3 65.6-1.3.5-2.7.8-4.1.8-1.4 '
    '0-2.8-.3-4.1-.8C162.5 433.3 46 374.5 46 318.8V81.4c0-5.4 3.9-10 '
    '9.3-10.9L71 68l147.1-23.5c.6-.1 1.2-.1 1.7-.1.6 0 1.2 0 1.7.1L374.8 '
    '69l9.5 1.5c2.7.4 5 1.8 6.7 3.7.4.5.8 1 1.1 1.6.6 1.1 1.1 2.3 1.3 '
    '3.6.1.6.2 1.3.2 2V319z"/>'
    '<path fill="#ffffff" d="M232.8 199.2c6.8 0 12.3-5.5 12.3-12.3s-5.5-12.3'
    '-12.3-12.3h-95c-1 0-1.7.8-1.7 1.7v10.6c0 6.6 5.2 12 11.7 12.4l85-.1z"/>'
    '<path fill="#ffffff" d="M256.2 102.7H155.6c-1 0-1.7.8-1.7 1.7V115c0 6.6 '
    '5.2 12 11.7 12.4l85.5-.2c3.2 0 6.1.1 6.1.1 31.5 1.5 56.6 27.7 56.6 '
    '59.6 0 32.2-25.6 58.3-57.5 59.3h-90c-.6 0-1.2 0-1.8.1-5.6.8-10 '
    '5.5-10.4 11.3v121.5c0 1 .8 1.7 1.7 1.7h10.6c6.6 0 12-5.2 '
    '12.4-11.7v-96.7c0-.8.8-1.5 1.6-1.5l77.7-.1c6.7-.3 13.2-1.4 '
    '19.4-3.1 35.3-10.1 61.1-42.4 61.1-80.9-.2-45.8-36.8-83-82.4-84.1z"/>';

const _square =
    '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">'
    '<stop offset="0" stop-color="#c084fc"/>'
    '<stop offset="1" stop-color="#7e22ce"/></linearGradient></defs>'
    '<rect width="500" height="500" rx="110" ry="110" fill="url(#g)"/>';

/// The shield, the "P" and the linked nodes.
const _logo =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 500 500">$_square'
    '<g transform="translate(60, 60) scale(0.76)">$_shield'
    '<g transform="translate(320, 320)">'
    '<circle cx="90" cy="90" r="100" fill="#a855f7" stroke="#6b21a8" '
    'stroke-width="20"/>'
    '<circle cx="50" cy="90" r="20" fill="#ffffff"/>'
    '<circle cx="130" cy="60" r="20" fill="#ffffff"/>'
    '<circle cx="110" cy="130" r="20" fill="#ffffff"/>'
    '<line x1="50" y1="90" x2="130" y2="60" stroke="#ffffff" '
    'stroke-width="12"/>'
    '<line x1="50" y1="90" x2="110" y2="130" stroke="#ffffff" '
    'stroke-width="12"/>'
    '<line x1="130" y1="60" x2="110" y2="130" stroke="#ffffff" '
    'stroke-width="12"/>'
    '</g></g></svg>';

/// The small variant: no nodes, a bigger shield (they are noise at icon
/// sizes).
const _smallLogo =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 500 500">$_square'
    '<g transform="translate(30, 26) scale(0.92)">$_shield</g></svg>';

class PivxNamesLogo extends StatelessWidget {
  const PivxNamesLogo({super.key, this.size = 28, this.small = false});

  final double size;

  /// The variant for icon sizes.
  final bool small;

  @override
  Widget build(BuildContext context) =>
      SvgPicture.string(small ? _smallLogo : _logo, width: size, height: size);
}

// =============================================================================
// Icons (the web app's heroicons)

abstract final class PivxNamesIcons {
  static const myNames =
      "M21 12a9 9 0 01-9 9m9-9a9 9 0 00-9-9m9 9H3m9 9a9 9 0 01-9-9m9 9c1.657 "
      "0 3-4.03 3-9s-1.343-9-3-9m0 18c-1.657 0-3-4.03-3-9s1.343-9 3-9m-9 9a9 "
      "9 0 019-9";
  static const balance =
      "M3 10h18M7 15h1m4 0h1m-7 4h12a3 3 0 003-3V8a3 3 0 00-3-3H6a3 3 0 00-3 "
      "3v8a3 3 0 003 3z";
  static const transactions =
      "M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 "
      "5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2m-3 7h3m-3 "
      "4h3m-6-4h.01M9 16h.01";
  static const marketplace =
      "M3 3h2l.4 2M7 13h10l4-8H5.4M7 13L5.4 5M7 13l-2.293 2.293c-.63.63-.184 "
      "1.707.707 1.707H17m0 0a2 2 0 100 4 2 2 0 000-4zm-8 2a2 2 0 11-4 0 2 2 "
      "0 014 0z";
  static const search = "M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z";
  static const done =
      "M9 12.75L11.25 15 15 9.75M21 12c0 1.268-.63 2.39-1.593 3.068a3.745 "
      "3.745 0 01-1.043 3.296 3.745 3.745 0 01-3.296 1.043A3.745 3.745 0 0112 "
      "21c-1.268 0-2.39-.63-3.068-1.593a3.746 3.746 0 01-3.296-1.043 3.745 "
      "3.745 0 01-1.043-3.296A3.745 3.745 0 013 12c0-1.268.63-2.39 "
      "1.593-3.068a3.746 3.746 0 011.043-3.296 3.746 3.746 0 "
      "013.296-1.043A3.746 3.746 0 0112 3c1.268 0 2.39.63 3.068 "
      "1.593a3.746 3.746 0 013.296 1.043 "
      "3.746 3.746 0 011.043 3.296A3.745 3.745 0 0121 12z";
  static const code = "M10 20l4-16m4 4l4 4-4 4M6 16l-4-4 4-4";
  static const clock = "M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z";
  static const incoming = "M19 13l-7 7-7-7m14-6l-7 7-7-7";
  static const refunds = "M9 15L3 9m0 0l6-6M3 9h12a6 6 0 010 12h-3";
  static const check = "M5 13l4 4L19 7";
  static const cross = "M6 18L18 6M6 6l12 12";
  static const warning =
      "M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 "
      "4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z";
  static const manage =
      "M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 "
      "1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756"
      ".426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 "
      "3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 "
      "1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37"
      "-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 "
      "1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 "
      "2.572-1.065zM15 12a3 3 0 11-6 0 3 3 0 016 0z";
  static const destination =
      "M15.232 5.232l3.536 3.536m-2.036-5.036a2.5 2.5 0 113.536 3.536L6.5 "
      "21.036H3v-3.572L16.732 3.732z";
  static const owner = "M8 7h12m0 0l-4-4m4 4l-4 4m0 6H4m0 0l4 4m-4-4l4-4";
  static const list =
      "M7 7h.01M7 3h5c.512 0 1.024.195 1.414.586l7 7a2 2 0 010 2.828l-7 7a2 "
      "2 0 01-2.828 0l-7-7A1.994 1.994 0 013 12V7a4 4 0 014-4z";
  static const price =
      "M12 8c-1.657 0-3 .895-3 2s1.343 2 3 2 3 .895 3 2-1.343 2-3 2m0-8c1.11 "
      "0 2.08.402 2.599 1M12 8V7m0 1v8m0 0v1m0-1c-1.11 0-2.08-.402-2.599-1M21 "
      "12a9 9 0 11-18 0 9 9 0 0118 0z";
  static const unlist =
      "M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 "
      "4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16";
}

/// A stroked heroicon ([PivxNamesIcons]) in [color].
class PivxNamesIcon extends StatelessWidget {
  const PivxNamesIcon(
    this.path, {
    super.key,
    this.size = 20,
    this.color,
    this.strokeWidth = 2,
  });

  final String path;
  final double size;
  final Color? color;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) => SvgPicture.string(
    // The dots of heroicons are strokes 0.01 long, too short for
    // flutter_svg to draw: 0.1 is still a round dot.
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" '
    'stroke="#000000" stroke-width="$strokeWidth" stroke-linecap="round" '
    'stroke-linejoin="round"><path d="${path.replaceAll("h.01", "h.1")}"/>'
    '</svg>',
    width: size,
    height: size,
    colorFilter: ColorFilter.mode(
      color ?? Theme.of(context).extension<StackColors>()!.textDark,
      BlendMode.srcIn,
    ),
  );
}

// =============================================================================
// Header

const kPivxNamesMyNamesRoute = "/pivxNamesMyNames";
const kPivxNamesBalanceRoute = "/pivxNamesBalance";
const kPivxNamesTransactionsRoute = "/pivxNamesTransactions";
const kPivxNamesMarketplaceRoute = "/pivxNamesMarketplace";

/// The sections of the hamburger menu, in the web app's order.
enum PivxNamesSection {
  myNames(PivxNamesIcons.myNames, kPivxNamesMyNamesRoute),
  balance(PivxNamesIcons.balance, kPivxNamesBalanceRoute),
  transactions(PivxNamesIcons.transactions, kPivxNamesTransactionsRoute),
  marketplace(PivxNamesIcons.marketplace, kPivxNamesMarketplaceRoute);

  const PivxNamesSection(this.icon, this.routeName);

  String get label => switch (this) {
    myNames => l10n.pivxNamesMyNames,
    balance => l10n.pivxNamesMyBalance,
    transactions => l10n.pivxNamesMyTransactions,
    marketplace => l10n.pivxNamesMarketplace,
  };
  final String icon;
  final String routeName;
}

/// The Names header, laid out like the wallet's: back, the PIVX.name
/// logo and [title], then the info button and the menu. [section] is the
/// open section (its menu entry replaces the screen with another one).
/// Sized like [PageAppBar].
class PivxNamesAppBar extends StatelessWidget implements PreferredSizeWidget {
  const PivxNamesAppBar({
    super.key,
    required this.walletId,
    this.title,
    this.section,
  });

  final String walletId;
  final String? title;
  final PivxNamesSection? section;

  @override
  Size get preferredSize => Size.fromHeight(PageAppBar.height);

  Future<void> _menu(BuildContext button) async {
    final colors = Theme.of(button).extension<StackColors>()!;
    final box = button.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(button).overlay!.context.findRenderObject()! as RenderBox;
    final topRight = box.localToGlobal(
      box.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    final picked = await showMenu<PivxNamesSection>(
      context: button,
      color: colors.popupBG,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      position: RelativeRect.fromLTRB(
        topRight.dx,
        topRight.dy + 4,
        overlay.size.width - topRight.dx,
        0,
      ),
      items: [
        for (final s in PivxNamesSection.values)
          PopupMenuItem(
            value: s,
            height: 52,
            child: Row(
              children: [
                PivxNamesIcon(
                  s.icon,
                  size: 22,
                  color: s == section
                      ? colors.accentColorBlue
                      : colors.textSubtitle1,
                ),
                const SizedBox(width: 14),
                Text(
                  s.label,
                  style: STextStyles.w600_14(button).copyWith(
                    color: s == section ? colors.accentColorBlue : null,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    if (picked == null || picked == section || !button.mounted) return;
    final navigator = Navigator.of(button);
    if (section == null) {
      await navigator.pushNamed(picked.routeName, arguments: walletId);
    } else {
      // One section on top of the Names home at a time.
      await navigator.pushReplacementNamed(
        picked.routeName,
        arguments: walletId,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final inset = Util.isDesktop ? 20.0 : 10.0;
    Widget action(Widget child) => Padding(
      padding: EdgeInsets.only(top: inset, bottom: inset, right: 10),
      child: AspectRatio(aspectRatio: 1, child: child),
    );
    return AppBar(
      toolbarHeight: PageAppBar.height,
      leadingWidth: PageAppBar.leadingWidth,
      leading: PageAppBar.backButton(context),
      titleSpacing: 0,
      title: Row(
        children: [
          const PivxNamesLogo(size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title ?? l10n.pivxNamesTitle,
              style: STextStyles.navBarTitle(context),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      actions: [
        action(
          AppBarIconButton(
            semanticsLabel: l10n.pivxNamesAbout,
            size: 36,
            shadows: const [],
            color: colors.background,
            icon: SvgPicture.asset(
              Assets.svg.circleInfo,
              colorFilter: ColorFilter.mode(
                colors.accentColorDark,
                BlendMode.srcIn,
              ),
              width: 20,
              height: 20,
            ),
            onPressed: () => showPivxNamesInfo(context),
          ),
        ),
        action(
          Builder(
            builder: (button) => AppBarIconButton(
              semanticsLabel: l10n.pivxNamesMenu,
              size: 36,
              shadows: const [],
              color: colors.background,
              icon: SvgPicture.asset(
                Assets.svg.bars,
                colorFilter: ColorFilter.mode(
                  colors.accentColorDark,
                  BlendMode.srcIn,
                ),
                width: 20,
                height: 20,
              ),
              onPressed: () => _menu(button),
            ),
          ),
        ),
      ],
    );
  }
}

/// A flow screen's header: back and [title].
PreferredSizeWidget pivxNamesFlowAppBar(BuildContext context, String title) =>
    PageAppBar(
      titleSpacing: 0,
      title: Text(
        title,
        style: STextStyles.navBarTitle(context),
        overflow: TextOverflow.ellipsis,
      ),
    );

// =============================================================================
// How it works

const _kInfoSeenKey = "pivxNamesInfoSeen";
const kPivxNamesTelegramUrl = "https://t.me/pivx_name";
const kPivxNamesDocsUrl = "https://docs.pivx.name/";

/// Shows [showPivxNamesInfo] the first time Names opens.
Future<void> showPivxNamesInfoOnce(BuildContext context) async {
  if (DB.instance.get<dynamic>(boxName: DB.boxNamePrefs, key: _kInfoSeenKey) ==
      true) {
    return;
  }
  await DB.instance.put<dynamic>(
    boxName: DB.boxNamePrefs,
    key: _kInfoSeenKey,
    value: true,
  );
  if (context.mounted) await showPivxNamesInfo(context);
}

/// What PIVX names are, how they work and what they give: the web app's
/// four slides.
Future<void> showPivxNamesInfo(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _InfoDialog());

class _InfoDialog extends StatefulWidget {
  const _InfoDialog();

  @override
  State<_InfoDialog> createState() => _InfoDialogState();
}

typedef _Point = (IconData, String);

class _InfoDialogState extends State<_InfoDialog> {
  int _slide = 0;

  static List<(String, List<_Point>)> get _slides => [
    (
      l10n.pivxNamesInfoHowTitle,
      [
        (
          Icons.person_outline_rounded,
          l10n.pivxNamesInfoHow1,
        ),
        (
          Icons.key_rounded,
          l10n.pivxNamesInfoHow2,
        ),
      ],
    ),
    (
      l10n.pivxNamesInfoBenefitsTitle,
      [
        (
          Icons.sell_outlined,
          l10n.pivxNamesInfoBenefits1,
        ),
        (
          Icons.link_rounded,
          l10n.pivxNamesInfoBenefits2,
        ),
        (
          Icons.visibility_off_outlined,
          l10n.pivxNamesInfoBenefits3,
        ),
      ],
    ),
    (
      l10n.pivxNamesInfoControlTitle,
      [
        (
          Icons.swap_horiz_rounded,
          l10n.pivxNamesInfoControl1,
        ),
        (
          Icons.edit_outlined,
          l10n.pivxNamesInfoControl2,
        ),
        (
          Icons.shopping_bag_outlined,
          l10n.pivxNamesInfoControl3,
        ),
      ],
    ),
    (l10n.pivxNamesInfoQuestionTitle, []),
  ];

  Widget _point(_Point p) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: colors.accentColorBlue.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(p.$1, size: 20, color: colors.accentColorBlue),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(p.$2, style: STextStyles.itemSubtitle(context))),
        ],
      ),
    );
  }

  Widget _link(IconData icon, String label, String url) {
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
                Icon(icon, size: 20, color: colors.accentColorBlue),
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

  Widget _slideBody(int i) {
    final (title, points) = _slides[i];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: STextStyles.pageTitleH2(context)),
        const SizedBox(height: 14),
        if (i < _slides.length - 1)
          for (final p in points) _point(p)
        else ...[
          _link(
            Icons.send_rounded,
            l10n.pivxNamesInfoTelegram,
            kPivxNamesTelegramUrl,
          ),
          _link(
            Icons.menu_book_rounded,
            l10n.pivxNamesInfoDocs,
            kPivxNamesDocsUrl,
          ),
          const SizedBox(height: 6),
          Text(
            l10n.pivxNamesInfoSlogan,
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
    return Dialog(
      backgroundColor: colors.popupBG,
      insetPadding: const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const PivxNamesLogo(size: 28),
                  const SizedBox(width: 10),
                  Text("PIVX Name", style: STextStyles.w600_16(context)),
                  const Spacer(),
                  Text(
                    l10n.commonPageOf(_slide + 1, _slides.length),
                    style: STextStyles.w500_12(context)
                        .copyWith(color: colors.textSubtitle1),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              // Every slide takes the tallest one's room, so the buttons
              // stay under the finger while paging.
              Stack(
                children: [
                  for (var i = 0; i < _slides.length; i++)
                    Visibility(
                      visible: i == _slide,
                      maintainSize: true,
                      maintainAnimation: true,
                      maintainState: true,
                      child: _slideBody(i),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < _slides.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == _slide ? 18 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: i == _slide
                            ? colors.accentColorBlue
                            : colors.textFieldDefaultBG,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
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
                        onPressed: () => setState(() => _slide++),
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

// =============================================================================
// Steps

enum PivxNamesStep { check, pay, done }

/// Check, Pay, Done!: where the user is in registering (or changing) a
/// name.
class PivxNamesSteps extends StatelessWidget {
  const PivxNamesSteps({super.key, required this.step});

  final PivxNamesStep step;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    Widget item(PivxNamesStep s, String icon, String label) {
      final color = s == step
          ? (s == PivxNamesStep.done
                ? colors.accentColorGreen
                : colors.accentColorBlue)
          : s.index < step.index
          ? colors.textSubtitle1
          : colors.textSubtitle1.withValues(alpha: 0.45);
      return Expanded(
        child: Column(
          children: [
            PivxNamesIcon(icon, size: 22, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: STextStyles.w600_12(context).copyWith(color: color),
            ),
          ],
        ),
      );
    }

    return Row(
      children: [
        item(PivxNamesStep.check, PivxNamesIcons.search, l10n.pivxNamesStepCheck),
        item(PivxNamesStep.pay, PivxNamesIcons.balance, l10n.pivxNamesStepPay),
        item(PivxNamesStep.done, PivxNamesIcons.done, l10n.pivxNamesStepDone),
      ],
    );
  }
}

// =============================================================================
// Badges

const _zoneColors = {
  ".pivx": Color(0xFFA855F7),
  ".private": Color(0xFFEC4899),
  ".secure": Color(0xFF3B82F6),
  ".safe": Color(0xFF10B981),
};

/// [name] for running text: a word joiner after each hyphen keeps
/// "my-shop.pivx" on one line instead of breaking it at the hyphen.
String pivxNamesUnbroken(String name) => name.replaceAll("-", "-\u2060");

/// A name with its zone in the zone's colour: "alice" ".pivx".
class PivxNamesNameText extends StatelessWidget {
  const PivxNamesNameText(this.name, {super.key, this.style});

  final String name;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final (:label, :zone) = splitPivxName(name);
    final base = style ?? STextStyles.w600_16(context);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: label, style: base),
          TextSpan(
            text: zone,
            style: base.copyWith(color: _zoneColors[zone] ?? base.color),
          ),
        ],
      ),
    );
  }
}

/// The zone of [name], as a pill.
class PivxNamesZoneBadge extends StatelessWidget {
  const PivxNamesZoneBadge({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final zone = splitPivxName(name).zone;
    final color = _zoneColors[zone] ?? const Color(0xFFA855F7);
    return PivxNamesPill(text: zone, color: color);
  }
}

class PivxNamesPill extends StatelessWidget {
  const PivxNamesPill({
    super.key,
    required this.text,
    required this.color,
    this.icon,
  });

  final String text;
  final Color color;
  final String? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(100),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          PivxNamesIcon(icon!, size: 12, color: color, strokeWidth: 2.5),
          const SizedBox(width: 4),
        ],
        Text(text, style: STextStyles.w600_12(context).copyWith(color: color)),
      ],
    ),
  );
}

/// Readable on light themes too (deepens light accents such as yellow).
Color pivxNamesReadable(Color color, StackColors colors) {
  if (colors.brightness == Brightness.dark) return color;
  final hsl = HSLColor.fromColor(color);
  return hsl.lightness > 0.45 ? hsl.withLightness(0.42).toColor() : color;
}

Color pivxNamesStatusColor(PivxNamesTxStatus? status, StackColors colors) =>
    pivxNamesReadable(switch (status) {
      PivxNamesTxStatus.done => colors.accentColorGreen,
      PivxNamesTxStatus.orphaned ||
      PivxNamesTxStatus.rejected => colors.accentColorRed,
      PivxNamesTxStatus.refunded ||
      PivxNamesTxStatus.pendingRefund => colors.accentColorOrange,
      null => colors.textSubtitle1,
      _ => colors.accentColorBlue,
    }, colors);

/// A command's status as a pill.
class PivxNamesStatusPill extends StatelessWidget {
  const PivxNamesStatusPill({super.key, required this.status, this.raw});

  final PivxNamesTxStatus? status;

  /// The code, for a status the app doesn't know.
  final int? raw;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final s = status;
    return PivxNamesPill(
      text: s?.label ?? (raw == null ? l10n.pivxNamesStatusSent : l10n.pivxNamesStatusCode("$raw")),
      color: pivxNamesStatusColor(s, colors),
      icon: switch (s) {
        PivxNamesTxStatus.done => PivxNamesIcons.check,
        PivxNamesTxStatus.orphaned ||
        PivxNamesTxStatus.rejected => PivxNamesIcons.warning,
        _ => null,
      },
    );
  }
}

// =============================================================================
// Lists

/// Previous, a few page numbers, next.
class PivxNamesPager extends StatelessWidget {
  const PivxNamesPager({
    super.key,
    required this.page,
    required this.count,
    required this.pageSize,
    required this.onPage,
  });

  final int page;

  /// All items, on all pages.
  final int count;
  final int pageSize;
  final ValueChanged<int> onPage;

  static const _window = 5;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final pages = (count / pageSize).ceil();
    if (pages <= 1) return const SizedBox.shrink();
    var first = (page - _window ~/ 2).clamp(1, pages);
    final last = (first + _window - 1).clamp(1, pages);
    first = (last - _window + 1).clamp(1, pages);
    Widget button(Widget child, int? to, {bool selected = false}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Material(
        color: selected ? colors.accentColorBlue : colors.textFieldDefaultBG,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: to == null || selected ? null : () => onPage(to),
          child: SizedBox(width: 36, height: 34, child: Center(child: child)),
        ),
      ),
    );
    final arrow = colors.textDark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          button(
            Icon(
              Icons.chevron_left_rounded,
              color: page > 1 ? arrow : arrow.withValues(alpha: 0.3),
            ),
            page > 1 ? page - 1 : null,
          ),
          for (var p = first; p <= last; p++)
            button(
              Text(
                "$p",
                style: STextStyles.w600_14(
                  context,
                ).copyWith(color: p == page ? colors.buttonTextPrimary : null),
              ),
              p,
              selected: p == page,
            ),
          button(
            Icon(
              Icons.chevron_right_rounded,
              color: page < pages ? arrow : arrow.withValues(alpha: 0.3),
            ),
            page < pages ? page + 1 : null,
          ),
        ],
      ),
    );
  }
}

/// A search field that keeps to what names are made of, and searches as
/// the user stops typing.
class PivxNamesSearchField extends StatefulWidget {
  const PivxNamesSearchField({
    super.key,
    required this.hint,
    required this.onSearch,
  });

  final String hint;
  final ValueChanged<String> onSearch;

  @override
  State<PivxNamesSearchField> createState() => _PivxNamesSearchFieldState();
}

class _PivxNamesSearchFieldState extends State<PivxNamesSearchField> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  String _last = "";

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _changed(String value) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(value));
  }

  void _search(String value) {
    _debounce?.cancel();
    // The web app searches what the field keeps of a name.
    final term = value.toLowerCase().replaceAll(RegExp(r"[^a-z0-9.-]"), "");
    if (term == _last) return;
    _last = term;
    widget.onSearch(term);
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(Constants.size.circularBorderRadius),
    child: TextField(
      controller: _controller,
      focusNode: _focus,
      autocorrect: false,
      enableSuggestions: false,
      maxLength: 64,
      style: STextStyles.field(context),
      onChanged: _changed,
      onSubmitted: _search,
      textInputAction: TextInputAction.search,
      decoration: standardInputDecoration(widget.hint, _focus, context)
          .copyWith(
            counterText: "",
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
                        _search("");
                        setState(() {});
                      },
                    ),
                  ),
          ),
    ),
  );
}

/// Loading, an error with Retry, or an empty list's [empty].
class PivxNamesListState extends StatelessWidget {
  const PivxNamesListState({
    super.key,
    this.loading = false,
    this.error,
    this.onRetry,
    this.empty,
    this.action,
  });

  final bool loading;
  final String? error;
  final VoidCallback? onRetry;
  final String? empty;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
      child: Column(
        children: [
          if (loading)
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 3),
            )
          else if (error != null) ...[
            Icon(
              Icons.cloud_off_rounded,
              size: 36,
              color: colors.textSubtitle1,
            ),
            const SizedBox(height: 10),
            Text(
              error!,
              textAlign: TextAlign.center,
              style: STextStyles.itemSubtitle(context),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              SecondaryButton(
                label: l10n.commonTryAgain,
                width: 160,
                buttonHeight: Util.isDesktop ? ButtonHeight.m : null,
                onPressed: onRetry,
              ),
            ],
          ] else if (empty != null) ...[
            Text(
              empty!,
              textAlign: TextAlign.center,
              style: STextStyles.itemSubtitle(context),
            ),
            if (action != null) ...[const SizedBox(height: 14), action!],
          ],
        ],
      ),
    );
  }
}

// =============================================================================
// Helpers

/// [sats] in the unit the user picked for the wallet's coin ("1,000
/// mtPIV"). With [exact], every decimal: an amount that must be paid as it
/// is.
String pivxNamesAmount(
  BigInt sats,
  WidgetRef ref,
  PivxWallet wallet, {
  bool exact = false,
}) {
  final coin = wallet.cryptoCurrency;
  var formatter = ref.read(pAmountFormatter(coin));
  if (exact) {
    formatter = AmountFormatter(
      unit: formatter.unit,
      locale: formatter.locale,
      coin: coin,
      maxDecimals: coin.fractionDigits,
    );
  }
  return formatter.format(
    Amount(rawValue: sats, fractionDigits: coin.fractionDigits),
  );
}

/// "abcd…wxyz".
String pivxNamesShortId(String id) => id.length > 12
    ? "${id.substring(0, 6)}…${id.substring(id.length - 6)}"
    : id;

/// What went wrong, for the user: the registrar's own words when it
/// refused, else the error.
String pivxNamesError(Object e) =>
    e is PivxNamesException ? e.message : l10n.commonSomethingWentWrongError(e.toString());

Future<void> pivxNamesCopy(
  BuildContext context,
  String value,
  String what,
) async {
  await Clipboard.setData(ClipboardData(text: value));
  if (context.mounted) {
    await showFloatingFlushBar(
      type: FlushBarType.info,
      message: l10n.commonCopiedWhat(what),
      iconAsset: Assets.svg.copy,
      context: context,
    );
  }
}

Future<void> showPivxNamesError(
  BuildContext context,
  Object error, {
  String? title,
  }) => showDialog<void>(
    context: context,
    builder: (_) => StackOkDialog(
      title: title ?? l10n.commonSomethingWentWrong,
      message: pivxNamesError(error),
    ),
);

/// Asks before [action]; true when the user goes ahead.
Future<bool> pivxNamesConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async {
  final colors = Theme.of(context).extension<StackColors>()!;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StackDialog(
      title: title,
      message: message,
      leftButton: TextButton(
        style: colors.getSecondaryEnabledButtonStyle(context),
        onPressed: () => Navigator.of(context).pop(false),
        child: Text(
          l10n.commonCancel,
          style: STextStyles.button(context)
              .copyWith(color: colors.accentColorDark),
        ),
      ),
      rightButton: TextButton(
        style: colors.getPrimaryEnabledButtonStyle(context),
        onPressed: () => Navigator.of(context).pop(true),
        child: Text(action, style: STextStyles.button(context)),
      ),
    ),
  );
  return ok == true;
}

/// The public key of each wallet's names, kept while the app runs (it
/// takes the recovery phrase to make, and the lists need it often). The
/// private key is made again for each signature.
final _publicKeys = <String, Future<String>>{};

Future<String> pivxNamesPublicKey(PivxWallet wallet) async {
  final pending = _publicKeys[wallet.walletId] ??= wallet.namesIdentity().then(
    (i) => i.publicKey,
  );
  try {
    return await pending;
  } catch (_) {
    _publicKeys.removeWhere((_, v) => identical(v, pending));
    rethrow;
  }
}

/// Ticks when a payment to PIVX.name finishes or its status screen
/// closes: the Names screens underneath reload then, so they don't show
/// a name as it was before the change.
final pivxNamesChanges = ValueNotifier<int>(0);

/// Ticks [pivxNamesChanges] once the current frame is done (it may come
/// from a dispose, while the widget tree is locked).
void pivxNamesChanged() => scheduleMicrotask(() => pivxNamesChanges.value++);
