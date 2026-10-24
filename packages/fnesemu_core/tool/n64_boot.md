# N64 task HLE boot and audio checks

A Japanese N64 cartridge stopped at three successive boundaries: a type-4 startup task, FlashRAM command writes at physical address `0x08010000`, and an in-list switch from F3DZEX to S2DEX2.

The startup task is recognized by its instructions and task sizes, rather than by cartridge identity or task type alone. Its SDV stores eight bytes of vector register 12 into DMEM at offset 8, followed by setting SIG2 and BREAK. The HLE initializes that vector result to zero because it has no RSP vector state. Power-on vector contents are unspecified; this is an HLE assumption, not a hardware reset guarantee. Other type-4 tasks, including JPEG decompression, still fail explicitly.

FlashRAM uses a 128 KiB backup appended after the existing EEPROM and SRAM regions. Existing shorter backups retain their prefix and gain an erased FlashRAM region. The reported Macronix MX-C ID selects the old chip's halfword-addressed PI DMA reads. Programming uses a 128-byte buffer and clears bits; sector erase covers 128 pages (16 KiB). Operations complete synchronously, without hardware busy timing. Save states include the command mode, page and pending write buffer; the N64 state version is now 2.

S2DEX2 background support covers RGBA16/RGBA32 images, scaling, wrapping, horizontal flip and scissoring. LOAD_UCODE uses the preceding RDPHALF_1 data pointer to select the decoder while preserving the current display-list stack. Other sprite commands and background formats remain unsupported.

The audio ABI is selected from the task microcode's opening vector constants, rather than the cartridge revision byte. The extended ABI embeds lengths in mixer and interleave commands, and uses opcode 7 for an eight-tap FIR filter. The decoder supports the signed two-bit ADPCM residuals used by this cartridge, and the envelope mixer handles independent dry/wet sign masks and wet-channel swapping. The filter averages target and saved Q15 coefficients and retains the preceding eight input samples. The existing linear resampler remains an approximation of the RSP's four-tap interpolation.

## References

- [Nintendo Flash library manual](https://jrra.zone/n64/doc/pro-man/pro28/28-02.htm): page buffering, sector boundaries and erase/program sequencing.
- [Nintendo S2DEX manual](https://ultra64.ca/files/documentation/online-manuals/man/pro-man/pro25/25-05.html): background drawing and scaling.
- [Nintendo gs2dex.h](https://ultra64.ca/files/documentation/online-manuals/man/header/gs2dex.htm): command numbers and fixed-point background fields.
- [SGI RSP Programmer's Guide](https://ultra64.ca/files/documentation/silicon-graphics/SGI_Nintendo_64_RSP_Programmers_Guide.pdf): vector stores, status writes and BREAK.

## Reproduction

Run from `packages/fnesemu_core` with a local Japanese cartridge dump:

```sh
dart run tool/core_headless.dart run n64 "$ROM" -r -f 2400 -e 600 -o /tmp/n64-boot -w \
  --input ':12 @1300 Start @1500 Start @1700 A @1900 A @2100 Start'
dart test test/core/n64
```

The title is visible by frame 1200 and the name-entry screen by frame 2400. These checks establish boot and menu progression. WAV output should become nonzero when the first voices start around frame 500; the earlier ABI selection produced silence. Hardware-exact audio is not claimed.
