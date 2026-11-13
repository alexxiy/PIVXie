import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../notifications/show_flush_bar.dart';
import '../../services/pivx_defi/pivx_defi_api.dart';
import '../../services/pivx_defi/pivx_defi_models.dart';
import '../../themes/coin_icon_provider.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/assets.dart';
import '../../utilities/format.dart';
import '../../utilities/text_styles.dart';
import '../../utilities/util.dart';
import '../../wallets/crypto_currency/crypto_currency.dart';
import '../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../widgets/page_app_bar.dart';
import '../../widgets/stack_dialog.dart';
import '../pivx_names/pivx_names_common.dart';
import 'pivx_defi_guide.dart';

// PIVXie DeFi Bridge (https://defi-bridge.pivxie.me), the parts its screens
// share. The look follows the bridge's web app: a wrap takes PIVX to the
// public side (cyan), an unwrap brings it back to the private side
// (magenta).

const kPivxDefiWrapColor = Color(0xFF22D3EE);
const kPivxDefiUnwrapColor = Color(0xFFE879F9);

/// The direction's colour, dark enough for a light theme.
Color pivxDefiColor(PivxDefiDirection d, StackColors colors) =>
    pivxNamesReadable(
      d == PivxDefiDirection.wrap ? kPivxDefiWrapColor : kPivxDefiUnwrapColor,
      colors,
    );

/// Done, matching, fine.
Color pivxDefiGreen(StackColors colors) =>
    pivxNamesReadable(colors.accentColorGreen, colors);

/// Waiting on something outside the app; not an error.
Color pivxDefiWarning(StackColors colors) =>
    pivxNamesReadable(colors.accentColorOrange, colors);

/// The wPIVX token's icon (the bridge's images/wpivx-256.png).
const kPivxDefiWpivxIcon = "assets/defi/wpivx.png";

/// The PIVX or the wPIVX icon.
class PivxDefiTokenIcon extends ConsumerWidget {
  const PivxDefiTokenIcon({
    super.key,
    required this.coin,
    required this.wrapped,
    this.size = 32,
  });

  final CryptoCurrency coin;

  /// wPIVX rather than PIVX.
  final bool wrapped;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) => wrapped
      ? Image.asset(
          kPivxDefiWpivxIcon,
          width: size,
          height: size,
          filterQuality: FilterQuality.medium,
        )
      : SvgPicture.file(
          File(ref.watch(coinIconProvider(coin))),
          width: size,
          height: size,
        );
}

/// The two icons of a direction, the one sent first.
class PivxDefiPairIcon extends StatelessWidget {
  const PivxDefiPairIcon({
    super.key,
    required this.coin,
    required this.direction,
    this.size = 28,
  });

  final CryptoCurrency coin;
  final PivxDefiDirection direction;
  final double size;

  @override
  Widget build(BuildContext context) {
    final wrap = direction == PivxDefiDirection.wrap;
    return SizedBox(
      width: size * 1.6,
      height: size,
      child: Stack(
        children: [
          PositionedDirectional(
            start: size * 0.6,
            child: PivxDefiTokenIcon(coin: coin, wrapped: wrap, size: size),
          ),
          PivxDefiTokenIcon(coin: coin, wrapped: !wrap, size: size),
        ],
      ),
    );
  }
}

// =============================================================================
// Numbers and texts

/// [sat] with its [symbol], "1,234.5 PIVX".
String pivxDefiAmount(int sat, String symbol) =>
    "${showPivxDefiAmount(sat)} $symbol";

/// The fee percentage, "1%" or "0.25%", in the app language's way.
String pivxDefiPercent(int bps) => Format.percent(
  bps / 100,
  decimals: bps % 100 == 0
      ? 0
      : bps % 10 == 0
      ? 1
      : 2,
);

/// The fee rule, or the fee of [amount] saying whether it is the percentage
/// or the minimum, as the web app shows it.
String pivxDefiFeeText(PivxDefiInfo info, PivxDefiDirection d, int? amount) {
  if (amount == null || amount <= 0) {
    return l10n.defiFeeRule(
      pivxDefiPercent(info.feeBps),
      showPivxDefiAmount(info.minFee(d)),
    );
  }
  final fee = info.feeOf(amount, d);
  final rule = fee > info.percentFee(amount)
      ? l10n.defiFeeMinimum
      : pivxDefiPercent(info.feeBps);
  return "$rule · ${pivxDefiAmount(fee, "PIVX")}";
}

/// A date and time from the bridge (seconds).
String pivxDefiDate(int seconds) => Format.extractDateFrom(seconds);

/// The time left until [seconds], "2 h 5 min".
String pivxDefiTimeLeft(int seconds) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final left = seconds - now < 0 ? 0 : seconds - now;
  final h = left ~/ 3600;
  final m = (left % 3600) ~/ 60;
  return h > 0
      ? l10n.defiTimeHoursMinutes(h.toString(), m.toString())
      : l10n.defiTimeMinutes((m < 1 ? 1 : m).toString());
}

/// "0x1234…abcdef" for hashes and long ids on a line.
String pivxDefiShort(String value, {int head = 10, int tail = 6}) =>
    value.length > head + tail + 1
    ? "${value.substring(0, head)}…${tail == 0 ? "" : value.substring(value.length - tail)}"
    : value;

/// What went wrong with a request to the bridge, for the user. The
/// bridge's errors are compared whole and shown in the app's words.
String pivxDefiErrorText(Object e) {
  if (e is PivxDefiConfigMismatch) return l10n.defiConfigMismatch;
  if (e is PivxDefiApiException) {
    if (e.isNetwork) return l10n.defiErrorNetwork;
    return switch (e.message) {
      "Amount is below the minimum" => l10n.defiErrorAmountLow,
      "Amount is above the maximum" => l10n.defiErrorAmountHigh,
      "Invalid EVM address" => l10n.defiErrorEvmAddress,
      "Invalid PIVX address" => l10n.defiErrorPivxAddress,
      "This address belongs to the bridge" => l10n.defiErrorBridgeAddress,
      "Unwraps are paid to shielded addresses only" => l10n.defiErrorShieldOnly,
      "The bridge is paused" => l10n.defiErrorPaused,
      "The bridge is temporarily unavailable" => l10n.defiErrorUnavailable,
      "Too many orders, try again later" => l10n.defiErrorRateLimit,
      "Order not found" => l10n.defiErrorNotFound,
      "The order does not accept this change" => l10n.defiErrorOrderState,
      _ => l10n.defiErrorServer,
    };
  }
  return l10n.defiErrorServer;
}

// =============================================================================
// The bridge's settings

PivxDefiInfo? _lastInfo;

/// The settings the bridge gave last while the app runs, to draw a screen
/// before they come again.
PivxDefiInfo? get pivxDefiLastInfo => _lastInfo;

/// The bridge's settings, checked against the app's own.
Future<PivxDefiInfo> loadPivxDefiInfo(PivxDefiApi api) async {
  try {
    return _lastInfo = await api.info();
  } on PivxDefiConfigMismatch {
    // Never draw a screen with settings the app refused.
    _lastInfo = null;
    rethrow;
  }
}

/// Ticks when an order is created or paid: the lists under it reload.
final pivxDefiChanges = ValueNotifier<int>(0);

void pivxDefiChanged() => scheduleMicrotask(() => pivxDefiChanges.value++);

// =============================================================================
// Links and messages

/// Opens [uri] in the browser (or the mail app).
Future<void> pivxDefiOpen(Uri? uri) async {
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

Future<void> pivxDefiCopy(
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

Future<void> pivxDefiToast(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 6),
}) => showFloatingFlushBar(
  type: FlushBarType.warning,
  message: message,
  duration: duration,
  context: context,
);

Future<void> showPivxDefiMessage(
  BuildContext context, {
  required String title,
  required String message,
}) => showDialog<void>(
  context: context,
  builder: (_) => StackOkDialog(title: title, message: message),
);

/// What the bridge is, and that it is a service of its own.
Future<void> showPivxDefiAbout(BuildContext context) {
  final info = pivxDefiLastInfo;
  final colors = Theme.of(context).extension<StackColors>()!;
  return showDialog<void>(
    context: context,
    builder: (context) => StackDialog(
      title: l10n.defiAbout,
      message: "${l10n.defiAboutService}\n\n${l10n.defiFootnote}",
      content: info == null
          ? null
          : Text(
              "${l10n.defiFee}: ${pivxDefiFeeText(info, PivxDefiDirection.wrap, null)}",
              style: STextStyles.w500_12(context)
                  .copyWith(color: colors.textSubtitle1),
            ),
      rightButton: TextButton(
        style: colors.getPrimaryEnabledButtonStyle(context),
        onPressed: () => Navigator.of(context).pop(),
        child: Text(l10n.commonClose, style: STextStyles.button(context)),
      ),
    ),
  );
}

// =============================================================================
// Header

/// The routes of the DeFi Bridge screens (route_generator.dart).
const kPivxDefiRoute = "/pivxDefi";
const kPivxDefiOrdersRoute = "/pivxDefiOrders";
const kPivxDefiReservesRoute = "/pivxDefiReserves";

enum _MenuItem { orders, reserves, guide, about, browser, support }

/// The DeFi Bridge header: back, the wPIVX mark and [title], then the menu
/// (recent orders, reserves, how it works, about, the web app, support).
/// Sized like [PageAppBar].
class PivxDefiAppBar extends StatelessWidget implements PreferredSizeWidget {
  const PivxDefiAppBar({
    super.key,
    required this.walletId,
    required this.config,
    this.title,
    this.webPath,
  });

  final String walletId;
  final PivxDefiConfig config;
  final String? title;

  /// The page of the web app this screen stands for ("order/…").
  final String? webPath;

  @override
  Size get preferredSize => Util.isDesktop
      ? Size.fromHeight(PageAppBar.height)
      : AppBar().preferredSize;

  Future<void> _menu(BuildContext button) async {
    final colors = Theme.of(button).extension<StackColors>()!;
    final box = button.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(button).overlay!.context.findRenderObject()! as RenderBox;
    final topRight = box.localToGlobal(
      box.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    final support = pivxDefiLastInfo?.supportUri;
    PopupMenuItem<_MenuItem> item(
      _MenuItem value,
      IconData icon,
      String text,
    ) => PopupMenuItem(
      value: value,
      height: 52,
      child: Row(
        children: [
          Icon(icon, size: 22, color: colors.textSubtitle1),
          const SizedBox(width: 14),
          Text(text, style: STextStyles.w600_14(button)),
        ],
      ),
    );
    final picked = await showMenu<_MenuItem>(
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
        item(_MenuItem.orders, Icons.receipt_long_rounded, l10n.defiRecent),
        item(
          _MenuItem.reserves,
          Icons.account_balance_rounded,
          l10n.defiReserves,
        ),
        item(_MenuItem.guide, Icons.help_outline_rounded, l10n.defiGuide),
        item(_MenuItem.about, Icons.info_outline_rounded, l10n.defiAbout),
        item(
          _MenuItem.browser,
          Icons.open_in_new_rounded,
          l10n.defiOpenInBrowser,
        ),
        if (support != null)
          item(
            _MenuItem.support,
            Icons.support_agent_rounded,
            l10n.defiSupport,
          ),
      ],
    );
    if (picked == null || !button.mounted) return;
    final navigator = Navigator.of(button);
    switch (picked) {
      case _MenuItem.orders:
        await navigator.pushNamed(kPivxDefiOrdersRoute, arguments: walletId);
      case _MenuItem.reserves:
        await navigator.pushNamed(kPivxDefiReservesRoute, arguments: walletId);
      case _MenuItem.guide:
        await showPivxDefiGuide(button, walletId);
      case _MenuItem.about:
        await showPivxDefiAbout(button);
      case _MenuItem.browser:
        await pivxDefiOpen(
          webPath == null ? config.site : config.site.resolve(webPath!),
        );
      case _MenuItem.support:
        await pivxDefiOpen(support);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final inset = Util.isDesktop ? 20.0 : 10.0;
    return AppBar(
      toolbarHeight: Util.isDesktop ? PageAppBar.height : null,
      leadingWidth: PageAppBar.leadingWidth,
      leading: PageAppBar.backButton(context),
      titleSpacing: 0,
      title: Row(
        children: [
          Image.asset(kPivxDefiWpivxIcon, width: 28, height: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title ?? l10n.defiTitle,
              style: STextStyles.navBarTitle(context),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      actions: [
        Padding(
          padding: EdgeInsetsDirectional.only(
            top: inset,
            bottom: inset,
            end: 10,
          ),
          child: AspectRatio(
            aspectRatio: 1,
            child: Builder(
              builder: (button) => AppBarIconButton(
                semanticsLabel: l10n.defiMenu,
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
        ),
      ],
    );
  }
}

// =============================================================================
// Pieces of the screens

/// A coloured note: a warning, a notice, an error.
class PivxDefiNote extends StatelessWidget {
  const PivxDefiNote({
    super.key,
    required this.text,
    required this.color,
    this.icon = Icons.info_outline_rounded,
  });

  final String text;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withValues(alpha: 0.3)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: STextStyles.w500_12(context).copyWith(color: color),
          ),
        ),
      ],
    ),
  );
}

/// A label and its value on one line, the value at the end; [onCopy] and
/// [onOpen] add their buttons. Addresses, ids and hashes ([mono]) stay
/// left to right in Arabic too.
class PivxDefiRow extends StatelessWidget {
  const PivxDefiRow({
    super.key,
    required this.label,
    required this.value,
    this.mono = false,
    this.onCopy,
    this.onOpen,
    this.valueColor,
  });

  final String label;
  final String value;
  final bool mono;
  final VoidCallback? onCopy;
  final VoidCallback? onOpen;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final style =
        (mono ? STextStyles.w500_12(context) : STextStyles.w500_14(context))
            .copyWith(color: valueColor ?? colors.textDark);
    Widget button(IconData icon, VoidCallback onTap, String tooltip) =>
        IconButton(
          tooltip: tooltip,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: EdgeInsets.zero,
          iconSize: 16,
          onPressed: onTap,
          icon: Icon(icon, color: colors.textSubtitle1),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              label,
              style: STextStyles.w500_12(context)
                  .copyWith(color: colors.textSubtitle1),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Text(
                value,
                textAlign: TextAlign.end,
                textDirection: mono ? TextDirection.ltr : null,
                style: style,
              ),
            ),
          ),
          if (onOpen != null)
            button(Icons.open_in_new_rounded, onOpen!, l10n.txOpenInExplorer),
          if (onCopy != null)
            button(Icons.copy_rounded, onCopy!, l10n.commonCopy),
        ],
      ),
    );
  }
}

/// A value to copy in full: a payment address, a memo, a deposit address.
class PivxDefiCopyBox extends StatelessWidget {
  const PivxDefiCopyBox({
    super.key,
    required this.label,
    required this.value,
    this.badge,
    this.color,
  });

  final String label;
  final String value;

  /// Next to the label ("Required!").
  final String? badge;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final accent = color ?? colors.textSubtitle1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                label,
                style: STextStyles.w600_12(context).copyWith(color: accent),
              ),
            ),
            if (badge != null) ...[
              const SizedBox(width: 6),
              Text(
                badge!,
                style: STextStyles.w600_12(context)
                    .copyWith(color: colors.textError),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Material(
          color: colors.textFieldDefaultBG,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => pivxDefiCopy(context, value, label),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 8, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      value,
                      textDirection: TextDirection.ltr,
                      style: STextStyles.w500_12(context)
                          .copyWith(color: colors.textDark),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.copy_rounded,
                    size: 18,
                    color: colors.textSubtitle1,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One step of an order: [sub] says where it stands, [progress] fills a
/// bar under it.
typedef PivxDefiStep = ({String label, String? sub, double? progress});

/// The steps of an order. Those before [active] are done; the active one
/// is [failed] or under way. [active] past the end: all done.
class PivxDefiStepper extends StatelessWidget {
  const PivxDefiStepper({
    super.key,
    required this.steps,
    required this.active,
    required this.color,
    this.failed = false,
  });

  final List<PivxDefiStep> steps;
  final int active;
  final Color color;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final green = pivxDefiGreen(colors);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < steps.length; i++)
          _step(context, colors, green, i, steps[i]),
      ],
    );
  }

  Widget _step(
    BuildContext context,
    StackColors colors,
    Color green,
    int i,
    PivxDefiStep step,
  ) {
    final done = i < active;
    final current = i == active;
    final tone = done
        ? green
        : current
        ? (failed ? colors.textError : color)
        : colors.textSubtitle1.withValues(alpha: 0.5);
    final icon = done
        ? Icons.check_rounded
        : current && failed
        ? Icons.priority_high_rounded
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: tone.withValues(alpha: done || current ? 0.15 : 0.06),
              border: Border.all(color: tone.withValues(alpha: 0.6)),
            ),
            child: Center(
              child: icon != null
                  ? Icon(icon, size: 16, color: tone)
                  : current
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: tone,
                      ),
                    )
                  : Text(
                      "${i + 1}",
                      style: STextStyles.w600_12(context).copyWith(color: tone),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text(
                  step.label,
                  style: STextStyles.w600_14(
                    context,
                  ).copyWith(color: done || current ? colors.textDark : tone),
                ),
                if (step.sub != null && (done || current)) ...[
                  const SizedBox(height: 2),
                  Text(
                    step.sub!,
                    style: STextStyles.w500_12(context)
                        .copyWith(color: colors.textSubtitle1),
                  ),
                ],
                if (step.progress != null && current && !failed) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: step.progress!.clamp(0, 1).toDouble(),
                      minHeight: 6,
                      color: tone,
                      backgroundColor: tone.withValues(alpha: 0.15),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
