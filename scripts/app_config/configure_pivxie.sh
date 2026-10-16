#!/usr/bin/env bash

set -x -e

# Configure files for PIVXie.
APP_BUILD_PLATFORM=$1

export NEW_NAME="PIVXie"
export NEW_APP_ID="me.pivxie"
export NEW_APP_ID_CAMEL="me.pivxie"
export NEW_APP_ID_SNAKE="me.pivxie"
# Linux: Flatpak IDs need three parts, and on Wayland a window finds its
# icon through a .desktop file named after its ID, so every Linux package
# (tarball, AppImage, Flatpak) uses this one.
export NEW_LINUX_APP_ID="me.pivxie.PIVXie"
export NEW_BASIC_NAME="pivxie"

NEW_PUBSPEC_NAME="paymint" # package name used across lib/ imports
PUBSPEC_FILE="${APP_PROJECT_ROOT_DIR}/pubspec.yaml"

# String replacements.
if [[ "$(uname)" == 'Darwin' ]]; then
  # macos specific sed
  sed -i '' "s/name: PLACEHOLDER/name: ${NEW_PUBSPEC_NAME}/g" "${PUBSPEC_FILE}"
  sed -i '' "s/description: PLACEHOLDER/description: ${NEW_NAME}/g" "${PUBSPEC_FILE}"
else
  sed -i "s/name: PLACEHOLDER/name: ${NEW_PUBSPEC_NAME}/g" "${PUBSPEC_FILE}"
  sed -i "s/description: PLACEHOLDER/description: ${NEW_NAME}/g" "${PUBSPEC_FILE}"
fi

dart "${APP_PROJECT_ROOT_DIR}/tool/process_pubspec_deps.dart" \
      "${PUBSPEC_FILE}" \
      TOR \
      PIVX

dart "${APP_PROJECT_ROOT_DIR}/tool/gen_interfaces.dart" \
      "${APP_PROJECT_ROOT_DIR}/tool/wl_templates" \
      "${APP_PROJECT_ROOT_DIR}/lib/wl_gen/generated" \
      TOR \
      PIVX

pushd "${APP_PROJECT_ROOT_DIR}"
BUILT_COMMIT_HASH=$(git log -1 --pretty=format:"%H")
popd

APP_CONFIG_DART_FILE="${APP_PROJECT_ROOT_DIR}/lib/app_config.g.dart"
rm -f "$APP_CONFIG_DART_FILE"
cat << EOF > "$APP_CONFIG_DART_FILE"
// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_config.dart';

const _prefix = "PIVXie";
const _separator = "";
const _suffix = "";
const _emptyWalletsMessage =
    "Create your first PIVX wallet";
const _appDataDirName = "pivxie";
const _shortDescriptionText = "Your privacy. Your keys. Your PIVX.";
const _commitHash = "$BUILT_COMMIT_HASH";

// Project links. Empty ones are not shown in the app.
const _websiteUrl = "https://pivxie.me";
const _termsUrl = "https://pivxie.me/terms-of-service.html";
const _privacyUrl = "https://pivxie.me/privacy-policy.html";

// Support: the official PIVX community channels (see pivx.org).
const List<SupportLink> _supportLinks = [
  (
    channel: SupportChannel.discord,
    text: "discord.pivx.org",
    url: "https://discord.pivx.org/",
  ),
  (
    channel: SupportChannel.telegram,
    text: "@PIVX_official",
    url: "https://t.me/PIVX_official",
  ),
  (
    channel: SupportChannel.reddit,
    text: "r/pivx",
    url: "https://www.reddit.com/r/pivx/",
  ),
  (channel: SupportChannel.x, text: "@_PIVX", url: "https://x.com/_PIVX"),
  (
    channel: SupportChannel.email,
    text: "support@pivxie.me",
    url: "mailto:support@pivxie.me",
  ),
];

const Set<AppFeature> _features = {
  AppFeature.tor,
  AppFeature.darkTheme,
};

const ({String light, String dark})? _appIconAsset = (
  light: "assets/in_app_logo_icons/pivxie-icon_light.svg",
  dark: "assets/in_app_logo_icons/pivxie-icon_dark.svg",
);

// Release builds are single-coin (mainnet). Debug builds, and test
// builds made with --dart-define=PIVX_TESTNET=true, add the test network
// (PIVX testnet / regtest).
const _pivxTestnet = bool.fromEnvironment("PIVX_TESTNET");

final List<CryptoCurrency> _supportedCoins = List.unmodifiable([
  Pivx(CryptoCurrencyNetwork.main),
  if (kDebugMode || _pivxTestnet) Pivx(CryptoCurrencyNetwork.test),
]);

EOF