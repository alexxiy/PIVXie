import 'dart:math';

import 'package:flutter/material.dart';

import '../utilities/util.dart';
import 'center_or_scroll.dart';
import 'glass.dart';
import 'motion.dart';

/// What the phone and tablet layouts adapt to. Desktop has its own layouts,
/// so on desktop all of this stays off.
abstract final class ScreenFit {
  /// The widest a column of text, fields and buttons gets.
  static const double columnWidth = 640;

  /// The widest two panes get together.
  static const double panesWidth = 1100;

  /// The widest a dialog gets when it doesn't span a phone screen.
  static const double dialogWidth = 520;

  /// Landscape with room for two panes: a phone on its side, a tablet.
  static bool sideBySide(BuildContext context) {
    if (Util.isDesktop) return false;
    final size = MediaQuery.sizeOf(context);
    return size.width > size.height && size.width >= 560;
  }

  /// Too short for tall artwork and big gaps: a phone on its side.
  static bool short(BuildContext context) =>
      !Util.isDesktop && MediaQuery.sizeOf(context).height < 480;

  /// Wider than a phone in portrait: dialogs stop spanning the screen.
  static bool wide(BuildContext context) =>
      !Util.isDesktop && MediaQuery.sizeOf(context).width >= 560;

  /// The body of a page that has two panes in landscape.
  static double panesOrColumn(BuildContext context) =>
      sideBySide(context) ? panesWidth : columnWidth;

  /// The height left under the app bar, without the system bars.
  static double bodyHeight(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final toolbar =
        Theme.of(context).appBarTheme.toolbarHeight ?? kToolbarHeight;
    return MediaQuery.sizeOf(context).height -
        padding.top -
        padding.bottom -
        toolbar;
  }
}

/// What the desktop layouts adapt to. A window goes from a netbook's 800x480
/// to a whole 4K screen, and can change size at any moment.
abstract final class DesktopFit {
  /// The widest the content of a page gets.
  static const double pageWidth = 1800;

  /// The height a page gets at least. A shorter window scrolls it.
  static const double pageHeight = 480;

  /// Narrower than this, the side menu folds to its icons.
  static const double foldMenuWidth = 1100;

  /// Shorter than this, the bars get lower and the gaps smaller.
  static const double shortHeight = 640;

  /// Narrower than this, labels on the bars give way to their icons.
  static const double tightWidth = 1000;

  static bool short(BuildContext context) =>
      MediaQuery.sizeOf(context).height < shortHeight;

  static bool tight(BuildContext context) =>
      MediaQuery.sizeOf(context).width < tightWidth;
}

/// The body of a desktop page: at most [DesktopFit.pageWidth] wide, and at
/// least [minHeight] high, scrolling when the window is shorter. The widget
/// tree is the same at every size, so resizing keeps the page's state.
class DesktopPageBody extends StatelessWidget {
  const DesktopPageBody({
    super.key,
    required this.child,
    this.minHeight = DesktopFit.pageHeight,
    this.growsWithChild = false,
  });

  final Widget child;
  final double minHeight;

  /// Gets as high as [child] needs, whatever the language and the window. For
  /// a column of fixed parts, without anything that fills the height.
  final bool growsWithChild;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final height = max(constraints.maxHeight, minHeight);
      return SingleChildScrollView(
        primary: false,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: max(
              (constraints.maxWidth - DesktopFit.pageWidth) / 2,
              0,
            ),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: height,
              maxHeight: growsWithChild ? double.infinity : height,
            ),
            child: child,
          ),
        ),
      );
    },
  );
}

/// A lower app bar for phones on their side, where every row counts. Always
/// in the tree, so that rotating doesn't rebuild the app below it.
class ScreenFitTheme extends StatelessWidget {
  const ScreenFitTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (Util.isDesktop) return child;
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        appBarTheme: theme.appBarTheme.copyWith(
          toolbarHeight: ScreenFit.short(context) ? 48 : null,
        ),
      ),
      child: child,
    );
  }
}

/// Keeps [child] in a centered column of at most [maxWidth], clear of the
/// notch and of side navigation bars.
///
/// The widget tree is the same at every size, so rotating keeps the state of
/// everything below it.
class PageColumn extends StatelessWidget {
  const PageColumn({
    super.key,
    required this.child,
    this.maxWidth = ScreenFit.columnWidth,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    if (Util.isDesktop) return child;
    final padding = MediaQuery.paddingOf(context);
    final room = MediaQuery.sizeOf(context).width - padding.horizontal;
    final side = max((room - maxWidth) / 2, 0.0);
    return Padding(
      padding: EdgeInsets.only(
        left: padding.left + side,
        right: padding.right + side,
      ),
      child: MediaQuery.removePadding(
        context: context,
        removeLeft: true,
        removeRight: true,
        child: child,
      ),
    );
  }
}

/// A [Scaffold] whose body stays in a [PageColumn]. The app bar still spans
/// the screen. Pages with their own wide layout pass [maxBodyWidth]
/// [double.infinity].
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    super.key,
    this.scaffoldKey,
    this.appBar,
    this.body,
    this.backgroundColor,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.resizeToAvoidBottomInset,
    this.maxBodyWidth = ScreenFit.columnWidth,
  });

  final Key? scaffoldKey;
  final PreferredSizeWidget? appBar;
  final Widget? body;
  final Color? backgroundColor;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final bool? resizeToAvoidBottomInset;
  final double maxBodyWidth;

  @override
  Widget build(BuildContext context) => Scaffold(
    key: scaffoldKey,
    appBar: appBar,
    backgroundColor: backgroundColor,
    floatingActionButton: floatingActionButton,
    floatingActionButtonLocation: floatingActionButtonLocation,
    resizeToAvoidBottomInset: resizeToAvoidBottomInset,
    body: body == null
        ? null
        : PageColumn(maxWidth: maxBodyWidth, child: body!),
  );
}

/// [start] and [end] next to each other in landscape, one above the other in
/// portrait. Built on a [Flex], so rotating keeps their state.
class SideBySide extends StatelessWidget {
  const SideBySide({
    super.key,
    required this.start,
    required this.end,
    this.startFlex = 1,
    this.endFlex = 1,
    this.gap = 16,
    this.endFillsHeight = false,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
    this.portraitCrossAxisAlignment = CrossAxisAlignment.stretch,
  });

  final Widget start;
  final Widget end;
  final int startFlex;
  final int endFlex;
  final double gap;

  /// In portrait, [end] takes the height left under [start].
  final bool endFillsHeight;

  final CrossAxisAlignment crossAxisAlignment;
  final CrossAxisAlignment portraitCrossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    final side = ScreenFit.sideBySide(context);
    return Flex(
      direction: side ? Axis.horizontal : Axis.vertical,
      mainAxisSize: side || endFillsHeight
          ? MainAxisSize.max
          : MainAxisSize.min,
      crossAxisAlignment: side
          ? crossAxisAlignment
          : portraitCrossAxisAlignment,
      children: [
        Flexible(flex: side ? startFlex : 0, fit: FlexFit.tight, child: start),
        SizedBox(width: side ? gap : 0, height: side ? 0 : gap),
        Flexible(
          flex: side ? endFlex : (endFillsHeight ? 1 : 0),
          fit: FlexFit.tight,
          child: end,
        ),
      ],
    );
  }
}

/// For a column with a [Spacer] that pushes its buttons to the bottom: fills
/// the room it's given, and scrolls when a short screen or the keyboard leaves
/// less room than the column needs.
class FillOrScroll extends StatelessWidget {
  const FillOrScroll({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Util.isDesktop
      ? child
      : LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(child: child),
            ),
          ),
        );
}

/// Cards one under the other, and two in a row in landscape.
class CardGrid extends StatelessWidget {
  const CardGrid({super.key, required this.children, this.gap = 10});

  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) {
    if (!ScreenFit.sideBySide(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => Wrap(
        spacing: gap,
        children: [
          for (final child in children)
            SizedBox(
              width: children.length == 1
                  ? constraints.maxWidth
                  : (constraints.maxWidth - gap) / 2,
              child: child,
            ),
        ],
      ),
    );
  }
}

/// A modal bottom sheet that fits a phone on its side, where the usual nine
/// sixteenths of the height leave room for two rows. Pass [scrollable] for a
/// sheet whose content doesn't scroll by itself. The height is worked out on
/// every build, so a sheet that's open while the phone rotates still fits.
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  ShapeBorder? shape,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  bool scrollable = false,
}) {
  // Most sheets paint their own surface on a transparent sheet; one that
  // passes a colour gets its glass here.
  final glass = Glass.on(context);
  final glassColor = glass && backgroundColor != null && backgroundColor.a > 0
      ? backgroundColor
      : null;
  Widget surface(BuildContext context, Widget child) => glassColor == null
      ? child
      : GlassSurface(
          color: glassColor,
          borderRadius: shape is RoundedRectangleBorder
              ? shape.borderRadius.resolve(Directionality.of(context))
              : const BorderRadius.vertical(top: Radius.circular(20)),
          child: child,
        );
  final sheetColor = glassColor == null ? backgroundColor : Colors.transparent;
  final double? elevation = glass ? 0 : null;
  if (Util.isDesktop) {
    return showModalBottomSheet<T>(
      context: context,
      builder: (context) => surface(context, builder(context)),
      backgroundColor: sheetColor,
      elevation: elevation,
      shape: shape,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      sheetAnimationStyle: Motion.sheet(context),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: sheetColor,
    elevation: elevation,
    shape: shape,
    isScrollControlled: true,
    useSafeArea: true,
    sheetAnimationStyle: Motion.sheet(context),
    builder: (context) {
      final child = surface(context, builder(context));
      final body = scrollable ? SingleChildScrollView(child: child) : child;
      if (isScrollControlled || ScreenFit.short(context)) return body;
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 9 / 16,
        ),
        child: body,
      );
    },
  );
}

/// Two panes for a landscape layout that isn't the portrait one reordered:
/// each scrolls on its own, and is centered when it's shorter than the room.
class SplitPane extends StatelessWidget {
  const SplitPane({
    super.key,
    required this.start,
    required this.end,
    this.startFlex = 1,
    this.endFlex = 1,
    this.gap = 24,
  });

  final Widget start;
  final Widget end;
  final int startFlex;
  final int endFlex;
  final double gap;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        flex: startFlex,
        child: CenterOrScroll(child: start),
      ),
      SizedBox(width: gap),
      Expanded(
        flex: endFlex,
        child: CenterOrScroll(child: end),
      ),
    ],
  );
}
