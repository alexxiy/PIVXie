# Building PIVXie

These steps build the Android app on a Linux host. iOS needs a macOS host (see [iOS](#ios)). Desktop targets are still in the project but untested (see [Desktop](#desktop)).

## Requirements

- A Linux host. PIVXie is built on Fedora 44; Ubuntu 24.04 works too.
- About 40 GB of free disk space (Flutter, the Android SDK, Gradle and Rust caches, and the build output).
- [Flutter](https://docs.flutter.dev/install/manual) 3.47.7 or newer (Dart 3.13). Run `flutter doctor` to check the install.
- JDK 17.
- The Android SDK with the command-line tools, platform 37 (Android 17) and NDK 28.0.13004108. You can install them with Android Studio's SDK Manager or with `sdkmanager`:
  ```bash
  sdkmanager "platforms;android-37.0" "build-tools;36.0.0" "ndk;28.0.13004108" "cmake;3.22.1"
  ```
- [Rust](https://rustup.rs) (stable) with the Android targets. The SHIELD library (`crypto_plugins/flutter_libpivxshield`) is Rust and is compiled during `flutter build`:
  ```bash
  rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
  ```
- Docker or Podman, only for building `libsecp256k1` for the host tests.

Set the environment, for example in `~/.bashrc`:
```bash
export JAVA_HOME=/path/to/jdk17
export ANDROID_HOME=/path/to/android-sdk
export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/28.0.13004108
export PATH=/path/to/flutter/bin:$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$HOME/.cargo/bin:$PATH
```

## Get the code

The app lives on the `pivxie` branch:
```bash
git clone --branch pivxie <PIVXie repository URL> PIVXie
cd PIVXie
```

## Configure

The project is a white-label Stack Wallet tree. `scripts/build_app.sh` turns it into PIVXie: it writes `pubspec.yaml` from `scripts/app_config/templates/pubspec.template.yaml`, generates `lib/app_config.g.dart` and the PIVX plugin interfaces, creates the platform files (Android manifest, Gradle files, iOS `Info.plist`, and so on) from `scripts/app_config/templates/`, and generates the icons and splash screen.

```bash
cd scripts
./build_app.sh -a pivxie -p android -v 1.0.0 -b 1 -i
cd ..
```

- `-a pivxie`: the app (the only one in this tree).
- `-p`: the platform: `android`, `ios`, `linux`, `macos` or `windows`.
- `-v` and `-b`: the version name and the build number. The script asks you to confirm them: never ship a lower build number than an installed version.
- `-i`: skip the native plugin scripts. Android needs none: the shield library is built by Flutter.

Run the configure step again after you change a template, `configure_pivxie.sh` or the version. The generated platform files are not tracked in git.

The app ID is `org.pivx.pivxie`. The app name, links and supported networks are in `scripts/app_config/configure_pivxie.sh`.

## Build the APK

```bash
flutter pub get
flutter build apk --release --target-platform android-arm64
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`.

Release builds are mainnet only. To include the PIVX testnet (and regtest), add `--dart-define=PIVX_TESTNET=true`. Debug builds always include it.

### Signing

Release builds are signed with the keystore described in `android/key.properties` (ignored by git):
```properties
storeFile=/path/to/release-keystore.jks
storePassword=...
keyAlias=...
keyPassword=...
```

Keep the release keystore out of the repository. For test builds you can point `key.properties` at a development keystore, but never publish an APK signed with it.

### Run on a device

```bash
flutter run --dart-define=PIVX_TESTNET=true
```

The Android emulator works only with x86_64 images. A real phone is better for checking the UI and the shield sync speed. Debug builds are much slower at shield work than release builds.

## Server

PIVXie gets chain data from a [pivx-bridge](https://github.com/PIVX-Labs/pivx-bridge) server. The bridge must run with `ADDR_INDEX=true` for transaction history. You can add your own server in the app under the PIVX node settings, and set the default one in `lib/wallets/crypto_currency/coins/pivx.dart` (`defaultNode`).

## Tests

The host tests need `libsecp256k1` in `build/`:
```bash
dart run coinlib:build_linux
```

If `lib/app_config.g.dart` is missing (for example after `build_runner` deleted it), `scripts/ensure_test_app_config.sh` writes the PIVXie config again.

General tests:
```bash
flutter test --concurrency=4 $(find test -name "*_test.dart" ! -path "test/pivx/*")
```

PIVX tests:
```bash
flutter test --concurrency=1 test/pivx/
```

Without extra settings, the regtest tests in `test/pivx/` are skipped. They need a PIVX Core regtest node and a pivx-bridge connected to it. They share one chain and mine blocks, so always run them with `--concurrency=1`. Set:

| Variable | Value |
| --- | --- |
| `PIVX_BRIDGE` | The bridge URL, for example `http://127.0.0.1:3000` |
| `PIVX_CLI` | The `pivx-cli` command for the regtest node, for example `pivx-cli -datadir=/srv/pivx-regtest` |
| `PIVX_SHIELD_LIB` | The host build of the shield library: `cargo build --release` in `crypto_plugins/flutter_libpivxshield/rust`, then `target/release/libpivx_shield_ffi.so` |
| `PIVX_PARAMS_DIR` | The folder with the Sapling parameters (`sapling-output.params`, `sapling-spend.params`) |
| `PIVX_MN_KEY`, `PIVX_MN_SERVICE` | For the masternode start test: the key and `ip:port` of a regtest masternode server that is running |

## iOS

On a macOS host with Xcode, CocoaPods, Flutter and Rust (with the `aarch64-apple-ios` target):
```bash
cd scripts
./build_app.sh -a pivxie -p ios -v 1.0.0 -b 1 -i
cd ..
flutter pub get
flutter build ios --release
```

## Desktop

The Linux, Windows and macOS targets come from Stack Wallet and still configure with `build_app.sh -p linux|windows|macos` (without `-i`, the script also builds the desktop native libraries). They are untested, and the shield library is only built for Android and iOS, so SHIELD is not available there.

Packaging files are in `flatpak/` (`org.pivx.pivxie`) and `appimage/pivxie/`. Both expect the Linux release bundle (`build/linux/x64/release/bundle`).

## Troubleshooting

- Run Flutter with `-v` for more detail when a build fails.
- `dart run build_runner build` deletes `lib/app_config.g.dart`. Run `scripts/ensure_test_app_config.sh` or the configure step afterwards.
