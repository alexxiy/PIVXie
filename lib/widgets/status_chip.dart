import 'package:flutter/material.dart';

import '../themes/stack_colors.dart';
import '../utilities/text_styles.dart';

/// A small tinted status label (connected, enabled, ...) in the app's
/// language, where the desktop pages once showed English text as images.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    var shade = color;
    // Deepen light accents (yellow, green) on light themes.
    if (colors.brightness != Brightness.dark) {
      final hsl = HSLColor.fromColor(color);
      if (hsl.lightness > 0.45) shade = hsl.withLightness(0.42).toColor();
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: shade.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: STextStyles.w600_14(context).copyWith(color: shade),
      ),
    );
  }
}
