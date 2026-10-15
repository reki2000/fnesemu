#!/usr/bin/env bash
set -euo pipefail

flutter_args=()
dart_args=()
case "${1:-vm}" in
  vm) ;;
  js) flutter_args=(--platform chrome); dart_args=(--platform chrome) ;;
  wasm) flutter_args=(--platform chrome --wasm); dart_args=(--platform chrome --compiler dart2wasm) ;;
  *) echo 'Expected vm, js or wasm' >&2; exit 1 ;;
esac

flutter pub get
(
  cd packages/cdrom_image
  dart pub get
  if [[ "${1:-vm}" == vm ]]; then
    dart test
  else
    # Other upstream suites load fixtures with dart:io; keep them on every VM host.
    dart test "${dart_args[@]}" test/cue_references_test.dart test/disc_image_test.dart
  fi
)
(cd packages/fnesemu_core && dart pub get && dart test "${dart_args[@]}")
flutter test "${flutter_args[@]}"
