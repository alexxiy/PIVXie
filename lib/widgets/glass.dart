import 'dart:ui' as ui;

import 'package:dropdown_button2/dropdown_button2.dart';
import 'package:flutter/material.dart';

import 'motion.dart';

/// Glass surfaces (preview). Bars, sheets, dialogs and toasts show what is
/// behind them blurred and a little more vivid, tinted with their usual
/// colour and edged with light, instead of a flat fill.
///
/// Off unless the app is built with `--dart-define=GLASS_UI=true`, and off
/// when the system asks for high contrast.
abstract final class Glass {
  /// Whether the app was built with glass.
  static const built = bool.fromEnvironment('GLASS_UI');

  static bool on(BuildContext context) =>
      built && !MediaQuery.highContrastOf(context);

  /// Lighter dimming behind dialogs and sheets than the usual 54 %, so
  /// what is behind the glass still shows through it.
  static const Color dimming = Color(0x47000000);

  /// For [ThemeData.dialogTheme] and [ThemeData.bottomSheetTheme]: null,
  /// so the defaults, without glass.
  static const DialogThemeData? dialogTheme = built
      ? DialogThemeData(barrierColor: dimming)
      : null;
  static const BottomSheetThemeData? sheetTheme = built
      ? BottomSheetThemeData(modalBarrierColor: dimming)
      : null;

  /// [style] with a glass menu: the menu's own fill turns clear, and glass
  /// tinted with it unfolds in step with the menu.
  static DropdownStyleData menu(BuildContext context, DropdownStyleData style) {
    final decoration = style.decoration;
    final color = decoration?.color;
    if (!on(context) || decoration == null || color == null) return style;
    return style.copyWith(
      decoration: decoration.copyWith(
        color: Colors.transparent,
        boxShadow: const [],
      ),
      dropdownBuilder: (context, menu) => _MenuGlass(
        color: color,
        borderRadius:
            decoration.borderRadius?.resolve(Directionality.of(context)) ??
            BorderRadius.zero,
        child: menu,
      ),
    );
  }
}

class _MenuGlass extends StatefulWidget {
  const _MenuGlass({
    required this.color,
    required this.borderRadius,
    required this.child,
  });

  final Color color;
  final BorderRadius borderRadius;
  final Widget child;

  @override
  State<_MenuGlass> createState() => _MenuGlassState();
}

class _MenuGlassState extends State<_MenuGlass> {
  CurvedAnimation? _unfold;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || Motion.reduced(context)) return;
    _unfold = CurvedAnimation(
      parent: animation,
      curve: Motion.menuOpen,
      // Closing, the whole menu just fades out.
      reverseCurve: const Threshold(0),
    );
  }

  @override
  void dispose() {
    _unfold?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    clipper: _UnfoldClipper(_unfold),
    child: GlassSurface(
      color: widget.color,
      borderRadius: widget.borderRadius,
      child: widget.child,
    ),
  );
}

class _UnfoldClipper extends CustomClipper<Rect> {
  _UnfoldClipper(this.unfold) : super(reclip: unfold);

  final Animation<double>? unfold;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width, size.height * (unfold?.value ?? 1));

  @override
  bool shouldReclip(_UnfoldClipper oldClipper) => oldClipper.unfold != unfold;
}

/// A surface filled with [color], or made of glass tinted with it when
/// [Glass.on].
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.color,
    required this.borderRadius,
    this.child,
    this.shadows,
    this.blur = 16,
  });

  /// The flat fill without glass; the tint with it.
  final Color color;
  final BorderRadius borderRadius;
  final List<BoxShadow>? shadows;

  /// How much what is behind gets blurred (the blur's sigma).
  final double blur;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    if (!Glass.on(context)) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: borderRadius,
          boxShadow: shadows,
        ),
        child: child,
      );
    }
    final dark = ThemeData.estimateBrightnessForColor(color) == Brightness.dark;
    Widget glass = ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.compose(
          outer: ui.ColorFilter.matrix(_saturation(1.7)),
          inner: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        ),
        child: CustomPaint(
          painter: _GlassFill(color, borderRadius, dark),
          foregroundPainter: _GlassRim(borderRadius, dark),
          child: child,
        ),
      ),
    );
    final outer = shadows;
    if (outer != null && outer.isNotEmpty) {
      glass = CustomPaint(
        painter: _OuterShadows(outer, borderRadius),
        child: glass,
      );
    }
    return glass;
  }

  /// A colour matrix that makes colours [s] times as saturated.
  static List<double> _saturation(double s) {
    const r = 0.2126, g = 0.7152, b = 0.0722;
    final i = 1 - s;
    return [
      r * i + s, g * i, b * i, 0, 0, //
      r * i, g * i + s, b * i, 0, 0, //
      r * i, g * i, b * i + s, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }
}

/// The tint, and a sheen of light falling on the top half.
class _GlassFill extends CustomPainter {
  _GlassFill(this.color, this.radius, this.dark);

  final Color color;
  final BorderRadius radius;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = radius.toRRect(rect);
    canvas.drawRRect(
      rrect,
      Paint()..color = color.withValues(alpha: color.a * (dark ? 0.6 : 0.62)),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: dark ? 0.07 : 0.24),
            Colors.white.withValues(alpha: 0),
          ],
          stops: const [0, 0.55],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GlassFill old) =>
      old.color != color || old.radius != radius || old.dark != dark;
}

/// A rim of light, brightest where light from the top left would catch the
/// edges, with a soft glow just inside it.
class _GlassRim extends CustomPainter {
  _GlassRim(this.radius, this.dark);

  final BorderRadius radius;
  final bool dark;

  Shader _light(Rect rect, double strength) => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      for (final a in const [0.8, 0.12, 0.12, 0.45])
        Colors.white.withValues(alpha: a * strength),
    ],
    stops: const [0, 0.35, 0.65, 1],
  ).createShader(rect);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final strength = dark ? 0.45 : 1.0;
    canvas.drawRRect(
      radius.toRRect(rect).deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = _light(rect, strength),
    );
    canvas.drawRRect(
      radius.toRRect(rect).deflate(2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
        ..shader = _light(rect, strength * 0.35),
    );
  }

  @override
  bool shouldRepaint(_GlassRim old) => old.radius != radius || old.dark != dark;
}

/// Shadows painted only outside the shape: under glass they would show
/// through as a dark smudge.
class _OuterShadows extends CustomPainter {
  _OuterShadows(this.shadows, this.radius);

  final List<BoxShadow> shadows;
  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = radius.toRRect(rect);
    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(rect.inflate(200))
        ..addRRect(rrect),
    );
    for (final shadow in shadows) {
      canvas.drawRRect(
        rrect.shift(shadow.offset).inflate(shadow.spreadRadius),
        shadow.toPaint(),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OuterShadows old) =>
      old.shadows != shadows || old.radius != radius;
}
