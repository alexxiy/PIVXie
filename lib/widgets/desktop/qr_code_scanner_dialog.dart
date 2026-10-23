import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera_linux/camera_linux.dart';
import 'package:camera_macos/camera_macos_arguments.dart';
import 'package:camera_macos/camera_macos_device.dart';
import 'package:camera_macos/camera_macos_platform_interface.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:camera_windows/camera_windows.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

import '../../l10n/l10n.dart';
import '../../notifications/show_flush_bar.dart';
import '../../utilities/assets.dart';
import '../../utilities/logger.dart';
import '../../utilities/text_styles.dart';
import 'desktop_dialog.dart';
import 'desktop_dialog_close_button.dart';
import 'primary_button.dart';
import 'secondary_button.dart';

class QrCodeScannerDialog extends StatefulWidget {
  const QrCodeScannerDialog({super.key});

  @override
  State<QrCodeScannerDialog> createState() => _QrCodeScannerDialogState();
}

class _QrCodeScannerDialogState extends State<QrCodeScannerDialog> {
  // Made when the camera starts: loading the plugin library can fail.
  CameraLinux? _cameraLinuxPlugin;
  final CameraWindows? _cameraWindowsPlugin =
      Platform.isWindows ? CameraWindows() : null;
  bool _noCamera = false;
  Image? _image;
  bool _isScanning = false;
  int _cameraId = -1;
  String? _macOSDeviceId;
  final int _imageDelayInMs = Platform.isLinux ? 500 : 250;

  @override
  void initState() {
    super.initState();

    _initializeCamera().then((camOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && camOpen) {
          unawaited(_captureAndScanImage());
        } else if (mounted) {
          setState(() => _noCamera = true);
        }
      });
    });
  }

  /// The Linux plugin can't say there's no camera (it just never delivers
  /// a frame), so look for a video device first.
  static bool _linuxHasVideoDevice() {
    try {
      return Directory("/dev")
          .listSync(followLinks: false)
          .any((e) => RegExp(r"/video\d+$").hasMatch(e.path));
    } catch (_) {
      return true; // Can't tell; let the plugin try.
    }
  }

  Future<bool> _initializeCamera() async {
    try {
      if (Platform.isLinux) {
        if (!_linuxHasVideoDevice()) {
          throw CameraException('No cameras available', 'No video device.');
        }
        final camera = _cameraLinuxPlugin = CameraLinux();
        await camera.initializeCamera();
        Logging.instance.d("Linux Camera initialized");
      } else if (Platform.isWindows && _cameraWindowsPlugin != null) {
        final List<CameraDescription> cameras =
            await _cameraWindowsPlugin.availableCameras();
        if (cameras.isEmpty) {
          throw CameraException('No cameras available', 'No cameras found.');
        }
        final CameraDescription camera = cameras[0]; // Could be user-selected.
        _cameraId = await _cameraWindowsPlugin.createCameraWithSettings(
          camera,
          const MediaSettings(
            resolutionPreset: ResolutionPreset.low,
            fps: 4,
            videoBitrate: 200000,
            enableAudio: false,
          ),
        );
        await _cameraWindowsPlugin.initializeCamera(_cameraId);
        // await _cameraWindowsPlugin!.onCameraInitialized(_cameraId).first;
        // TODO [prio=low]: Make this work. ^^^
        Logging.instance.d(
          "Windows Camera initialized with ID: $_cameraId",
        );
      } else if (Platform.isMacOS) {
        final List<CameraMacOSDevice> videoDevices = await CameraMacOS.instance
            .listDevices(deviceType: CameraMacOSDeviceType.video);
        if (videoDevices.isEmpty) {
          throw Exception('No cameras available');
        }
        _macOSDeviceId = videoDevices.first.deviceId;
        await CameraMacOS.instance
            .initialize(cameraMacOSMode: CameraMacOSMode.photo);

        Logging.instance.d(
          "macOS Camera initialized with ID: $_macOSDeviceId",
        );
      }

      return true;
    } catch (e, s) {
      Logging.instance.e(
        "Failed to initialize camera",
        error: e,
        stackTrace: s,
      );
      return false;
    }
  }

  Future<void> _stopCamera() async {
    _isScanning = false;

    try {
      final linuxCamera = _cameraLinuxPlugin;
      if (linuxCamera != null) {
        linuxCamera.stopCamera();
        Logging.instance.d("Linux Camera stopped");
      } else if (Platform.isWindows && _cameraWindowsPlugin != null) {
        // if (_cameraId >= 0) {
        await _cameraWindowsPlugin.dispose(_cameraId);
        Logging.instance.d("Windows Camera stopped with ID: $_cameraId");
      } else if (Platform.isMacOS) {
        // if (_macOSDeviceId != null) {
        await CameraMacOS.instance.stopImageStream();
        Logging.instance.d("macOS Camera stopped with ID: $_macOSDeviceId");
      }
    } catch (e, s) {
      Logging.instance.e(
        "Failed to stop camera",
        error: e,
        stackTrace: s,
      );
    }
  }

  Future<void> _captureAndScanImage() async {
    _isScanning = true;
    while (_isScanning) {
      try {
        String? base64Image;
        final linuxCamera = _cameraLinuxPlugin;
        if (linuxCamera != null) {
          base64Image = await linuxCamera.captureImage();
        } else if (Platform.isWindows) {
          final XFile xfile =
              await _cameraWindowsPlugin!.takePicture(_cameraId);
          final bytes = await xfile.readAsBytes();
          base64Image = base64Encode(bytes);
          // We could use a Uint8List to optimize for Windows and macOS.
        } else if (Platform.isMacOS) {
          final macOSimg = await CameraMacOS.instance.takePicture();
          if (macOSimg == null) {
            Logging.instance.w("Failed to capture image");
            await Future<void>.delayed(Duration(milliseconds: _imageDelayInMs));
            continue;
          }
          final img.Image? image = img.decodeImage(macOSimg.bytes!);
          if (image == null) {
            Logging.instance.w("Failed to capture image");
            await Future<void>.delayed(Duration(milliseconds: _imageDelayInMs));
            continue;
          }
          base64Image = base64Encode(img.encodePng(image));
        }
        if (base64Image == null || base64Image.isEmpty) {
          await Future<void>.delayed(Duration(milliseconds: _imageDelayInMs));
          continue;
        }
        final img.Image? image = img.decodeImage(base64Decode(base64Image));
        // TODO [prio=low]: Optimize this process. Docs say:
        // > WARNING Since this will check the image data against all known
        // > decoders, it is much slower than using an explicit decoder
        if (image == null) {
          Logging.instance.w("Failed to decode image");
          await Future<void>.delayed(Duration(milliseconds: _imageDelayInMs));
          continue;
        }

        if (mounted) {
          setState(() {
            _image = Image.memory(
              base64Decode(base64Image!),
              fit: BoxFit.cover,
            );
          });
        }

        final String? scanResult = await _scanImage(image);
        if (scanResult != null && scanResult.isNotEmpty) {
          await _stopCamera();

          if (mounted) {
            Navigator.of(context).pop(scanResult);
          }
          break;
        }

        await Future<void>.delayed(Duration(milliseconds: _imageDelayInMs));
      } catch (_) {
        // Not logged: it would fill the log, frame after frame.
      }
    }
  }

  Future<String?> _scanImage(img.Image image) async {
    try {
      final LuminanceSource source = RGBLuminanceSource(
        image.width,
        image.height,
        image
            // 8 bits per channel whatever the source (1-bit palette PNGs
            // from QR generators, 16-bit PNGs): one int per pixel.
            .convert(format: img.Format.uint8, numChannels: 4)
            .getBytes(order: img.ChannelOrder.abgr)
            .buffer
            .asInt32List(),
      );
      final BinaryBitmap bitmap =
          BinaryBitmap(GlobalHistogramBinarizer(source));

      final QRCodeReader reader = QRCodeReader();
      final qrDecode = reader.decode(bitmap);
      if (qrDecode.text.isEmpty) {
        return null;
      }
      return qrDecode.text;
    } catch (_) {
      // No QR code in this frame (not logged: there are many).
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (_, __) {
        _stopCamera();
      },
      child: DesktopDialog(
        maxWidth: 696,
        maxHeight: 600,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 32),
                  child: Text(
                    l10n.qrScanTitle,
                    style: STextStyles.desktopH3(context),
                  ),
                ),
                const DesktopDialogCloseButton(),
              ],
            ),
            Expanded(
              child: _noCamera
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          l10n.qrScanNoCamera,
                          textAlign: TextAlign.center,
                          style: STextStyles.desktopTextMedium(context),
                        ),
                      ),
                    )
                  : _image ??
                      const Center(
                        child: CircularProgressIndicator(),
                      ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // "Select file" button.
                  Flexible(
                    flex: 200,
                    child: SecondaryButton(
                      buttonHeight: ButtonHeight.l,
                      label: l10n.qrScanSelectFile,
                      width: 200,
                      onPressed: () async {
                        final result = await FilePicker.pickFile(
                          type: FileType.custom,
                          allowedExtensions: ["png", "jpg", "jpeg"],
                        );

                        if (context.mounted) {
                          if (result == null || result.path == null) {
                            await showFloatingFlushBar(
                              type: FlushBarType.info,
                              message: l10n.qrScanNoFileSelected,
                              iconAsset: Assets.svg.file,
                              context: context,
                            );
                            return;
                          }

                          final filePath = result.path;
                          if (filePath == null) {
                            await showFloatingFlushBar(
                              type: FlushBarType.info,
                              message: l10n.qrScanFileError,
                              iconAsset: Assets.svg.file,
                              context: context,
                            );
                            return;
                          }

                          try {
                            final img.Image? image =
                                img.decodeImage(File(filePath).readAsBytesSync());
                            if (image == null) {
                              await showFloatingFlushBar(
                                type: FlushBarType.info,
                                message: l10n.qrScanDecodeFailed,
                                iconAsset: Assets.svg.file,
                                context: context,
                              );
                              return;
                            }

                            final String? scanResult = await _scanImage(image);
                            if (context.mounted) {
                              if (scanResult != null && scanResult.isNotEmpty) {
                                Navigator.of(context).pop(scanResult);
                              } else {
                                await showFloatingFlushBar(
                                  type: FlushBarType.info,
                                  message: l10n.qrScanNoCode,
                                  iconAsset: Assets.svg.file,
                                  context: context,
                                );
                              }
                            }
                          } catch (e, s) {
                            Logging.instance.e(
                              "Failed to decode image: ",
                              error: e,
                              stackTrace: s,
                            );
                            if (context.mounted) {
                              await showFloatingFlushBar(
                                type: FlushBarType.info,
                                message:
                                    l10n.qrScanProcessError,
                                iconAsset: Assets.svg.file,
                                context: context,
                              );
                            }
                          }
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Close button.
                  Flexible(
                    flex: 272,
                    child: PrimaryButton(
                      buttonHeight: ButtonHeight.l,
                      label: l10n.commonClose,
                      width: 272.5,
                      onPressed: () {
                        Navigator.of(context).pop();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
