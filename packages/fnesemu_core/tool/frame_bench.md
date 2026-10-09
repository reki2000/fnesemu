The frame benchmark drives a core through the same frame boundaries and input schedule as `tool/core_harness.dart`. It supports `nes`, `snes`, `gb`, `gba` and `n64`.

Store a harness argument array in a local JSON file. Include the core, media path, input events, hold duration and BIOS option when applicable. Media names and paths belong in the local file rather than the repository. Harness `-f`, `-e`, `-s`, `-o` and `-w` options are accepted but ignored by the timing driver.

```sh
dart compile exe tool/frame_bench.dart -o /tmp/frame-bench
/tmp/frame-bench --case /tmp/case.json --warmup 1800 --frames 300 --repetitions 3
/tmp/frame-bench --case /tmp/case.json --warmup 1800 --frames 300 --repetitions 3 --frame-runner
dart tool/frame_bench.dart --case /tmp/case.json --warmup 1800 --frames 300 --repetitions 3 --frame-runner
```

After warmup, each measured block acquires `/tmp/claude-1000/fnesemu-bench.lock` using `flock`. It releases the lock after the block, including on exceptions. Do not wrap this driver in another `flock` on that file: acquisition happens inside the driver. Keep each block within a few tens of seconds.

The three repetitions are consecutive frame intervals after one warmup, not resets of the same interval. Compare the same `fromFrame`/`toFrame` intervals across builds and report their median. `us`, `msPerFrame` and `fps` use elapsed time while executing the core. `cpuUs`, `cpuMsPerFrame` and `cpuFps` use process CPU time from Linux `/proc/self/stat` and `getconf CLK_TCK`, so scheduling delays can be distinguished from emulator work. CPU time has the system clock-tick resolution and includes input processing and any requested file output. Other tasks may compile or validate outside the shared lock; their CPU activity can still affect elapsed timings.

Use `--out DIR` for raw RGBA snapshots, stereo/mono Float32 audio and final clocks/sample counts/state. Omit it for reported timings. The regular harness also accepts `--frame-runner` (`-r`) to produce PNG/WAV regression outputs through the bulk execution path; its default continues to step instructions.
