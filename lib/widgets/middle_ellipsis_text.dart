import 'package:flutter/material.dart';

/// One line of [text] at its normal size; when it doesn't fit, the middle
/// is replaced by "…" so the start and the end stay readable (addresses,
/// txids).
class MiddleEllipsisText extends StatelessWidget {
  const MiddleEllipsisText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  static String _shorten(String s, int keep) =>
      "${s.substring(0, (keep + 1) ~/ 2)}…${s.substring(s.length - keep ~/ 2)}";

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(this.style);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        bool fits(String s) {
          final painter = TextPainter(
            text: TextSpan(text: s, style: style),
            textDirection: direction,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          final width = painter.width;
          painter.dispose();
          return width <= constraints.maxWidth;
        }

        var shown = text;
        if (constraints.hasBoundedWidth && text.length > 2 && !fits(text)) {
          // Most characters (split between both ends) that still fit.
          int lo = 2, hi = text.length - 1;
          shown = _shorten(text, 2);
          while (lo <= hi) {
            final mid = (lo + hi) ~/ 2;
            final candidate = _shorten(text, mid);
            if (fits(candidate)) {
              shown = candidate;
              lo = mid + 1;
            } else {
              hi = mid - 1;
            }
          }
        }
        return Text(
          shown,
          style: style,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          semanticsLabel: text,
        );
      },
    );
  }
}
