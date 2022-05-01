# fnes

A NES Emulator written in Flutter Web

This project is under experimental.

- 60 fps on i5-8250
- supports mapper type 0 and 3

# How to run

`flutter run -d chrome`

select `.nes` file from 'File' button and click 'Run', then emulation starts.

# Joypad-Keyboard assignment

| A | B | select | start | UP | DOWN | LEFT | RIGHT |
|---|---|--------|-------|----|------|------|------|
| X | Z | A | S | UP | DOWN | LEFT | RIGHT |

# How to test 6502 emulation

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

