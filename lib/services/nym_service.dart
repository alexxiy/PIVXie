import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../wl_gen/generated/nym_service_impl.dart';
import 'event_bus/events/global/tor_connection_status_changed_event.dart';

final pNymService = Provider<NymService>((_) => nymService);

/// The Nym mixnet client: like [TorService], a local SOCKS5 proxy that
/// requests go through. Its states are Tor's ([TorConnectionStatus]).
abstract class NymService {
  static NymService get sharedInstance => nymService;

  /// Current status. Same as that fired on the event bus.
  TorConnectionStatus get status;

  /// The local proxy. Throws if the client is not connected.
  ({InternetAddress host, int port}) getProxyInfo();

  /// Connect to the mixnet; tries again until it works or [disable] is
  /// called. Completes when connected or cancelled.
  Future<void> start();

  /// Disconnect, also while still connecting.
  Future<void> disable();
}
