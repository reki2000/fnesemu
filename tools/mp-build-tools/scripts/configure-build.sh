#!/usr/bin/env bash
# Configure one target without changing the caller's working directory.
set -euo pipefail

: "${ARTIFACT_NAME:?artifact-name is required}"
: "${TARGET:?target is required}"
case "$TARGET" in
  web|android|linux|windows|macos|ios|ios-simulator) ;;
  *) echo "Unsupported build target: $TARGET" >&2; exit 1 ;;
esac
source "${BASH_SOURCE[0]%/*}/release.sh" version

scripts=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
if [[ "$RUNNER_OS" == Windows ]]; then
  scripts=$(cygpath -m "$scripts")
fi
build_name=${version%%-*}
if [[ "$TARGET" == web ]]; then
  ARCH=browser
  build_name=$version
else
  : "${ARCH:?architecture is required for native builds}"
fi

printf '%s\n' \
  "APP_DIR=$APP_DIR" "ARTIFACT_NAME=$ARTIFACT_NAME" "FLUTTER_VERSION=$FLUTTER_VERSION" \
  "VERSION=$version" "BUILD_NAME=$build_name" "TARGET=$TARGET" "ARCH=$ARCH" \
  "ANDROID_SIGNING=$ANDROID_SIGNING" "IOS_SIGNING=$IOS_SIGNING" \
  "MP_BUILD_SCRIPTS=$scripts" >> "$GITHUB_ENV"
