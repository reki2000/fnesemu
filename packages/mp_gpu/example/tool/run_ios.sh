#!/bin/sh
# Boots an iPhone simulator, installs the simulator build of the probe,
# starts it and prints its output until the probe is done.
set -e
cd "$(dirname "$0")/.."
udid="$(xcrun simctl list devices available | grep -m 1 -E '^ +iPhone' | grep -oE '[0-9A-F-]{36}')"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid"
xcrun simctl install "$udid" build/ios/iphonesimulator/Runner.app
xcrun simctl launch --console-pty "$udid" dev.mpgpu.mpGpuProbe > probe.log 2>&1 &
i=0
while [ $i -lt 300 ] && ! grep -q MP_GPU_PROBE_DONE probe.log; do
  sleep 2
  i=$((i + 1))
done
kill $! 2>/dev/null || true
grep -E 'MP_GPU_PROBE|Impeller' probe.log | sed 's/^.*\(MP_GPU_PROBE\)/\1/' > probe.out || true
cat probe.out
grep -q MP_GPU_PROBE_DONE probe.out
