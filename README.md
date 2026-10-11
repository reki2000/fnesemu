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

`packages/cdrom_image` and `packages/mp_bigfile_picker` are maintained in
their own repositories and used here through local `path` dependencies.
Before editing a package, switch its submodule to a development branch:

```sh
git -C packages/cdrom_image switch main
git -C packages/mp_bigfile_picker switch main
```

Package edits are used directly by the app. Commit and push changes in the
package repository first, then commit the updated submodule reference in
fnesemu. To update to the commits recorded by fnesemu after a pull, run
`git submodule update --init --recursive`.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the packages, the direction of
the dependencies and the interfaces between them.

After adding or removing a core module, regenerate the registration list:

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

