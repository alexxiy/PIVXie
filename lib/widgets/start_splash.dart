import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The start of the app: the logo on the splash background, drawn the same
/// size and place as the native splash (assets/icon/splash.png at a quarter
/// of its pixels, centred), so the hand-over to Flutter can't be seen. Once
/// the first page has drawn, the logo dips a little, then flies toward the
/// viewer while the background fades into that page.
///
/// It sits above MaterialApp, which gets a new key on theme and language
/// changes, so it runs once per start.
class StartSplash extends StatefulWidget {
  const StartSplash({super.key, required this.child});

  final Widget child;

  // Colours of flutter_native_splash in pubspec.template.yaml.
  static const _light = Color(0xFFF7F7F7);
  static const _dark = Color(0xFF2A2D34);
  static const _asset = "assets/icon/splash.png";

  static ui.Image? _logo;
  static final _ready = ValueNotifier(false);

  /// Decodes the logo before runApp, so the first frame already has it.
  static Future<void> preload() async {
    try {
      final data = await rootBundle.load(_asset);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      _logo = (await codec.getNextFrame()).image;
    } catch (_) {
      // No overlay then: the native splash just gives way to the app.
    }
  }

  /// Called by the first page; the logo flies off after its first frame.
  static void markReady() {
    if (_ready.value) return;
    SchedulerBinding.instance.addPostFrameCallback((_) => _ready.value = true);
  }

  @override
  State<StartSplash> createState() => _StartSplashState();
}

class _StartSplashState extends State<StartSplash>
    with SingleTickerProviderStateMixin {
  late final _fly = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 560),
  );

  // Never keep the logo up for good if the first page doesn't come.
  Timer? _fallback;
  late bool _done = StartSplash._logo == null;

  @override
  void initState() {
    super.initState();
    if (_done) return;
    _fly.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _done = true);
      }
    });
    StartSplash._ready.addListener(_onReady);
    _fallback = Timer(const Duration(seconds: 8), _start);
    _onReady();
  }

  void _onReady() {
    if (StartSplash._ready.value) _start();
  }

  void _start() {
    _fallback?.cancel();
    if (mounted && !_done && !_fly.isAnimating) _fly.forward();
  }

  @override
  void dispose() {
    StartSplash._ready.removeListener(_onReady);
    _fallback?.cancel();
    _fly.dispose();
    super.dispose();
  }

  static double _part(double t, double from, double to) =>
      ((t - from) / (to - from)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final logo = StartSplash._logo;
    return Stack(
      textDirection: TextDirection.ltr,
      fit: StackFit.expand,
      children: [
        widget.child,
        if (!_done && logo != null)
          IgnorePointer(
            child: AnimatedBuilder(
              animation: _fly,
              builder: (context, _) => _frame(logo, _fly.value),
            ),
          ),
      ],
    );
  }

  Widget _frame(ui.Image logo, double t) {
    final dispatcher = ui.PlatformDispatcher.instance;
    final still = dispatcher.accessibilityFeatures.disableAnimations;
    final background = dispatcher.platformBrightness == Brightness.dark
        ? StartSplash._dark
        : StartSplash._light;

    double scale = 1;
    if (!still) {
      // A short dip, then the fast zoom (ease-in, so most of it comes last).
      scale = t < 0.3
          ? 1 - 0.1 * Curves.easeInOut.transform(_part(t, 0, 0.3))
          : 0.9 + 15 * Curves.easeInCubic.transform(_part(t, 0.3, 1));
    }
    final backgroundOpacity =
        1 - Curves.easeIn.transform(_part(t, still ? 0 : 0.5, 1));
    final logoOpacity =
        1 - Curves.easeIn.transform(_part(t, still ? 0 : 0.65, 1));

    return Stack(
      textDirection: TextDirection.ltr,
      fit: StackFit.expand,
      children: [
        Opacity(
          opacity: backgroundOpacity,
          child: ColoredBox(color: background),
        ),
        Center(
          child: Opacity(
            opacity: logoOpacity,
            child: Transform.scale(
              scale: scale,
              child: RawImage(
                image: logo,
                width: logo.width / 4,
                height: logo.height / 4,
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
