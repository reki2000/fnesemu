import 'dart:typed_data';

import 'package:fnesemu_core/src/core/gb/gb.dart';
import 'package:test/test.dart';

// builds a rom image whose header has the given GBC flag (0x80: GBC-compatible, 0xc0: GBC only)
Gb _core({int gbcFlag = 0x80}) {
  final rom = Uint8List(0x8000)
    ..[0x143] = gbcFlag
    ..[0x147] = 0x00;
  return Gb()..setRom(rom);
}

void main() {

  group('mode selection', () {
    test('GBC-flagged images start with the GBC register state', () {
      final gb = _core();
      expect(gb.bus.gbc, isTrue);
      expect(gb.cpu.af, 0x1180);
      expect(gb.cpu.bc, 0x0000);
      expect(gb.cpu.de, 0xff56);
      expect(gb.cpu.hl, 0x000d);
    });

  });

  test('WRAM bank 0 is fixed and the D000 window selects banks 1-7', () {
    final bus = _core().bus;
    bus.write(0xc000, 0x11);
    bus.write(0xd000, 0x01); // bank 1
    expect(bus.read(0xff70), 0xf9);

    bus.write(0xff70, 3);
    expect(bus.read(0xff70), 0xfb);
    expect(bus.read(0xd000), 0x00);
    bus.write(0xd000, 0x33);
    expect(bus.read(0xd000), 0x33);
    expect(bus.read(0xf000), 0x33); // echo of D000
    expect(bus.read(0xc000), 0x11);

    bus.write(0xff70, 0); // 0 selects bank 1
    expect(bus.read(0xff70), 0xf9);
    expect(bus.read(0xd000), 0x01);
  });

  test('KEY1 armed STOP switches to double speed', () {
    final rom = Uint8List(0x8000)..[0x143] = 0x80;
    rom.setRange(
        0x100, 0x104, [0x3e, 0x01, 0xe0, 0x4d]); // LD A,1 / LDH (FF4D),A
    rom.setRange(0x104, 0x106, [0x10, 0x00]); // STOP
    final gb = Gb()..setRom(rom);
    final bus = gb.bus;

    gb.exec(false);
    gb.exec(false);
    expect(bus.read(0xff4d), 0x7f);

    gb.exec(false);
    expect(bus.doubleSpeed, isTrue);
    expect(bus.read(0xff4d), 0xfe);

    // one machine cycle is 4 CPU clocks but only 2 system clocks
    final clocks = bus.clocks, dots = bus.dotClocks;
    bus.tick();
    expect(bus.clocks - clocks, 4);
    expect(bus.dotClocks - dots, 2);
  });
}
