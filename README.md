# fnesemu

A Cross-Platform NES/PCE/MD/PS1/SS/GB/GBA/SNES/N64/SMS/WS Emulator Built with Flutter

This project is experimental.

- Runs on all Flutter-supported platforms: Android, iOS, macOS, Linux, Windows, and Web
- Targets 60 fps for NES and PCE on i5-8250 (web), MD on i5-8250 (Windows), PS1 on i7-13700HX (Windows)

# How to use 

1. Visit the [stable version](https://reki2000.github.io/fnesemu/) or the [develop version](https://reki2000.github.io/fnesemu/develop/)
1. Open the menu, choose 'CD / ROM', and select a ROM directory
1. Choose a ROM in the list to start emulation. The menu button or Escape pauses/resumes it

## BIOS 

- Set the BIOS of each system from the 'Core setup' menu (the gear icon).
- The files are saved on your browser's IndexDB and used each time the system starts


## Joypad-Keyboard assignment

| key | Z | X | C | A | S | D | Q | W | E | R | arrows |
|-----|---|---|---|---|---|---|---|---|---|---|--------|
| NES | B | A |  | Select | Start |  |  |  |  |  | up / down / left / right |
| PCE | II | I |  | Select | Run |  |  |  |  |  | up / down / left / right |
| MD | A | B | C | X | Y | Z | Mode | | Start |  | up / down / left / right |
| PS1 | # | x | o | Select | ^ |  | L1 | Start | R1 |  | up / down / left / right |
| GB | B | A |  | Select | Start |  |  |  |  |  | up / down / left / right |
| GBA | A | B | L | Select | Start |  | R |  |  |  | up / down / left / right |
| SNES | Select |  | Start | Y | B | A | L | X | R |  | up / down / left / right |
| SS | A | B | C | L | Start |  | X | Y | Z | R | up / down / left / right |
| N64 | B | A | Z | C-left | C-down | C-right | L | C-up | R | Start | up / down / left / right |
| SMS | 1 | 2 |  |  | Pause (Start on the portable console) |  |  |  |  |  | up / down / left / right |
| WS | B | A | Y2 | Y1 | Start |  | Y4 | Y3 |  |  | X1 / X3 / X4 / X2 |

# How to develop

Clone with the package submodules:

```sh
git clone --recurse-submodules https://github.com/reki2000/fnesemu.git
```

For an existing checkout, initialize them with `git submodule update --init --recursive`.

### Packages

`packages/cdrom_image` and `packages/mp_bigfile_picker` are submodules from
separate repositories, used as local dependencies. Switch a package to `main`
before editing it:

```sh
git -C packages/cdrom_image switch main
git -C packages/mp_bigfile_picker switch main
```

Commit and push package changes in that repository, then commit its updated
submodule reference here. Restore the recorded revisions with
`git submodule update --init --recursive`.

See [ARCHITECTURE.md](ARCHITECTURE.md) for package responsibilities and
dependency rules.

### Adding or removing a core

After changing core modules, regenerate the registration list:

```sh
cd packages/fnesemu_core && dart run tool/generate_core_registry.dart
```

## Binary builds and releases

The **Build binaries** GitHub Actions workflow tests PRs and builds Web; merges to `main` and manual runs build all supported platforms. Download its artifacts for internal verification, then tag that exact successful full-build commit to publish the same binaries to GitHub Releases without rebuilding. See [BINARY-DISTRIBUTION.md](BINARY-DISTRIBUTION.md) for the release process and optional signing secrets.

# Tests

| Kind | Setup | Command | Needs |
|---|---|---|---|
| Unit tests | | `make test` | Dart and Flutter |
| CPU tests | `make test-cpu-setup` | `make test-cpu` | Python 3.11+, Git |
| ROM harness tests | `make test-roms-setup` | `make test-roms` | Python 3.11+, Git, Pillow, numpy (Docker for ROMs built from source) |
| Quick regression | | `make regress` | Dart and Flutter |

The setup targets fetch (or build) public test data into `.build/` directories, which Git ignores. Run them once, and again after the pinned data changes. The tests do not run the setup, and skip a test whose data is missing.

## Unit tests

Unit tests use synthesized ROMs and in-memory discs, so they need no ROM files. Core tests are in `packages/fnesemu_core/test/core/<core>/`, one file per component.

```sh
make test                                                # all packages and the app
cd packages/fnesemu_core && dart test                    # the cores only
cd packages/fnesemu_core && dart test test/core/nes/     # one core
```

## CPU tests

The CPU cores are checked instruction by instruction against public test data. Each test has a `setup.py` in `packages/fnesemu_core/test/cpu/<name>/` that fetches the data, pinned by commit or sha256; `make test-cpu-setup` runs them all.

| Target | CPU | Data |
|---|---|---|
| `make test-6502` | 6502 (NES) | `nestest.nes` and its log from [nes-test-roms](https://github.com/christopherpow/nes-test-roms) |
| `make test-z80` | Z80 | `tests.in` and `tests.expected` from the [Fuse](https://fuse-emulator.sourceforge.net/) 1.6.0 release |
| `make test-m68` | 68000 | [SingleStepTests/680x0](https://github.com/SingleStepTests/680x0) (`68000/v1`, about 200MB; skips the ASR cases that disagree with hardware) |
| `make test-r3000` | R3000 (PS1) | [SingleStepTests/r3000](https://github.com/SingleStepTests/r3000) (`v1`; registers, delay slots and memory writes, not cycles; skips misaligned loads and stores, whose address errors are not emulated) |
| `make test-gte` | PS1 GTE | `gte/test-all/tests.c` from [ps1-tests](https://github.com/JaCzekanski/ps1-tests) |
| `make test-huc6280` | HuC6280 (PCE) | [SingleStepTests/huc6280](https://github.com/SingleStepTests/huc6280) (`v1`; registers, MPRs and memory, not cycles; skips ST0/ST1/ST2, which write the VDC) |

`make test-cpu` runs all of them.

## ROM harness tests

Public test ROMs run in the headless harness (`packages/fnesemu_core/tool/core_harness.dart`), and their screens are compared with expected images.

```
packages/fnesemu_core/test/roms/<core>/
  roms.toml            the cases of the core
  <dir>/setup.py       fetches (or builds) the ROM and its upstream data into <dir>/.build/
  <dir>/expected/      the expected images kept in the repository
```

- A check compares a frame with an image under `expected/` (the current behavior) or with a reference image that the ROM's project publishes (under `.build/`).
- A case whose ROM reports a failure records the reason in `known_failure`. Its output must still match `expected/`, so a change of behavior is detected.
- ROMs that have no prebuilt release are built in a Docker image (`packages/fnesemu_core/test/docker/Dockerfile`) when the tools are not installed.

```sh
make test-roms-setup                             # fetch or build the ROMs (python3 scripts/romtest.py setup [target...])
make test-roms                                   # all cases
python3 scripts/romtest.py run nes -j 4          # one core, 4 cases in parallel
python3 scripts/romtest.py run gb/dmg-acid2      # one case
python3 scripts/romtest.py run nes --update      # record the outputs as expected/ after checking them
python3 scripts/romtest.py list                  # the cases
python3 scripts/romtest.py lint                  # paths stay in the tree, expected/ stays small
```

Covered cores: NES, PCE, SNES, MD, SMS, GB, GBA (with a replacement BIOS), N64, WS and PS1 (test EXEs on OpenBIOS). Cases marked `slow = true` (minutes long) run only with `--slow`.

## Quick regression

`make regress` runs the unit test suites of the disc image package, the cores and the app within a total time budget of 55 seconds, and fails when the budget runs out.
