import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:mobile_app_privacy/mobile_app_privacy.dart';

import '../utilities/prefs.dart';

/// Blocks screenshots and screen recording (Android's FLAG_SECURE) while
/// [child] shows a secret, such as a recovery phrase or a private key,
/// whatever the "Disable screenshots" setting says. The setting applies
/// again once no such screen is open.
class SecretScreen extends StatefulWidget {
  const SecretScreen({super.key, required this.child});

  final Widget child;

  @override
  State<SecretScreen> createState() => _SecretScreenState();
}

class _SecretScreenState extends State<SecretScreen> {
  /// Secret screens open now (one can open over another).
  static int _open = 0;

  static final _privacy = Platform.isAndroid ? MobileAppPrivacy() : null;

  @override
  void initState() {
    super.initState();
    if (_open++ == 0) unawaited(_privacy?.setFlagSecure(true));
  }

  @override
  void dispose() {
    if (--_open == 0) {
      unawaited(_privacy?.setFlagSecure(Prefs.instance.disableScreenShots));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
