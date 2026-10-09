import 'dart:async';

import 'logger.dart';

/// Logs when the UI isolate is blocked long enough for the app to stop
/// reacting (taps, frames), with the work in progress at the time.
///
/// Wallet code names its long-running steps with [run], so a log line
/// like "UI blocked for 2400 ms during PIVX My wallet: shield sync"
/// points at the culprit.
abstract final class UiStallWatch {
  static const _tick = Duration(milliseconds: 100);
  static const _reportAfterMs = 300;

  static Timer? _timer;
  static final _activities = <String>[];

  static void start() {
    if (_timer != null) return;
    final sw = Stopwatch()..start();
    var last = sw.elapsedMilliseconds;
    _timer = Timer.periodic(_tick, (_) {
      final now = sw.elapsedMilliseconds;
      final blocked = now - last - _tick.inMilliseconds;
      last = now;
      if (blocked >= _reportAfterMs) {
        Logging.instance.w(
          "UI blocked for $blocked ms during "
          "${_activities.isEmpty ? "(no tagged activity)" : _activities.join(", ")}",
        );
      }
    });
  }

  /// Run [action], tagged as [activity] in stall reports.
  static Future<T> run<T>(String activity, Future<T> Function() action) async {
    _activities.add(activity);
    final sw = Stopwatch()..start();
    try {
      return await action();
    } finally {
      _activities.remove(activity);
      if (sw.elapsedMilliseconds > 2000) {
        Logging.instance.i("$activity took ${sw.elapsedMilliseconds} ms");
      }
    }
  }
}
