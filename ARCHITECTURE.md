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
- Cores receive discs through `CdromDrive` (`core/cdrom_drive.dart`): tray
  state, TOC, and synchronous polling of raw sectors by LBA. They do not know
  CUE/ISO/BIN or file pickers. The CD cores use it through the helpers of
  `core/cdrom.dart` (not exported): reads by absolute sector, sector constants
  and MSF, the disc identification helpers, and `DiscSwapWatcher`.
- Disc images receive files through their own `DiscFile` interface
  (relative path, self-contained reads) in `filesystem_api.dart`; a directory
  is an `Iterable<DiscFile>`. The format-independent sector and TOC contract
  is in `image_api.dart`; `DiscImage.parse(files, file)` returns an image and
  its referenced files.
- Only the app connects the packages: `lib/gui/picked_disc.dart` adapts picker
  files; `async_cdrom_drive.dart` adapts disc images with read-ahead and caching;
  `rom_scanner.dart` excludes CUE-referenced files from the ROM list.
- Headless tools supply their own adapters: `tool/local_disc.dart` and
  `tool/cdrom_drive.dart` inside the core package.

## Core layers

The public entry point is `packages/fnesemu_core/lib/app_api.dart`.
The existing `core/` and `util/` trees live unchanged under `lib/src/`;
GUI/App never imports `src/` directly. Diagnostic app tools may inspect
internals when testing chips with Flutter or audio output. Within `lib/src/`:

- Before implementing core-package code, read the extensions in `util/` and
  use them where they improve readability.
- **Modules** (`core/<system>/`) use shared core contracts, components, and
  utilities. They never import another module.
- **Shared contracts and helpers** (`core/*.dart`) never import modules or
  components. `CoreFactory` accesses modules through the generated registry.
- **Components** (`core/components/<chip>/`) depend only on their own files
  and `util/`. They communicate through interfaces such as a CPU bus.
  Move a chip here when another core needs it; intentional divergent copies
  must be documented (e.g. SS and 32X SH-2).
- **Registry** (`core/installed_core_modules.dart`) alone imports module
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
