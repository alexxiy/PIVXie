#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env.sh"

APP_CONFIG_DART_FILE="${APP_PROJECT_ROOT_DIR}/lib/app_config.g.dart"

if test -f "$APP_CONFIG_DART_FILE"; then
    echo 'ensure_test_app_config.sh: verified lib/app_config.g.dart'
    exit 0
fi

BUILT_COMMIT_HASH="$(git -C "${APP_PROJECT_ROOT_DIR}" log -1 --pretty=format:%H 2>/dev/null || true)"

cat > "$APP_CONFIG_DART_FILE" <<EOF
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

const Set<AppFeature> _features = {
  AppFeature.tor,
  AppFeature.darkTheme,
};

const ({String light, String dark})? _appIconAsset = null;

final List<CryptoCurrency> _supportedCoins = List.unmodifiable([
  Pivx(CryptoCurrencyNetwork.main),
  Pivx(CryptoCurrencyNetwork.test),
]);
EOF

echo 'ensure_test_app_config.sh: created lib/app_config.g.dart'
