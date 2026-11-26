import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// Spring motion for pages, dialogs, sheets and notifications: things
/// settle like physical objects instead of easing along a fixed curve.
/// With "reduce motion" on in the system, they appear at once.
abstract final class Motion {
  /// Whether the system asks for less motion.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// Growing or dropping something into view: quick, with a small bounce.
  static final SpringDescription pop = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 420),
    bounce: 0.22,
  );

  /// Pages and sheets: no bounce, so their edges never overshoot.
  static final SpringDescription glide =
      SpringDescription.withDurationAndBounce(
        duration: const Duration(milliseconds: 380),
      );

  static const pageDuration = Duration(milliseconds: 460);
  static const pageReverseDuration = Duration(milliseconds: 320);
  static final Curve pageCurve = SpringCurve(glide, pageDuration);

  /// Pages on desktop. Phones keep their platform's own transitions:
  /// predictive back on Android, the swipe-back slide on iOS.
  static const pageTransitions = PageTransitionsTheme(
    builders: {
      TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: SpringPageTransitionsBuilder(),
      TargetPlatform.linux: SpringPageTransitionsBuilder(),
      TargetPlatform.windows: SpringPageTransitionsBuilder(),
      TargetPlatform.fuchsia: SpringPageTransitionsBuilder(),
    },
  );

  /// Bottom sheets: they glide up and settle.
  static AnimationStyle sheet(BuildContext context) => reduced(context)
      ? AnimationStyle.noAnimation
      : AnimationStyle(
          duration: pageDuration,
          curve: pageCurve,
          reverseDuration: const Duration(milliseconds: 260),
          reverseCurve: Curves.easeInOutCubic,
        );

  /// For an [AnimatedSwitcher]: the new child fades in while it grows
  /// from a little smaller.
  static Widget fadeScale(Widget child, Animation<double> animation) =>
      _fadeScale(child, animation, 0.96);

  /// [fadeScale] growing from [begin], for pictures that should pop more.
  static AnimatedSwitcherTransitionBuilder fadeScaleFrom(double begin) =>
      (child, animation) => _fadeScale(child, animation, begin);

  static final Curve _popCurve = SpringCurve(
    pop,
    const Duration(milliseconds: 420),
  );

  static Widget _fadeScale(
    Widget child,
    Animation<double> animation,
    double begin,
  ) => FadeTransition(
    opacity: animation,
    child: ScaleTransition(
      scale: animation.drive(
        Tween<double>(begin: begin, end: 1).chain(CurveTween(curve: _popCurve)),
      ),
      child: child,
    ),
  );

  /// Dropdown menus unfold on a spring over the first half of their
  /// 300 ms route, then the items fade in one by one. For
  /// `DropdownStyleData.openInterval`: the menu starts fading its items in
  /// where this interval ends.
  static final Interval menuOpen = Interval(
    0,
    0.5,
    curve: SpringCurve(
      SpringDescription.withDurationAndBounce(
        duration: const Duration(milliseconds: 180),
      ),
      const Duration(milliseconds: 150),
    ),
  );
}

/// [spring] going from 0 to 1 as a curve over [span], for animations that
/// run for a set time (routes, sheets). It ends exactly at 1; a bouncy
/// spring overshoots 1 on the way.
class SpringCurve extends Curve {
  SpringCurve(SpringDescription spring, Duration span)
    : _simulation = SpringSimulation(spring, 0, 1, 0),
      _span = span.inMicroseconds / Duration.microsecondsPerSecond {
    _end = _simulation.x(_span);
  }

  final SpringSimulation _simulation;
  final double _span;
  late final double _end;

  @override
  double transformInternal(double t) => _simulation.x(t * _span) / _end;
}

/// Desktop pages: the new page slides in a short way while it fades in,
/// and the page under it drifts the other way. Going back runs it in
/// reverse, starting fast and settling.
class SpringPageTransitionsBuilder extends PageTransitionsBuilder {
  const SpringPageTransitionsBuilder();

  @override
  Duration get transitionDuration => Motion.pageDuration;

  @override
  Duration get reverseTransitionDuration => Motion.pageReverseDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (Motion.reduced(context)) return child;
    return _SpringPageTransition(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      child: child,
    );
  }
}

class _SpringPageTransition extends StatefulWidget {
  const _SpringPageTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  State<_SpringPageTransition> createState() => _SpringPageTransitionState();
}

class _SpringPageTransitionState extends State<_SpringPageTransition> {
  late CurvedAnimation _in;
  late CurvedAnimation _out;

  CurvedAnimation _curve(Animation<double> parent) => CurvedAnimation(
    parent: parent,
    curve: Motion.pageCurve,
    reverseCurve: FlippedCurve(Motion.pageCurve),
  );

  @override
  void initState() {
    super.initState();
    _in = _curve(widget.animation);
    _out = _curve(widget.secondaryAnimation);
  }

  @override
  void didUpdateWidget(_SpringPageTransition old) {
    super.didUpdateWidget(old);
    if (old.animation != widget.animation) {
      _in.dispose();
      _in = _curve(widget.animation);
    }
    if (old.secondaryAnimation != widget.secondaryAnimation) {
      _out.dispose();
      _out = _curve(widget.secondaryAnimation);
    }
  }

  @override
  void dispose() {
    _in.dispose();
    _out.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final sign = rtl ? -1.0 : 1.0;
    return AnimatedBuilder(
      animation: Listenable.merge([_in, _out]),
      child: widget.child,
      builder: (context, child) {
        final enter = _in.value;
        final leave = _out.value;
        final dx = sign * (40 * (1 - enter) - 24 * leave);
        return Opacity(
          opacity: enter.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(dx, 0),
            child: Transform.scale(
              scale: 1 - 0.015 * (1 - enter) - 0.01 * leave,
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// Springs [child] in when its popup (dialog or sheet) opens: it grows
/// from a little smaller, rising a bit when it sits at the bottom, and
/// settles with a small bounce. When the popup closes, it shrinks back as
/// it fades out. Outside a popup it shows [child] as is.
class SpringIn extends StatefulWidget {
  const SpringIn({
    super.key,
    required this.child,
    this.alignment = Alignment.center,
    this.rise = 0,
  });

  final Widget child;

  /// The point it grows from, within [child].
  final Alignment alignment;

  /// How far it rises into place, in logical pixels.
  final double rise;

  @override
  State<SpringIn> createState() => _SpringInState();
}

class _SpringInState extends State<SpringIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spring = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final route = ModalRoute.of(context);
    if (route is! PopupRoute || Motion.reduced(context)) return;
    // Only while the popup opens: content swapped in later stays put.
    if (route.animation?.status != AnimationStatus.forward) return;
    _spring.value = 0;
    _spring.animateWith(SpringSimulation(Motion.pop, 0, 1, 0));
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    final routeAnimation = route is PopupRoute ? route.animation : null;
    return AnimatedBuilder(
      animation: routeAnimation == null
          ? _spring
          : Listenable.merge([_spring, routeAnimation]),
      child: widget.child,
      builder: (context, child) {
        final grow = _spring.value;
        final closing =
            routeAnimation != null &&
            routeAnimation.status == AnimationStatus.reverse &&
            !Motion.reduced(context);
        final shrink = closing ? 1 - routeAnimation.value : 0.0;
        final scale = (0.9 + 0.1 * grow) * (1 - 0.06 * shrink);
        final dy = widget.rise * ((1 - grow) + 0.5 * shrink);
        // Always the same widgets around [child], so its state (text
        // being typed, say) survives the end of the animation.
        return Transform.translate(
          offset: Offset(0, dy),
          child: Transform.scale(
            scale: scale,
            alignment: widget.alignment,
            child: child,
          ),
        );
      },
    );
  }
}

/// Gives [child] a small springy swell each time [active] turns on, or
/// when it shows up already on: a PIN dot as it fills or is added.
class SpringBump extends StatefulWidget {
  const SpringBump({
    super.key,
    required this.active,
    required this.child,
    this.swell = 0.3,
  });

  final bool active;
  final Widget child;

  /// How much it grows at the peak: 0.3 is 30 %.
  final double swell;

  @override
  State<SpringBump> createState() => _SpringBumpState();
}

class _SpringBumpState extends State<SpringBump>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spring = AnimationController.unbounded(
    vsync: this,
  );

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.active) _bump();
  }

  @override
  void didUpdateWidget(SpringBump old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _bump();
  }

  void _bump() {
    if (Motion.reduced(context)) return;
    // A push from rest: with [Motion.pop] this peaks at about 1 after
    // 70 ms and settles back to 0.
    _spring.animateWith(SpringSimulation(Motion.pop, 0, 0, 35));
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _spring,
    child: widget.child,
    builder: (context, child) =>
        Transform.scale(scale: 1 + widget.swell * _spring.value, child: child),
  );
}
