# Architecture

Each part owns its domain and depends only on the interfaces below.

## Parts and dependencies

| Part | Location | Responsibility | Dependencies |
|---|---|---|---|
| Cores | `packages/fnesemu_core` | Emulation, ROM/disc identification, BIOS setup | Dart SDK only; no Flutter or `dart:io` |
| Disc images | `packages/cdrom_image` | CUE/ISO/BIN/CHD parsing, referenced files, TOC, sector reads | Dart SDK and `archive` (deflate, LZMA, zstd); no `dart:io` |
| File picker | `packages/mp_bigfile_picker` | Platform file/directory selection and random reads | Flutter and platform APIs; no app or core knowledge |
| App | `lib/` | GUI, storage, adapters connecting the packages | All three packages |
| Core harnesses | `packages/fnesemu_core/tool` | Headless runs, benchmarks, CPU tests | Cores, `dart:io`, disc images as a dev dependency; never the app |
| App tools | `tool/` | Tools requiring Flutter or audio output | App dependencies |

## Package boundaries

- App/GUI and app tests access cores through `app_api.dart` only. They never import concrete cores or encode core-specific IDs
  or formats. Identification and BIOS interpretation belong to each core.
- Cores receive discs through `CdromDrive` (`src/cdrom_drive.dart`): tray
  state, queued tray open/close and disc ready/error events, TOC, and
  synchronous polling of raw sectors by LBA. They do not know
  CUE/ISO/BIN or file pickers. The CD cores use it through the helpers of
  `src/cdrom.dart` (not exported): reads by absolute sector, sector constants
  and MSF, and disc identification helpers. Each core consumes one drive
  event per execution step; attaching/resetting discards past events.
- Disc images receive files through their own `DiscFile` interface
  (relative path, self-contained reads) in `filesystem_api.dart`; a directory
  is an `Iterable<DiscFile>`. The format-independent sector and TOC contract
  is in `image_api.dart`; `DiscImage.parse(file, files: files)` returns an image and
  its referenced files.
- Only the app connects the packages: `lib/gui/picked_disc.dart` adapts picker
  files; `async_cdrom_drive.dart` adapts disc images with read-ahead and caching;
  `rom_scanner.dart` excludes CUE-referenced files from the ROM list.
- Headless tools supply their own adapters: `tool/local_disc.dart` and
  `tool/cdrom_drive.dart` inside the core package.

## Core layers

`Core` provides empty defaults for optional features; required timing,
execution, ROM loading and reset operations throw `UnimplementedError`.
A plain `Core()` represents the unloaded state and has no CPU metadata.
`Core.runFrame()` defaults to repeated `exec(false)` calls; cores may override
it with a faster implementation. Debug execution uses `exec()` directly.

The public entry point is `packages/fnesemu_core/lib/app_api.dart`.
`core_controller.dart`, `core_factory.dart` and `debugger.dart` live directly
under `lib/`. Cores provide debugging data through `src/core_debug.dart`; `Core` extends
`CoreDebug`, and `Debugger` depends only on this inspection contract.
Apps invoke `Debugger.pause/run/step/next/stepOut/runToLine/runToFrame` and settings
methods. `DebugState` and its stream are immutable display snapshots; apps
never write execution modes or stop conditions. Temporary stops are owned by
Debugger and kept separate from persistent breakpoints. Controller connects
execution callbacks and invokes the debugger's instruction/stop hooks.
Video inspection uses core-owned layer/pattern descriptors in `src/video_debug.dart`.
The debugger captures the selected view on stops and explicit settings changes;
normal frame notifications reuse snapshots unless live rendering is enabled.
Only the selected video tab is captured. Live capture runs at most 10 Hz and
waits longer after expensive captures to leave time for input and emulation.
Layer roles come from core metadata; pattern layout groups native tiles into
8/16/32-pixel blocks with a maximum atlas width of 512 pixels. GUI handles layout, overlays and
magnification without hardware IDs or decoding VRAM. Shared debug-only geometry
and pixel helpers add no work to normal render loops.

Tracing snapshots native instruction flow before execution and commits it after
the selected CPU runs. Calls, returns and delayed branches control indentation;
interrupt returns are distinct from normal returns. A new capture clears both
text and call context. Copy flushes deferred loop output before copying. Turning
logging or the debug view off discards all trace buffers and detection context.
Repeat suppression confirms a complete consecutive cycle and compares each
instruction with the same phase of the previous cycle, including its executed
next PC and call context. `LoopDetector` owns immutable snapshots, bounded history
with monotonic indices (2048 instructions by default), and a PC index that expires
with the history. Search examines at most eight recent occurrences of the current
PC; limiting candidates can miss a repeat but never discards unconfirmed output.
Once a period is confirmed, the PC index is released and history retains only one
cycle for comparison. Exact mode compares structured and displayed register state;
the debugger explicitly uses path mode, which reports state changes. Cores may
supply a stable instruction key when disassembly includes runtime annotations.
The first cycle is ordinary output. Completed repeated cycles are omitted, and
only the unfinished exit cycle is returned with the statistics; its mismatching
instruction is ordinary output. `add` and `finish` return detection state, ready
snapshots and optional loop-end snapshots/statistics; `reset` discards capture.
Tracer owns call context and output formatting. Stop and Copy close the comparison
segment while preserving call and delay-slot context.
Disassembly uses `address: code mnemonic operands`, with a fixed code-column
width supplied by each CPU's native decoder, including extension words.
Trace appends a single-line register dump and `cl:clock f:frame s:scanline`.
Only the shared formatter owns separators; native decoders own instruction
length, code units and address width.

Internal registration and application support (tracing, FPS
counting and stream notifications) live in `src/internal/`.
Shared contracts and helpers live directly under `lib/src/`;
`src/core/` contains only individual cores, `src/components/` shared CPU
components, and `src/util/` general utilities.
GUI/App never imports `src/` directly. Diagnostic app tools may inspect
internals when testing chips with Flutter or audio output. Within `lib/src/`:

- Before implementing core-package code, read the extensions in `util/` and
  use them where they improve readability.
- **Modules** (`core/<system>/`) use shared core contracts, components, and
  utilities. They never import another module.
- **Shared contracts and helpers** (`src/*.dart`) never import modules,
  components or `internal/`. Individual cores never import `internal/` or
  public entry points. Controller, factory and debugger may use internal processing.
- **Components** (`components/<chip>/`) depend only on their own files
  and `util/`. They communicate through interfaces such as a CPU bus.
  Move a chip here when another core needs it; intentional divergent copies
  must be documented (e.g. SS and 32X SH-2).
- **Internal processing** (`internal/`) depends on contracts and utilities;
  it never imports concrete cores except through the generated registry.
- **Registry** (`internal/core_registry_generated.dart`) alone imports module
  entry points. Each `module.dart` declares systems, BIOS setup, and media
  identification; the factory enumerates and delegates.

After adding or removing a core module, regenerate the registry:

```sh
cd packages/fnesemu_core && dart run tool/generate_core_registry.dart
```

The app must build and run with any core omitted, including an empty registry,
without changes to App/GUI.

## Tests

- Core and harness tests: `packages/fnesemu_core/test` — `dart test`.
- Disc image tests: `packages/cdrom_image/test` — `dart test` on in-memory files.
- GUI and adapter tests: `test/` — `flutter test`. Concrete-core behavior tests
  belong in the core package.

`make test` runs all three suites, as does CI. Boundary rules are checked by
`test/gui/core_boundary_test.dart` and
`packages/fnesemu_core/test/core/core_layers_test.dart`.
Routine regression checks use `make regress` (55-second budget).
Real-ROM screenshot/audio checks are opt-in via `make regress-full`;
see `docs/TEST.md`.
