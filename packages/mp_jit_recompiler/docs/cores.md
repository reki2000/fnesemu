# Core adapters

This document records what each core currently does with the recompiler: defaults, build options and the policies its adapter owns. The adapter contracts that apply to every core are in the [frontend guide](frontends.md), and the core boundaries in the [architecture](../../../ARCHITECTURE.md).

## Current status

| Core | Frontend | Default | Notes |
| --- | --- | --- | --- |
| PS1 | R3000 (`core/ps/jit`) | enabled on supported hosts | Shared CPU state, memory aliases and precise CPU fallback |
| N64 | VR4300 (`core/n64/jit`) | enabled on supported hosts | Native integer and supported COP1 execution |
| SS | SH-2 (`components/sh2/jit`) | disabled | Optional JIT, default CPU quantum 64 clocks |
| 32X | SH-2 (`components/sh2/jit`) | enabled on supported hosts | Default CPU quantum 32 clocks |

A host without an available compiled backend uses the interpreter. `JIT=false` selects the interpreter for PS1 and N64, and `JIT=true` enables SS recompilation. `SH2_JIT_32X=false` selects the 32X interpreter. `PS_TRACE=true` disables PS1 recompilation.

Changing a default needs the evidence described in the [performance guide](performance.md#changing-a-default), and this table must then be updated.

## Common behavior

PS1, N64 and SH-2 use `JitDriver` for warmup, fallback, batch accounting and reset. The runtime chains installed static and dynamic targets while the budget and stop conditions allow it. Linked precise exits keep their snapshots and refund only the unexecuted block cost.

A positive budget lets the final block complete or take a precise exit, so adapters account for deadline overshoot. Budget preparation avoids entering with exhausted work. Where return causes need investigation, use `core_headless bench --profile-exits` as described in [Diagnostics](diagnostics.md#native-return-profile).

## PS1

PS1 enables recompilation by default. The RAM mapping mirrors 2MiB over the first 8MiB, and the bus and the JIT must agree on read and write ranges and on every alias used for code-page protection and invalidation. `packages/fnesemu_core/tool/ps_jit_bench.dart` compares the interpreter with the recompiler.

## N64

N64 blocks use native i64 values, big-endian memory, and register and FPU views shared with the CPU interpreter. Entry tags distinguish the FPU register layout and COP1 availability. Aligned ordinary-memory accesses can remain compiled. Device and TLB accesses, faults and unsupported operations return before effects.

### Integer coverage

Besides the integer ALU, shifts, branches and aligned memory access, the frontend translates MULT, MULTU, MFHI, MFLO, MTHI and MTLO. HI and LO live in the register storage that the interpreter shares (`N64Registers`), so exits and the interpreter see them without copying. The divides, the 64-bit multiplies and the COP0 moves still use the CPU fallback.

### COP1 coverage

The default native path supports transfers, aligned memory access, branches, ADD/SUB/MUL, finite C.EQ/C.LT/C.LE comparisons, supported word rounding and conversion, CVT.S from double and CVT.D from single. Nonfinite operands, out-of-range word conversions and unsupported rounding modes use CPU fallback. Additional architectural floating-point exceptions and rounding modes are not implemented.

`--jit-cop1 off|transfers|native|helpers` selects the coverage in `core_headless`; `helpers` uses Dart arithmetic callbacks. The `N64` constructor parameters `jitCop1`, `jitNativeFpu` and `jitFpu` select the same coverage for tests and tools; there are no build defines for them. Untaken branch-likely continuations use linked precise exits after snapshot stores and cost refunds.

### Block limits and statistics

The translation limit is 24 instructions, and the `inlineJumps` constructor parameter (default off) lets direct jumps continue translation at their target. These are comparison settings, not substitutes for measuring actual invocation boundaries. `N64_JIT_STATS` (or `--jit-stats`) enables installation and block-end histograms and the fallback and exit counters.

### Tools and checks

`tool/n64_jit_compare.dart` compares variants. Build it with `dart build cli` and retain its bundled native library. Pass a case JSON containing shared media and input arguments, plus `--warmup` and `--frames` to select the interval. Use `--cop1 --fpu` when comparing floating-point variants.

Differential tests compare CPU, reference IR and compiled execution for full-width integer values, FPU layouts and control, finite and special operands, delay slots, traps, precise memory faults, host writes and aliases. ARM64 QEMU checks exercise float arithmetic, conversion and N64 translation with compiled availability asserted and skipped tests rejected.

## SH-2 (SS and 32X)

SS and 32X use the common integer frontend under `components/sh2/jit`, with register views and ordinary memory shared with their CPU interpreters. `JitDriver` handles dispatch, cold-entry observations, fallback, batch accounting and reset. The adapters keep memory maps, interrupt handling, on-chip ticks, CPU ordering and device deadlines. Read faults and unsupported delay slots exit before effects so the CPU can replay the branch precisely.

The specialization mechanism is described in the [frontend guide](frontends.md#guarded-specialization). `Sh2Jit.create(profileMemory: false)` selects the ordinary path, and `compileThreshold` controls native warmup (default 10).

### CPU quantum

SS uses a default 64-clock quantum. 32X alternates the CPUs in bounded 32-clock quanta clipped to the main CPU deadline, and quantum 1 selects instruction alternation with one-instruction compilation. Changing a quantum changes CPU and device interleaving and requires independent synchronization checks. The options are `--ss-slice-clocks` and `--32x-slice-clocks`.

`sh2_slice_compare.dart --case FILE --warmup N --frames N [--out DIR]` compares the supported quantum and interpreter or JIT variants in one AOT process. The case JSON contains media and input arguments without mode or quantum options. `ss_slice_compare.dart` is a compatibility entry point. Output capture includes periodic PNGs and continuous audio.

### SS

- Recompilation is opt-in through `--jit on`, `Ss(jit: true)` or `JIT=true`. CPU slices are clipped at scanline boundaries, and the last block may overshoot its deadline. Master and slave ordering and on-chip updates are adapter-owned.
- MAC.L and MAC.W are enabled (`jitMacLong`, `jitMacWord`) using the CPU model's saturation, aliasing and access-order semantics with its one-clock instruction model.
- `jitFtcsr` allows the FTCSR byte to be read from a context word. Its read has no side effect and its value remains stable until CPU or on-chip processing resumes, so it is refreshed before every native attempt rather than frozen as a compile-time value.
- `jitIdleGuards` enables the native check of unchanged pure self-loops. The adapter then advances to its deadline, ticks devices normally and excludes the skipped clocks from the native counter. Selected backward-edge yields feed the adapter's idle detector; multi-block waits keep the CPU detector and its wake path. The no-store condition alone is not an idle proof.
- Tests cover unchanged and changing loops, wakeups, device ticks, memory changes, callback exclusion, saturation, aliased operands, two-read exits and branch-slot replay.
- Comparison command: `core_headless bench ss <media...> --frame-runner --jit on|off --ss-slice-clocks N --fixed-clock` with identical input and interval settings.

### 32X

- Native recompilation is enabled by default. SDRAM code is compiled. Private-cache code and other excluded regions stay on the CPU path, and banked ROM compilation needs a separate mapping and invalidation contract. The adapter shares one masked code-address predicate between fetch and dispatch so private-cache and ROM PCs do not repeatedly probe the SDRAM-only JIT.
- The CPU keeps MAC.L and MAC.W where its timing differs. There is no idle detector, so the idle yields are disabled.
- Communication-register reads with no side effects may continue within the same budget through adapter-approved read helpers (the `jitRegisterReads` parameter, default true). FIFO, control, video and PWM accesses keep CPU exits. Such a return does not itself switch CPUs, so shared-RAM communication still depends on the quantum.
- On-chip ticks follow each native batch or CPU instruction. Debugger steps still execute one instruction.
- Interpreter and JIT instances can exchange checkpoints with the same CPU quantum.
- Validate game progression, rendering and continuous audio when changing the quantum.

## Synthetic benchmark

`tool/sh2_jit_bench.dart` creates an in-memory SH-2 program and compares interpretation with native execution without external media. It checks CPU state, clocks and work RAM outside the timing. `tool/jit_compile_bench.dart` measures the compile path. Synthetic instruction throughput does not predict whole-core or GUI throughput.

## Frame comparison

`core_headless bench` compares CPU interpretation and native execution through the frame runner. Build it from the core package with `dart build cli -t tool/core_headless.dart -o /tmp/core-headless` and keep `bundle/lib` beside `bundle/bin`. Run `bundle/bin/core_headless bench <core> <media...> --frame-runner --jit off` and the corresponding `--jit on` command with matching input, warmup, frame intervals and lock options.

The timer includes frame execution and `imageBuffer()`. Disc settling, input updates and image encoding are outside it, while audio callback work runs inside core execution. Process CPU time and elapsed time have different denominators. Headless frame throughput does not predict the displayed GUI FPS. The tool options are in the [core tools](../../fnesemu_core/tool/README.md#benchmarks).
