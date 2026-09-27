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
    - 19: Namco163 (waveform sound not supported), 88/206: Namco118
- PCE (.pce) + SGX16
  - Does not support SRAM / CD
- MD (.gen .md)
  - Does not suppor SRAM / CD / PAL / 32X
- PS1 (.ps) * experimental *
  - requires BIOS with `.ps` extension 
  - loads disc file by build-time parameter, `--dart-define=DISCS={local-iso-file,...}`

# How to use 

1. Visit [the demo site](https://fnesemu.codemagic.app) or access [the latest version](https://reki2000.github.io/fnesemu/) directly
1. Select the file by clicking on the 'Load ROM' icon (a square and small arrow) on the leftmost of the App bar icons
1. Click on the 'Run' icon (a right-directed triangle) to start emulation

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
## cdrom support (experimental)

Load your own version 3.0 system-card BIOS ROM as a `.pce` file, then select a CD
image from the existing disc menu (`DISC_DIR` / `DISC` launch settings can
also select the image). Reset after changing the disc. The BIOS and games
are not included. Use a binary CUE image with MODE1/2352 data tracks and
AUDIO tracks; the existing raw BIN reader is also supported. Cooked
MODE1/2048 images, CHD and compressed audio tracks are not supported.

The console core enables the CD interface when a nonempty disc is attached.
It maps the 192 KiB system-card RAM at banks `$68–$7F`, retains the
64 KiB CD RAM at `$80–$87`, and keeps both separate from dual-controller work RAM.
The implementation includes SCSI command/data/status/message handshakes,
READ(6), TOC and subchannel-Q queries, IRQ2, stereo CD-DA playback,
64 KiB ADPCM RAM with DMA and MSM5205 decoding, and basic fade control.
The 2 KiB backup RAM at bank `$F7` uses the existing SRAM storage under
`pce-cd-bram` and follows the CD interface's lock/unlock registers.

This is an initial register-level implementation, not a claim of game
compatibility. Seek delays, subchannel streaming, ADPCM read/write busy
timing and audio filtering are not yet reproduced accurately. Additional expansion-card RAM
support is not included. BIOS startup and commercial game playback still
need validation with user-provided images.

Hardware behavior was checked against the register and memory mappings in
[reference CD interface](https://github.com/libretro/beetle-pce-libretro/blob/master/mednafen/pce/pcecd.cpp),
[memory mapper](https://github.com/libretro/beetle-pce-libretro/blob/master/mednafen/pce/huc.cpp),
and [NEC CD command definitions](https://github.com/libretro/beetle-pce-libretro/blob/master/mednafen/cdrom/scsicd-pce-commands.inc).

Run the synthetic CD tests with:

```sh
flutter test test/core/pce/cdrom_test.dart
```
