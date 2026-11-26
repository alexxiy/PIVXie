import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/services/app_updates.dart';

void main() {
  const repo = "alexxiy/PIVXie";
  final sha = "ab" * 32;
  Map<String, dynamic> latest({int build = 20, Object? android}) => {
    "version": "1.4.0",
    "build": build,
    "android":
        android ??
        {
          for (final abi in ["arm64-v8a", "armeabi-v7a", "x86_64", "universal"])
            abi: {"file": "pivxie-1.4.0-android-$abi.apk", "sha256": sha},
        },
  };

  group("fromLatestJson", () {
    test("nothing when the installed build is as new", () {
      expect(
        AppUpdates.fromLatestJson(
          latest(),
          repo: repo,
          installedBuild: 20,
          android: true,
        ),
        isNull,
      );
      // arm64 split APK of build 20.
      expect(
        AppUpdates.fromLatestJson(
          latest(),
          repo: repo,
          installedBuild: 2020,
          android: true,
        ),
        isNull,
      );
    });

    test("the APK of the installed kind", () {
      for (final (installed, abi) in [
        (2019, "arm64-v8a"),
        (1019, "armeabi-v7a"),
        (4019, "x86_64"),
        (19, "universal"),
      ]) {
        final update = AppUpdates.fromLatestJson(
          latest(),
          repo: repo,
          installedBuild: installed,
          android: true,
        )!;
        expect(update.version, "1.4.0");
        expect(
          update.apk!.url.toString(),
          "https://github.com/$repo/releases/download/v1.4.0/"
          "pivxie-1.4.0-android-$abi.apk",
        );
        expect(update.apk!.sha256, sha);
      }
    });

    test("only the release page for desktop or a bad entry", () {
      final desktop = AppUpdates.fromLatestJson(
        latest(),
        repo: repo,
        installedBuild: 19,
        android: false,
      )!;
      expect(desktop.apk, isNull);
      expect(
        desktop.page.toString(),
        "https://github.com/$repo/releases/tag/v1.4.0",
      );
      for (final entry in [
        {"file": "../evil.apk", "sha256": sha},
        {"file": "a.apk", "sha256": "xyz"},
        {"file": "a.exe", "sha256": sha},
      ]) {
        final update = AppUpdates.fromLatestJson(
          latest(android: {"universal": entry}),
          repo: repo,
          installedBuild: 19,
          android: true,
        )!;
        expect(update.apk, isNull);
        expect(update.page, isNotNull);
      }
    });

    test("nothing for a malformed file", () {
      expect(
        AppUpdates.fromLatestJson(
          {"version": "1.4.0/../x", "build": 99},
          repo: repo,
          installedBuild: 19,
          android: false,
        ),
        isNull,
      );
      expect(
        AppUpdates.fromLatestJson(
          {"version": "1.4.0", "build": "99"},
          repo: repo,
          installedBuild: 19,
          android: false,
        ),
        isNull,
      );
    });
  });

  test("isNewer", () {
    expect(AppUpdates.isNewer("1.10.0", "1.9.2"), isTrue);
    expect(AppUpdates.isNewer("1.3.1", "1.3"), isTrue);
    expect(AppUpdates.isNewer("1.3", "1.3.0"), isFalse);
    expect(AppUpdates.isNewer("1.2.9", "1.3.0"), isFalse);
  });
}
