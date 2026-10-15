#!/usr/bin/env bash
set -euo pipefail
runtime=${1:-vm}

flutter pub get
(
  cd packages/cdrom_image
  dart pub get
  if [[ "$runtime" == vm ]]; then
    bash "$MP_BUILD_SCRIPTS/test.sh" dart "$runtime"
  else
    # Other upstream suites load fixtures with dart:io; keep them on every VM host.
    bash "$MP_BUILD_SCRIPTS/test.sh" dart "$runtime" test/cue_references_test.dart test/disc_image_test.dart
  fi
)
(cd packages/fnesemu_core && dart pub get && bash "$MP_BUILD_SCRIPTS/test.sh" dart "$runtime")
bash "$MP_BUILD_SCRIPTS/test.sh" flutter "$runtime"
