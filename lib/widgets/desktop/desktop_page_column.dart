import 'package:flutter/material.dart';

import '../../themes/stack_colors.dart';
import '../../utilities/util.dart';

/// On desktop, a phone-sized screen pushed as a full page (the PIVX
/// screens, coin control) sits in a centered column on the app background
/// instead of stretching across the window. [card]: a screen built for a
/// dialog on desktop (the confirm screen) gets a dialog-like card.
/// On mobile it is just [child].
class DesktopPageColumn extends StatelessWidget {
  const DesktopPageColumn({super.key, required this.child, this.card = false});

  final Widget child;
  final bool card;

  static const double _pageWidth = 720;
  static const double _cardWidth = 580;

  @override
  Widget build(BuildContext context) {
    if (!Util.isDesktop) return child;
    final colors = Theme.of(context).extension<StackColors>()!;
    return ColoredBox(
      color: colors.background,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: card ? _cardWidth : _pageWidth),
          child: card
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Material(
                    color: colors.popupBG,
                    borderRadius: BorderRadius.circular(20),
                    clipBehavior: Clip.antiAlias,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 16, bottom: 32),
                      child: child,
                    ),
                  ),
                )
              : child,
        ),
      ),
    );
  }
}
