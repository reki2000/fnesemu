# fnesemu

A Cross-Platform NES/PCE/MD/PS1/N64 Emulator Built with Flutter

This project is experimental.

- Achieves 60 fps: NES and PCE on i5-8250 (web), MD on i5-8250 (Windows), PS1 on i7-13700HX (Windows)
- Runs on all Flutter-supported platforms: Android, iOS, macOS, Linux, Windows, and Web
- NES (.nes)
  - SRAM backup by [shared_preference](https://pub.dev/packages/shared_preferences)
  - Supports the following iNES mapper types:
    - 0: NROM, 1: MMC1, 2: UxROM, 3: CNROM, 4: MMC3, 9/10: MMC2/4
    - 73: VRC3, 75: VRC1, 21/23/25: VRC2/4, 24|26: VRC6 (with audio), 85: VRC7 (with audio)
    - 19: Namco163 (waveform sound not supported), 88/206: Namco118
- PCE (.pce)
  - Does not support SRAM / CD / SG16
- MD (.gen .md)
  - Does not suppor SRAM / CD / PAL / 32X
- PS1 (.ps) * experimental *
  - requires BIOS with `.ps` extension 
  - loads disc file by build-time parameter, `--dart-define=DISCS={local-iso-file,...}`

- N64 (.z64 .v64 .n64), independent Dart implementation
  - VR4300 integer/COP1 interpreter, CP0 exceptions and interrupt delivery,
    basic TLB mappings, 8 MiB RDRAM, SP/PI/SI DMA, VI scanout and AI stereo PCM.
  - RSP graphics tasks are decoded as Fast3D/F3DEX GBI commands. Matrices,
    lighting, clip-space clipping, depth tests, texture formats/TLUT, texture
    rectangles and color combining are rasterized in Dart. Audio tasks use
    independent command interpreters for the original and Shindou SM64 ABIs.
  - Controller/PIF and 4 Kbit EEPROM use the existing keyboard/virtual pad and
    shared-preferences save storage. Arrows drive the analog stick.
  - IPL/CIC is bypassed: up to 1 MiB of the payload at ROM offset 0x1000 is
    copied to the header entry point, and cartridge boot variables are set.
    ROM byte order is detected from its signature, including files inside ZIPs.
  - This is still experimental and can run slower than real time. Instruction
    timing, audio resampling, blending
    and VI filtering are approximate. Arbitrary RSP microcode, raw RDP triangle
    streams, F3DEX2, controller paks, SRAM/FlashRAM and 64DD are not implemented.
    Other commercial games are not claimed compatible. Unsupported commands
    stop with a diagnostic in the debugger.
  - No external emulator core or native emulator library is used.


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
| N64 | B | A | C-down | Z | start | L | C-left | R | stick up | stick down | stick left | stick right |
| PS1 | # | x | o | select | ^ | L | start | R | UP | DOWN | LEFT | RIGHT |

N64 also assigns `R` to C-up and `T` to C-right.

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

## N64 validation

A local cartridge dump was verified
through boot, menu navigation and in-game movement.
Graphics and nonzero stereo PCM continued without an unsupported-operation
stop over 90 emulated seconds (2,559 graphics tasks and 5,370 audio tasks).
The sampled headless AOT run took about 731 seconds on the development machine;
real-time performance has not been reached. This is an initial gameplay check,
not a full-game compatibility claim.

Run the 25 synthetic CPU/FPU, DMA, interrupt, PIF/EEPROM, graphics and audio
tests (also verified with Dart VM and Dart2JS/Node):

```
flutter test test/core/n64
```

For a local cartridge dump, the standalone smoke runner executes the same Dart
core, reports graphics/audio activity and writes RGBA frames plus dimensions to
`/tmp/fnesemu-n64-N.{rgba,json}`. The ROM is never copied into the repository.

```
flutter pub get
dart --packages=.dart_tool/package_config.json tool/n64_smoke.dart /path/to/owned-rom.v64 8437500000 --input --sample-frames
```

The cycle limit is optional. `--input` supplies a reproducible sequence of Start,
A and stick events; `--sample-frames` rasterizes only the last six frames of each
second for faster headless testing, covering the three rotating framebuffers.
Normal app execution renders every frame. `--out=DIR` selects the evidence
folder; `--input-events=FILE` reads a JSON array of `[seconds, button, down]`
events (for example `[12, "start", true]`). `--dump-ram` adds compressed RDRAM
snapshots, and `--watch=HEX_PC,...` logs CPU registers at selected addresses.

Protocol references used for this independent implementation:
[libdragon system registers](https://github.com/DragonMinded/libdragon/blob/trunk/include/n64sys.h),
[N64 RCP registers](https://github.com/n64decomp/sm64/blob/master/include/PR/rcp.h),
[GBI command formats](https://github.com/n64decomp/sm64/blob/master/include/PR/gbi.h),
[audio command formats](https://github.com/n64decomp/sm64/blob/master/include/PR/abi.h).
