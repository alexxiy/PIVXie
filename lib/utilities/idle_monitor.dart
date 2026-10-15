import 'dart:async';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class IdleMonitor with WidgetsBindingObserver {
  final Duration timeout;
  final VoidCallback onIdle;

  final WidgetsBinding binding = WidgetsBinding.instance;

  IdleMonitor({required this.timeout, required this.onIdle});

  Timer? _idleTimer;
  bool _isAttached = false;
  void Function(PointerDataPacket)? _prevPointerHandler;
  KeyEventCallback? _keyboardHandler;

  void attach() {
    if (_isAttached) return;
    _isAttached = true;
    _resetTimer();
    _prevPointerHandler = binding.platformDispatcher.onPointerDataPacket;
    binding.platformDispatcher.onPointerDataPacket = (packet) {
      _onUserActivity();
      _prevPointerHandler?.call(packet);
    };
    _keyboardHandler = (event) {
      _onUserActivity();
      return false;
    };
    binding.keyboard.addHandler(_keyboardHandler!);
    binding.addObserver(this);
  }

  void detach() {
    if (!_isAttached) return;
    _isAttached = false;
    binding.platformDispatcher.onPointerDataPacket = _prevPointerHandler;
    if (_keyboardHandler != null) {
      binding.keyboard.removeHandler(_keyboardHandler!);
    }
    binding.removeObserver(this);
    _cancelTimer();
  }

  /// When the user last touched or typed, by the clock: timers stand
  /// still while the phone sleeps, the clock doesn't.
  DateTime _lastActivity = DateTime.now();

  void _onUserActivity() {
    _resetTimer();
  }

  void _resetTimer() {
    _lastActivity = DateTime.now();
    _cancelTimer();
    _idleTimer = Timer(timeout, onIdle);
  }

  void _cancelTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  /// Back from the background: lock if the time away (asleep included)
  /// reached the timeout.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_isAttached || state != AppLifecycleState.resumed) return;
    final idle = DateTime.now().difference(_lastActivity);
    _cancelTimer();
    if (idle >= timeout) {
      onIdle();
    } else {
      _idleTimer = Timer(timeout - idle, onIdle);
    }
  }
}
