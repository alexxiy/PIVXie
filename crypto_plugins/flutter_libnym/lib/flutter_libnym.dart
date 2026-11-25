/// A Nym mixnet SOCKS5 client: requests sent to its local proxy travel
/// through the mixnet and leave it at an exit gateway.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

DynamicLibrary _open() {
  final override = Platform.environment["NYM_SOCKS_LIB"];
  if (override != null) return DynamicLibrary.open(override);
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open("libnym_socks_ffi.so");
  }
  if (Platform.isIOS || Platform.isMacOS) return DynamicLibrary.process();
  if (Platform.isWindows) return DynamicLibrary.open("nym_socks_ffi.dll");
  throw UnsupportedError("Nym is not available on this platform");
}

DynamicLibrary? _lib;
DynamicLibrary get _library => _lib ??= _open();

typedef _StartC = Int32 Function(Uint32 timeoutSecs);
typedef _StartDart = int Function(int timeoutSecs);
typedef _VoidC = Void Function();
typedef _VoidDart = void Function();
typedef _BoolC = Bool Function();
typedef _BoolDart = bool Function();
typedef _ErrorC = Pointer<Utf8> Function();

/// Connecting failed; [message] says why.
class NymStartException implements Exception {
  NymStartException(this.message);

  final String message;

  @override
  String toString() => "NymStartException: $message";
}

/// The start was cancelled by [Nym.stop].
class NymStartCancelled implements Exception {}

abstract final class Nym {
  static const _channel = MethodChannel("flutter_libnym");
  static bool _androidReady = false;

  /// Android only: the Nym client checks TLS certificates against the
  /// system's trust store, which needs the app context once. The plugin
  /// loads the library and hands it over on the first start.
  static Future<void> _prepareAndroid() async {
    if (!Platform.isAndroid || _androidReady) return;
    final bool? ok;
    try {
      ok = await _channel.invokeMethod<bool>("init");
    } on PlatformException catch (e) {
      throw NymStartException(e.message ?? e.code);
    }
    if (ok != true) {
      final error = _library.lookupFunction<_ErrorC, _ErrorC>(
        "nym_last_error",
      )();
      throw NymStartException(
        error == nullptr ? "TLS verifier setup failed" : error.toDartString(),
      );
    }
    _androidReady = true;
  }

  /// Connects to the mixnet and opens the local SOCKS5 proxy; returns
  /// its port.
  ///
  /// The native call blocks, so it runs in a background isolate. Throws
  /// [NymStartCancelled] when [stop] was called meanwhile, or
  /// [NymStartException] when connecting failed or took longer than
  /// [timeout].
  static Future<int> start({
    Duration timeout = const Duration(seconds: 90),
  }) async {
    await _prepareAndroid();
    final seconds = timeout.inSeconds;
    final result = await Isolate.run(() {
      final start = _library.lookupFunction<_StartC, _StartDart>("nym_start");
      final port = start(seconds);
      if (port >= 0) return (port: port, error: null);
      final error = _library.lookupFunction<_ErrorC, _ErrorC>(
        "nym_last_error",
      )();
      return (
        port: port,
        error: error == nullptr ? "unknown error" : error.toDartString(),
      );
    });
    if (result.port == 0) throw NymStartCancelled();
    if (result.port < 0) throw NymStartException(result.error!);
    return result.port;
  }

  /// Cancels a start in progress and closes the proxy.
  static Future<void> stop() => Isolate.run(() {
        _library.lookupFunction<_VoidC, _VoidDart>("nym_stop")();
      });

  /// Whether the client is connected and its proxy open.
  static bool get isRunning =>
      _library.lookupFunction<_BoolC, _BoolDart>("nym_is_running")();
}
