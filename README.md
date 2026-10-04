# fnesemu

A Cross-Platform NES/PCE/MD/PS1/SS/GB/GBA/SNES/N64 Emulator Built with Flutter

This project is experimental.

- Achieves 60 fps: NES and PCE on i5-8250 (web), MD on i5-8250 (Windows), PS1 on i7-13700HX (Windows)
- Runs on all Flutter-supported platforms: Android, iOS, macOS, Linux, Windows, and Web
- NES (.nes)
  - SRAM backup by [shared_preference](https://pub.dev/packages/shared_preferences)
  - Supports the following iNES mapper types:
    - 0: NROM, 1: MMC1, 2: UxROM, 3: CNROM, 4: MMC3, 9/10: MMC2/4
    - 73: VRC3, 75: VRC1, 21/23/25: VRC2/4, 24|26: VRC6 (with audio), 85: VRC7 (with audio)
    - 19: mapper 19 (waveform sound not supported), 88/206: mapper 88/206
- PCE (.pce) + SGX16
  - Does not support SRAM / CD
- MD (.gen .md)
  - Does not suppor SRAM / CD / PAL / 32X
- GB (.gb)
  - SRAM backup by [shared_preference](https://pub.dev/packages/shared_preferences)
  - Supports ROM only / MBC1 / MBC2 / MBC3 (with clock) / MBC5 cartridges
  - Starts without a boot program. Does not support GBC-only cartridges / serial link
  - Experimental md cdrom support: BIOS boot, sub 68000, PRG/Word RAM,
    CDD/CDC, PCM/CD-DA audio, backup RAM and stamp conversion
  - Experimental md 32x support: dual SH-2, shared RAM, bitmap VDP and PWM
  - Does not support cartridge SRAM / PAL
- PS1 (.ps) * experimental *
  - requires BIOS with `.ps` extension 
  - loads disc file by build-time parameter, `--dart-define=DISCS={local-iso-file,...}`
  - async-cdrom mode by build-time parameter, `--dart-define=ASYNC_CDROM=true`
    - reads only the required sectors asynchronously (75 sectors read-ahead, 60 seconds cache) instead of loading the whole disc image into memory
    - adds 'Insert Disc' / 'Eject Disc' buttons. on the web, select a `.cue` file together with its `.bin` files, or a single `.iso`/`.bin` file
- SS (.ss) * work in progress *
  - requires BIOS with `.ss` extension, disc is selected from the disc menu
  - not verified with real BIOS / games yet

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
| N64 | B | A | C-down | Z | start | L | C-left | R | stick up | stick down | stick left | stick right |
| PS1 | # | x | o | select | ^ | L | start | R | UP | DOWN | LEFT | RIGHT |
| GB  | B | A | | select | start | | | | UP | DOWN | LEFT | RIGHT |
| SS  | A | B | C | L | start | X | Y | Z | UP | DOWN | LEFT | RIGHT |

N64 also assigns `R` to C-up and `T` to C-right.

SS also assigns `R` to its R button (the table has no column for it).

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

## To check SNES cartridges without the UI

Run the frame capture harness with a `.sfc`/`.smc` file or a directory of
cartridges. ROMs are read from their original location and are not added to
the repository.

```
dart run lib/tools/snes_harness.dart /path/to/snes-roms 120 /tmp/snes-harness
```

It prints each cartridge's detected title and mapping, CPU address, PPU mode,
blanking state, and image color count at frame 1, every 30 frames, and the
final frame. It saves PNG captures at those points. The final frame also
produces individual BG/OBJ layer captures and a VRAM dump for investigating
graphics defects. The frame count and output directory are optional; they
default to 180 and `/tmp/snes-harness`.

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
After CPU/register and rasterizer optimization, the sampled headless AOT run
took about 456 seconds, down from 731 seconds (about 1.6x faster).
Real-time performance has not been reached. This is an initial gameplay check,
not a full-game compatibility claim.

Run the 31 synthetic CPU/FPU, DMA, interrupt, PIF/EEPROM, graphics and audio
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

The register file stores sign-extended 32-bit values in `Int32List` and converts
wide values with `BigInt` only when needed, preserving 64-bit behavior on Web.
The rasterizer reuses color buffers and increments interpolation values across
pixels. In the 90-second comparison, all 89 sampled task/audio metadata records
matched; 75 frame images matched byte-for-byte. The other 14 had small texture
boundary differences from floating-point interpolation order (at most 0.4% of
RGBA bytes per frame). Sampled RDRAM at seconds 60, 73 and 89 matched exactly.

AOT microbenchmark medians from three runs on the development machine:

| Workload | Before | After | Speedup |
| --- | ---: | ---: | ---: |
| CPU, 32-bit loop | 4.619 s | 1.216 s | 3.8x |
| CPU, mixed 64-bit loop | 8.497 s | 3.309 s | 2.6x |
| Rasterizer, 300 triangles | 7.609 s | 4.950 s | 1.5x |

Checksums matched for all workloads. These are native AOT measurements, not Web
FPS guarantees. Run the reproducible workloads with:

```
dart --packages=.dart_tool/package_config.json tool/n64_bench.dart
```

For native AOT timing, compile this script with `dart compile exe` in a standalone
Dart package containing this core (the Flutter application cannot be compiled as
a standalone executable). The command above runs with the Dart VM instead.

Protocol references used for this independent implementation:
[libdragon system registers](https://github.com/DragonMinded/libdragon/blob/trunk/include/n64sys.h),
[N64 RCP registers](https://github.com/n64decomp/sm64/blob/master/include/PR/rcp.h),
[GBI command formats](https://github.com/n64decomp/sm64/blob/master/include/PR/gbi.h),
[audio command formats](https://github.com/n64decomp/sm64/blob/master/include/PR/abi.h).
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
and [manufacturer CD command definitions](https://github.com/libretro/beetle-pce-libretro/blob/master/mednafen/cdrom/scsicd-pce-commands.inc).

Run the synthetic CD tests with:

```sh
flutter test test/core/pce/cdrom_test.dart
```
