# fnesemu

A Cross-Platform NES Emulator Built with Flutter

This project is currently experimental.

Achieves nearly 60 fps on an i5-8250 processor
Runs on all Flutter-supported platforms: Android, iOS, macOS, Linux, Windows, and Web
SRAM backup feature not yet implemented
Supports the following iNES mapper types:
0: NROM
1: MMC1
2: UxROM
3: CNROM
4: MMC3
9,10: MMC2,4
73: VRC3
75: VRC1
21,23,25: VRC2,4
19: Namco163 (waveform sound not supported)
88,206: Namco118

# How to use 

1. visit [demo site](https://fnesemu.codemagic.app) or [latest version](https://reki2000.github.io/fnesemu/)
1. select `.nes` file by click 'Load ROM' icon (a square and a small arrow) on the leftmost of the App bar icons
1. click 'Run' icon (a right-directed triangle) to start emulation

## Joypad-Keyboard assignment

| A | B | select | start | UP | DOWN | LEFT | RIGHT |
|---|---|--------|-------|----|------|------|------|
| X | Z | A | S | UP | DOWN | LEFT | RIGHT |

## How to build and run on local machine

Requires flutter 3.7.6 with at least one enabled device.

```
git submodule update --init
flutter run -d [windows|linux|chrome|macos|your-android-device|your-ios-device] --release
```

# How to develop


## test 6502 emulation

This 6502 emulator core has been validated using the Nestest ROM by comparing register and flag values against the Nestest log.

```
$ curl https://raw.githubusercontent.com/christopherpow/nes-test-roms/master/other/nestest.log > assets/nestest.log
$ curl https://raw.githubusercontent.com/christopherpow/nes-test-roms/master/other/nestest.nes > assets/rom/nestest.nes
$ make cputest
running fnesemu cpu test...
loading: File: 'assets/rom/nestest.nes'
cpu test completed successfully.
```

