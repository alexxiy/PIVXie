import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/networking/trusted_roots.dart';

void main() {
  test("bundled roots are valid certificates", () {
    for (final pem in bundledRootCertificates) {
      SecurityContext(withTrustedRoots: false)
          .setTrustedCertificatesBytes(utf8.encode(pem));
    }
  });

  test("trusting them again is harmless", () {
    trustBundledRootCertificates();
    trustBundledRootCertificates();
  });
}
