import 'package:flutter/material.dart';

import '../utilities/util.dart';
import 'custom_buttons/app_bar_icon_button.dart';
import 'desktop/desktop_app_bar.dart';

/// The header of a phone screen that also opens in the desktop window (in
/// a DesktopPageColumn): back, [title] and [actions].
///
/// On desktop the back button comes with the padding of the desktop app
/// bar, which a regular 56 px app bar squeezes to a few pixels. There the
/// header takes the desktop app bar's compact height and room for the
/// button. On mobile it's a regular app bar.
class PageAppBar extends StatelessWidget implements PreferredSizeWidget {
  const PageAppBar({
    super.key,
    this.title,
    this.onBack,
    this.leading,
    this.actions,
    this.titleSpacing,
  });

  final Widget? title;

  /// What back does (default: pop).
  final VoidCallback? onBack;

  /// Instead of the back button.
  final Widget? leading;
  final List<Widget>? actions;
  final double? titleSpacing;

  static double get height =>
      Util.isDesktop ? kDesktopAppBarHeightCompact : kToolbarHeight;

  /// The back button's padding on desktop and the button itself.
  static double? get leadingWidth => Util.isDesktop ? 90 : null;

  /// On desktop, actions as high as the back button, and off the edge.
  static EdgeInsetsGeometry? get actionsPadding => Util.isDesktop
      ? const EdgeInsetsDirectional.fromSTEB(0, 20, 12, 20)
      : null;

  static Widget backButton(BuildContext context, {VoidCallback? onPressed}) {
    final button = AppBarBackButton(
      isCompact: Util.isDesktop,
      onPressed: onPressed ?? () => Navigator.of(context).pop(),
    );
    return Util.isDesktop ? Center(child: button) : button;
  }

  /// On mobile, what a regular app bar reports: the app bar theme decides.
  @override
  Size get preferredSize =>
      Util.isDesktop ? Size.fromHeight(height) : AppBar().preferredSize;

  @override
  Widget build(BuildContext context) {
    return AppBar(
      toolbarHeight: Util.isDesktop ? height : null,
      leadingWidth: leadingWidth,
      automaticallyImplyLeading: false,
      leading: leading ?? backButton(context, onPressed: onBack),
      titleSpacing: titleSpacing ?? (Util.isDesktop ? 0 : null),
      title: title,
      actions: actions,
      actionsPadding: actionsPadding,
    );
  }
}
