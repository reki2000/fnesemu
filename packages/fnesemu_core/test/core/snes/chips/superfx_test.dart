import 'package:fnesemu_core/src/core/snes/snes.dart';
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

  });
}
