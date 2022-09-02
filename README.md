# fnesemu

A multi-platform NES Emulator written in Flutter

This project is under experiment.

- runs almost 60 fps on i5-8250
- running on all flutter-supported platforms - Android, iOS, macOS, Linux, Windows and Web
- no SRAM backup feature
- supported iNES mapper types:
    - 0: NROM
    - 1: MMC1
    - 2: UxROM
    - 3: CNROM
    - 4: MMC3
    - 9,10: MMC2,4
    - 73: VRC3
    - 75: VRC1
    - 21,23,25: VRC2,4
    - 19: Namco163 *no waveform sound support
    - 88,206: Namco118

# How to use 

1. visit [demo site](https://fnesemu.codemagic.app) or [latest version](https://reki2000.github.io/fnesemu/)
1. select `.nes` file by click 'Load ROM' icon (a square and a small arrow) on the leftmost of the App bar icons
1. click 'Run' icon (a right-directed triangle) to start emulation

## Joypad-Keyboard assignment

| A | B | select | start | UP | DOWN | LEFT | RIGHT |
|---|---|--------|-------|----|------|------|------|
| X | Z | A | S | UP | DOWN | LEFT | RIGHT |

## How to build and run on local machine

Requires flutter 3.3.0 with at least one enabled device.

```
git submodule update --init
flutter run -d [windows|linux|chrome|macos|your-android-device|your-ios-device] --release
```

# How to develop


## test 6502 emulation

```
curl https://raw.githubusercontent.com/christopherpow/nes-test-roms/master/other/nestest.log > assets/nestest.log
curl https://raw.githubusercontent.com/christopherpow/nes-test-roms/master/other/nestest.nes > assets/rom/nestest.nes
make cputest
```

then you see the test stops at the point below, for this emulator hasn't implemented unofficial instructions.

```
running fnes...
loading file: File: 'assets/rom/nestest.nes'
previous: C6BC  28        PLP                             A:AA X:97 Y:4E P:A5 SP:F8 PPU:128, 77 CYC:14575 N:1 V:0 R:1 B:0 D:0 I:1 Z:0 C:1 
expected: C6BD  04 A9    *NOP $A9 = 00                    A:AA X:97 Y:4E P:EF SP:F9 PPU:128, 89 CYC:14579 N:1 V:1 R:1 B:0 D:1 I:1 Z:1 C:1 
result  : ---                                             A:AA X:97 Y:4E P:EF SP:F9 PPU:128, 89 CYC:14579 N:1 V:1 R:1 B:0 D:1 I:1 Z:1 C:1 
```

