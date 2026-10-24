# Architecture

Each package owns its domain and communicates through the interfaces below.

## Packages

| Part | Location | Responsibility | Dependencies |
|---|---|---|---|
| Cores | `packages/fnesemu_core` | Emulation, media identification, BIOS setup | Dart SDK, recompiler; no Flutter or `dart:io` |
| Recompiler | `packages/mp_jit_recompiler` | Block IR, x86-64/ARM64/Wasm code generation, and the reference IR interpreter | Dart SDK, native C memory-publication helper (`dart:ffi`), Web interop; build hooks use a C toolchain; no Flutter, runtime `dart:io` or core dependencies |
| Disc images | `packages/cdrom_image` | CUE/ISO/BIN/CHD parsing and sector reads | Dart SDK, `archive`; no `dart:io` |
| Pixel images | `packages/mp_pixel_image` | `ui.Image` creation from 32-bit RGBA pixel buffers, fast on every platform | Flutter; `dart:js_interop` on the Web only; no app/core dependencies |
| File picker | `packages/mp_bigfile_picker` | Platform file/directory selection and random reads | Flutter and platform APIs; no app/core dependencies |
| App | `lib/` | GUI, storage, and package adapters | All packages |
| Core tools | `packages/fnesemu_core/tool` | Headless runs, benchmarks, and CPU tests | Cores, `dart:io`, disc images; never the app |
| App tools | `tool/` | Flutter-dependent tools and audio output | App dependencies |

## Package interfaces

- The app and its tests access cores only through `app_api.dart`; core IDs, formats, media identification, and BIOS interpretation remain core-owned.
- Cores return frames and debug images as `ImageBuffer`, a `Uint32List` with one RGBA pixel per element; the app creates `ui.Image`s from them only through `decodePixelImage` in `mp_pixel_image`.
- Cores that recompile guest code translate it to `IrBlock`s and run them through `JitRuntime` (`mp_jit_recompiler`). The runtime allocates the guest registers and memory that blocks access, and the core's interpreter uses the same buffers, so neither side copies state. PS1, N64 and 32X enable recompilation by default on supported hosts; SS retains opt-in recompilation; `JIT=false` selects the interpreter, and `PS_TRACE=true` also disables PS1 recompilation. Hosts without an available compiled backend fall back to the interpreter.
- Cores access discs through `CdromDrive` (`src/cdrom_drive.dart`), which exposes tray state/events, TOC, and synchronous raw-sector reads by LBA; cores do not depend on disc formats or picker APIs.
- Disc images accept files through `DiscFile` (`filesystem_api.dart`) and expose format-independent TOC and sector access through `image_api.dart`; `DiscImage.parse` resolves referenced files from the supplied directory.
- The app connects packages through `picked_disc.dart`, `async_cdrom_drive.dart`, and `rom_scanner.dart`; headless tools provide their own adapters.

## JIT correctness and performance notes

### Adding a recompiler frontend

| Layer | Owns |
| --- | --- |
| Shared runtime | IR/backends, host ABI, block links, mapping/invalidation mechanisms, dispatch primitives and optional counters |
| CPU frontend | Decode and instruction semantics, block shape, tags, coverage, delay slots, guarded assumptions and precise exits |
| Core adapter | Hardware memory maps/aliases, devices, budgets/deadlines, range-based event detection, CPU fallback and state synchronization |

Runtime APIs use addresses, masks, buffers, callbacks, tags and exit reasons rather than hardware-specific segments or registers. Cores use those APIs rather than modifying generated host code or native tables. The shared SH-2 frontend stays independent of core names; SS/32x differences enter through adapter policy and mappings. Establish the state/clock contract before optimizing; see the [frontend contracts](packages/mp_jit_recompiler/FRONTENDS.md) and [performance guide](packages/mp_jit_recompiler/OPTIMIZATION.md).

### PS1 state and memory boundaries

- Compiled blocks and the interpreter share registers, RAM, ROM, and scratchpad buffers. Keep ordinary RAM and valid scratchpad loads/stores in generated code; exit before device accesses, exceptions, cache isolation, or writes to protected code pages so the interpreter can execute the instruction with synchronized CPU state.
- After compiled instructions finish, clear `inBranchDelay` and `inBranchTaken` along with synchronizing PC, load-delay state, HI/LO, and elapsed clocks. Clear those flags only when compiled execution spent clocks: an exit before its first instruction must preserve a branch left by the interpreter.
- Default PS1 RAM mapping mirrors 2MiB over the first 8MiB. The earlier 128MiB read fast path incorrectly treated unmapped space as RAM. The bus and JIT must agree on read/write ranges and every alias used for code-page protection and invalidation.
- Scratchpad is exactly 1KiB at physical `0x1f800000..0x1f8003ff`, accessible through KUSEG and KSEG0 while enabled. Neither the following 3KiB nor the KSEG1 alias is scratchpad. PS1 uses `addrMask: 0x7fffffff` and explicitly maps uncached RAM/ROM aliases so address masking cannot accidentally expose scratchpad through KSEG1. Synchronize scratchpad mappings after interpreted cache-control changes before entering another compiled block.
- Guest mapping granularity is configurable through `pageShift`; PS1 uses 10 for 1KiB pages, while the runtime default and host allocation page size remain 4KiB. Code-page protection, aliases, native/Wasm page lookup, and the reference executor must use the guest granularity consistently.
- Smaller pages and the wider address mask increase dense page-table memory: PS1's native read/write pointer tables alone occupy 32MiB. A sparse `Map` metadata experiment reduced memory but regressed native speed and was discarded. Measure both memory and execution time before changing this representation again.
- MFC0 can call the existing COP0 read helper from generated code, preserving the normal load delay and branch-slot behavior. COP0 writes and commands still use the interpreter. Restrict BIOS-hook exits to the actual hook addresses rather than interpreting the entire low vector area.

### Shared code generation and native memory

- PS1, N64 and SH-2 share `JitDriver` batch budget setup, signed elapsed-clock accounting and execution totals. Driver reset clears runtime blocks and dispatch profiles and restores `JitCodeMemory` write mappings while retaining guest buffers and helper wiring. Adapters own state preparation, synchronization, fallback, interrupt handling and device deadlines; only compiled-runtime work contributes to their public JIT counters.
- A block entered with a positive budget runs to its end or a side exit, so execution may overshoot a deadline by up to one block; no frontend refunds a block that does not fit. The adapter carries the overshoot as elapsed clocks and must detect device events by range (an event passed since the previous check), never only at an exact clock.
- Every backend provides the same IR and runtime features on every platform, so cores emit one lowering without querying capabilities. A new IR feature needs the reference executor and all compiled backends.
- Host register allocation, helper ABI preservation, code publication and instruction-cache synchronization belong to the runtime; see its [API overview](packages/mp_jit_recompiler/README.md) and [ARM64 platform contracts](packages/mp_jit_recompiler/ARM64.md).
- Guest buffers may be shared between sequential CPU runtimes, with separate register contexts. Borrowers must finish and remove mappings before the allocating owner is disposed. Sharing provides neither concurrent execution nor guest-memory synchronization. The adapter protects all writable aliases and accounts for other-CPU/DMA writes.

### SH-2 state and timing boundaries

- The common integer frontend and cache live under `components/sh2/jit`; the SS and 32x CPU adapters own interrupts, delay state, on-chip ticks and fallback. This component depends on the shared recompiler API and never imports a core module. Register/control views share context storage with the CPU.
- SS uses 64-clock slices clipped at scanline boundaries and preserves master/slave ordering and on-chip ticking at the existing run boundary. Compiled blocks may overshoot the slice by one block, capture branch conditions and targets before their slots, and replay a branch when its slot must leave before effects. Unmapped/device accesses, unsupported operations and privileged SR changes use the CPU. Step execution remains instruction-based.
- SS maps ordinary BIOS/work RAM and declares the byte FTCSR read as a side-effect-free adapter-maintained context word. The adapter refreshes it before each native attempt, including after interpreted register writes; on-chip time still advances at the run boundary. Code guards cover aligned 32-bit words, deduplicated across adjacent halfword instructions. Write protection covers all work-RAM mirrors; native stores increment an idle-detection write counter. Blocks without stores yield at short backward edges that the existing idle detector examines. The frontend records the source block PC so forward calls and returns may chain without changing the detector's observation point. For a complete self-loop with no stores or callbacks, native entry/final state comparisons permit unchanged loops to return an idle result and changing loops to continue. The adapter skips remaining guest clocks for an idle result without counting them as native work. This can change scheduling phase; validate progression and media output rather than requiring identical internal histories.
- 32x alternates the CPUs in bounded 32-clock quanta, clipped to the main CPU deadline. Quantum 1 retains legacy instruction alternation for comparison; debugger steps still execute one instruction. Its optional SH2_JIT_32X path compiles SDRAM blocks and chains while budget remains, without the SS idle-detector yield. On-chip ticks follow each native batch or CPU instruction, and device accesses return before effects for CPU execution unless the adapter declares an approved read helper. The adapter permits side-effect-free communication-register reads to continue within the same budget; FIFO, control, video and PWM accesses retain CPU exits. Such a return does not itself switch CPUs; shared-RAM communication still depends on the quantum. Native JIT is enabled by default; `SH2_JIT_32X=false` selects the interpreter. Validate game progression, rendering and continuous audio when changing the quantum.
- SH-2 instruction-count limits link to the next block; unsupported instructions or unavailable fetches still return to the CPU. The 32x adapter shares one masked code-address predicate between fetch and dispatch so private-cache/ROM PCs do not repeatedly probe the SDRAM-only JIT. Configuration and memory boundaries are described in the [SH-2 guide](packages/fnesemu_core/tool/sh2_jit_bench.md).
- Cold-entry profiles and adapter-approved guarded pointer literals follow the [frontend specialization contract](packages/mp_jit_recompiler/FRONTENDS.md#guarded-specialization). They preserve code protection and live device reads; observed stability does not establish hardware semantics.

### N64 state and timing boundaries

- N64 integer blocks use native i64 values and big-endian memory operations on every runtime. Each complete 64-bit GPR occupies two adjacent context words; word results explicitly truncate and sign-extend. The CPU uses an Int64List view of the same context, and its bus uses the runtime RAM allocation. Neither registers nor memory are copied on entry or exit.
- Only aligned KSEG0/KSEG1 accesses to mapped RDRAM execute directly. TLB translation, MMIO, alignment faults, trapping arithmetic, COP0, disabled COP1, LL/SC and unsupported integer operations return to the CPU before effects. Native branch-plus-slot translation requires a supported slot. With N64_JIT_INLINE_JUMPS enabled, direct jumps may continue translation at their target until the instruction limit or an already visited address; guards cover every included code word, including non-contiguous targets. Slot exits restore the state before the branch, so the interpreter reproduces link registers, delay state and faults.
- FPU registers share a ByteData view of the context. COP1 transfers, aligned memory operations and branches run inside blocks by default; finite ADD/SUB/MUL use native floating-point IR on capable runtimes. Other arithmetic and nonfinite operands use CPU fallback. The optional helper variant calls the existing FPU implementation and is disabled by default. FR layout and CU1 availability form the block tag. FCSR is synchronized on entry/return and around helpers. Untaken likely branches skip their slots and refund unused slot cost before continuing native dispatch.
- Code words have entry guards in their raw RAM byte order. Compiled code pages lose write mappings for all direct aliases through the common physical address mask. A store to code exits before modification; DMA or host changes are detected by guards on the next block entry.
- The JIT is used by runFrame; exec retains instruction-based behavior for debugger checks. Runtime chaining continues inside compiled code while budget remains; the last block may pass a scanline, audio completion or Count/Compare deadline. Timer interrupts detect a Compare match anywhere between two polls, and the interrupt is taken at the next instruction boundary after the block.
- Compilation-size and block-end histograms are optional under N64_JIT_STATS and count installations, not dynamic execution hits. They do not instrument the native execution path. N64_JIT_BLOCK_SIZE controls the translation limit for comparison builds.

### Scheduling and polling

- Avoid waking the CPU runner at short fixed intervals solely to poll an idle device. Even a device method that immediately returns still incurs scheduler checks and CPU dispatch; a short deadline also limits interpreter batching and native block chaining. Check how often the scheduler returns and what useful work each wake performs before optimizing the device method itself.
- PS1 previously scheduled DMA every 24 CPU clocks even with no enabled, running channel. The retained optimization excludes idle DMA from both the nearest-deadline calculation and `dma.exec` calls. Active DMA keeps its existing 24-clock interval; the change removes idle polling rather than shortening transfers or increasing their interval. An early return inside `dma.exec` alone would leave the 24-clock CPU batch boundary in place.
- Removing idle polling requires a wake path. PS1 DMA control-register writes reactivate the controller, align `nextDmaClock` to the existing 24-clock phase, shorten the current interpreter batch and request a JIT yield. Preserve completion/IRQ ordering and device-readiness waits; pending work must not be treated as idle merely because it cannot transfer yet. Test activation at different phases, enabling a pending channel, and reactivation after completion against instruction-based execution.
- Retain the existing fixed timer/serial/CD-ROM polling of 100/100/200 CPU clocks. These are emulator scheduling choices, not PS1 hardware requirements. The current CPU model charges two clocks per instruction, and the last JIT block can cross a device deadline; it is not cycle accurate.
- Timer updates must count all target/overflow events crossed by a batch, preserve toggle parity, and retain one-shot behavior. Increasing polling intervals exposed event loss in the old single-hit implementation. Correct batched updates are necessary even with fixed polling and are tested independently of the scheduler.

### Performance evidence

- Acceptance rule for optimizations and scheduling changes: the game must not break. Screens, audio and internal state need not match the previous build exactly; timing shifts such as a different interrupt instruction, polling count or audio phase are acceptable. Reject a change when the game hangs or crashes, does not respond to input, progresses differently in a way a player would notice, or shows clearly broken graphics or audio. Exact equality remains required for instruction-level differential tests that compare executors running the same schedule.

The [recompiler performance guide](packages/mp_jit_recompiler/OPTIMIZATION.md) defines the improvement workflow, metric denominators and acceptance protocol. [CPU profiling guidance](packages/fnesemu_core/tool/cpu_profile_notes.md) describes sampling requirements and interpretation limits. The [headless tools](packages/fnesemu_core/tool/README.md) provide frame comparison and execution diagnostics.

## Core API and debugging

- `Core.saveState()` and `loadState()` exchange the logical emulation state at a frame boundary, written with `StateWriter` (`src/util/state.dart`, also exported by `src/state.dart`): a header with the core name, a format version and a media hash, then tagged sections per component. Components serialize their own logical state through the utility layer; the owning core saves memory, media identity and scheduling state, and restores existing buffers and callback wiring. A state is for a new instance of the same core, build configuration and media; ROM bytes, callbacks, compiled code and native tables are not part of it, and loading resets the JIT. N64, SS, cartridge MD and 32X implement it; MD CD and other cores throw `UnsupportedError`. MD and 32X identify the full cartridge ROM, and 32X also identifies its boot ROMs and CPU quantum. The SS identity is the BIOS bytes and the disc TOC, not the whole disc, and the drive sector cache is not saved, so a restored SS run may wait for sectors and diverge in timing while staying intact. Logical device state is restored into the same build; interpreter continuation must match an uninterrupted run. Cold batched JIT caches and asynchronous disc reads can change execution timing.

- `packages/fnesemu_core/lib/app_api.dart` is the public core API; controllers, factories, and debuggers live directly under `lib/`, and cores expose inspection data through `CoreDebug` in `src/core_debug.dart`.
- `Core` supplies defaults for optional features, throws for required operations that are not implemented, and represents the unloaded state when instantiated directly; `runFrame()` defaults to repeated `exec(false)` calls.
- Apps control execution through `Debugger` methods and consume immutable `DebugState` snapshots; temporary stops belong to the debugger and remain separate from persistent breakpoints.
- `CoreDebug.jitDiagnostics` enumerates available runtime descriptors in CPU order. Frontends supply instruction width, byte order and custom exit classification; the shared recompiler collects bounded native-return statistics. Diagnostics inspect mapped instruction bytes without bus reads, while tools use the same interface for every core. Descriptors optionally bind bounded execution recorders to CPU adapters; adapters own CPU dispatch, idle-clock and bus-request observation points and region labels. These CPU-side memory counts exclude direct mapped native accesses.
- JIT usage is the fraction of guest CPU clocks executed by a compiled backend, sampled over the same 500ms windows as FPS and delivered in `DebugState`. Count existing block-budget consumption when returning from compiled execution; CPU and reference IR interpretation do not contribute. It is not a host CPU-time or speedup measurement.
- Video debug descriptors and capture are core-owned; the GUI handles layout and overlays without hardware IDs or VRAM decoding, and normal frame updates reuse snapshots unless live rendering is enabled.
- Tracing owns call context, formatting, and repeat suppression; `LoopDetector` stores bounded immutable history (2048 instructions by default), checks at most eight prior occurrences per PC, and preserves unconfirmed output when a repeat is not detected.
- Trace comparison supports exact state and path-change modes; completed repeat cycles are suppressed, while unfinished exit instructions and loop statistics remain available to the debugger.
- Native decoders define instruction length, address width, and code units; the shared formatter defines separators and appends register, clock, frame, and scanline state.

## Core package layers

- `src/core/<system>/` contains independent core modules; modules use shared contracts, components, and utilities, and never import other modules.
- `src/*.dart` contains shared contracts and helpers; these files do not import modules, components, or `internal/`, and individual cores do not import `internal/` or public entry points.
- `src/components/<chip>/` contains reusable hardware components that depend only on their own files and `util/`; the shared SH-2 JIT component also depends on `mp_jit_recompiler` for IR/runtime contracts. Document intentional divergent interpreter copies.
- `src/internal/` contains registration and app support such as tracing, FPS counting, and stream notifications; it depends on contracts and utilities, and accesses modules only through the generated registry.
- `src/internal/core_registry_generated.dart` is the only file that imports module entry points; each `module.dart` declares systems, BIOS setup, and media identification for the factory.
- Before implementing a core, inspect and understand the existing methods and extensions under `packages/fnesemu_core/lib/src/util/`, then reuse them where appropriate.
- After adding or removing a core module, run `cd packages/fnesemu_core && dart run tool/generate_core_registry.dart`.
- The app must build and run with any core omitted, including an empty registry, without App/GUI changes.

## Tests

- Run core and harness tests with `cd packages/fnesemu_core && dart test`, recompiler tests with `cd packages/mp_jit_recompiler && dart test`, disc-image tests with `cd packages/cdrom_image && dart test`, pixel-image tests with `cd packages/mp_pixel_image && flutter test`, and GUI tests with `flutter test`.
- `make test` runs all five suites; boundary rules are checked by `test/gui/core_boundary_test.dart` and `packages/fnesemu_core/test/core/core_layers_test.dart`.
- Use `make regress` for routine regression checks (55-second budget) and `make regress-full` for opt-in real-ROM screenshot/audio comparisons; see `docs/TEST.md`.
