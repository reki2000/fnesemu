import 'dart:typed_data';

import 'package:fnesemu/core/gb/bus.dart';
import 'package:fnesemu/core/gb/cpu.dart';
import 'package:fnesemu/core/gb/gb.dart';
import 'package:fnesemu/core/gb/pad.dart';
import 'package:fnesemu/core/pad_button.dart';
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

  test('call and return keep the stack balanced', () {
    final gb = _run([
      0xcd, 0x10, 0x01, // CALL $0110
      0x76, // HALT
      ...List.filled(12, 0x00),
      0x3e, 0x42, // $0110: LD A, $42
      0xc9, // RET
    ], 3);
    expect(gb.cpu.a, 0x42);
    expect(gb.cpu.pc, 0x0103);
    expect(gb.cpu.sp, 0xfffe);
  });

  test('instruction cycles are counted by memory accesses', () {
    final gb = Gb()..setRom(_rom([0x00, 0xc3, 0x00, 0x01]));
    final start = gb.bus.clocks;
    gb.exec(false); // NOP: 1 machine cycle
    expect(gb.bus.clocks - start, 4);
    gb.exec(false); // JP a16: 4 machine cycles
    expect(gb.bus.clocks - start, 20);
  });

  test('timer overflow requests an interrupt and reloads TMA', () {
    final bus = Bus()..reset();
    bus.write(0xff0f, 0);
    bus.write(0xff06, 0xab);
    bus.write(0xff05, 0xff);
    bus.write(0xff07, 0x05); // enabled, 16 clocks per increment

    // overflow and reload happen within 5 machine cycles
    for (int i = 0; i < 5 && bus.intFlag & Bus.intTimer == 0; i++) {
      bus.tick();
    }
    expect(bus.read(0xff05), 0xab);
    expect(bus.intFlag & Bus.intTimer, Bus.intTimer);
  });

  test('vertical blank interrupt is requested once per frame', () {
    final bus = Bus()..reset();
    bus.write(0xff0f, 0);
    for (int i = 0; i < 154 * 456 ~/ 4; i++) {
      bus.tick();
    }
    expect(bus.intFlag & Bus.intVBlank, Bus.intVBlank);
    expect(bus.ppu.frames, 1);
  });

  test('joypad register reflects the selected button group', () {
    final bus = Bus()..reset();
    final pad = bus.pad;
    pad.keyDown(0, Pad.start);
    pad.keyDown(0, PadButton.left);

    bus.write(0xff00, 0x20); // directions
    expect(bus.read(0xff00) & 0x0f, 0x0d);
    bus.write(0xff00, 0x10); // actions
    expect(bus.read(0xff00) & 0x0f, 0x07);
    expect(bus.intFlag & Bus.intJoypad, Bus.intJoypad);
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

  test('OAM DMA copies 160 bytes', () {
    final bus = Bus()..reset();
    for (int i = 0; i < 160; i++) {
      bus.write(0xc000 + i, i);
    }
    bus.write(0xff46, 0xc0);
    for (int i = 0; i < 162; i++) {
      bus.tick();
    }
    expect(bus.ppu.oam.sublist(0, 160), List.generate(160, (i) => i));
  });

  test('disassembler decodes operands', () {
    final gb = Gb()..setRom(_rom([0x21, 0x34, 0x12, 0x18, 0xfe, 0xcb, 0x7c]));
    expect(gb.disasm(0, 0x100).$1, endsWith("LD HL,\$1234"));
    expect(gb.disasm(0, 0x103).$1, endsWith("JR \$0103"));
    expect(gb.disasm(0, 0x105).$1, endsWith("BIT 7,H"));
  });
}
