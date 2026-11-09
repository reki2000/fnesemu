#!/bin/sh
# Generates the platform runners of the probe with Flutter GPU enabled and
# compiles its shaders with the impellerc of the Flutter SDK on PATH. Run it
# from any directory before a build. The arguments are the platforms, all of
# them when none is given.
set -e
cd "$(dirname "$0")/.."
platforms="$(echo "${*:-linux windows macos android ios web}" | tr ' ' ',')"
flutter create --empty --no-pub --platforms="$platforms" \
  --project-name mp_gpu_probe --org dev.mp_gpu . >/dev/null
rm -rf test

# The settings that enable Flutter GPU, as in the runners of the app.
patch() {
  [ -f "$1" ] && ! grep -q "$2" "$1" && perl -0pi -e "$3" "$1" || true
}
patch linux/runner/my_application.cc enable_flutter_gpu \
  's/(project = fl_dart_project_new\(\);\r?\n)/$1  fl_dart_project_set_enable_impeller(project, TRUE);\n  fl_dart_project_set_enable_flutter_gpu(project, TRUE);\n/'
patch windows/runner/main.cpp enable_flutter_gpu \
  's/(flutter::DartProject project\(L"data"\);\r?\n)/$1  project.set_enable_flutter_gpu(true);\n/'
for plist in macos/Runner/Info.plist ios/Runner/Info.plist; do
  patch "$plist" FLTEnableFlutterGPU \
    's#<dict>#<dict>\n\t<key>FLTEnableFlutterGPU</key>\n\t<true/>#'
done
patch android/app/src/main/AndroidManifest.xml EnableFlutterGPU \
  's#(<application\b[^>]*>)#$1\n        <meta-data android:name="io.flutter.embedding.android.EnableFlutterGPU" android:value="true" />#'

# The bundle must come from the impellerc of the SDK that builds the probe.
flutter_root="$(dirname "$(dirname "$(readlink -f "$(command -v flutter)")")")"
impellerc="$(ls "$flutter_root"/bin/cache/artifacts/engine/*/impellerc* | head -n 1)"
"$impellerc" \
  --shader-bundle='{"ProbeVertex":{"type":"vertex","file":"shaders/probe.vert"},"ProbeFragment":{"type":"fragment","file":"shaders/probe.frag"}}' \
  --sl=shaders/probe.shaderbundle \
  --runtime-stage-vulkan --runtime-stage-gles --runtime-stage-gles3 \
  --include="$(dirname "$impellerc")/shader_lib"
