#!/bin/sh
# Compiles the shaders into shaders/check.shaderbundle with the impellerc of
# the Flutter SDK on PATH. Run it from any directory.
set -e
cd "$(dirname "$0")/.."
flutter_root="$(dirname "$(dirname "$(readlink -f "$(command -v flutter)")")")"
engine="$flutter_root/bin/cache/artifacts/engine"
impellerc="$(ls "$engine"/*/impellerc | head -n 1)"
"$impellerc" \
  --shader-bundle='{"CheckVertex":{"type":"vertex","file":"shaders/check.vert"},"CheckFragment":{"type":"fragment","file":"shaders/check.frag"}}' \
  --sl=shaders/check.shaderbundle \
  --runtime-stage-vulkan --runtime-stage-gles --runtime-stage-gles3 \
  --include="$(dirname "$impellerc")/shader_lib"
