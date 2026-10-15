import 'flutter_secure_storage_interface.dart';

/// Wrong PIN entries, shared by every PIN screen and kept across
/// restarts: after [_free] wrong PINs each one locks PIN entry for longer,
/// until the right PIN (or biometrics) unlocks the app.
class PinAttempts {
  PinAttempts(this._store);

  final SecureStorageInterface _store;

  static const _kFailures = "pinFailedAttempts";
  static const _kLockedUntil = "pinLockedUntil";
  static const _free = 3;

  /// How much longer PIN entry stays locked; null when it isn't.
  Future<Duration?> lockedFor() async {
    final until = int.tryParse(await _store.read(key: _kLockedUntil) ?? "");
    if (until == null) return null;
    final left = DateTime.fromMillisecondsSinceEpoch(until)
        .difference(DateTime.now());
    return left > Duration.zero ? left : null;
  }

  /// Records a wrong PIN. Returns the lockout it starts, if any.
  Future<Duration?> failed() async {
    final failures =
        (int.tryParse(await _store.read(key: _kFailures) ?? "") ?? 0) + 1;
    await _store.write(key: _kFailures, value: "$failures");
    if (failures <= _free) return null;
    final lockout = switch (failures - _free) {
      1 => const Duration(seconds: 30),
      2 => const Duration(minutes: 1),
      3 => const Duration(minutes: 5),
      4 => const Duration(minutes: 10),
      5 => const Duration(minutes: 20),
      6 => const Duration(minutes: 30),
      _ => const Duration(hours: 1),
    };
    await _store.write(
      key: _kLockedUntil,
      value: "${DateTime.now().add(lockout).millisecondsSinceEpoch}",
    );
    return lockout;
  }

  /// The app was unlocked: wrong PINs before don't count any more.
  Future<void> succeeded() async {
    await _store.delete(key: _kFailures);
    await _store.delete(key: _kLockedUntil);
  }

  /// The message for a locked PIN entry, with [left] rounded up.
  static String lockedMessage(Duration left) {
    final seconds = (left.inMilliseconds / 1000).ceil();
    final minutes = (seconds / 60).ceil();
    final wait = seconds == 1
        ? "1 second"
        : seconds < 60
        ? "$seconds seconds"
        : minutes == 1
        ? "1 minute"
        : "$minutes minutes";
    return "Too many wrong PINs. Try again in $wait.";
  }
}
