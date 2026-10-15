import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'camera_linux_bindings_generated.dart';

class CameraLinux {
  /// Throws when the native library can't be loaded.
  CameraLinux()
      : _bindings =
            CameraLinuxBindings(DynamicLibrary.open('libcamera_linux.so'));

  final CameraLinuxBindings _bindings;

  /// Opens the first camera that delivers frames, capturing in the
  /// background. Without one, [captureImage] just never returns a frame.
  Future<void> initializeCamera() async {
    _bindings.startVideoCaptureInThread();
  }

  /// Stops capturing and closes the camera.
  void stopCamera() {
    _bindings.stopVideoCapture();
  }

  /// The newest frame as base64 JPEG, or "" when none arrived since the
  /// last call.
  Future<String> captureImage() async {
    final length = calloc<Int>();
    Pointer<Uint8> frame = nullptr;
    try {
      frame = _bindings.getLatestFrameBytes(length);
      if (frame == nullptr || length.value <= 0) return "";
      return base64UrlEncode(frame.asTypedList(length.value));
    } finally {
      calloc.free(length);
      // The library allocates it with malloc.
      if (frame != nullptr) calloc.free(frame);
    }
  }
}
