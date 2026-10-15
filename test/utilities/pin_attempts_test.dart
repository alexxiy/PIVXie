import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/utilities/flutter_secure_storage_interface.dart';
import 'package:paymint/utilities/pin_attempts.dart';

void main() {
  test("three wrong PINs are free, then each locks for longer", () async {
    final store = FakeSecureStorage();
    final attempts = PinAttempts(store);

    for (var i = 0; i < 3; i++) {
      expect(await attempts.failed(), isNull);
    }
    expect(await attempts.lockedFor(), isNull);

    expect(await attempts.failed(), const Duration(seconds: 30));
    expect(await attempts.lockedFor(), isNotNull);
    expect(await attempts.failed(), const Duration(minutes: 1));
    expect(await attempts.failed(), const Duration(minutes: 5));

    // A new screen (or a restart) reads the same state.
    expect(await PinAttempts(store).lockedFor(), isNotNull);

    await attempts.succeeded();
    expect(await attempts.lockedFor(), isNull);
    expect(await attempts.failed(), isNull);
  });

  test("the lockout never drops back while PINs stay wrong", () async {
    final attempts = PinAttempts(FakeSecureStorage());
    Duration? last;
    for (var i = 0; i < 12; i++) {
      last = await attempts.failed() ?? last;
    }
    expect(last, const Duration(hours: 1));
  });

  test("the wait is rounded up", () {
    expect(
      PinAttempts.lockedMessage(const Duration(seconds: 29, milliseconds: 1)),
      "Too many wrong PINs. Try again in 30 seconds.",
    );
    expect(
      PinAttempts.lockedMessage(const Duration(seconds: 60)),
      "Too many wrong PINs. Try again in 1 minute.",
    );
    expect(
      PinAttempts.lockedMessage(const Duration(minutes: 4, seconds: 1)),
      "Too many wrong PINs. Try again in 5 minutes.",
    );
  });
}
