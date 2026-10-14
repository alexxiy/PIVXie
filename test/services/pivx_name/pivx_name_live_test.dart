import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/services/pivx_name/pivx_name.dart';
import 'package:paymint/services/pivx_name/pivx_name_resolver.dart';

/// Against the production PIVX.name server and BNB Smart Chain. Opt in:
/// PIVX_NAME_LIVE=1 flutter test test/services/pivx_name/pivx_name_live_test.dart
void main() {
  // Prefs aren't loaded here, so the app's Tor setting reads as off.
  final live = Platform.environment["PIVX_NAME_LIVE"] == "1";

  test(
    "registered names verify",
    () async {
      final resolver = PivxNameResolver(PivxNameService.mainnet);
      for (final name in [
        "alexxiy.pivx",
        "anonymous.pivx",
        "donate.pivx",
        "donation.pivx",
        "dungvn3000.pivx",
        "incognito.pivx",
      ]) {
        final result = await resolver.lookup(name);
        expect(result, isA<PivxNameVerified>(), reason: name);
        final address = (result as PivxNameVerified).address;
        expect(isStrictPivxNameTarget(address), isTrue, reason: name);
        // ignore: avoid_print
        print("$name -> $address");
      }
    },
    skip: !live,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test("an unregistered name", () async {
    final resolver = PivxNameResolver(PivxNameService.mainnet);
    final result = await resolver.lookup("no-such-name-pivxie-test.pivx");
    expect(result, isA<PivxNameNotRegistered>());
    expect(await resolver.caughtUp(), isTrue);
  }, skip: !live);
}
