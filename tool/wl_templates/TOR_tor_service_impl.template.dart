//ON
import 'dart:io';

import 'package:tor_ffi_plugin/tor_ffi_plugin.dart';

import '../../services/event_bus/events/global/tor_connection_status_changed_event.dart';
import '../../services/event_bus/global_event_bus.dart';
//END_ON
import '../../services/tor_service.dart';
//ON
import '../../utilities/logger.dart';
//END_ON

TorService get torService => _getInterface();

//OFF
TorService _getInterface() => throw Exception("TOR not enabled!");

//END_OFF
//ON
TorService _getInterface() => _TorServiceImpl.instance;

class _TorServiceImpl extends TorService {
  static _TorServiceImpl? _instance;
  static _TorServiceImpl get instance => _instance ??= _TorServiceImpl._();

  _TorServiceImpl._();

  String? _torDataDirPath;
  TorConnectionStatus _status = TorConnectionStatus.disconnected;

  /// Bumped by [disable]; a start that finishes under an older
  /// generation was cancelled.
  int _generation = 0;

  @override
  TorConnectionStatus get status => _status;

  /// Getter for the proxyInfo.
  ///
  /// Throws if Tor is not connected.
  @override
  ({InternetAddress host, int port}) getProxyInfo() {
    if (status == TorConnectionStatus.connected) {
      return (host: InternetAddress.loopbackIPv4, port: Tor.instance.port);
    } else {
      throw Exception("Tor proxy info fetched while not connected!");
    }
  }

  @override
  void init({required String torDataDirPath}) {
    _torDataDirPath ??= torDataDirPath;
  }

  /// Start Tor and bootstrap a circuit.
  ///
  /// The plugin does both in background isolates, so the UI doesn't wait
  /// for the network. A bootstrap that times out (no network yet, as on a
  /// phone started offline) is tried again until it works or [disable] is
  /// called, which also cancels a start in progress.
  @override
  Future<void> start() async {
    if (_torDataDirPath == null) {
      throw Exception("TorService.init has not been called!");
    }
    if (_status != TorConnectionStatus.disconnected) return;

    final generation = ++_generation;
    _updateStatusAndFireEvent(
      status: TorConnectionStatus.connecting,
      message: "TorService.start call in progress",
    );

    try {
      while (true) {
        try {
          await Tor.instance.start(torDataDirPath: _torDataDirPath!);
          break;
        } on TorBootstrapTimeout catch (e) {
          if (generation != _generation) return;
          Logging.instance.w("Tor bootstrap timed out, trying again: $e");
        }
      }
      if (generation != _generation) return;

      _updateStatusAndFireEvent(
        status: TorConnectionStatus.connected,
        message: "TorService.start call success",
      );
    } on TorStartCancelled {
      // disable() was called meanwhile.
    } catch (e, s) {
      if (generation != _generation) return;
      Logging.instance.w("TorService.start failed: ", error: e, stackTrace: s);
      _updateStatusAndFireEvent(
        status: TorConnectionStatus.disconnected,
        message: "TorService.start call failed",
      );
      rethrow;
    }
  }

  /// Disable Tor, also while it is still connecting.
  ///
  /// The proxy is shut down and the client released; until that's done,
  /// nothing uses it (the status already reads disconnected).
  @override
  Future<void> disable() async {
    if (_status == TorConnectionStatus.disconnected) return;
    _generation++;
    _updateStatusAndFireEvent(
      status: TorConnectionStatus.disconnected,
      message: "TorService.disable call success",
    );
    try {
      await Tor.instance.stop();
    } catch (e, s) {
      // The next start or stop retries the release.
      Logging.instance.w("Tor stop failed: ", error: e, stackTrace: s);
    }
  }

  void _updateStatusAndFireEvent({
    required TorConnectionStatus status,
    required String message,
  }) {
    _status = status;
    GlobalEventBus.instance.fire(
      TorConnectionStatusChangedEvent(_status, message),
    );
  }
}

//END_ON
