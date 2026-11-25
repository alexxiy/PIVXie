//ON
import 'dart:io';

import 'package:flutter_libnym/flutter_libnym.dart';
import 'package:socks5_proxy/socks_client.dart';

import '../../app_config.dart';

import '../../services/event_bus/events/global/nym_connection_status_changed_event.dart';
import '../../services/event_bus/events/global/tor_connection_status_changed_event.dart';
import '../../services/event_bus/global_event_bus.dart';
//END_ON
import '../../services/nym_service.dart';
//ON
import '../../utilities/logger.dart';

//END_ON

NymService get nymService => _getInterface();

//OFF
NymService _getInterface() => throw Exception("NYM not enabled!");

//END_OFF
//ON
NymService _getInterface() => _NymServiceImpl.instance;

class _NymServiceImpl extends NymService {
  static _NymServiceImpl? _instance;
  static _NymServiceImpl get instance => _instance ??= _NymServiceImpl._();

  _NymServiceImpl._();

  TorConnectionStatus _status = TorConnectionStatus.disconnected;
  int? _port;

  /// Bumped by [disable]; a start that finishes under an older
  /// generation was cancelled.
  int _generation = 0;

  @override
  TorConnectionStatus get status => _status;

  @override
  ({InternetAddress host, int port}) getProxyInfo() {
    if (_status == TorConnectionStatus.connected && _port != null) {
      return (host: InternetAddress.loopbackIPv4, port: _port!);
    }
    throw Exception("Nym proxy info fetched while not connected!");
  }

  /// Connects in a background isolate. A failed attempt (no network yet,
  /// a gateway that doesn't answer) is tried again, waiting a little
  /// longer each time, until it works or [disable] is called.
  @override
  Future<void> start() async {
    if (_status != TorConnectionStatus.disconnected) return;

    final generation = ++_generation;
    _update(TorConnectionStatus.connecting, "NymService.start in progress");

    var wait = const Duration(seconds: 5);
    while (true) {
      try {
        final port = await Nym.start();
        if (generation == _generation && !await _exitWorks(port)) {
          // Another try picks another exit.
          await Nym.stop();
          throw Exception("the exit gateway passed no traffic");
        }
        if (generation != _generation) {
          // disable() came after the client was up: close it again.
          await Nym.stop();
          return;
        }
        _port = port;
        _update(TorConnectionStatus.connected, "NymService.start success");
        return;
      } on NymStartCancelled {
        return;
      } catch (e) {
        if (generation != _generation) return;
        Logging.instance.w("Nym start failed, trying again: $e");
      }
      await Future<void>.delayed(wait);
      if (generation != _generation) return;
      if (wait < const Duration(minutes: 1)) wait *= 2;
    }
  }

  /// Some exit gateways pass no traffic, so a new connection is tried
  /// with one request to the app's own server first (any answer will
  /// do). A server on the local network (test builds) can't be reached
  /// over Nym at all; then the check is left out.
  Future<bool> _exitWorks(int port) async {
    final node = AppConfig.coins.first.defaultNode(isPrimary: true);
    var url = Uri.parse(node.host.trim());
    if (!url.hasScheme) {
      url = Uri(
        scheme: node.useSSL ? "https" : "http",
        host: node.host.trim(),
        port: node.port,
      );
    }
    final host = url.host;
    if (host == "localhost" ||
        host.endsWith(".local") ||
        (InternetAddress.tryParse(host)?.isLoopback ?? false) ||
        RegExp(r"^(10|127)\.|^192\.168\.|^172\.(1[6-9]|2\d|3[01])\.")
            .hasMatch(host)) {
      return true;
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    SocksTCPClient.assignToHttpClient(client, [
      ProxySettings(InternetAddress.loopbackIPv4, port),
    ]);
    try {
      final request = await client.getUrl(url);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      await response.drain<void>();
      return true;
    } catch (e) {
      Logging.instance.w("Nym exit check failed: $e");
      return false;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> disable() async {
    if (_status == TorConnectionStatus.disconnected) return;
    _generation++;
    _port = null;
    _update(TorConnectionStatus.disconnected, "NymService.disable success");
    try {
      await Nym.stop();
    } catch (e, s) {
      Logging.instance.w("Nym stop failed: ", error: e, stackTrace: s);
    }
  }

  void _update(TorConnectionStatus status, String message) {
    _status = status;
    GlobalEventBus.instance.fire(
      NymConnectionStatusChangedEvent(status, message),
    );
  }
}

//END_ON
