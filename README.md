# fnesemu

A Cross-Platform NES/PCE/MD/PS1/SS/GB/GBA/SNES/N64 Emulator Built with Flutter

This project is experimental.

- Runs on all Flutter-supported platforms: Android, iOS, macOS, Linux, Windows, and Web
- Targets 60 fps for NES and PCE on i5-8250 (web), MD on i5-8250 (Windows), PS1 on i7-13700HX (Windows)

# How to use 

1. Visit [the demo site](https://fnesemu.codemagic.app) or access [the latest version](https://reki2000.github.io/fnesemu/) directly
1. Open the menu, choose 'CD / ROM', and select a ROM directory
1. Choose a ROM in the list to start emulation. The menu button or Escape pauses/resumes it

## BIOS and discs

- Set the BIOS of each system from the 'Core setup' menu (the gear icon). The files are saved and used each time the system starts
  - fds (8 KiB), pce cdrom (system card), md cdrom, ps1 and ss require it. 32x (3 boot ROM files) and gba are optional
- Select a disc from the disc menu. The system is detected from the disc header
  - if the running system plays the disc, only the disc is changed as on the real console. press Reset to boot it



## FDS

Set the BIOS from Core setup → fds (8 KiB raw or an iNES `.nes` image),
then choose an `.fds` file from a
CD / ROM directory. Disk 1 A is inserted initially. Press R or the on-screen
Flip Disk button to flip between A and B. Holding the key does not flip repeatedly.
The drive exposes a brief ejected interval to the running software. A one-sided
image remains on A. There is no menu for choosing a specific disk side.
Writes are saved in the application's storage; the original image is kept intact.

The headless harness supports the same core:

```sh
dart run lib/tools/core_harness.dart fds /path/to/disk.fds -b /path/to/bios.bin -f 600
```

FDS tests use synthetic BIOS/disk programs. Additional local checks use
user-supplied BIOS and disk images, which are not included in the repository.
Data-only disks require their corresponding boot disk and cannot boot alone.
QD images are not supported.

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

## Core module boundary

App/GUI imports only `lib/core/core_api.dart`. Core modules in
`lib/core/<module>/module.dart` declare their systems, BIOS setup metadata,
and ROM/disc ownership rules. `CoreFactory` enumerates registered modules and
forwards identification and construction requests to them.

After adding or removing a module, regenerate the core-side registration list:

```sh
dart tool/generate_core_registry.dart
```

No App/GUI changes are needed, including when no game core is installed.
The tests exercise an empty registry; a Linux build is also checked with all
concrete module directories removed in a temporary checkout.

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
