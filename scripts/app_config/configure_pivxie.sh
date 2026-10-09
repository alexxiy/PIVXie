#!/usr/bin/env bash

set -x -e

# Configure files for PIVXie.
APP_BUILD_PLATFORM=$1

export NEW_NAME="PIVXie"
export NEW_APP_ID="org.pivx.pivxie"
export NEW_APP_ID_CAMEL="org.pivx.pivxie"
export NEW_APP_ID_SNAKE="org.pivx.pivxie"
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

export INCLUDE_EPIC_SO="OFF"
export INCLUDE_MWC_SO="OFF"

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

const _mwebdExeHash = "";

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

final ({String from, String fromFuzzyNet, String to, String toFuzzyNet})
_swapDefaults = (
  from: "BTC",
  fromFuzzyNet: "btc",
  to: "PIVX",
  toFuzzyNet: "pivx",
);

EOF