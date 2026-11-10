#!/bin/sh
# Compiles the shaders into shaders/frame.shaderbundle with the impellerc of
# the Flutter SDK on PATH. Run it from any directory.
set -e
cd "$(dirname "$0")/.."
flutter_root="$(dirname "$(dirname "$(readlink -f "$(command -v flutter)")")")"
engine="$flutter_root/bin/cache/artifacts/engine"
impellerc="$(ls "$engine"/*/impellerc | head -n 1)"
"$impellerc" \
  --shader-bundle='{"FrameVertex":{"type":"vertex","file":"shaders/frame.vert"},"FrameFragment":{"type":"fragment","file":"shaders/frame.frag"}}' \
  --sl=shaders/frame.shaderbundle \
  --runtime-stage-vulkan --runtime-stage-gles --runtime-stage-gles3 \
  --include="$(dirname "$impellerc")/shader_lib"
"$impellerc" \
  --shader-bundle='{"Ps2Vertex":{"type":"vertex","file":"shaders/ps2.vert"},"Ps2Fragment":{"type":"fragment","file":"shaders/ps2.frag"},"Ps2SpriteVertex":{"type":"vertex","file":"shaders/ps2_sprite.vert"},"Ps2SpriteFragment":{"type":"fragment","file":"shaders/ps2_sprite.frag"},"Ps2FeedbackFragment":{"type":"fragment","file":"shaders/ps2_feedback.frag"}}' \
  --sl=shaders/ps2.shaderbundle \
  --runtime-stage-vulkan --runtime-stage-gles --runtime-stage-gles3 \
  --include="$(dirname "$impellerc")/shader_lib"
