# fnesemu

A Cross-Platform NES/PCE/MD/PS1 Emulator Built with Flutter

This project is experimental.

- Achieves 60 fps: NES and PCE on i5-8250 (web), MD on i5-8250 (Windows), PS1 on i7-13700HX (Windows)
- Runs on all Flutter-supported platforms: Android, iOS, macOS, Linux, Windows, and Web
- NES (.nes)
  - SRAM backup by [shared_preference](https://pub.dev/packages/shared_preferences)
  - Supports the following iNES mapper types:
    - 0: NROM, 1: MMC1, 2: UxROM, 3: CNROM, 4: MMC3, 9/10: MMC2/4
    - 73: VRC3, 75: VRC1, 21/23/25: VRC2/4, 24|26: VRC6 (with audio), 85: VRC7 (with audio)
    - 19: mapper 19 (waveform sound not supported), 88/206: mapper 88/206
- PCE (.pce)
  - Does not support SRAM / CD / SG16
- MD (.gen .md)
  - Experimental md cdrom support: BIOS boot, sub 68000, PRG/Word RAM,
    CDD/CDC, PCM/CD-DA audio, backup RAM and stamp conversion
  - Experimental md 32x support: dual SH-2, shared RAM, bitmap VDP and PWM
  - Does not support cartridge SRAM / PAL
- PS1 (.ps) * experimental *
  - requires BIOS with `.ps` extension 
  - loads disc file by build-time parameter, `--dart-define=DISCS={local-iso-file,...}`

# How to use 

1. Visit [the demo site](https://fnesemu.codemagic.app) or access [the latest version](https://reki2000.github.io/fnesemu/) directly
1. Select the file by clicking on the 'Load ROM' icon (a square and small arrow) on the leftmost of the App bar icons
1. Click on the 'Run' icon (a right-directed triangle) to start emulation

## md cdrom support (experimental)

Load a legally obtained **128 KiB MD CD-ROM BIOS** using the Load ROM button.
Use the `.mdcd` extension to select CD boot mode explicitly; `.bin`
BIOS files containing the `manufacturer BOOT` header are detected automatically.
Select the game from the disc menu. As with PS1, disc paths are supplied through
`--dart-define=DISC=/path/to/game.cue` for a single image, or through the
`DISC_DIR` environment variable for the disc menu.
BIOS files and games are not included.

Supported images are raw Mode 1 BIN/CUE, cooked 2048-byte ISO, and CUE with
separate `MODE1/2048` data and raw AUDIO files. CD-DA requires raw little-endian
stereo PCM tracks; WAV/MP3/CHD images are not supported. Backup RAM uses the
existing save storage under `md_cdrom_bram`. The debugger exposes the sub CPU as
CPU 2. CD hardware is enabled by loading its BIOS, not by attaching a disc to a
cartridge game.

A supplied Japanese BIOS reaches its startup screen and accepts Start input.
A local CUE/IMG smoke run reads its eight-track TOC and data
sectors, but remains on the BIOS waiting screen after Start; game startup and
gameplay are **not verified**. Synthetic hardware regression tests also run. Bus contention and
seek/DMA/graphics timing are approximations. Stamp output is computed when the
operation starts, followed by an estimated busy interval and IRQ1. CD subcode,
error correction, audio de-emphasis, gradual fader ramps, cartridge boot mode,
PAL timing is not implemented. Combined CD-ROM/32x boot is not verified. Compatibility with individual games is
not guaranteed.

For a local BIOS/disc smoke run (prints CPU/CD state and stops on unsupported
instructions):

```sh
dart run lib/tools/md_cdrom.dart /path/to/bios.bin /path/to/game.cue 1800 \
  --start-frame=600 --out=/tmp/md-cdrom-check --every=300
```

Regression tests:

```sh
flutter test test/core/md/md_cdrom_test.dart test/disc/md_cdrom_disc_test.dart
```

Register layouts and mapping follow the hardware development manual.

## md 32x support (experimental)

The implementation lives in `lib/core/md/32x/`, including
`sh2/sh2.dart`, `md_32x.dart`, `video.dart` and `pwm.dart`.
The `.32x` extension or a `32X` cartridge header selects the adapter.
Supply boot ROMs through `Md.setExpansionBootRoms`: 256 bytes for the main
68000, 2048 bytes for the master SH-2 and 1024 bytes for the slave SH-2.
The GUI does not yet provide a boot ROM selector. Boot ROMs and games are not bundled.

Implemented paths include big-endian shared SDRAM, cartridge windows,
communication ports, external interrupt masks/acknowledgement, a four-word
DREQ FIFO, framebuffer ownership and swapping, indexed/direct/RLE bitmap
modes, fill/overwrite access, MD plane priority and three-entry PWM FIFOs.
The debugger exposes both SH-2 CPUs. Unknown instructions stop execution
with the opcode and PC in the state dump.

Ordinary MD cartridges use the original bus without adapter address checks
and do not allocate an opacity buffer or additional CPU result map. When ADEN is clear or
reset is held, SH-2 execution, peripheral timers, video composition and PWM
mixing stop; resuming synchronizes the clock without processing the paused
interval. MD opacity tracking is enabled only during adapter rendering.

This is an initial implementation with synthetic CPU/peripheral tests.
Commercial boot ROM/game startup and gameplay have **not been verified**.
SH-2 MAC instructions, cache, on-chip peripherals/DMAC, bus wait states,
accurate instruction timing and PAL/240-line video remain unimplemented.
The DREQ FIFO is CPU-readable; automatic DMA transfer is not implemented.
PWM resampling and fill timing are approximate.

```sh
dart run lib/tools/md_32x.dart game.32x main.bin master.bin slave.bin 600
flutter test test/core/md/32x
```

## Joypad-Keyboard assignment

| key | Z | X | C | A | S | Q | W | E | UP | DOWN | LEFT | RIGHT |
|-----|---|---|---|---|---|---|---|---|----|-----|------|------|
| NES | B | A | | select | start | | | | UP | DOWN | LEFT | RIGHT |
| PCE | II | I | | select | run | | |  | UP | DOWN | LEFT | RIGHT |
| MD  | A | B | C | | start | X | Y | Z | UP | DOWN | LEFT | RIGHT |
| PS1 | # | x | o | select | ^ | L | start | R | UP | DOWN | LEFT | RIGHT |

## How to build and run on local machine

To build and run fnesemu on a local machine, you will need flutter 3.22.0 with at least one enabled device. 
Follow these steps:

```
git submodule update --init
flutter run -d [windows|linux|chrome|macos|your-android-device|your-ios-device] --release
```

# How to develop

## To add more mapper type support

TBD

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
