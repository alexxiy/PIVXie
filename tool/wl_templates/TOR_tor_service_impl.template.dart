//ON
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:tor_ffi_plugin/tor_ffi_plugin.dart';
import 'package:tor_ffi_plugin/tor_ffi_plugin_bindings_generated.dart'
    as bindings;

import '../../services/event_bus/events/global/tor_connection_status_changed_event.dart';
import '../../services/event_bus/global_event_bus.dart';
//END_ON
import '../../services/fusion_tor_service.dart';
import '../../services/tor_service.dart';
//ON
import '../../utilities/logger.dart';
//END_ON

TorService get torService => _getInterface();
FusionTorService get fusionTorService => _getFusionInterface();

//OFF
TorService _getInterface() => throw Exception("TOR not enabled!");
FusionTorService _getFusionInterface() => throw Exception("TOR not enabled!");

//END_OFF
//ON
TorService _getInterface() => _TorServiceImpl.instance;
FusionTorService _getFusionInterface() => _FusionTorServiceImpl.instance;

class _TorServiceImpl extends TorService {
  static _TorServiceImpl? _instance;
  static _TorServiceImpl get instance => _instance ??= _TorServiceImpl._();

  _TorServiceImpl._();

  String? _torDataDirPath;
  TorConnectionStatus _status = TorConnectionStatus.disconnected;

  /// SOCKS port and native proxy handle of the running Tor client.
  int? _port;
  int _proxyAddress = 0;

  /// Bumped by [disable]; a start that finishes under an older
  /// generation was cancelled and shuts its proxy down.
  int _generation = 0;

  @override
  TorConnectionStatus get status => _status;

  /// Getter for the proxyInfo.
  ///
  /// Throws if Tor is not connected.
  @override
  ({InternetAddress host, int port}) getProxyInfo() {
    if (status == TorConnectionStatus.connected && _port != null) {
      return (host: InternetAddress.loopbackIPv4, port: _port!);
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
  /// Both run in a background isolate: bootstrapping blocks for as long as
  /// the network takes, and must not freeze the UI. [disable] cancels a
  /// start in progress.
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
      final stateDir =
          await Directory("$_torDataDirPath/tor_state").create(recursive: true);
      final cacheDir =
          await Directory("$_torDataDirPath/tor_cache").create(recursive: true);
      final port = await _unusedPort();

      final proxyAddress = await Isolate.run(() {
        final tor = bindings.tor_start(
          port,
          stateDir.path.toNativeUtf8().cast(),
          cacheDir.path.toNativeUtf8().cast(),
        );
        if (tor.client == nullptr) {
          throw Exception(_lastTorError());
        }
        if (!bindings.tor_client_bootstrap(tor.client)) {
          final error = _lastTorError();
          bindings.tor_proxy_stop(tor.proxy);
          throw Exception(error);
        }
        return tor.proxy.address;
      });

      if (generation != _generation) {
        // Cancelled while bootstrapping.
        _stopProxy(proxyAddress);
        return;
      }

      _port = port;
      _proxyAddress = proxyAddress;
      _updateStatusAndFireEvent(
        status: TorConnectionStatus.connected,
        message: "TorService.start call success",
      );
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
  @override
  Future<void> disable() async {
    if (_status == TorConnectionStatus.disconnected) return;
    _generation++;
    _stopProxy(_proxyAddress);
    _proxyAddress = 0;
    _port = null;
    _updateStatusAndFireEvent(
      status: TorConnectionStatus.disconnected,
      message: "TorService.disable call success",
    );
  }

  static void _stopProxy(int address) {
    if (address == 0) return;
    bindings.tor_proxy_stop(Pointer.fromAddress(address));
  }

  static Future<int> _unusedPort() async {
    final random = Random.secure();
    for (int i = 0; i < 100; i++) {
      final port = 1024 + random.nextInt(65535 - 1024);
      try {
        final socket = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          port,
        );
        await socket.close();
        return port;
      } catch (_) {}
    }
    throw Exception("Failed to get an unused port for Tor");
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

String _lastTorError() =>
    bindings.tor_last_error_message().cast<Utf8>().toDartString();

class _FusionTorServiceImpl extends FusionTorService {
  static _FusionTorServiceImpl? _instance;
  static _FusionTorServiceImpl get instance =>
      _instance ??= _FusionTorServiceImpl._();

  _FusionTorServiceImpl._();

  Tor? _tor;
  String? _torDataDirPath;

  /// Getter for the proxyInfo.
  ///
  /// Throws if Tor is not connected.
  @override
  ({InternetAddress host, int port}) getProxyInfo() {
    try {
      return (host: InternetAddress.loopbackIPv4, port: _tor!.port);
    } catch (_) {
      throw Exception("Tor proxy info fetched while not connected!");
    }
  }

  /// Initialize the tor ffi lib instance if it hasn't already been set. Nothing
  /// changes if _tor is already been set.
  @override
  void init({required String torDataDirPath, Tor? mockableOverride}) {
    _tor ??= mockableOverride ?? Tor.instance;
    _torDataDirPath ??= torDataDirPath;
  }

  /// Start the Tor service.
  ///
  /// This will start the Tor service and establish a Tor circuit.
  ///
  /// Throws an exception if the Tor library was not inited or if the Tor
  /// service fails to start.
  ///
  /// Returns a Future that completes when the Tor service has started.
  @override
  Future<void> start() async {
    if (_tor == null || _torDataDirPath == null) {
      throw Exception("FusionTorService.init has not been called!");
    }

    // Start the Tor service.
    try {
      await _tor!.start(torDataDirPath: _torDataDirPath!);
    } catch (e, s) {
      Logging.instance.w(
        "FusionTorService.start failed: ",
        error: e,
        stackTrace: s,
      );
      rethrow;
    }
  }
}

//END_ON
