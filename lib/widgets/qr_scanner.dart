import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../themes/stack_colors.dart';
import '../utilities/text_styles.dart';
import 'background.dart';
import 'custom_buttons/app_bar_icon_button.dart';

/// Full screen QR scanner. Pops with the scanned text.
///
/// Uses the platform detectors (ML Kit on Android, Vision on iOS), which
/// read codes at an angle or from a screen as quickly as the camera app.
class QrScanner extends StatefulWidget {
  const QrScanner({super.key});

  @override
  State<QrScanner> createState() => _QrScannerState();
}

class _QrScannerState extends State<QrScanner> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );

  bool _done = false;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final code = capture.barcodes
        .map((e) => e.rawValue)
        .nonNulls
        .where((e) => e.isNotEmpty)
        .firstOrNull;
    if (code == null) return;
    _done = true;
    Navigator.of(context).pop(code);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          backgroundColor: colors.backgroundAppBar,
          leading: const AppBarBackButton(),
          title: Text("Scan QR code", style: STextStyles.navBarTitle(context)),
          actions: [
            ValueListenableBuilder<MobileScannerState>(
              valueListenable: _controller,
              builder: (context, state, _) {
                if (state.torchState == TorchState.unavailable) {
                  return const SizedBox.shrink();
                }
                return IconButton(
                  tooltip: "Flashlight",
                  icon: Icon(
                    state.torchState == TorchState.on
                        ? Icons.flashlight_off
                        : Icons.flashlight_on,
                    color: colors.topNavIconPrimary,
                  ),
                  onPressed: _controller.toggleTorch,
                );
              },
            ),
          ],
        ),
        body: MobileScanner(controller: _controller, onDetect: _onDetect),
      ),
    );
  }
}
