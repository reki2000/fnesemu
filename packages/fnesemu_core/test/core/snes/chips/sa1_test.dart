import 'package:fnesemu_core/core/snes/component/bus.dart';
import 'package:fnesemu_core/core/snes/rom/snes_file.dart';
import 'package:fnesemu_core/core/snes/snes.dart';
import 'package:test/test.dart';

import '../test_rom.dart';

void main() {
  group('SA-1', () {
    test('the second cpu starts at CRV and shares I-RAM', () {
      final rom = loRom(romType: 0x34, sramSizeByte: 3);
      put(rom, 0x0000, [
        0xa9, 0x00, 0x8d, 0x03, 0x22, // LDA #$00 / STA $2203
        0xa9, 0x81, 0x8d, 0x04, 0x22, // LDA #$81 / STA $2204: CRV = $8100
        0x9c, 0x00, 0x22, // STZ $2200: release the SA-1 reset
        0x80, 0xfe, // BRA *
      ]);
      put(rom, 0x0100, [
        0xa9, 0xff, 0x8d, 0x2a, 0x22, // LDA #$FF / STA $222A: I-RAM writable
        0xa9, 0x42, 0x8d, 0x00, 0x30, // LDA #$42 / STA $3000
        0x80, 0xfe, // BRA *
      ]);
      final snes = Snes()..setRom(rom);
      snes.runFrame(10);
      expect(snes.bus.read(0x003000), 0x42);
    });

    Bus sa1Bus() =>
        Bus()..setRom(SnesFile()..load(loRom(romType: 0x34, sramSizeByte: 3)));

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

    test('I-RAM writes are protected until enabled', () {
      final bus = sa1Bus();
      bus.write(0x003000, 0x11);
      expect(bus.read(0x003000), 0);
      bus.write(0x2229, 0x01); // SIWP: $3000-$30FF
      bus.write(0x003000, 0x11);
      expect(bus.read(0x003000), 0x11);
    });

    test('maps 1MB rom banks into \$C0-\$FF', () {
      final rom = loRom(romType: 0x34, sramSizeByte: 3, size: 0x400000);
      rom[0x300000] = 0x5a;
      final bus = Bus()..setRom(SnesFile()..load(rom));
      bus.write(0x2220, 3);
      expect(bus.read(0xc00000), 0x5a);
    });
  });
}
