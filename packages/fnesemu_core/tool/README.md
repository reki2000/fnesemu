# Tools

Command-line tools of the cores. Run them with `dart run tool/<name>.dart` in `packages/fnesemu_core`, or compile them with `dart compile exe`. Each prints its usage when it is run without arguments.

| Tool | What it does |
|---|---|
| `core_headless.dart` | Runs a core with its media and input: `run` writes the screen and the audio, `serve` gives stepwise control over HTTP, `bench` times frames, `trace` records the instructions through the tracer of the debugger, `buttons` and `check-input` print the button names and the presses of an input |
| `cpu_test.dart` | Runs the instruction tests of a CPU (`nestest`, `z80`, `v30`, `m68k`, `r3000`, `huc6280`), used by `make test-cpu` |
| `disasm.dart` | Disassembles one 68000 or Z80 instruction |
| `microbench.dart` | Synthetic benchmarks that need no ROM (`vr4300`, `video-debug`) |
| `generate_core_registry.dart` | Writes the registry of the core modules |

`input_sequence.dart` holds the syntax of the button presses, which `core_headless`, its server and `scripts/e2e.py` share.

## Benchmarks

`core_headless bench` drives a core through the same frames and input as `core_headless run`, so a case of `e2e.toml` can be timed with the same media and input. Media names and paths belong in local commands, not in the repository.

```sh
dart compile exe tool/core_headless.dart -o /tmp/core-headless
/tmp/core-headless bench snes <rom> --input ":12 @300 Start" --warmup 1800 --measure 300 --repetitions 3 \
    --lock /tmp/claude-1000/fnesemu-bench.lock
/tmp/core-headless bench ps <bios> <disc> --fast-boot --warmup 2000 --measure 600 --checksum
```

- `--lock FILE` holds `flock` on the shared benchmark lock during each timed block and releases it after the block, also on errors. Do not wrap the command in another `flock` on the same file. Keep each block within a few tens of seconds.
- The repetitions are consecutive frame blocks after one warmup, not resets of the same block. Compare the same `fromFrame`/`toFrame` blocks across builds and report their median.
- `us`, `msPerFrame` and `fps` are the elapsed time of the core execution and one `imageBuffer()` call per frame. Waiting for the disc, the input, the hashes and the files are outside of it. `cpuUs`, `cpuMsPerFrame` and `cpuFps` are the process CPU time of the whole block from `/proc/self/stat` and `getconf CLK_TCK`, so scheduling delays can be told from emulator work.
- `--checksum` adds the hashes of the frame images and the audio, and `--hashes FILE` writes the hash of every frame, to check that an optimization does not change the output. `--sync DIR` times two builds side by side: each writes `DIR/ready.<pid>` and waits for `DIR/go`.
- `--frame-runner` (`-r`) runs whole frames inside the core, as the GUI does without the debugger; without it, the core runs by `exec()`.
