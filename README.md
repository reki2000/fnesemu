# fnesemu

A Cross-Platform NES/PCE/MD/PS1/SS/GB/GBA/SNES/N64 Emulator Built with Flutter

This project is experimental.

- Achieves 60 fps: NES and PCE on i5-8250 (web), MD on i5-8250 (Windows), PS1 on i7-13700HX (Windows)
- Runs on all Flutter-supported platforms: Android, iOS, macOS, Linux, Windows, and Web
- NES (.nes)
  - Supports the following iNES mapper types:
    - 0: NROM, 1: MMC1, 2: UxROM, 3: CNROM, 4: MMC3, 9/10: MMC2/4
    - 73: VRC3, 75: VRC1, 21/23/25: VRC2/4, 24|26: VRC6, 85: VRC7
    - 19: mapper 19, 88/206: mapper 88/206
- PCE (.pce) + SGX16 + CD
- MD (.gen .md) + CD + 32X
- GB (.gb)
  - Supports ROM only / MBC1 / MBC2 / MBC3 (with clock) / MBC5 cartridges
- PS1 (.exe, disc) * experimental *, requires BIOS
- SS (disc) * work in progress *, requires BIOS
- N64 (.z64 .v64 .n64)

# How to use 

1. Visit [the demo site](https://fnesemu.codemagic.app) or access [the latest version](https://reki2000.github.io/fnesemu/) directly
1. Select the file by clicking on the 'Load ROM' icon (a square and small arrow) on the leftmost of the App bar icons
1. Click on the 'Run' icon (a right-directed triangle) to start emulation

## BIOS and discs

- Set the BIOS of each system from the 'Core setup' menu (the gear icon). The files are saved and used each time the system starts
  - the pce cdrom (system card), md cdrom, ps1 and ss require it. 32x (3 boot ROM files) and gba are optional
- Select a disc from the disc menu. The system is detected from the disc header
  - if the running system plays the disc, only the disc is changed as on the real console. press Reset to boot it



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
