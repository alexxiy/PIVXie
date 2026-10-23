import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import 'pivx_donation_stage.dart';

/// The donation sizes on a track: one stop per label, snapping, with a
/// click under the finger at every stop.
class PivxDonationTierSlider extends StatelessWidget {
  const PivxDonationTierSlider({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
    required this.palette,
    required this.semanticLabel,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;
  final PivxDonationPalette palette;
  final String semanticLabel;

  void _select(int i) {
    if (i == index) return;
    HapticFeedback.selectionClick();
    onChanged(i);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final n = labels.length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        // Stops at the middle of equal label slots.
        double x(int i) => (i + 0.5) * w / n;
        int at(double dx) => (dx / (w / n) - 0.5).round().clamp(0, n - 1);
        const duration = Duration(milliseconds: 180);
        return Semantics(
          slider: true,
          label: semanticLabel,
          value: labels[index],
          increasedValue: index < n - 1 ? labels[index + 1] : null,
          decreasedValue: index > 0 ? labels[index - 1] : null,
          onIncrease: index < n - 1 ? () => _select(index + 1) : null,
          onDecrease: index > 0 ? () => _select(index - 1) : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _select(at(d.localPosition.dx)),
            onHorizontalDragUpdate: (d) => _select(at(d.localPosition.dx)),
            child: ExcludeSemantics(
              child: Column(
                children: [
                  SizedBox(
                    height: 30,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          left: x(0),
                          right: w - x(n - 1),
                          top: 12,
                          height: 6,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.textFieldDefaultBG,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                        AnimatedPositioned(
                          duration: duration,
                          left: x(0),
                          width: x(index) - x(0),
                          top: 12,
                          height: 6,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: palette.gradient,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                        for (var i = 0; i < n; i++)
                          Positioned(
                            left: x(i) - 4,
                            top: 11,
                            width: 8,
                            height: 8,
                            child: AnimatedContainer(
                              duration: duration,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: i <= index
                                    ? palette.accent2
                                    : colors.textSubtitle4,
                              ),
                            ),
                          ),
                        AnimatedPositioned(
                          duration: duration,
                          curve: Curves.easeOutBack,
                          left: x(index) - 13,
                          top: 2,
                          width: 26,
                          height: 26,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                              border: Border.all(color: palette.glow, width: 3),
                              boxShadow: [
                                BoxShadow(
                                  color: palette.glow.withValues(alpha: 0.6),
                                  blurRadius: 12,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      for (var i = 0; i < n; i++)
                        Expanded(
                          child: Center(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                ),
                                child: Text(
                                  labels[i],
                                  maxLines: 1,
                                  style: STextStyles.w500_12(context).copyWith(
                                    fontWeight: i == index
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: i == index
                                        ? colors.textDark
                                        : colors.textSubtitle1,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A slide-to-confirm button: the knob has to be dragged to the end, so a
/// stray tap sends nothing. Screen readers get a plain button.
class PivxSlideToConfirm extends StatefulWidget {
  const PivxSlideToConfirm({
    super.key,
    required this.label,
    required this.onConfirmed,
    required this.palette,
    this.enabled = true,
  });

  final String label;

  /// Runs once the knob is at the end; the knob comes back when it's done.
  final Future<void> Function() onConfirmed;
  final PivxDonationPalette palette;
  final bool enabled;

  @override
  State<PivxSlideToConfirm> createState() => _PivxSlideToConfirmState();
}

class _PivxSlideToConfirmState extends State<PivxSlideToConfirm>
    with SingleTickerProviderStateMixin {
  static const _height = 56.0;
  static const _knob = 48.0;

  /// The knob's distance from the start.
  double _drag = 0;
  bool _busy = false;

  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  Future<void> _animateTo(double target) async {
    final from = _drag;
    void tick() => setState(
      () => _drag = lerpDouble(
        from,
        target,
        Curves.easeOut.transform(_settle.value),
      )!,
    );
    _settle.addListener(tick);
    try {
      await _settle.forward(from: 0).orCancel;
    } on TickerCanceled {
      // Disposed.
    } finally {
      _settle.removeListener(tick);
    }
  }

  Future<void> _confirm(double max) async {
    if (_busy || !widget.enabled) return;
    _busy = true;
    unawaited(HapticFeedback.mediumImpact());
    await _animateTo(max);
    try {
      await widget.onConfirmed();
    } finally {
      _busy = false;
      if (mounted) await _animateTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final p = widget.palette;
    final on = widget.enabled;
    return LayoutBuilder(
      builder: (context, constraints) {
        final max = constraints.maxWidth - _knob - 8;
        final progress = max <= 0 ? 0.0 : (_drag / max).clamp(0.0, 1.0);
        return Semantics(
          button: true,
          enabled: on,
          label: widget.label,
          onTap: on ? () => _confirm(max) : null,
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: !on || _busy
                ? null
                : (d) => setState(
                    () => _drag = (_drag + d.delta.dx).clamp(0.0, max),
                  ),
            onHorizontalDragEnd: !on || _busy
                ? null
                // The knob as it is now, not as last built.
                : (_) => _drag > max * 0.85 ? _confirm(max) : _animateTo(0),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              height: _height,
              decoration: BoxDecoration(
                color: on
                    ? p.glow.withValues(alpha: 0.12)
                    : colors.textFieldDefaultBG,
                borderRadius: BorderRadius.circular(_height / 2),
                border: Border.all(
                  color: on
                      ? p.glow.withValues(alpha: 0.8)
                      : Colors.transparent,
                  width: 1.5,
                ),
                boxShadow: on
                    ? [
                        BoxShadow(
                          color: p.glow.withValues(alpha: 0.3),
                          blurRadius: 16,
                        ),
                      ]
                    : null,
              ),
              child: Stack(
                children: [
                  if (on)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: _drag + _knob + 8,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              p.glow.withValues(alpha: 0.15),
                              p.accent2.withValues(alpha: 0.45),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(_height / 2),
                        ),
                      ),
                    ),
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.only(
                        left: _knob + 8,
                        right: 16,
                      ),
                      child: Center(
                        child: Opacity(
                          opacity: (1 - progress * 1.6).clamp(0.0, 1.0),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              widget.label,
                              maxLines: 1,
                              style: STextStyles.button(context).copyWith(
                                color: on
                                    ? colors.textDark
                                    : colors.textSubtitle2,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 4 + _drag,
                    top: (_height - _knob) / 2 - 1.5,
                    width: _knob,
                    height: _knob,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: on ? p.gradient : null,
                        color: on ? null : colors.textSubtitle4,
                      ),
                      child: const Icon(
                        Icons.keyboard_double_arrow_right_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
