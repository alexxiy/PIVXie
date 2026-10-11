import 'dart:async';
import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

import 'logger.dart';

/// Android 17 blocks apps that target it from reaching devices on the
/// local network (a node on a home server, `192.168.x.x`) unless the user
/// grants ACCESS_LOCAL_NETWORK ("Nearby devices"). Requests then just
/// time out. [ensure] asks once per host before the first connection.
/// Earlier Android versions need no permission (the request is a no-op).
abstract final class LocalNetworkAccess {
  static final _checked = <String, Future<void>>{};

  /// One system prompt at a time: the plugin refuses parallel requests.
  static Future<PermissionStatus>? _prompt;

  /// Ask for local network access when [host] is on the local network.
  /// Never throws; a refusal shows up as failing requests.
  static Future<void> ensure(String host) {
    if (!Platform.isAndroid) return Future.value();
    return _checked[host] ??= _ensure(host).catchError((Object e) {
      // E.g. no activity yet: try again on the next request.
      Logging.instance.w("Local network permission for $host: $e");
      _checked.remove(host);
    });
  }

  static Future<void> _ensure(String host) async {
    if (!await isLocal(host)) return;
    if (await Permission.accessLocalNetwork.isGranted) return;
    final prompt = _prompt ??= Permission.accessLocalNetwork
        .request()
        .whenComplete(() => _prompt = null);
    final status = await prompt;
    Logging.instance.i("Local network permission for $host: $status");
  }

  /// Whether [host] (a name or an IP address) is on the local network:
  /// a private, link-local or `.local` address. Loopback is not.
  static Future<bool> isLocal(String host) async {
    final ip = InternetAddress.tryParse(host);
    if (ip != null) return isLocalAddress(ip);
    final name = host.toLowerCase();
    if (name == "localhost") return false;
    if (name.endsWith(".local") || !name.contains(".")) return true;
    try {
      final addresses = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 5));
      return addresses.any(isLocalAddress);
    } catch (_) {
      return false;
    }
  }

  static bool isLocalAddress(InternetAddress ip) {
    if (ip.isLoopback) return false;
    final b = ip.rawAddress;
    if (ip.type == InternetAddressType.IPv4) {
      return b[0] == 10 ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 && b[1] == 168) ||
          (b[0] == 169 && b[1] == 254);
    }
    if (ip.type == InternetAddressType.IPv6) {
      return (b[0] & 0xfe) == 0xfc || // fc00::/7 unique local
          (b[0] == 0xfe && (b[1] & 0xc0) == 0x80); // fe80::/10 link-local
    }
    return false;
  }
}
