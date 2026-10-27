#!/usr/bin/env bash

set -x -e

if [ $# -ne 2 ]; then
    echo "Usage: $0 <theme specific assets dir name (ex. stack_wallet)> <platform (ex. windows)>"
    exit 1
fi

SELECT_ASSETS_DIR=$1
APP_BUILD_PLATFORM=$2

# declare full paths
ASSET_SOURCES_DIR="${APP_PROJECT_ROOT_DIR}/asset_sources"
ASSETS_DIR="${APP_PROJECT_ROOT_DIR}/assets"


# finally update symlinks

for dirname in "default_themes" "icon" "lottie" "in_app_logo_icons" "svg"; do
  LINK_SOURCE_DIR="${ASSET_SOURCES_DIR}/${dirname}/${SELECT_ASSETS_DIR}"

  rm -f "${ASSETS_DIR}/${dirname}"

  if [[ "${APP_BUILD_PLATFORM}" = 'windows' ]] && ! command -v cygpath >/dev/null 2>&1; then
    # WSL: a Windows directory link, which the Windows Flutter follows.
    LINK_SOURCE_DIR_WIN_PATH_VERSION=$(wslpath -w "${LINK_SOURCE_DIR}")
    LINK_NAME_WIN_PATH_VERSION=$(wslpath -w "${ASSETS_DIR}")
    cmd.exe /c mklink /D "${LINK_NAME_WIN_PATH_VERSION}\\${dirname}" "${LINK_SOURCE_DIR_WIN_PATH_VERSION}"
  else
    # On Windows (Git Bash, CI) these make ln create real Windows links
    # instead of copies (needs admin or Developer Mode); elsewhere unused.
    MSYS=winsymlinks:nativestrict CYGWIN=winsymlinks:nativestrict \
      ln -s "${LINK_SOURCE_DIR}" "${ASSETS_DIR}/${dirname}"
  fi
done
