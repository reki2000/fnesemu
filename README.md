# fnesemu

A Cross-Platform NES/PCE Emulator Built with Flutter

This project is currently experimental.

- Achieves nearly 60 fps on an i5-8250 processor
- Runs on all Flutter-supported platforms: Android, iOS, macOS, Linux, Windows, and Web
- NES (.nes)
  - SRAM backup by [shared_preference](https://pub.dev/packages/shared_preferences)
  - Supports the following iNES mapper types:
    - 0: NROM
    - 1: MMC1
    - 2: UxROM
    - 3: CNROM
    - 4: MMC3
    - 9,10: MMC2,4
    - 73: VRC3
    - 75: VRC1
    - 21,23,25: VRC2,4
    - 24,26: VRC6 (with audio)
    - 19: Namco163 (waveform sound not supported)
    - 88,206: Namco118
- PCE (.pce)
  - No SRAM / CD-ROM / SuperGrafx16 support

# How to use 

1. Visit [the demo site](https://fnesemu.codemagic.app) or access [the latest version](https://reki2000.github.io/fnesemu/) directly
1. Select the `.nes` or `.pce` file by clicking on the 'Load ROM' icon (a square and small arrow) on the leftmost of the App bar icons
1. Click on the 'Run' icon (a right-directed triangle) to start emulation

## Joypad-Keyboard assignment

Here is the keyboard-pad assignment table for your reference:

| key | X | Z | A | S | UP | DOWN | LEFT | RIGHT |
|---|---|---|--------|-------|----|------|------|------|
| NES | A | B | select | start | UP | DOWN | LEFT | RIGHT |
| PCE | I | II | select | run | UP | DOWN | LEFT | RIGHT |

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
$ make cputest
running fnesemu cpu test...
loading: File: 'assets/rom/nestest.nes'
cpu test completed successfully.
```

