import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mutex/mutex.dart';

import '../../notifications/show_flush_bar.dart';
import '../../providers/global/duress_provider.dart';
import '../../providers/global/prefs_provider.dart';
import '../../providers/global/secure_store_provider.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/assets.dart';
import '../../utilities/biometrics.dart';
import '../../utilities/flutter_secure_storage_interface.dart';
import '../../utilities/pin_attempts.dart';
import '../../utilities/text_styles.dart';
import '../../widgets/custom_pin_put/custom_pin_put.dart';
import '../../widgets/shake/shake.dart';
import '../../widgets/stack_dialog.dart';
import 'lock_screen_view.dart';

class PinpadDialog extends ConsumerStatefulWidget {
  const PinpadDialog({
    super.key,
    required this.biometricsAuthenticationTitle,
    required this.biometricsLocalizedReason,
    required this.biometricsCancelButtonString,
    this.biometrics = const Biometrics(),
    this.customKeyLabel = "Button",
  });

  final String biometricsAuthenticationTitle;
  final String biometricsLocalizedReason;
  final String biometricsCancelButtonString;
  final Biometrics biometrics;
  final String customKeyLabel;

  @override
  ConsumerState<PinpadDialog> createState() => _PinpadDialogState();
}

class _PinpadDialogState extends ConsumerState<PinpadDialog> {
  late final ShakeController _shakeController;

  late final bool _autoPin;

  late final PinAttempts _pinAttempts;

  final FocusNode _pinFocusNode = FocusNode();

  late SecureStorageInterface _secureStore;
  late Biometrics biometrics;
  int pinCount = 1;

  final _pinTextController = TextEditingController();

  BoxDecoration get _pinPutDecoration {
    return BoxDecoration(
      color: Theme.of(context).extension<StackColors>()!.infoItemIcons,
      border: Border.all(
        width: 1,
        color: Theme.of(context).extension<StackColors>()!.infoItemIcons,
      ),
      borderRadius: BorderRadius.circular(6),
    );
  }

  Future<String?> _storedPin() =>
      _secureStore.read(key: ref.read(pDuress) ? kDuressPinKey : kPinKey);

  final Mutex _autoPinCheckLock = Mutex();

  /// Auto PIN: unlock as soon as the PIN is right. A PIN as long as the
  /// stored one that isn't right counts as a wrong PIN, as if submitted.
  void _onPinChangedAutologinCheck() async {
    if (mounted) {
      await _autoPinCheckLock.acquire();
    }

    try {
      final pin = _pinTextController.text;
      if (_autoPin && pin.length >= 4) {
        final storedPin = await _storedPin();
        if (await _pinAttempts.lockedFor() == null && pin == storedPin) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          unawaited(_onUnlock());
        } else if (pin.length >= (storedPin?.length ?? 4)) {
          await _onSubmit(pin);
        }
      }
    } finally {
      _autoPinCheckLock.release();
    }
  }

  Future<void> _onUnlock() async {
    await _pinAttempts.succeeded();
    final now = DateTime.now().toUtc();
    ref.read(prefsChangeNotifierProvider).lastUnlocked =
        now.millisecondsSinceEpoch ~/ 1000;

    Navigator.of(context).pop("verified success");
  }

  Future<void> _checkUseBiometrics() async {
    if (!ref.read(prefsChangeNotifierProvider).isInitialized) {
      await ref.read(prefsChangeNotifierProvider).init();
    }

    final bool useBiometrics = ref
        .read(prefsChangeNotifierProvider)
        .useBiometrics;

    final title = widget.biometricsAuthenticationTitle;
    final localizedReason = widget.biometricsLocalizedReason;
    final cancelButtonText = widget.biometricsCancelButtonString;

    if (useBiometrics) {
      if (await biometrics.authenticate(
        title: title,
        localizedReason: localizedReason,
        cancelButtonText: cancelButtonText,
      )) {
        unawaited(_onUnlock());
      }
    }
  }

  Future<void> _onSubmit(String pin) async {
    final locked = await _pinAttempts.lockedFor();
    if (locked != null) {
      if (mounted) {
        unawaited(
          showFloatingFlushBar(
            type: FlushBarType.warning,
            message: PinAttempts.lockedMessage(locked),
            context: context,
            iconAsset: Assets.svg.alertCircle,
          ),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      _pinTextController.text = '';
      return;
    }

    if (pin == await _storedPin()) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (mounted) unawaited(_onUnlock());
    } else {
      final lockout = await _pinAttempts.failed();
      if (!mounted) return;
      unawaited(_shakeController.shake());
      unawaited(
        showFloatingFlushBar(
          type: FlushBarType.warning,
          message: lockout != null
              ? PinAttempts.lockedMessage(lockout)
              : "Wrong PIN. Try again.",
          context: context,
          iconAsset: Assets.svg.alertCircle,
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));

      _pinTextController.text = '';
    }
  }

  @override
  void initState() {
    _shakeController = ShakeController();

    _secureStore = ref.read(secureStoreProvider);
    biometrics = widget.biometrics;
    _pinAttempts = PinAttempts(_secureStore);
    _autoPin = ref.read(prefsChangeNotifierProvider).autoPin;
    if (_autoPin) {
      _pinTextController.addListener(_onPinChangedAutologinCheck);
    }

    _checkUseBiometrics();
    super.initState();
  }

  @override
  dispose() {
    _pinTextController.removeListener(_onPinChangedAutologinCheck);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StackDialogBase(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Shake(
            animationDuration: const Duration(milliseconds: 700),
            animationRange: 12,
            controller: _shakeController,
            child: Center(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Text(
                      "Enter PIN",
                      style: STextStyles.pageTitleH1(context),
                    ),
                  ),
                  const SizedBox(height: 40),
                  CustomPinPut(
                    fieldsCount: pinCount,
                    eachFieldHeight: 12,
                    eachFieldWidth: 12,
                    textStyle: STextStyles.label(context).copyWith(fontSize: 1),
                    focusNode: _pinFocusNode,
                    controller: _pinTextController,
                    useNativeKeyboard: false,
                    obscureText: "",
                    inputDecoration: InputDecoration(
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      fillColor: Theme.of(context)
                          .extension<StackColors>()!
                          .popupBG,
                      counterText: "",
                    ),
                    submittedFieldDecoration: _pinPutDecoration,
                    isRandom: ref
                        .read(prefsChangeNotifierProvider)
                        .randomizePIN,
                    onSubmit: (pin) {
                      if (!_autoPinCheckLock.isLocked) {
                        unawaited(_onSubmit(pin));
                      }
                    },
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
