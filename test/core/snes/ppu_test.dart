import 'package:fnesemu/core/snes/component/ppu.dart';
import 'package:fnesemu/core/snes/component/ppu_render.dart';
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

    test('halved subtraction', () {
      final ppu = backdropPpu();
      ppu.write(0x2131, 0xe0); // subtract, half, backdrop
      ppu.write(0x2132, 0x21); // fixed color: red 1
      ppu.renderScanline(1);
      // (31 - 1) / 2 = 15 -> 8-bit 0x7b
      expect(ppu.buffer[0], 0xff00007b);
    });

    test('master brightness is applied', () {
      final ppu = backdropPpu();
      ppu.write(0x2100, 0x00);
      ppu.renderScanline(1);
      expect(ppu.buffer[0], 0xff000000);
    });
  });

  test('a vram read after the dummy read starts at the set address', () {
    final ppu = Ppu();
    ppu.write(0x2115, 0x80); // increment after the high byte
    ppu.write(0x2116, 0x00);
    ppu.write(0x2117, 0x10);
    for (final v in [0x11, 0x22, 0x33, 0x44]) {
      ppu.write(0x2118, v);
      ppu.write(0x2119, v + 1);
    }
    ppu.write(0x2116, 0x00);
    ppu.write(0x2117, 0x10);
    ppu.read(0x2139); // dummy read: the buffer still holds the old word
    ppu.read(0x213a);
    expect([ppu.read(0x2139), ppu.read(0x213a)], [0x11, 0x12]);
    expect([ppu.read(0x2139), ppu.read(0x213a)], [0x22, 0x23]);
  });
}
