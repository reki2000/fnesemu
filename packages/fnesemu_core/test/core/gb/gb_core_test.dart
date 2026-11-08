import 'dart:typed_data';

import 'package:fnesemu_core/src/core/gb/bus.dart';
import 'package:fnesemu_core/src/core/gb/cpu.dart';
import 'package:fnesemu_core/src/core/gb/gb.dart';
import 'package:fnesemu_core/src/core/gb/pad.dart';
import 'package:fnesemu_core/src/pad_button.dart';
import 'package:fnesemu_core/src/pad_source.dart';
import 'package:test/test.dart';

// builds a rom image with the program placed at the entry point 0x0100
Uint8List _rom(List<int> program, {int type = 0x00, int romSizeCode = 0}) {
  final rom = Uint8List(0x8000 << romSizeCode);
  rom.setRange(0x100, 0x100 + program.length, program);
  rom[0x147] = type;
  rom[0x148] = romSizeCode;
  return rom;
}

Gb _run(List<int> program, int steps) {
  final gb = Gb()..setRom(_rom(program));
  for (int i = 0; i < steps; i++) {
    gb.exec(false);
  }
  return gb;
}

void main() {
  test('arithmetic and flags', () {
    final gb = _run([
      0x3e, 0x0f, // LD A, $0f
      0xc6, 0x01, // ADD A, $01
      0x06, 0x45, // LD B, $45
      0x3e, 0x38, // LD A, $38
      0x80, // ADD A, B
      0x27, // DAA
    ], 6);
    expect(gb.cpu.a, 0x83);
    expect(gb.cpu.f & Cpu.flagC, 0);
  });

  test('bank controller switches the upper rom bank', () {
    final rom = _rom([], type: 0x01, romSizeCode: 2); // 128KB, 8 banks
    for (int bank = 0; bank < 8; bank++) {
      rom[bank * 0x4000 + 0x10] = bank;
    }
    final gb = Gb()..setRom(rom);

    expect(gb.read(0, 0x4010), 1);
    gb.bus.write(0x2000, 5);
    expect(gb.read(0, 0x4010), 5);
    gb.bus.write(0x2000, 0); // bank 0 is mapped as 1
    expect(gb.read(0, 0x4010), 1);
  });

}
