import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:socks5_proxy/socks_client.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_config.dart';
import '../db/hive/db.dart';
import '../l10n/l10n.dart';
import '../networking/http.dart';
import '../themes/stack_colors.dart';
import '../utilities/logger.dart';
import '../utilities/prefs.dart';
import '../utilities/app_store_build.dart';
import '../utilities/text_styles.dart';
import '../utilities/util.dart';
import '../widgets/conditional_parent.dart';
import '../widgets/desktop/desktop_dialog.dart';
import '../widgets/desktop/primary_button.dart';
import '../widgets/desktop/secondary_button.dart';
import '../widgets/stack_dialog.dart';
import 'network_privacy.dart';

/// Where this build is published: Apple's App Store builds are known by
/// [isAppStoreBuild], others by `--dart-define=PIVXIE_DIST=github` or
/// `play`. It decides where updates are looked for and whether store
/// reviews are asked for.
enum AppDistribution {
  /// GitHub releases: Android APKs update themselves; desktop builds
  /// point to the release page.
  github,

  /// Google Play.
  play,

  /// Apple's App Store, on iPhone, iPad and Mac.
  appStore,

  /// Anything else (test builds, Flathub): no checks, no asks.
  none;

  static const _name = String.fromEnvironment("PIVXIE_DIST");

  static AppDistribution get current => isAppStoreBuild
      ? appStore
      : switch (_name) {
          "github" => github,
          "play" when Platform.isAndroid => play,
          _ => none,
        };
}

/// The app's own native calls for updates and reviews (MainActivity on
/// Android, the app delegate on Apple systems).
const _store = MethodChannel("PIVXIE_STORE");

/// A newer version than the one running.
class AppUpdate {
  const AppUpdate({this.version, this.page, this.apk});

  /// Its version name; null where the store doesn't say (Google Play).
  final String? version;

  /// Its release or store page.
  final Uri? page;

  /// GitHub builds on Android: the APK of the same kind as the one
  /// installed, and its SHA-256 from the release.
  final ({Uri url, String sha256})? apk;
}

/// Looks for a newer version where the app came from, at most once a day,
/// and offers it. Everything goes through Tor or Nym when one is on.
abstract final class AppUpdates {
  static const _lastCheckKey = "updateLastCheck";
  static const _laterKey = "updateLater";

  /// Whether this build looks for updates at all.
  static bool get available => AppDistribution.current != AppDistribution.none;

  static bool _running = false;

  /// GitHub, or a local server standing in for it in update tests
  /// (`--dart-define=PIVXIE_UPDATE_BASE=http://...`; never in releases).
  static const _base = String.fromEnvironment(
    "PIVXIE_UPDATE_BASE",
    defaultValue: "https://github.com",
  );

  /// At start: at most once a day, a while after the app is up.
  static Future<void> onStart(BuildContext context) async {
    await StoreReview._noteFirstUse();
    if (!available || !Prefs.instance.checkUpdates || _running) return;
    // The APK of an update that is now installed (or was given up).
    await _removeOldDownload();
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = await _get<int>(_lastCheckKey) ?? 0;
    if (now - last < const Duration(hours: 20).inMilliseconds) {
      return;
    }
    _running = true;
    try {
      // Let the start settle (and Tor or Nym connect) first.
      await Future<void>.delayed(const Duration(seconds: 8));
      final update = await find();
      await _put(_lastCheckKey, now);
      if (update == null || !context.mounted) return;
      // "Later" keeps that version quiet for a few days.
      final later = await _get<String>(_laterKey);
      final key = update.version ?? "?";
      if (later != null) {
        final parts = later.split("|");
        final at = int.tryParse(parts.last) ?? 0;
        if (parts.first == key &&
            now - at < const Duration(days: 3).inMilliseconds) {
          return;
        }
      }
      if (!context.mounted) return;
      if (!await offer(context, update)) await _put(_laterKey, "$key|$now");
    } catch (e, s) {
      // Not connected yet, no release file, ...: tried again next start.
      Logging.instance.w("Update check failed", error: e, stackTrace: s);
    } finally {
      _running = false;
    }
  }

  /// The newer version, or null when this one is the latest.
  static Future<AppUpdate?> find() async {
    final info = await PackageInfo.fromPlatform();
    return switch (AppDistribution.current) {
      AppDistribution.github => _fromGitHub(info),
      AppDistribution.play => _fromPlay(),
      AppDistribution.appStore => _fromAppStore(info),
      AppDistribution.none => null,
    };
  }

  /// latest.json, attached to every GitHub release.
  static Future<AppUpdate?> _fromGitHub(PackageInfo info) async {
    final repo = AppConfig.gitHubRepo;
    final response = await const HTTP().get(
      url: Uri.parse("$_base/$repo/releases/latest/download/latest.json"),
      proxyInfo: NetworkPrivacy.proxyInfo(),
      connectionTimeout: const Duration(seconds: 30),
    );
    if (response.code != 200) return null;
    return fromLatestJson(
      jsonDecode(response.body) as Map<String, dynamic>,
      repo: repo,
      installedBuild: int.tryParse(info.buildNumber) ?? 0,
      android: Platform.isAndroid,
    );
  }

  /// The update latest.json offers, or null when [installedBuild] is as
  /// new.
  @visibleForTesting
  static AppUpdate? fromLatestJson(
    Map<String, dynamic> json, {
    required String repo,
    required int installedBuild,
    required bool android,
  }) {
    final version = json["version"];
    final build = json["build"];
    if (version is! String ||
        build is! int ||
        !RegExp(r"^\d+(\.\d+){1,3}$").hasMatch(version)) {
      return null;
    }
    // Split APKs number their builds abi * 1000 + build; the universal
    // APK and the other systems use the build alone.
    if (build <= installedBuild % 1000) return null;
    final page = Uri.parse("$_base/$repo/releases/tag/v$version");
    if (!android) return AppUpdate(version: version, page: page);

    // The same kind of APK as the one installed, so later updates (from
    // here or from a store) still go over it.
    final abi = switch (installedBuild ~/ 1000) {
      1 => "armeabi-v7a",
      2 => "arm64-v8a",
      4 => "x86_64",
      _ => "universal",
    };
    final apks = json["android"];
    final entry = apks is Map<String, dynamic> ? apks[abi] : null;
    final file = entry is Map<String, dynamic> ? entry["file"] : null;
    final sha256 = entry is Map<String, dynamic> ? entry["sha256"] : null;
    if (file is! String ||
        sha256 is! String ||
        !RegExp(r"^[\w.\-]+\.apk$").hasMatch(file) ||
        !RegExp(r"^[0-9a-f]{64}$").hasMatch(sha256)) {
      return AppUpdate(version: version, page: page);
    }
    return AppUpdate(
      version: version,
      page: page,
      apk: (
        url: Uri.parse("$_base/$repo/releases/download/v$version/$file"),
        sha256: sha256,
      ),
    );
  }

  /// Google Play's own answer (its in-app updates).
  static Future<AppUpdate?> _fromPlay() async {
    final result = await _store.invokeMapMethod<String, dynamic>(
      "playUpdateInfo",
    );
    return result?["available"] == true ? const AppUpdate() : null;
  }

  /// Apple's lookup of the app's App Store entry.
  static Future<AppUpdate?> _fromAppStore(PackageInfo info) async {
    final response = await const HTTP().get(
      url: Uri.https("itunes.apple.com", "/lookup", {
        "bundleId": info.packageName,
      }),
      proxyInfo: NetworkPrivacy.proxyInfo(),
      connectionTimeout: const Duration(seconds: 30),
    );
    if (response.code != 200) return null;
    final results =
        (jsonDecode(response.body) as Map<String, dynamic>)["results"]
            as List<dynamic>?;
    // This system's entry: a Mac may not have an iPhone version yet.
    final kind = Platform.isMacOS ? "mac-software" : "software";
    final app = results
        ?.whereType<Map<String, dynamic>>()
        .where((e) => e["kind"] == kind)
        .firstOrNull;
    if (app == null) return null;
    final version = app["version"] as String?;
    final page = Uri.tryParse(app["trackViewUrl"] as String? ?? "");
    if (version == null ||
        page == null ||
        page.scheme != "https" ||
        !page.host.endsWith("apple.com") ||
        !isNewer(version, info.version)) {
      return null;
    }
    return AppUpdate(version: version, page: page);
  }

  /// Whether version name [a] is later than [b] ("1.10.0" > "1.9.2").
  @visibleForTesting
  static bool isNewer(String a, String b) {
    List<int> parts(String v) =>
        v.split(".").map((e) => int.tryParse(e) ?? 0).toList();
    final x = parts(a), y = parts(b);
    for (var i = 0; i < x.length || i < y.length; i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d > 0;
    }
    return false;
  }

  /// Asks whether to update now and does it. False for "Later".
  static Future<bool> offer(BuildContext context, AppUpdate update) async {
    final app = AppConfig.appName;
    final now = await showChoice<bool>(
      context,
      title: l10n.updateTitle,
      text: update.version == null
          ? l10n.updateTextNoVersion(app)
          : l10n.updateText(app, update.version!),
      choices: [(l10n.commonLater, false), (l10n.updateNow, true)],
    );
    if (now != true || !context.mounted) return false;
    final apk = update.apk;
    if (AppDistribution.current == AppDistribution.play) {
      // Google Play shows its own update screen.
      await _store.invokeMethod<bool>("playStartUpdate");
    } else if (apk != null) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ApkUpdateDialog(apk: apk, page: update.page),
      );
    } else if (update.page != null) {
      await launchUrl(update.page!, mode: LaunchMode.externalApplication);
    }
    return true;
  }

  static Future<File> _apkFile() async =>
      File("${(await getTemporaryDirectory()).path}/app-update.apk");

  /// An update downloaded earlier is installed (or given up) by now.
  static Future<void> _removeOldDownload() async {
    if (!Platform.isAndroid) return;
    try {
      final file = await _apkFile();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

/// Far more than any app APK.
const _maxApkBytes = 400 * 1024 * 1024;

class _ApkCorrupt implements Exception {}

/// Downloads the APK (through Tor or Nym when one is on), checks its
/// SHA-256 against the release, and hands it to Android's installer,
/// which also checks it is signed like the installed app.
class _ApkUpdateDialog extends StatefulWidget {
  const _ApkUpdateDialog({required this.apk, this.page});

  final ({Uri url, String sha256}) apk;

  /// The release page, offered when this doesn't work out.
  final Uri? page;

  @override
  State<_ApkUpdateDialog> createState() => _ApkUpdateDialogState();
}

enum _Stage { downloading, installing, needsPermission, failed }

class _ApkUpdateDialogState extends State<_ApkUpdateDialog> {
  HttpClient? _client;
  File? _file;
  double? _progress;
  _Stage _stage = _Stage.downloading;
  String _error = "";

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    _client?.close(force: true);
    super.dispose();
  }

  Future<void> _run() async {
    try {
      _file = await _download();
      await _install();
    } catch (e, s) {
      if (!mounted) return;
      Logging.instance.w("App update failed", error: e, stackTrace: s);
      setState(() {
        _stage = _Stage.failed;
        _error = switch (e) {
          _ApkCorrupt() => l10n.updateNotMatching,
          PlatformException() => l10n.updateInstallFailed,
          _ => l10n.updateDownloadFailed,
        };
      });
    }
  }

  Future<File> _download() async {
    final proxy = NetworkPrivacy.proxyInfo();
    final client = _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 60);
    if (proxy != null) {
      SocksTCPClient.assignToHttpClient(client, [
        ProxySettings(proxy.host, proxy.port),
      ]);
    }
    final file = await AppUpdates._apkFile();
    try {
      final response = await (await client.getUrl(widget.apk.url)).close();
      if (response.statusCode != 200) {
        throw HttpException("HTTP ${response.statusCode}");
      }
      final total = response.contentLength;
      final digest = _DigestSink();
      final hasher = sha256.startChunkedConversion(digest);
      final out = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          received += chunk.length;
          if (received > _maxApkBytes) {
            throw const HttpException("The file is too large");
          }
          hasher.add(chunk);
          out.add(chunk);
          if (mounted && total > 0) {
            setState(() => _progress = received / total);
          }
        }
      } finally {
        await out.close();
      }
      hasher.close();
      if (digest.value.toString() != widget.apk.sha256) throw _ApkCorrupt();
      return file;
    } catch (_) {
      if (await file.exists()) await file.delete();
      rethrow;
    } finally {
      client.close(force: true);
      _client = null;
    }
  }

  Future<void> _install() async {
    setState(() => _stage = _Stage.installing);
    // Android asks to confirm, and the app restarts updated.
    final result = await _store.invokeMethod<String>("installApk", {
      "path": _file!.path,
    });
    if (!mounted) return;
    switch (result) {
      case "permission":
        // Android opened its "install unknown apps" setting for the app.
        setState(() => _stage = _Stage.needsPermission);
      case "failed":
        setState(() {
          _stage = _Stage.failed;
          _error = l10n.updateInstallFailed;
        });
      default:
        Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final text = switch (_stage) {
      _Stage.downloading =>
        _progress == null ? null : "${(_progress! * 100).floor()} %",
      _Stage.installing => l10n.updateConfirmInstall,
      _Stage.needsPermission => l10n.updateAllowInstall(AppConfig.appName),
      _Stage.failed => _error,
    };
    return _DialogFrame(
      title: switch (_stage) {
        _Stage.downloading => l10n.updateDownloading,
        _Stage.installing => l10n.updateInstalling,
        _ => l10n.updateTitle,
      },
      body: [
        if (_stage == _Stage.downloading || _stage == _Stage.installing) ...[
          LinearProgressIndicator(
            value: _stage == _Stage.installing ? null : _progress,
            color: colors.accentColorGreen,
            backgroundColor: colors.textFieldDefaultBG,
          ),
          const SizedBox(height: 12),
        ],
        if (text != null) Text(text, style: STextStyles.smallMed14(context)),
      ],
      buttons: [
        SecondaryButton(
          label: _stage == _Stage.failed ? l10n.commonClose : l10n.commonCancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        if (_stage == _Stage.failed && widget.page != null)
          PrimaryButton(
            label: l10n.updateOpenPage,
            onPressed: () {
              Navigator.of(context).pop();
              unawaited(
                launchUrl(widget.page!, mode: LaunchMode.externalApplication),
              );
            },
          ),
        if (_stage == _Stage.needsPermission)
          PrimaryButton(
            label: l10n.updateInstall,
            onPressed: () => unawaited(_install()),
          ),
      ],
    );
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Store builds ask for a rating now and then: after two weeks of use, at
/// a send that went through. "Later" asks again in two months; "Rate"
/// or "Don't ask again" end it, and it stops after three asks. (Stores
/// don't tell apps whether a review was left.)
abstract final class StoreReview {
  static const _firstUseKey = "reviewFirstUse";
  static const _asksKey = "reviewAsks";
  static const _lastAskKey = "reviewLastAsk";
  static const _doneKey = "reviewDone";

  static bool get available => switch (AppDistribution.current) {
    AppDistribution.play || AppDistribution.appStore => true,
    _ => false,
  };

  static Future<void> _noteFirstUse() async {
    if (!available || await _get<int>(_firstUseKey) != null) return;
    await _put(_firstUseKey, DateTime.now().millisecondsSinceEpoch);
  }

  /// After a send went through. [context] must outlive the send screens
  /// (the navigator's).
  static Future<void> afterSend(BuildContext context) async {
    if (!available || await _get<bool>(_doneKey) == true) return;
    final asks = await _get<int>(_asksKey) ?? 0;
    final first = await _get<int>(_firstUseKey);
    final last = await _get<int>(_lastAskKey);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (asks >= 3 ||
        first == null ||
        now - first < const Duration(days: 14).inMilliseconds ||
        (last != null &&
            now - last < const Duration(days: 60).inMilliseconds)) {
      return;
    }
    // Once the wallet is back on screen.
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!context.mounted) return;
    await _put(_asksKey, asks + 1);
    await _put(_lastAskKey, now);
    if (!context.mounted) return;
    final app = AppConfig.appName;
    final choice = await showChoice<String>(
      context,
      title: l10n.reviewTitle(app),
      text: l10n.reviewText(app),
      choices: [
        (l10n.reviewNever, "never"),
        (l10n.commonLater, "later"),
        (l10n.reviewRate, "rate"),
      ],
    );
    if (choice == "never" || choice == "rate") await _put(_doneKey, true);
    if (choice == "rate") {
      try {
        await _store.invokeMethod<bool>(
          Platform.isAndroid ? "playReview" : "requestReview",
        );
      } catch (e, s) {
        Logging.instance.w("Store review failed", error: e, stackTrace: s);
      }
    }
  }
}

Future<T?> _get<T>(String key) async =>
    await DB.instance.get<dynamic>(boxName: DB.boxNamePrefs, key: key) as T?;

Future<void> _put(String key, Object value) =>
    DB.instance.put<dynamic>(boxName: DB.boxNamePrefs, key: key, value: value);

/// A question with a few answers as buttons, the last one the main one.
/// Null when dismissed.
Future<T?> showChoice<T>(
  BuildContext context, {
  required String title,
  required String text,
  required List<(String, T)> choices,
}) => showDialog<T>(
  context: context,
  builder: (context) => _DialogFrame(
    title: title,
    body: [Text(text, style: STextStyles.smallMed14(context))],
    buttons: [
      for (final (i, (label, value)) in choices.indexed)
        i == choices.length - 1
            ? PrimaryButton(
                label: label,
                onPressed: () => Navigator.of(context).pop(value),
              )
            : SecondaryButton(
                label: label,
                onPressed: () => Navigator.of(context).pop(value),
              ),
    ],
  ),
);

/// A dialog with a title, some content and buttons: two side by side,
/// three or more under each other (the main one first), so long
/// translations fit.
class _DialogFrame extends StatelessWidget {
  const _DialogFrame({
    required this.title,
    required this.body,
    required this.buttons,
  });

  final String title;
  final List<Widget> body;
  final List<Widget> buttons;

  @override
  Widget build(BuildContext context) {
    final isDesktop = Util.isDesktop;
    final gap = isDesktop ? 16.0 : 12.0;
    return ConditionalParent(
      condition: isDesktop,
      builder: (child) => DesktopDialog(
        maxHeight: double.infinity,
        child: Padding(padding: const EdgeInsets.all(32), child: child),
      ),
      child: ConditionalParent(
        condition: !isDesktop,
        builder: (child) => StackDialogBase(child: child),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: isDesktop
                  ? STextStyles.desktopH3(context)
                  : STextStyles.pageTitleH2(context),
            ),
            SizedBox(height: isDesktop ? 16 : 8),
            ...body,
            SizedBox(height: isDesktop ? 32 : 20),
            if (buttons.length <= 2)
              Row(
                children: [
                  for (final (i, button) in buttons.indexed) ...[
                    if (i > 0) SizedBox(width: gap),
                    Expanded(child: button),
                  ],
                ],
              )
            else
              for (final (i, button) in buttons.reversed.indexed) ...[
                if (i > 0) SizedBox(height: gap),
                button,
              ],
          ],
        ),
      ),
    );
  }
}
