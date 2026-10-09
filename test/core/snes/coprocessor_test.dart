import 'dart:typed_data';

import 'package:fnesemu/core/snes/component/bus.dart';
import 'package:fnesemu/core/snes/rom/snes_file.dart';
import 'package:fnesemu/core/snes/snes.dart';
import 'package:test/test.dart';

// LoROM image of [size] bytes with [romType] as the header's chip byte, an
// 8KB ram and the reset vector at $8000
Uint8List _loRom(int romType, {int size = 0x8000}) {
  final rom = Uint8List(size);
  rom[0x7fd6] = romType;
  rom[0x7fd8] = 3;
  rom[0x7ffc] = 0x00;
  rom[0x7ffd] = 0x80;
  return rom;
}

void _put(Uint8List rom, int offset, List<int> code) =>
    rom.setRange(offset, offset + code.length, code);

void main() {
  group('SA-1', () {
    test('the second cpu starts at CRV and shares I-RAM', () {
      final rom = _loRom(0x34);
      _put(rom, 0x0000, [
        0xa9, 0x00, 0x8d, 0x03, 0x22, // LDA #$00 / STA $2203
        0xa9, 0x81, 0x8d, 0x04, 0x22, // LDA #$81 / STA $2204: CRV = $8100
        0x9c, 0x00, 0x22, // STZ $2200: release the SA-1 reset
        0x80, 0xfe, // BRA *
      ]);
      _put(rom, 0x0100, [
        0xa9, 0x42, 0x8d, 0x00, 0x30, // LDA #$42 / STA $3000
        0x80, 0xfe, // BRA *
      ]);
      final snes = Snes()..setRom(rom);
      snes.runFrame(10);
      expect(snes.bus.read(0x003000), 0x42);
    });

    Bus sa1Bus() => Bus()..setRom(SnesFile()..load(_loRom(0x34)));

    void writeWord(Bus bus, int reg, int v) {
      bus.write(reg, v & 0xff);
      bus.write(reg + 1, (v >> 8) & 0xff);
    }

    int result(Bus bus, int bytes) {
      var v = 0;
      for (var i = 0; i < bytes; i++) {
        v |= bus.read(0x2306 + i) << (i * 8);
      }
      return v;
    }

    test('multiplies signed words', () {
      final bus = sa1Bus();
      bus.write(0x2250, 0);
      writeWord(bus, 0x2251, -3);
      writeWord(bus, 0x2253, 7);
      expect(result(bus, 4), -21 & 0xffffffff);
    });

    test('divides a signed word, leaving a non-negative remainder', () {
      final bus = sa1Bus();
      bus.write(0x2250, 1);
      writeWord(bus, 0x2251, -7);
      writeWord(bus, 0x2253, 2);
      expect(result(bus, 4), 1 << 16 | (-4 & 0xffff));
    });

    test('accumulates products', () {
      final bus = sa1Bus();
      bus.write(0x2250, 2);
      writeWord(bus, 0x2251, 100);
      writeWord(bus, 0x2253, 200);
      writeWord(bus, 0x2251, 3);
      writeWord(bus, 0x2253, 4);
      expect(result(bus, 5), 20012);
    });

    test('maps 1MB rom banks into \$C0-\$FF', () {
      final rom = _loRom(0x34, size: 0x400000);
      rom[0x300000] = 0x5a;
      final bus = Bus()..setRom(SnesFile()..load(rom));
      bus.write(0x2220, 3);
      expect(bus.read(0xc00000), 0x5a);
    });
  });

  group('Super FX', () {
    test('runs from R15 until STOP and raises the main cpu IRQ', () {
      final rom = _loRom(0x13);
      _put(rom, 0x0100, [
        0xa1, 0x05, // IBT R1,#5
        0xa2, 0x07, // IBT R2,#7
        0xb1, 0x13, 0x52, // FROM R1 / TO R3 / ADD R2
        0x00, 0x01, // STOP / NOP
      ]);
      final snes = Snes()..setRom(rom);
      final bus = snes.bus;
      bus.write(0x301e, 0x00);
      bus.write(0x301f, 0x81); // R15 = $8100 and go
      expect(bus.read(0x3030) & 0x20, 0x20);
      bus.superFx!.run(1000);
      expect(bus.read(0x3030) & 0x20, 0);
      expect(bus.read(0x3006), 12);
      expect(bus.read(0x3031) & 0x80, 0x80);
      expect(bus.read(0x3031) & 0x80, 0); // reading acknowledges the IRQ
    });

    test('plots a pixel into a 4bpp character', () {
      final rom = _loRom(0x13);
      _put(rom, 0x0100, [
        0x3d, 0x4e, // ALT1 / CMODE (R0 = 0: opaque, no dither)
        0xa0, 0x05, 0x4e, // IBT R0,#5 / COLOR
        0xa1, 0x09, 0xa2, 0x02, // IBT R1,#9 / IBT R2,#2
        0x4c, // PLOT
        0x00, 0x01, // STOP / NOP
      ]);
      final snes = Snes()..setRom(rom);
      final bus = snes.bus;
      bus.write(0x303a, 0x01); // 4bpp, 128 lines
      bus.write(0x301e, 0x00);
      bus.write(0x301f, 0x81);
      bus.superFx!.run(1000);
      // x 9 is in character 16 (32 bytes each), bit 6; y 2 is row 2
      const row = 16 * 32 + 2 * 2;
      expect(bus.read(0x700000 + row), 0x40); // plane 0
      expect(bus.read(0x700000 + row + 1), 0); // plane 1
      expect(bus.read(0x700000 + row + 16), 0x40); // plane 2
      expect(bus.read(0x700000 + row + 17), 0); // plane 3
    });
  });

  group('S-DD1', () {
    test('maps 1MB rom banks into \$C0-\$FF', () {
      final rom = _loRom(0x43, size: 0x400000);
      rom[0x200010] = 0xa5;
      final bus = Bus()..setRom(SnesFile()..load(rom));
      expect(bus.read(0xc00010), 0);
      bus.write(0x4804, 2);
      expect(bus.read(0x4804), 2);
      expect(bus.read(0xc00010), 0xa5);
    });
  });
}
