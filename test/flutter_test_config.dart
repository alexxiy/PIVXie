import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

/// Runs before the tests of each file.
///
/// google_fonts loads a font the first time a text asks for it, and each
/// load tells the framework that the system fonts changed, which schedules
/// a frame. A widget test that ends before that frame fails with "An
/// animation is still running even after the widget tree was disposed".
/// Loaded before any widget is built, nothing is scheduled.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUpAll(() async {
    // Only where the tests set up the binding (widget tests do): it also
    // replaces the HTTP client, which the fake servers of other tests
    // need.
    if (BindingBase.debugBindingType() == null) return;
    try {
      await GoogleFonts.pendingFonts([
        for (final weight in const [
          FontWeight.w400,
          FontWeight.w500,
          FontWeight.w600,
          FontWeight.w700,
        ])
          GoogleFonts.inter(fontWeight: weight),
        GoogleFonts.roboto(fontWeight: FontWeight.w400),
      ]);
      // The "fonts changed" messages arrive asynchronously.
      await Future<void>.delayed(Duration.zero);
    } catch (_) {
      // The tests that need the fonts report it.
    }
  });
  await testMain();
}
