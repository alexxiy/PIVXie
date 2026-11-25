import 'dart:math';

import 'package:flutter/material.dart';

import '../services/event_bus/events/global/tor_connection_status_changed_event.dart';
import '../themes/stack_colors.dart';

/// The Nym mixnet at work: packets go from the app through three layers
/// of mix nodes, each packet on its own route, to the exit. Still and
/// grey when off, slow and yellow while connecting, green when
/// connected.
class NymAnimation extends StatefulWidget {
  const NymAnimation({super.key, required this.size, required this.status});

  final double size;
  final TorConnectionStatus status;

  @override
  State<NymAnimation> createState() => _NymAnimationState();
}

class _NymAnimationState extends State<NymAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  );

  void _sync() {
    if (widget.status == TorConnectionStatus.disconnected) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(NymAnimation oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          size: Size.square(widget.size),
          painter: _MixnetPainter(
            // Counts whole turns too, so routes change every turn.
            time: (_controller.lastElapsedDuration?.inMilliseconds ?? 0) / 4000,
            status: widget.status,
            colors: colors,
          ),
        ),
      ),
    );
  }
}

class _MixnetPainter extends CustomPainter {
  _MixnetPainter({
    required this.time,
    required this.status,
    required this.colors,
  });

  /// In turns of the animation.
  final double time;
  final TorConnectionStatus status;
  final StackColors colors;

  static const _layers = 3;
  static const _perLayer = 3;
  static const _packets = 7;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final center = Offset(s / 2, s / 2);
    final accent = switch (status) {
      TorConnectionStatus.disconnected => colors.textSubtitle3,
      TorConnectionStatus.connecting => colors.accentColorYellow,
      TorConnectionStatus.connected => colors.accentColorGreen,
    };

    // Backdrop.
    canvas.drawCircle(
      center,
      s * 0.48,
      Paint()..color = accent.withValues(alpha: 0.10),
    );
    canvas.drawCircle(
      center,
      s * 0.48,
      Paint()
        ..color = accent.withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = max(1, s * 0.012),
    );

    // The app (left), three mix layers, the exit (right).
    final entry = Offset(s * 0.14, s / 2);
    final exit = Offset(s * 0.86, s / 2);
    final layers = [
      for (var l = 0; l < _layers; l++)
        [
          for (var n = 0; n < _perLayer; n++)
            Offset(s * (0.32 + 0.18 * l), s * (0.30 + 0.20 * n)),
        ],
    ];

    // Links between neighbouring layers.
    final link = Paint()
      ..color = colors.textSubtitle3.withValues(alpha: 0.35)
      ..strokeWidth = max(0.5, s * 0.006);
    for (final a in layers.first) {
      canvas.drawLine(entry, a, link);
    }
    for (var l = 0; l + 1 < _layers; l++) {
      for (final a in layers[l]) {
        for (final b in layers[l + 1]) {
          canvas.drawLine(a, b, link);
        }
      }
    }
    for (final a in layers.last) {
      canvas.drawLine(a, exit, link);
    }

    // Packets, each on a route of one node per layer, picked anew every
    // turn; they set off at different times, so they leave in a
    // different order than they came.
    final packetPaint = Paint()..color = accent;
    if (status != TorConnectionStatus.disconnected) {
      final count = status == TorConnectionStatus.connected ? _packets : 3;
      final speed = status == TorConnectionStatus.connected ? 1.0 : 0.5;
      for (var i = 0; i < count; i++) {
        final t = time * speed + i / count;
        final turn = t.floor();
        final p = t - turn;
        final random = Random(i * 7919 + turn);
        final route = [
          entry,
          for (final layer in layers) layer[random.nextInt(_perLayer)],
          exit,
        ];
        final position = _along(route, p);
        canvas.drawCircle(position, s * 0.028, packetPaint);
      }
    }

    // Nodes on top. While connecting they light up layer by layer.
    final nodeFill = Paint()..color = colors.popupBG;
    final nodeRing = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = max(1, s * 0.014);
    void node(Offset at, double radius, double glow) {
      canvas.drawCircle(at, radius, nodeFill);
      nodeRing.color = Color.lerp(colors.textSubtitle3, accent, glow)!;
      canvas.drawCircle(at, radius, nodeRing);
    }

    double glowOf(int column) {
      switch (status) {
        case TorConnectionStatus.disconnected:
          return 0;
        case TorConnectionStatus.connected:
          return 1;
        case TorConnectionStatus.connecting:
          final phase = (time * 1.5) % 1 * (_layers + 2);
          return (1 - (phase - column).abs()).clamp(0.0, 1.0);
      }
    }

    node(entry, s * 0.055, glowOf(0));
    for (var l = 0; l < _layers; l++) {
      for (final at in layers[l]) {
        node(at, s * 0.04, glowOf(l + 1));
      }
    }
    node(exit, s * 0.055, glowOf(_layers + 1));
  }

  /// The point [p] (0 to 1) of the way along [route], at even speed per
  /// hop.
  static Offset _along(List<Offset> route, double p) {
    final hops = route.length - 1;
    final x = p * hops;
    final hop = min(x.floor(), hops - 1);
    return Offset.lerp(route[hop], route[hop + 1], x - hop)!;
  }

  @override
  bool shouldRepaint(_MixnetPainter old) =>
      old.time != time || old.status != status || old.colors != colors;
}
