#!/usr/bin/env bash

set -x -e

if [ $# -ne 1 ]; then
    echo "Usage: $0 <platform>"
    exit 1
fi

APP_BUILD_PLATFORM=$1

# run icon and image generators
pushd "${APP_PROJECT_ROOT_DIR}"
YAML_FILE="${APP_PROJECT_ROOT_DIR}/scripts/app_config/platforms/${APP_BUILD_PLATFORM}/flutter_launcher_icons.yaml"
if [[ "${APP_BUILD_PLATFORM}" = 'windows' ]]; then
  if command -v cygpath >/dev/null 2>&1; then
    # Git Bash (CI) runs the Windows Flutter directly. Its path conversion
    # would turn cmd.exe's /c into C:/.
    flutter pub get
    dart run flutter_launcher_icons -f "$(cygpath -w "${YAML_FILE}")"
  else
    # WSL: the Windows Flutter through cmd.exe.
    cmd.exe /c flutter pub get
    cmd.exe /c dart run flutter_launcher_icons -f "$(wslpath -w "${YAML_FILE}")"
  fi
  # not needed in windows
#  cmd.exe /c dart run flutter_native_splash:create
else
  flutter pub get
  dart run flutter_launcher_icons -f "${YAML_FILE}"

  if [[ "${APP_BUILD_PLATFORM}" = 'ios' || "${APP_BUILD_PLATFORM}" = 'android' ]]; then
    dart run flutter_native_splash:create
    # The splash tool gives the launch theme the shortEdges cutout mode,
    # deprecated since Android 15 (Play flags it). enableEdgeToEdge() in
    # MainActivity sets the cutout mode at start anyway. (-i.bak works with
    # both GNU and macOS sed.)
    sed -i.bak '/android:windowLayoutInDisplayCutoutMode/d' android/app/src/main/res/values*/styles.xml
    rm -f android/app/src/main/res/values*/styles.xml.bak
  fi
fi
popd