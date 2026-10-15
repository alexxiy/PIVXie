# camera_linux (PIVXie copy)

Camera capture for PIVXie's desktop QR scanner on Linux, through Dart FFI.
Based on [camera_linux](https://github.com/islamroshan/camera-linux) by
Muhammad Islam (BSD 3-Clause, see `LICENSE`), as used by Stack Wallet
(`cypherstack/camera-linux` at `ecb4124`).

## What changed

- One native library, `libcamera_linux.so`. Upstream built a second one
  (`libopencv_wrapper.so`) that Flutter never copied into the app bundle,
  so the plugin only loaded on the machine that built it.
- OpenCV is linked in statically when the app provides a static build
  (`CAMERA_LINUX_OPENCV_DIR`, set by PIVXie's Linux CMake file from
  `scripts/linux/build_opencv.sh`): just the core, imgproc, imgcodecs and
  videoio modules, V4L2 capture and JPEG only. Its symbols stay private.
  Without it the system OpenCV is linked, and users need it installed.
- Uses the first camera that delivers frames, not only `/dev/video0`.
- The frame handed out is at most 200 ms old (upstream read one frame every
  500 ms from the camera's queue, so it lagged by seconds).
- Nothing waits for the camera on Flutter's UI thread. Upstream's stop
  joined the capture thread, so a camera stuck in its driver froze the app.
  Now the thread closes the camera on its own once its read returns.
- Fixes: frames are allocated with `malloc` to match the Dart side's
  `free`; starting twice no longer aborts; no exception escapes into Dart;
  no stale frame from an earlier session; no `system("pause")`.

## API

```dart
final camera = CameraLinux(); // throws if the library can't be loaded
await camera.initializeCamera();
final jpegBase64 = await camera.captureImage(); // "" until a new frame
camera.stopCamera();
```

The bindings in `lib/camera_linux_bindings_generated.dart` come from
`src/camera_linux.h` (`dart run ffigen --config ffigen.yaml`, with `ffigen`
added as a dev dependency).
