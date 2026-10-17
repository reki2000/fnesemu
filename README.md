# fnesemu

A Cross-Platform NES/PCE/MD/PS1/SS/GB/GBA/SNES/N64 Emulator Built with Flutter

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

| key | Z | X | C | A | S | Q | W | E | R | D | arrows |
|-----|---|---|---|---|---|---|---|---|---|---|--------|
| NES | B | A |  | Select | Start |  |  |  |  |  | up / down / left / right |
| PCE | II | I |  | Select | Run |  |  |  |  |  | up / down / left / right |
| MD | A | B | C | X | Y | Mode | | Start |  | Z | up / down / left / right |
| PS1 | # | x | o | Select | ^ | L1 | Start | R1 |  |  | up / down / left / right |
| GB | B | A |  | Select | Start |  |  |  |  |  | up / down / left / right |
| GBA | A | B | L | Select | Start | R |  |  |  |  | up / down / left / right |
| SNES | Select |  | Start | Y | B | L | X | R |  | A | up / down / left / right |
| SS | A | B | C | L | Start | X | Y | Z | R |  | up / down / left / right |
| N64 | B | A | Z | C-left | C-down | L | C-up | R | Start | C-right | up / down / left / right |

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

### PS1 recompiler

Build or run with `--dart-define=JIT=true` to run the PS1 CPU through `packages/mp_jit_recompiler`, which translates R3000 code to x86-64 on Linux, Android and Windows x64 hosts, or to WebAssembly on the Web. For example, `flutter build web --wasm --dart-define=JIT=true` enables the Web backend. WebAssembly is also used when the app itself is compiled to JavaScript. Other hosts, or browser policies that prohibit compiling Wasm, keep the interpreter. Linux and Windows x64 CI exercise the native backend, and browser tests exercise Wasm. `packages/fnesemu_core/tool/ps_jit_bench.dart` compares the interpreter with the recompiler.

Device accesses and writes to translated RAM pages return to the interpreter before the instruction executes, preserving device clocks, interrupts and self-modifying code. Ordinary RAM accesses remain native. A debugger step that stops at a branch delay slot completes that slot before entering compiled code.

### Adding or removing a core

After changing core modules, regenerate the registration list:

```sh
cd packages/fnesemu_core && dart run tool/generate_core_registry.dart
```

## To test 6502 emulation

The 6502 emulator core used in fnesemu has been validated using the Nestest ROM by comparing register and flag values against the Nestest log.

To test the 6502 emulation, run the following command:

```
$ curl https://raw.githubusercontent.com/christopherpow/nes-test-roms/master/other/nestest.log > assets/nestest.log
$ curl https://raw.githubusercontent.com/christopherpow/nes-test-roms/master/other/nestest.nes > assets/rom/nestest.nes
$ make test-6502
running fnesemu cpu test...
loading: File: 'assets/rom/nestest.nes'
cpu test completed successfully.
```

## To test z80 emulation

get `tests.in` and `tests.expected` from [Fuse](https://fuse-emulator.sourceforge.net/), store these file to `assets`

```
$ make test-z80
```

## To test M68000 emulation

```
$ cd assets && git clone https://github.com/SingleStepTests/680x0.git
$ cd ..
$ make test-m68
```

## To Test R3000 emulation

```
$ cd assets && git clone https://github.com/mshockwave/MIPS-R3000-CPU-Simulator.git
$ cd ..
$ make test-r3000
```

## To Test PS1 GTE emulation

```
$ cd assets && git clone https://github.com/JaCzekanski/ps1-tests.git
$ cd ..
$ make test-gte 
```

## Binary builds and releases

The **Build binaries** GitHub Actions workflow tests PRs and builds Web; merges to `main` and manual runs build all supported platforms. Download its artifacts for internal verification, then tag that exact successful full-build commit to publish the same binaries to GitHub Releases without rebuilding. See [BINARY-DISTRIBUTION.md](BINARY-DISTRIBUTION.md) for the release process and optional signing secrets.
