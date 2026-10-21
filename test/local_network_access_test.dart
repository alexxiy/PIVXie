import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/utilities/local_network_access.dart';

void main() {
  test("local network addresses", () async {
    for (final host in [
      "192.168.1.101",
      "10.0.0.5",
      "172.16.0.1",
      "172.31.255.1",
      "169.254.3.4",
      "fd12::1",
      "fe80::1",
      "pivx-node.local",
      "homeserver",
    ]) {
      expect(await LocalNetworkAccess.isLocal(host), isTrue, reason: host);
    }
    for (final host in [
      "127.0.0.1",
      "::1",
      "localhost",
      "172.32.0.1",
      "8.8.8.8",
      "2001:4860::8888",
    ]) {
      expect(await LocalNetworkAccess.isLocal(host), isFalse, reason: host);
    }
    expect(
      LocalNetworkAccess.isLocalAddress(InternetAddress("192.168.0.1")),
      isTrue,
    );
  });
}
