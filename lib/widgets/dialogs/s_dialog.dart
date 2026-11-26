import 'package:flutter/material.dart';

import '../../themes/stack_colors.dart';
import '../../utilities/util.dart';
import '../adaptive_page.dart';
import '../conditional_parent.dart';
import '../motion.dart';

class SDialog extends StatelessWidget {
  const SDialog({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.contentCanScroll = true,
    this.margin,
    this.background,
    this.mainAxisAlignment,
    this.crossAxisAlignment,
  });

  final Widget child;
  final bool contentCanScroll;
  final Color? background;
  final EdgeInsets? margin;
  final EdgeInsets padding;
  final MainAxisAlignment? mainAxisAlignment;
  final CrossAxisAlignment? crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    final placement =
        mainAxisAlignment ??
        (Util.isDesktop || ScreenFit.wide(context)
            ? MainAxisAlignment.center
            : MainAxisAlignment.end);
    final atBottom = placement == MainAxisAlignment.end;
    return Padding(
      padding: margin ?? EdgeInsets.all(Util.isDesktop ? 32 : 16),
      child: Column(
        mainAxisAlignment: placement,
        crossAxisAlignment: crossAxisAlignment ?? CrossAxisAlignment.center,
        mainAxisSize: .min,
        children: [
          Flexible(
            child: SpringIn(
              alignment: atBottom ? Alignment.bottomCenter : Alignment.center,
              rise: atBottom ? 24 : 0,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: ScreenFit.wide(context)
                      ? ScreenFit.dialogWidth
                      : double.infinity,
                ),
                child: Material(
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    decoration: BoxDecoration(
                      color:
                          background ??
                          Theme.of(context).extension<StackColors>()!.popupBG,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: ConditionalParent(
                      condition: contentCanScroll,
                      builder: (child) => SingleChildScrollView(child: child),
                      child: Padding(padding: padding, child: child),
                    ),
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
