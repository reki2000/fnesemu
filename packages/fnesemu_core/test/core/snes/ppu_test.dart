import 'package:fnesemu_core/src/core/snes/component/ppu.dart';
import 'package:fnesemu_core/src/core/snes/component/ppu_render.dart';
import 'package:test/test.dart';

void main() {
  group('ppu', () {
    Ppu backdropPpu() {
      final ppu = Ppu();
      ppu.write(0x2100, 0x0f); // display on, full brightness
      ppu.write(0x2105, 0x01); // mode 1
      ppu.write(0x2121, 0x00);
      ppu.write(0x2122, 0x1f); // backdrop = red
      ppu.write(0x2122, 0x00);
      return ppu;
    }

    test('color math runs when CGWSEL selects "always" (0)', () {
      final ppu = backdropPpu();
      ppu.write(0x2130, 0x00); // math always, fixed color as sub screen
      ppu.write(0x2131, 0x20); // add, backdrop participates
      ppu.write(0x2132, 0x9f); // fixed color: blue 31
      ppu.renderScanline(1);
      expect(ppu.buffer[0], 0xffff00ff);
    });

  });

  group('OAM', () {

  });
}
