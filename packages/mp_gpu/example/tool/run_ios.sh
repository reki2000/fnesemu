#!/bin/sh
# Boots an iPhone simulator, installs the simulator build of the probe,
# starts it and writes its results to probe.out when the probe is done.
set -e
cd "$(dirname "$0")/.."
id=dev.mpgpu.mpGpuProbe
udid="$(xcrun simctl list devices available | grep -m 1 -E '^ +iPhone' | grep -oE '[0-9A-F-]{36}')"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" > /dev/null
xcrun simctl install "$udid" build/ios/iphonesimulator/Runner.app
# The log shows the steps of a probe that stalls.
xcrun simctl spawn "$udid" log stream --style compact --predicate 'eventMessage CONTAINS "MP_GPU_PROBE" OR eventMessage CONTAINS "Impeller"' > sim.log 2>&1 &
logger=$!
out="$(xcrun simctl get_app_container "$udid" "$id" data)/tmp/probe.out"
rm -f "$out"
SIMCTL_CHILD_MP_GPU_PROBE_OUT="$out" xcrun simctl launch "$udid" "$id"
i=0
while [ $i -lt 300 ] && ! grep -qs MP_GPU_PROBE_DONE "$out"; do
  sleep 2
  i=$((i + 1))
done
kill $logger 2>/dev/null || true
if [ -f "$out" ]; then cp "$out" probe.out; else sed 's/^.*\(MP_GPU_PROBE\)/\1/' sim.log > probe.out; fi
cat probe.out
grep -q MP_GPU_PROBE_DONE probe.out
