# Tools

Command-line tools of the cores. Run them with `dart run tool/<name>.dart` in `packages/fnesemu_core`, or build standalone bundles with `dart build cli`. Each prints its usage when it is run without arguments.

| Tool | What it does |
|---|---|
| `core_headless.dart` | Runs a core with its media and input: `run` writes the screen and the audio, `serve` gives stepwise control over HTTP, `bench` times frames, `trace` records the instructions through the tracer of the debugger, `buttons` and `check-input` print the button names and the presses of an input |
| `cpu_test.dart` | Runs the instruction tests of a CPU (`nestest`, `z80`, `v30`, `m68k`, `r3000`, `huc6280`), used by `make test-cpu` |
| `disasm.dart` | Disassembles one 68000 or Z80 instruction |
| `microbench.dart` | Synthetic benchmarks that need no ROM (`vr4300`, `video-debug`) |
| `generate_core_registry.dart` | Writes the registry of the core modules |

`input_sequence.dart` holds the syntax of the button presses, which `core_headless`, its server and `scripts/e2e.py` share.

The standalone bundle includes the JIT memory helper as a native asset. Keep `bundle/lib` alongside `bundle/bin`; `dart compile exe` alone does not package this dependency. The e2e runner caches complete bundles and invalidates them when local runtime or native-helper sources change.

## Benchmarks

`core_headless bench` drives a core through the same frames and input as `core_headless run`, so a case of `e2e.toml` can be timed with the same media and input.

```sh
dart build cli -t tool/core_headless.dart -o /tmp/core-headless
/tmp/core-headless/bundle/bin/core_headless bench snes <rom> --input ":12 @300 Start" --warmup 1800 --measure 300 --repetitions 3 \
    --lock /tmp/claude-1000/fnesemu-bench.lock
/tmp/core-headless/bundle/bin/core_headless bench ps <bios> <disc> --fast-boot --warmup 2000 --measure 600 --checksum
```

- `--lock FILE` holds `flock` on the shared benchmark lock during each timed block and releases it after the block, also on errors. Do not wrap the command in another `flock` on the same file. Keep each block within a few tens of seconds.
- The repetitions are consecutive frame blocks after one warmup, not resets of the same block. Compare the same `fromFrame`/`toFrame` blocks across builds and report their median.
- `us`, `msPerFrame` and `fps` are the elapsed time of the core execution and one `imageBuffer()` call per frame. Waiting for the disc, the input, the hashes and the files are outside of it. `cpuUs`, `cpuMsPerFrame` and `cpuFps` are the process CPU time of the whole block from `/proc/self/stat` and `getconf CLK_TCK`, so scheduling delays can be told from emulator work.
- `--checksum` adds the hashes of the frame images and the audio, and `--hashes FILE` writes the hash of every frame, to check that an optimization does not change the output. `--sync DIR` times two builds side by side: each writes `DIR/ready.<pid>` and waits for `DIR/go`.
- `--profile-compile --jit on` reports translation/publication time, published payload bytes, host driver cache lookups, fallback-cache hits, guard failures, invalidations and clears in `compilationProfiles`, in CPU descriptor order. Collection starts after warmup without flushing code and resets at each timed block. Payload bytes are cumulative, rather than resident memory; repeated installations are tracked only at retained bounded sites. Host driver lookups exclude linked native block transitions. Combining with `--profile-blocks` also records that diagnostic's explicit cache clear. Timing is perturbed; use separate runs for throughput. See the [shared telemetry contract](../../mp_jit_recompiler/README.md).
- `--profile-cpu --jit on|off` enables bounded CPU dispatch, idle-clock and CPU-side bus-request statistics for each available JIT CPU, in descriptor order. A compiled backend must be available even with `--jit off`; that mode suspends compilation and uses the interpreter on shared buffers. Collection starts after warmup and resets for each timed block. The JSON `cpuProfiles` includes dispatch sites, guest clocks and fetch/read/write requests by region and width. Dispatches can service interrupts instead of executing the selected opcode. Bus requests include synchronous nested accesses; mapped native loads/stores are outside this scope. Capacity overflow preserves totals and reports omitted sites. Region labels describe observations and do not establish access permissions. Profiling perturbs timing.
- `--profile-blocks` records positive executed block-cycle spans in a separate diagnostic; `--profile-exits` profiles actual native returns after warmup. Both perturb timing. See the [canonical metrics and diagnostic contracts](../../mp_jit_recompiler/OPTIMIZATION.md#required-interval-metrics), including standard interval coverage, entry count and mean return cycles.
- `--jit on|off` selects native compilation or CPU interpretation for `ps`, `n64`, `ss` and `32x` in the same executable. `--warmup-jit on|off` runs the warmup in the other mode on the same core instance, for example the faster mode for a long intro; the timed blocks then use `--jit`. The core keeps its compiled backend and `jitSuspended` switches it off, so a timed interpreter runs on the JIT-shared register and memory buffers. Bench JSON reports `jitEnabled` and the measured `jitClocks` / `cpuClocks` deltas. These counters describe guest clocks, not host CPU time.
- `--jit-cop1 off|transfers|native|helpers` selects N64 COP1 coverage (default `native`) and requires `n64 --jit on`. `transfers` includes register/control transfers, aligned ordinary-memory accesses and branches. `native` adds ADD/SUB/MUL, finite C.EQ/C.LT/C.LE comparisons in both precisions, ROUND.W/TRUNC.W/CVT.W, CVT.S from double and CVT.D from single. Nonfinite operands, out-of-range word conversions, CVT.W outside round-to-nearest and other COP1 operations fall back to the CPU. `helpers` uses Dart arithmetic callbacks inside blocks.
- `--jit-stats` requires `n64 --jit on` and emits `n64Stats` per measured interval: skipped idle clocks, CPU fallback selections by raw opcode, and runtime exits by reason and raw opcode. A selection at the current PC can service an interrupt before that opcode executes; these counts are not an instruction trace. Runtime exits include cache misses, budgets and native continuation dispatch, so they do not all imply CPU interpretation. Keep these diagnostics separate from throughput measurements.
- `--ss-slice-clocks N` selects an experimental SS CPU quantum and requires `ss --jit on|off`. The core default is 64. Changing the quantum changes CPU/device interleaving; other values remain comparison variants. `ss_slice_compare.dart --case FILE --warmup 2800 --frames 90` compares 32/64/128 in one native AOT process and reports state/output differences. See [the SH-2 configuration](sh2_jit_bench.md).
- `--32x-slice-clocks N` selects the 32x CPU quantum and requires `32x --jit on|off`. The default is 64; 1 reproduces legacy instruction alternation and one-instruction compilation. Both are clipped to the main CPU deadline. Native JIT is enabled by default.
- `sh2_slice_compare.dart --case FILE --warmup N --frames 90 [--out DIR]` compares SS JIT quanta 32/64/128 or 32x interpretation/JIT at 1/32 and JIT at 64 in one AOT process. The fixture is a local JSON array of media/input arguments without JIT or quantum options. It rotates timed batches under the shared lock and reports state/image/audio differences without treating state equality as the sole acceptance gate. `--out` saves periodic PNGs and a continuous WAV; PCM collection and hashing run inside the timed audio callback. `ss_slice_compare.dart` remains a compatibility entry point.
- N64 and SH-2 comparison tools share `headless/comparison.dart` for absolute frame intervals, warmup, rotated/reversed batches and the measurement lock. Warmup runs before acquiring the lock; batch checks and final output run while it is held. Each tool retains its timer boundaries and comparison policy: N64 times a whole frame batch and requires exact state/output equality, while SH-2 times execution plus image retrieval per frame and reports differences. `core_headless bench` uses the same lock and external-start handshake helpers.
- For `run`, `--save-state FILE` writes state after the last completed frame and `--load-state FILE` restores it before frame execution. `--frames N` is the absolute final frame number (default 600), not a count of additional frames: loading frame 900 and passing `--frames 1200` runs through frame 1200. The input sequence also continues from the restored frame. Only cores implementing `Core.saveState` (N64, SS, cartridge MD and 32X; MD CD is unsupported) support these flags. For `bench`, the same flags save after warmup or resume from the saved frame; compiled code starts cold after loading. SS states identify the BIOS and disc TOC and omit the drive sector cache, so restoration may change initial audio or execution timing. Interpreter/JIT instances can exchange 32X checkpoints with the same CPU quantum. The state codec uses 64-bit integer storage and is not supported by dart2js.
- `--frame-runner` (`-r`) runs whole frames inside the core, as the GUI does without the debugger; without it, the core runs by `exec()`.

## JIT configuration

### Current JIT status

| Core | Default | Configuration |
| --- | --- | --- |
| PS1 | enabled on supported hosts | Shared CPU state, memory aliases and precise CPU fallback |
| N64 | enabled on supported hosts | Native integer and supported COP1 execution |
| SS | disabled | Optional JIT; default CPU quantum 64 clocks |
| 32X | enabled on supported hosts | Default CPU quantum 32 clocks |

See [frame comparison](jit_frame_bench.md), [continuation and returns](jit_return_followup.md), [N64](n64_jit_bench.md), [SH-2](sh2_jit_bench.md), [SS execution](ss64_jit_bench.md), [CPU profiling](cpu_profile_notes.md), [Dart AOT performance notes](dart_aot_tips.md) and the shared [performance guide](../../mp_jit_recompiler/OPTIMIZATION.md).
