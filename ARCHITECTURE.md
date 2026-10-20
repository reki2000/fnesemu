# Architecture

Each package owns its domain and communicates through the interfaces below.

## Packages

| Part | Location | Responsibility | Dependencies |
|---|---|---|---|
| Cores | `packages/fnesemu_core` | Emulation, media identification, BIOS setup | Dart SDK, recompiler; no Flutter or `dart:io` |
| Recompiler | `packages/mp_jit_recompiler` | Block IR, x86-64/Wasm code generation, and the reference IR interpreter | Dart SDK (`dart:ffi` on native hosts, `dart:js_interop` on the Web); no Flutter, `dart:io` or core dependencies |
| Disc images | `packages/cdrom_image` | CUE/ISO/BIN/CHD parsing and sector reads | Dart SDK, `archive`; no `dart:io` |
| Pixel images | `packages/mp_pixel_image` | `ui.Image` creation from 32-bit RGBA pixel buffers, fast on every platform | Flutter; `dart:js_interop` on the Web only; no app/core dependencies |
| File picker | `packages/mp_bigfile_picker` | Platform file/directory selection and random reads | Flutter and platform APIs; no app/core dependencies |
| App | `lib/` | GUI, storage, and package adapters | All packages |
| Core tools | `packages/fnesemu_core/tool` | Headless runs, benchmarks, and CPU tests | Cores, `dart:io`, disc images; never the app |
| App tools | `tool/` | Flutter-dependent tools and audio output | App dependencies |

## Package interfaces

- The app and its tests access cores only through `app_api.dart`; core IDs, formats, media identification, and BIOS interpretation remain core-owned.
- Cores return frames and debug images as `ImageBuffer`, a `Uint32List` with one RGBA pixel per element; the app creates `ui.Image`s from them only through `decodePixelImage` in `mp_pixel_image`.
- Cores that recompile guest code translate it to `IrBlock`s and run them through `JitRuntime` (`mp_jit_recompiler`). The runtime allocates the guest registers and memory that blocks access, and the core's interpreter uses the same buffers, so neither side copies state. PS1 enables recompilation by default on supported hosts; `JIT=false` or `PS_TRACE=true` selects the interpreter. Hosts without an available compiled backend fall back to the interpreter.
- Cores access discs through `CdromDrive` (`src/cdrom_drive.dart`), which exposes tray state/events, TOC, and synchronous raw-sector reads by LBA; cores do not depend on disc formats or picker APIs.
- Disc images accept files through `DiscFile` (`filesystem_api.dart`) and expose format-independent TOC and sector access through `image_api.dart`; `DiscImage.parse` resolves referenced files from the supplied directory.
- The app connects packages through `picked_disc.dart`, `async_cdrom_drive.dart`, and `rom_scanner.dart`; headless tools provide their own adapters.

## JIT correctness and performance notes

### PS1 state and memory boundaries

- Compiled blocks and the interpreter share registers, RAM, ROM, and scratchpad buffers. Keep ordinary RAM and valid scratchpad loads/stores in generated code; exit before device accesses, exceptions, cache isolation, or writes to protected code pages so the interpreter can execute the instruction with synchronized CPU state.
- A stale interpreter branch flag caused the test-game divergence investigated in October 2026. After compiled instructions finish, clear `inBranchDelay` and `inBranchTaken` along with synchronizing PC, load-delay state, HI/LO, and elapsed clocks. Clear those flags only when compiled execution spent clocks: an exit before its first instruction must preserve a branch left by the interpreter. Forcing subsequent loads through the interpreter hid this bug and unnecessarily penalized memory access.
- Default PS1 RAM mapping mirrors 2MiB over the first 8MiB. The earlier 128MiB read fast path incorrectly treated unmapped space as RAM. The bus and JIT must agree on read/write ranges and every alias used for code-page protection and invalidation.
- Scratchpad is exactly 1KiB at physical `0x1f800000..0x1f8003ff`, accessible through KUSEG and KSEG0 while enabled. Neither the following 3KiB nor the KSEG1 alias is scratchpad. PS1 uses `addrMask: 0x7fffffff` and explicitly maps uncached RAM/ROM aliases so address masking cannot accidentally expose scratchpad through KSEG1. Synchronize scratchpad mappings after interpreted cache-control changes before entering another compiled block.
- Guest mapping granularity is configurable through `pageShift`; PS1 uses 10 for 1KiB pages, while the runtime default and host allocation page size remain 4KiB. Code-page protection, aliases, native/Wasm page lookup, and the reference executor must use the guest granularity consistently.
- Smaller pages and the wider address mask increase dense page-table memory: PS1's native read/write pointer tables alone occupy 32MiB. A sparse `Map` metadata experiment reduced memory but regressed native speed and was discarded. Measure both memory and execution time before changing this representation again.
- MFC0 can call the existing COP0 read helper from generated code, preserving the normal load delay and branch-slot behavior. COP0 writes and commands still use the interpreter. Restrict BIOS-hook exits to the actual hook addresses rather than interpreting the entire low vector area.

### Scheduling experiments

- Retain the existing fixed timer/serial/CD-ROM polling of 100/100/200 CPU clocks. These are emulator scheduling choices, not PS1 hardware requirements. The current CPU model charges two clocks per instruction, and the last JIT block can cross a device deadline; it is not cycle accurate.
- Timer updates must count all target/overflow events crossed by a batch, preserve toggle parity, and retain one-shot behavior. Increasing polling intervals exposed event loss in the old single-hit implementation. Correct batched updates are necessary even with fixed polling and are tested independently of the scheduler.
- Polling all three devices at 300 clocks changed test-game menu progression, so its apparent FPS improvement was not a valid comparison of equivalent work. Do not adopt a larger interval based only on throughput.
- An event-driven scheduler with strict block budgets made JIT/interpreter registers, RAM, scratchpad, image histories, and audio hashes agree through frame 2400 of the test game. It did not improve throughput over the fixed-period JIT control and was approximately 1-5% slower in the measured scenes. Its scheduler, register-access synchronization, and strict-budget machinery were discarded because the demonstrated benefit did not justify the added complexity. The independent timer event-counting fix remains.

### Measurement and expected speedup

- Compare variants within one executable where possible, rotate timed batches, warm up compilation and disc caches, and use the same inputs and emulated frames. Exclude screenshots/state-file encoding from timed intervals. Native Linux headless FPS and browser/Wasm FPS are different measurements and must not be compared directly.
- A matching screenshot alone does not establish correct execution. Check registers, pending loads and branch state, IRQ EPC/BD, RAM/scratchpad boundaries, self-modifying code aliases, image/audio histories, and actual game progression. Fixed polling and block overshoot can still produce timing differences between the retained JIT and interpreter; the complete-state agreement above belongs to the discarded scheduling experiment.
- Use an AOT build to explain AOT performance. Sparse stopwatch measurements of short CPU batches were unstable and sometimes yielded impossible estimates; nested or sampled stopwatch durations must not be added or extrapolated into whole-program percentages. A Dart VM profile is useful for diagnosis but is not an AOT measurement.
- The October 2026 Linux x64 AOT profile used disc 1 of a test game with the interpreter and fixed 100/100/200 polling. It sampled Linux user-space CPU time at 0.5ms and 1ms, resolved AOT call chains and inlined functions with separate DWARF information, and counted only samples under `Ps._run`. Harness work, image/state captures, and drive settling were excluded. Both intervals produced matching emulated states and no lost sampling records.

| AOT scene | Timed frames after warm-up | Core samples across both runs | R3000.step including callees |
| --- | --- | ---: | ---: |
| Title screen | 901-1200 | 11,575 | 43.1% |
| Menu screen | 2101-2400 | 9,169 | 42.7% |

- These are scene-specific estimates. In the first AOT run, SPU work was approximately 24%/15% and GPU work 8%/18% at the title/menu. With a CPU fraction near 43%, doubling only CPU execution predicts about `1 / (0.57 + 0.43 / 2) = 1.27x` overall; eliminating that work entirely would cap this simplified model near 1.75x. These estimates do not measure the JIT's internal speedup or establish performance in other scenes.

## Core API and debugging

- `packages/fnesemu_core/lib/app_api.dart` is the public core API; controllers, factories, and debuggers live directly under `lib/`, and cores expose inspection data through `CoreDebug` in `src/core_debug.dart`.
- `Core` supplies defaults for optional features, throws for required operations that are not implemented, and represents the unloaded state when instantiated directly; `runFrame()` defaults to repeated `exec(false)` calls.
- Apps control execution through `Debugger` methods and consume immutable `DebugState` snapshots; temporary stops belong to the debugger and remain separate from persistent breakpoints.
- Video debug descriptors and capture are core-owned; the GUI handles layout and overlays without hardware IDs or VRAM decoding, and normal frame updates reuse snapshots unless live rendering is enabled.
- Tracing owns call context, formatting, and repeat suppression; `LoopDetector` stores bounded immutable history (2048 instructions by default), checks at most eight prior occurrences per PC, and preserves unconfirmed output when a repeat is not detected.
- Trace comparison supports exact state and path-change modes; completed repeat cycles are suppressed, while unfinished exit instructions and loop statistics remain available to the debugger.
- Native decoders define instruction length, address width, and code units; the shared formatter defines separators and appends register, clock, frame, and scanline state.

## Core package layers

- `src/core/<system>/` contains independent core modules; modules use shared contracts, components, and utilities, and never import other modules.
- `src/*.dart` contains shared contracts and helpers; these files do not import modules, components, or `internal/`, and individual cores do not import `internal/` or public entry points.
- `src/components/<chip>/` contains reusable hardware components that depend only on their own files and `util/`; document intentional divergent copies.
- `src/internal/` contains registration and app support such as tracing, FPS counting, and stream notifications; it depends on contracts and utilities, and accesses modules only through the generated registry.
- `src/internal/core_registry_generated.dart` is the only file that imports module entry points; each `module.dart` declares systems, BIOS setup, and media identification for the factory.
- Before implementing a core, inspect and understand the existing methods and extensions under `packages/fnesemu_core/lib/src/util/`, then reuse them where appropriate.
- After adding or removing a core module, run `cd packages/fnesemu_core && dart run tool/generate_core_registry.dart`.
- The app must build and run with any core omitted, including an empty registry, without App/GUI changes.

## Tests

- Run core and harness tests with `cd packages/fnesemu_core && dart test`, recompiler tests with `cd packages/mp_jit_recompiler && dart test`, disc-image tests with `cd packages/cdrom_image && dart test`, pixel-image tests with `cd packages/mp_pixel_image && flutter test`, and GUI tests with `flutter test`.
- `make test` runs all five suites; boundary rules are checked by `test/gui/core_boundary_test.dart` and `packages/fnesemu_core/test/core/core_layers_test.dart`.
- Use `make regress` for routine regression checks (55-second budget) and `make regress-full` for opt-in real-ROM screenshot/audio comparisons; see `docs/TEST.md`.
