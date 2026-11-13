import 'dart:io';

/// The Mac App Store build is made with --dart-define=APP_STORE=true; the
/// macOS build on GitHub is not.
const _macAppStore = bool.fromEnvironment("APP_STORE");

/// Whether this build goes to Apple's App Store: every iOS build, and the
/// Mac App Store build. These leave out what App Review hasn't seen yet
/// (the DeFi Bridge) and tips to the developer, which the App Store wants
/// to go through in-app purchase.
bool get isAppStoreBuild =>
    Platform.isIOS || (Platform.isMacOS && _macAppStore);
