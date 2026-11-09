#!/bin/sh
# Installs the probe APK on the running emulator or device, starts it and
# prints the probe lines of the log until the probe is done.
set -e
cd "$(dirname "$0")/.."
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb logcat -c
adb shell am start -n dev.mp_gpu.mp_gpu_probe/.MainActivity
i=0
while [ $i -lt 300 ] && ! adb logcat -d | grep -q MP_GPU_PROBE_DONE; do
  sleep 2
  i=$((i + 1))
done
adb logcat -d | grep -E "MP_GPU_PROBE|Impeller|AndroidRuntime|DEBUG" | sed 's/^.*\(MP_GPU_PROBE\)/\1/' | tee probe.log
grep -q MP_GPU_PROBE_DONE probe.log
