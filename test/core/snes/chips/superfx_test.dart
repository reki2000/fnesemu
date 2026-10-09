import 'package:fnesemu/core/snes/snes.dart';
import 'package:test/test.dart';

import '../test_rom.dart';

void main() {
  group('Super FX', () {
    test('runs from R15 until STOP and raises the main cpu IRQ', () {
      final rom = loRom(romType: 0x13, sramSizeByte: 3);
      put(rom, 0x0100, [
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
      final rom = loRom(romType: 0x13, sramSizeByte: 3);
      put(rom, 0x0100, [
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
}
