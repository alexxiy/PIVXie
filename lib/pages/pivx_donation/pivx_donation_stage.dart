import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'pivx_donation.dart';

/// The donation screen's colours: violet for the shielded (hooded) PIVXie,
/// cyan for the transparent one. The stage is always night: the art is
/// drawn for a dark backdrop.
class PivxDonationPalette {
  const PivxDonationPalette._(
    this.top,
    this.bottom,
    this.glow,
    this.accent,
    this.accent2,
  );

  static const shielded = PivxDonationPalette._(
    Color(0xFF2A1650),
    Color(0xFF120A26),
    Color(0xFFA855F7),
    Color(0xFFC084FC),
    Color(0xFFE879F9),
  );
  static const transparent = PivxDonationPalette._(
    Color(0xFF1A2358),
    Color(0xFF0D1130),
    Color(0xFF22D3EE),
    Color(0xFF67E8F9),
    Color(0xFFC084FC),
  );

  static PivxDonationPalette of({required bool shielded}) =>
      shielded ? PivxDonationPalette.shielded : PivxDonationPalette.transparent;

  final Color top;
  final Color bottom;
  final Color glow;
  final Color accent;
  final Color accent2;

  /// For buttons and the tier slider.
  LinearGradient get gradient => LinearGradient(colors: [glow, accent2]);
}

/// PIVXie on stage: the tier's picture, floating, with a glow and the
/// tier's particles (zzz, sparkles, code bits, bubbles, lightning, orbiting
/// coins), the custom amounts' surprises, and confetti for a thank-you.
/// A tap makes PIVXie hop.
class PivxDonationStage extends StatefulWidget {
  const PivxDonationStage({
    super.key,
    required this.art,
    required this.mood,
    required this.shielded,
    this.egg,
    this.celebrating = false,
    this.height = 250,
  });

  /// The picture's asset.
  final String art;

  /// Which tier's animation plays (a fixed tier).
  final PivxDonationTier mood;
  final bool shielded;
  final PivxDonationEgg? egg;
  final bool celebrating;
  final double height;

  @override
  State<PivxDonationStage> createState() => _PivxDonationStageState();
}

class _PivxDonationStageState extends State<PivxDonationStage>
    with TickerProviderStateMixin {
  /// Seconds since the stage appeared.
  final _time = ValueNotifier<double>(0);
  late final Ticker _ticker = createTicker(
    (elapsed) => _time.value = elapsed.inMicroseconds / 1e6,
  );
  late final AnimationController _hop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  );
  double? _pokedAt;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.disableAnimationsOf(context);
    if (still && _ticker.isActive) {
      _ticker.stop();
    } else if (!still && !_ticker.isActive) {
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _hop.dispose();
    _time.dispose();
    super.dispose();
  }

  void _poke() {
    HapticFeedback.lightImpact();
    _pokedAt = _time.value;
    _hop.forward(from: 0);
  }

  int get _energy => PivxDonationTier.fixed.indexOf(widget.mood);

  Widget _picture(double size) {
    final image = Image.asset(
      widget.art,
      key: ValueKey(widget.art),
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
    );
    if (widget.egg != PivxDonationEgg.coffeeNotFound) return image;
    // Error 404: the picture tears into colour channels now and then.
    return ValueListenableBuilder<double>(
      key: ValueKey("glitch ${widget.art}"),
      valueListenable: _time,
      builder: (_, t, _) {
        final g = _glitch(t);
        Widget tinted(Color color, double dx) => Transform.translate(
          offset: Offset(dx, 0),
          child: ColorFiltered(
            colorFilter: ColorFilter.mode(color, BlendMode.srcATop),
            child: image,
          ),
        );
        return Stack(
          children: [
            if (g > 0) ...[
              Opacity(opacity: 0.55, child: tinted(Colors.red, -5 * g)),
              Opacity(opacity: 0.55, child: tinted(Colors.cyan, 5 * g)),
            ],
            Opacity(opacity: g > 0.5 ? 0.6 : 1, child: image),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = PivxDonationPalette.of(shielded: widget.shielded);
    final egg = widget.egg;
    final h = widget.height;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final madman = egg == PivxDonationEgg.madman;
        final size =
            math.min(h * 0.86, math.min(w * 0.72, 240.0)) * (madman ? 0.78 : 1);
        final center = Offset(madman ? w * 0.3 : w / 2, h - 8 - size / 2);
        final scene = _Scene(
          time: _time,
          palette: palette,
          energy: _energy,
          mood: widget.mood,
          egg: egg,
          celebrating: widget.celebrating,
          center: center,
          size: size,
          pokedAt: _pokedAt,
        );
        return Semantics(
          image: true,
          label: widget.mood.title,
          child: GestureDetector(
            onTap: _poke,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                height: h,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [palette.top, palette.bottom],
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(painter: _BackPainter(scene)),
                    ),
                    Positioned(
                      left: center.dx - size / 2,
                      top: center.dy - size / 2,
                      width: size,
                      height: size,
                      child: AnimatedBuilder(
                        animation: Listenable.merge([_time, _hop]),
                        builder: (_, child) => Transform.translate(
                          offset: scene.bob,
                          child: Transform.scale(
                            scale: 1 + 0.08 * math.sin(_hop.value * math.pi),
                            alignment: Alignment.bottomCenter,
                            child: child,
                          ),
                        ),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 350),
                          switchInCurve: Curves.easeOutBack,
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: ScaleTransition(
                                  scale: Tween(
                                    begin: 0.85,
                                    end: 1.0,
                                  ).animate(animation),
                                  child: child,
                                ),
                              ),
                          child: _picture(size),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(painter: _FrontPainter(scene)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// How torn the 404 picture is at [t]: mostly 0, short bursts up to 1.
double _glitch(double t) {
  final slot = (t / 1.3).floor();
  final into = t - slot * 1.3;
  if (_rnd(slot, 7) < 0.35 || into > 0.22) return 0;
  return 0.5 + 0.5 * _rnd((t * 30).floor(), 3);
}

/// A repeatable random number in [0, 1).
double _rnd(int i, int salt) {
  final x = math.sin(i * 12.9898 + salt * 78.233) * 43758.5453;
  return x - x.floorToDouble();
}

/// What both painters draw from.
class _Scene {
  _Scene({
    required this.time,
    required this.palette,
    required this.energy,
    required this.mood,
    required this.egg,
    required this.celebrating,
    required this.center,
    required this.size,
    required this.pokedAt,
  });

  final ValueNotifier<double> time;
  final PivxDonationPalette palette;

  /// 0 (Tiny Drop) to 5 (Moon Boost).
  final int energy;
  final PivxDonationTier mood;
  final PivxDonationEgg? egg;
  final bool celebrating;
  final Offset center;
  final double size;
  final double? pokedAt;

  double get t => time.value;

  /// The floating offset: a sleepy sway for the tiny drop, a buzz for the
  /// direct IV, a slow climb for the moon boost. The thank-you art just
  /// floats.
  Offset get bob {
    final t = this.t;
    switch (celebrating ? null : mood) {
      case PivxDonationTier.tinyDrop:
        return Offset(1.5 * math.sin(t * 0.8), 2 * math.sin(t * 1.6));
      case PivxDonationTier.directIv:
        return Offset(
          1.2 * math.sin(t * 47),
          -5 + 5 * math.sin(t * 3) + math.cos(t * 39),
        );
      case PivxDonationTier.moonBoost:
        return Offset(2 * math.sin(t * 1.3), -8 + 7 * math.sin(t * 2.2));
      default:
        final amp = 3.0 + energy;
        return Offset(0, -amp + amp * math.sin(t * (1.6 + energy * 0.25)));
    }
  }
}

// Shapes shared by the painters.

void _sparkle(Canvas canvas, Offset c, double r, Color color) {
  final path = Path()
    ..moveTo(c.dx, c.dy - r)
    ..quadraticBezierTo(c.dx, c.dy, c.dx + r, c.dy)
    ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy + r)
    ..quadraticBezierTo(c.dx, c.dy, c.dx - r, c.dy)
    ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy - r)
    ..close();
  canvas.drawPath(path, Paint()..color = color);
}

void _text(
  Canvas canvas,
  String text,
  Offset center,
  double fontSize,
  Color color, {
  FontWeight weight = FontWeight.w800,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontSize: fontSize,
        color: color,
        fontWeight: weight,
        height: 1,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, center - Offset(painter.width / 2, painter.height / 2));
}

void _bolt(Canvas canvas, Offset from, Offset to, int seed, Paint paint) {
  final path = Path()..moveTo(from.dx, from.dy);
  const steps = 6;
  for (var i = 1; i < steps; i++) {
    final p = Offset.lerp(from, to, i / steps)!;
    path.lineTo(p.dx + (_rnd(seed, i) - 0.5) * 18, p.dy);
  }
  path.lineTo(to.dx, to.dy);
  canvas.drawPath(path, paint);
}

/// Behind PIVXie: corner pixels, the glow, the floor shadow, and the moon
/// boost's star streaks and the direct IV's lightning.
class _BackPainter extends CustomPainter {
  _BackPainter(this.s) : super(repaint: s.time);

  final _Scene s;

  @override
  void paint(Canvas canvas, Size size) {
    final t = s.t;
    final p = s.palette;

    // Pixel confetti in two corners, like the artwork's backdrop.
    for (var i = 0; i < 14; i++) {
      final corner = i.isEven;
      final dx = _rnd(i, 1) * 70;
      final dy = _rnd(i, 2) * 60;
      final side = 4.0 + (_rnd(i, 3) * 3).floor() * 3;
      final twinkle = 0.5 + 0.5 * math.sin(t * (0.8 + _rnd(i, 4)) + i);
      canvas.drawRect(
        Rect.fromLTWH(
          corner ? size.width - 12 - dx : 12 + dx,
          corner ? 12 + dy : size.height - 12 - dy,
          side,
          side,
        ),
        Paint()..color = p.glow.withValues(alpha: 0.08 + 0.18 * twinkle),
      );
    }

    if (s.mood == PivxDonationTier.moonBoost && !s.celebrating) {
      // Stars streaking down: PIVXie is going up.
      for (var i = 0; i < 16; i++) {
        final x = _rnd(i, 5) * size.width;
        final speed = 60 + _rnd(i, 6) * 120;
        final len = 8 + _rnd(i, 7) * 22;
        final y =
            (_rnd(i, 8) * size.height + t * speed) % (size.height + len) - len;
        canvas.drawLine(
          Offset(x, y),
          Offset(x, y + len),
          Paint()
            ..strokeWidth = 1.5
            ..strokeCap = StrokeCap.round
            ..color = Colors.white.withValues(alpha: 0.15 + 0.35 * _rnd(i, 9)),
        );
      }
    }

    // The glow, brighter for bigger tiers.
    final energy = s.energy / 5;
    var glow = 0.28 + 0.3 * energy;
    if (s.mood == PivxDonationTier.directIv && !s.celebrating) {
      glow *= 0.75 + 0.25 * _rnd((t * 12).floor(), 11);
    }
    final bob = s.bob;
    final c = s.center + Offset(bob.dx, bob.dy * 0.5);
    final r = s.size * (0.5 + 0.12 * energy) * (1 + 0.04 * math.sin(t * 2));
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [
            p.glow.withValues(alpha: glow),
            p.glow.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    if (s.mood != PivxDonationTier.moonBoost || s.celebrating) {
      // The floor shadow shrinks as PIVXie rises.
      final lift = (-bob.dy).clamp(0, 12) / 12;
      final floor = Offset(s.center.dx, s.center.dy + s.size * 0.47);
      canvas.drawOval(
        Rect.fromCenter(
          center: floor,
          width: s.size * (0.62 - 0.12 * lift),
          height: 12,
        ),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.3 - 0.1 * lift)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
    }

    if (s.mood == PivxDonationTier.directIv && !s.celebrating) {
      // Lightning now and then.
      final slot = (t / 1.4).floor();
      if (t - slot * 1.4 < 0.16) {
        final paint = Paint()
          ..color = p.accent2.withValues(alpha: 0.85)
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round;
        final left = _rnd(slot, 12) < 0.5;
        final x = left
            ? s.center.dx - s.size * 0.55
            : s.center.dx + s.size * 0.55;
        _bolt(canvas, Offset(x, 0), Offset(x, s.center.dy), slot, paint);
        canvas.drawRect(
          Offset.zero & size,
          Paint()..color = Colors.white.withValues(alpha: 0.04),
        );
      }
    }

    if (s.egg == PivxDonationEgg.madman) _giantMug(canvas, size, t);
  }

  /// $250 and up: a mug stretching past the top of the stage.
  void _giantMug(Canvas canvas, Size size, double t) {
    final p = s.palette;
    final width = math.min(size.width * 0.34, 150.0);
    final left = size.width * 0.56;
    final bottom = size.height - 10;
    final stretch = 1.2 + 0.08 * math.sin(t * 2.4);
    final top = bottom - size.height * stretch;
    final body = RRect.fromLTRBAndCorners(
      left,
      top,
      left + width,
      bottom,
      bottomLeft: const Radius.circular(22),
      bottomRight: const Radius.circular(22),
    );
    canvas.drawRRect(body, Paint()..color = p.glow.withValues(alpha: 0.32));
    final stroke = Paint()
      ..color = p.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawRRect(body, stroke);
    // Handle.
    canvas.drawArc(
      Rect.fromLTWH(left + width - 14, bottom - 92, 44, 58),
      -math.pi / 2,
      math.pi,
      false,
      stroke..strokeWidth = 6,
    );
    // Stretch marks, scrolling up.
    for (var i = 0; i < 7; i++) {
      final y = bottom - 40 - ((i * 34 + t * 50) % (bottom - 40 - top));
      canvas.drawLine(
        Offset(left + 16, y),
        Offset(left + width - 16, y),
        Paint()
          ..color = p.accent.withValues(alpha: 0.25)
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }
    // The PIVX badge.
    final badge = Offset(left + width / 2, bottom - 48);
    canvas.drawCircle(badge, 20, Paint()..color = p.bottom);
    canvas.drawCircle(
      badge,
      20,
      Paint()
        ..color = p.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    _text(canvas, "P", badge, 20, p.accent);
  }

  @override
  bool shouldRepaint(_BackPainter old) => true;
}

/// In front of PIVXie: the tier's particles, the eggs' props, the burst
/// after a tap and confetti.
class _FrontPainter extends CustomPainter {
  _FrontPainter(this.s) : super(repaint: s.time);

  final _Scene s;

  @override
  void paint(Canvas canvas, Size size) {
    final t = s.t;
    final p = s.palette;
    final c = s.center + s.bob;
    final half = s.size / 2;

    if (s.celebrating) {
      _confetti(canvas, size, t);
    } else {
      switch (s.mood) {
        case PivxDonationTier.tinyDrop:
          // Zzz.
          for (var i = 0; i < 3; i++) {
            final phase = ((t + i) % 3) / 3;
            final pos =
                c + Offset(half * 0.3 + phase * 22, -half * 0.55 - phase * 42);
            _text(
              canvas,
              "z",
              pos,
              11 + phase * 10,
              Colors.white.withValues(alpha: math.sin(phase * math.pi) * 0.8),
            );
          }
        case PivxDonationTier.doubleShot:
          // Code bits flying off the keyboard.
          for (var i = 0; i < 9; i++) {
            final phase = ((t * 0.9 + _rnd(i, 21)) % 1);
            final x = c.dx + (_rnd(i, 22) - 0.5) * s.size * 0.9;
            final y = c.dy + half * 0.4 - phase * half * 1.3;
            _text(
              canvas,
              _rnd(i, 23) < 0.5 ? "0" : "1",
              Offset(x, y),
              10,
              p.accent.withValues(alpha: math.sin(phase * math.pi) * 0.9),
              weight: FontWeight.w600,
            );
          }
        case PivxDonationTier.zeroKnowledgeNitro:
          // Bubbles.
          for (var i = 0; i < 10; i++) {
            final phase = ((t * 0.45 + _rnd(i, 31)) % 1);
            final x =
                c.dx +
                (_rnd(i, 32) - 0.5) * s.size * 0.8 +
                4 * math.sin(t * 3 + i);
            final y = c.dy + half * 0.5 - phase * half * 1.5;
            canvas.drawCircle(
              Offset(x, y),
              2 + _rnd(i, 33) * 3.5,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.2
                ..color = p.accent.withValues(
                  alpha: math.sin(phase * math.pi) * 0.8,
                ),
            );
          }
        case PivxDonationTier.directIv:
          // Sparks around the edges.
          final slot = (t * 8).floor();
          for (var i = 0; i < 3; i++) {
            if (_rnd(slot, 40 + i) < 0.5) continue;
            final a = _rnd(slot, 50 + i) * math.pi * 2;
            final from = c + Offset(math.cos(a), math.sin(a)) * half * 0.75;
            final to = c + Offset(math.cos(a), math.sin(a)) * half * 0.98;
            _bolt(
              canvas,
              from,
              to,
              slot + i,
              Paint()
                ..color = Colors.white.withValues(alpha: 0.85)
                ..strokeWidth = 1.5
                ..style = PaintingStyle.stroke,
            );
          }
        case PivxDonationTier.moonBoost:
          // PIV coins in orbit; the far half of the orbit is dimmer.
          for (var i = 0; i < 2; i++) {
            final a = t * 1.4 + i * math.pi;
            final pos =
                c + Offset(math.cos(a) * half * 1.05, math.sin(a) * half * 0.3);
            final near = (math.sin(a) + 1) / 2;
            final r = 7 + 4 * near;
            canvas.drawCircle(
              pos,
              r,
              Paint()..color = p.glow.withValues(alpha: 0.35 + 0.5 * near),
            );
            canvas.drawCircle(
              pos,
              r,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.5
                ..color = Colors.white.withValues(alpha: 0.5 + 0.4 * near),
            );
            _text(
              canvas,
              "P",
              pos,
              r * 1.1,
              Colors.white.withValues(alpha: 0.6 + 0.4 * near),
            );
          }
        case PivxDonationTier.cyberMug:
        case PivxDonationTier.customBrew:
          break;
      }
      // Twinkles, more of them for bigger tiers.
      final count = 2 + s.energy;
      for (var i = 0; i < count; i++) {
        final a = _rnd(i, 61) * math.pi * 2;
        final d = half * (0.75 + 0.3 * _rnd(i, 62));
        final pos = c + Offset(math.cos(a) * d, math.sin(a) * d * 0.8);
        final tw = math.max(0.0, math.sin(t * (1.5 + _rnd(i, 63) * 2) + i * 2));
        _sparkle(
          canvas,
          pos,
          2 + 4 * tw,
          (i.isEven ? p.accent : p.accent2).withValues(alpha: 0.9 * tw),
        );
      }
    }

    switch (s.egg) {
      case PivxDonationEgg.tapWater:
        _waterGlass(canvas, c + Offset(half * 0.78, half * 0.45), t);
      case PivxDonationEgg.coffeeNotFound:
        _phantomCup(canvas, size, c + Offset(half * 0.8, half * 0.4), t);
      case PivxDonationEgg.madman:
        // Little arrows up the mug.
        for (var i = 0; i < 3; i++) {
          final phase = ((t * 0.6 + i / 3) % 1);
          _text(
            canvas,
            "↑",
            Offset(size.width * 0.5, size.height * (0.8 - phase * 0.7)),
            16,
            Colors.white.withValues(alpha: math.sin(phase * math.pi) * 0.7),
          );
        }
      case null:
        break;
    }

    // The burst after a tap.
    final poked = s.pokedAt;
    if (poked != null && t - poked < 0.7) {
      final k = (t - poked) / 0.7;
      for (var i = 0; i < 10; i++) {
        final a = i / 10 * math.pi * 2 + _rnd(i, 71);
        final pos =
            c + Offset(math.cos(a), math.sin(a)) * half * (0.3 + k * 0.8);
        _sparkle(
          canvas,
          pos,
          5 * (1 - k) + 1,
          (i.isEven ? p.accent2 : Colors.white).withValues(alpha: 1 - k),
        );
      }
    }
  }

  /// Under a dollar: a glass of water, and a question.
  void _waterGlass(Canvas canvas, Offset bottom, double t) {
    final p = s.palette;
    final o = bottom + Offset(0, 3 * math.sin(t * 2));
    final glass = Path()
      ..moveTo(o.dx - 17, o.dy - 46)
      ..lineTo(o.dx + 17, o.dy - 46)
      ..lineTo(o.dx + 13, o.dy)
      ..lineTo(o.dx - 13, o.dy)
      ..close();
    final waterTop = o.dy - 27 + 1.5 * math.sin(t * 3);
    canvas.save();
    canvas.clipPath(glass);
    canvas.drawRect(
      Rect.fromLTRB(o.dx - 20, waterTop, o.dx + 20, o.dy),
      Paint()..color = const Color(0xFF60A5FA).withValues(alpha: 0.55),
    );
    for (var i = 0; i < 4; i++) {
      final phase = ((t * 0.7 + i / 4) % 1);
      canvas.drawCircle(
        Offset(o.dx - 7 + i * 5, o.dy - 3 - phase * 22),
        1.4,
        Paint()..color = Colors.white.withValues(alpha: 0.7 * (1 - phase)),
      );
    }
    canvas.restore();
    canvas.drawPath(
      glass,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withValues(alpha: 0.85),
    );
    _text(
      canvas,
      "?",
      o + Offset(14 + 2 * math.sin(t * 4), -62),
      20,
      p.accent2,
    );
  }

  /// $4.04: an outline of a cup that keeps blinking out, and a torn picture.
  void _phantomCup(Canvas canvas, Size size, Offset bottom, double t) {
    final p = s.palette;
    final g = _glitch(t);
    if (g > 0) {
      for (var i = 0; i < 4; i++) {
        final y = _rnd((t * 30).floor(), 80 + i) * size.height;
        canvas.drawRect(
          Rect.fromLTWH(0, y, size.width, 2 + 6 * _rnd(i, 81)),
          Paint()
            ..color = (i.isEven ? Colors.cyan : Colors.pinkAccent).withValues(
              alpha: 0.18,
            ),
        );
      }
    }
    final on = _rnd((t * 6).floor(), 90) > 0.25;
    if (!on) return;
    final dash = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = p.accent.withValues(alpha: 0.75);
    final cup = Rect.fromLTRB(
      bottom.dx - 16,
      bottom.dy - 34,
      bottom.dx + 16,
      bottom.dy,
    );
    // Dashed sides and bottom.
    void dashed(Offset a, Offset b) {
      const n = 6;
      for (var i = 0; i < n; i += 2) {
        canvas.drawLine(
          Offset.lerp(a, b, i / n)!,
          Offset.lerp(a, b, (i + 1) / n)!,
          dash,
        );
      }
    }

    dashed(cup.topLeft, cup.bottomLeft);
    dashed(cup.bottomLeft, cup.bottomRight);
    dashed(cup.bottomRight, cup.topRight);
    dashed(cup.topLeft, cup.topRight);
    canvas.drawArc(
      Rect.fromLTWH(cup.right - 6, cup.top + 6, 16, 18),
      -math.pi / 2,
      math.pi,
      false,
      dash,
    );
    _text(canvas, "404", Offset(cup.center.dx, cup.top - 12), 12, p.accent2);
  }

  void _confetti(Canvas canvas, Size size, double t) {
    final p = s.palette;
    final colors = [p.accent, p.accent2, Colors.white, const Color(0xFFFBBF24)];
    for (var i = 0; i < 40; i++) {
      final speed = 50 + _rnd(i, 101) * 70;
      final y =
          (_rnd(i, 102) * size.height + t * speed) % (size.height + 20) - 10;
      final x = _rnd(i, 103) * size.width + 10 * math.sin(t * 2 + i);
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(t * (1 + _rnd(i, 104) * 3) + i);
      canvas.drawRect(
        const Rect.fromLTWH(-3, -1.5, 6, 3),
        Paint()..color = colors[i % colors.length],
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_FrontPainter old) => true;
}
