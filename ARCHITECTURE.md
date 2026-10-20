# Architecture

Each package owns its domain and communicates through the interfaces below.

## Packages

| Part | Location | Responsibility | Dependencies |
|---|---|---|---|
| Cores | `packages/fnesemu_core` | Emulation, media identification, BIOS setup | Dart SDK, recompiler; no Flutter or `dart:io` |
| Recompiler | `packages/mp_jit_recompiler` | Block IR, native code generation, and the reference IR interpreter | Dart SDK (`dart:ffi` on native hosts); no Flutter, `dart:io` or core dependencies |
| Disc images | `packages/cdrom_image` | CUE/ISO/BIN/CHD parsing and sector reads | Dart SDK, `archive`; no `dart:io` |
| Pixel images | `packages/mp_pixel_image` | `ui.Image` creation from 32-bit RGBA pixel buffers, fast on every platform | Flutter; `dart:js_interop` on the Web only; no app/core dependencies |
| File picker | `packages/mp_bigfile_picker` | Platform file/directory selection and random reads | Flutter and platform APIs; no app/core dependencies |
| App | `lib/` | GUI, storage, and package adapters | All packages |
| Core tools | `packages/fnesemu_core/tool` | Headless runs, benchmarks, and CPU tests | Cores, `dart:io`, disc images; never the app |
| App tools | `tool/` | Flutter-dependent tools and audio output | App dependencies |

## Package interfaces

- The app and its tests access cores only through `app_api.dart`; core IDs, formats, media identification, and BIOS interpretation remain core-owned.
- Cores return frames and debug images as `ImageBuffer`, a `Uint32List` with one RGBA pixel per element; the app creates `ui.Image`s from them only through `decodePixelImage` in `mp_pixel_image`.
- Cores that recompile guest code translate it to `IrBlock`s and run them through `JitRuntime` (`mp_jit_recompiler`). The runtime allocates the guest registers and memory that blocks access, and the core's interpreter uses the same buffers, so neither side copies state. Recompilation is opt-in per core and falls back to the interpreter where the host has no native backend.
- Cores access discs through `CdromDrive` (`src/cdrom_drive.dart`), which exposes tray state/events, TOC, and synchronous raw-sector reads by LBA; cores do not depend on disc formats or picker APIs.
- Disc images accept files through `DiscFile` (`filesystem_api.dart`) and expose format-independent TOC and sector access through `image_api.dart`; `DiscImage.parse` resolves referenced files from the supplied directory.
- The app connects packages through `picked_disc.dart`, `async_cdrom_drive.dart`, and `rom_scanner.dart`; headless tools provide their own adapters.

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
