// cartridge images and components shared by the snes tests
import 'dart:typed_data';

import 'package:fnesemu/core/snes/component/bus.dart';
import 'package:fnesemu/core/snes/component/dsp.dart';
import 'package:fnesemu/core/snes/component/spc700.dart';
import 'package:fnesemu/core/snes/rom/snes_file.dart';

/// a LoROM image of [size] bytes with [romType] (the chips) and
/// [sramSizeByte] (0 = none, 3 = 8KB) in the header, the reset vector at
/// $8000 and the emulation-mode IRQ/BRK vector at $9000
Uint8List loRom({int romType = 0, int sramSizeByte = 0, int size = 0x8000}) {
  final rom = Uint8List(size);
  rom[0x7fd6] = romType;
  rom[0x7fd8] = sramSizeByte;
  rom[0x7ffc] = 0x00;
  rom[0x7ffd] = 0x80;
  rom[0x7ffe] = 0x00;
  rom[0x7fff] = 0x90;
  return rom;
}

/// a HiROM image with a plausible header at $FFC0 and an 8KB sram
Uint8List hiRom() {
  final rom = Uint8List(0x10000);
  for (int i = 0; i < 21; i++) {
    rom[0xffc0 + i] = 0x41; // printable title
  }
  rom[0xffd8] = 3; // 8KB sram
  rom[0xffdc] = 0xff; // checksum complement
  rom[0xffdd] = 0xff;
  rom[0xfffd] = 0x80; // reset vector $8000
  return rom;
}

/// writes [code] into [rom] at [offset]
void put(Uint8List rom, int offset, List<int> code) =>
    rom.setRange(offset, offset + code.length, code);

Bus busWith(Uint8List rom) => Bus()..setRom(SnesFile()..load(rom));

/// a sound cpu running [program] at $0200
Spc700 soundCpuAt(List<int> program) {
  final snd = Spc700(Dsp());
  for (int i = 0; i < program.length; i++) {
    snd.ram[0x200 + i] = program[i];
  }
  snd.pc = 0x200;
  return snd;
}
