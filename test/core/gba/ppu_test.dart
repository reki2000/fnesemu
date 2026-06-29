import 'package:fnesemu/core/gba/bus.dart';
import 'package:fnesemu/core/gba/ppu.dart';
import 'package:test/test.dart';

// expected ABGR8888 value for a BGR555 colour (mirrors Ppu's internal table).
int abgr(int bgr555) {
  final r5 = bgr555 & 0x1f, g5 = (bgr555 >> 5) & 0x1f, b5 = (bgr555 >> 10) & 0x1f;
  final r = (r5 << 3) | (r5 >> 2);
  final g = (g5 << 3) | (g5 >> 2);
  final b = (b5 << 3) | (b5 >> 2);
  return 0xff000000 | (b << 16) | (g << 8) | r;
}

void main() {
  group('Ppu', () {
    test('mode 3 bitmap renders a direct-colour pixel', () {
      final bus = Bus();
      final ppu = Ppu(bus);

      // mode 3, BG2 enabled, identity affine.
      bus.write16(0x04000000, 0x0403); // DISPCNT
      bus.write16(0x04000020, 0x0100); // BG2PA = 1.0
      bus.write16(0x04000026, 0x0100); // BG2PD = 1.0

      const color = 0x001f; // red
      bus.write16(0x06000000 + (20 * 240 + 10) * 2, color);

      for (int y = 0; y < 160; y++) {
        ppu.renderLine(y);
      }

      expect(ppu.buffer[20 * 240 + 10], abgr(color));
      expect(ppu.buffer[0], abgr(0)); // untouched pixel = palette/backdrop 0
    });

    test('mode 4 bitmap renders a paletted pixel', () {
      final bus = Bus();
      final ppu = Ppu(bus);

      bus.write16(0x04000000, 0x0404); // mode 4, BG2 on
      bus.write16(0x04000020, 0x0100);
      bus.write16(0x04000026, 0x0100);

      bus.write16(0x05000000 + 5 * 2, 0x7c00); // palette[5] = blue
      bus.write8(0x06000000 + 30 * 240 + 40, 5); // pixel index 5

      for (int y = 0; y < 160; y++) {
        ppu.renderLine(y);
      }

      expect(ppu.buffer[30 * 240 + 40], abgr(0x7c00));
    });

    test('mode 0 text background renders a 4bpp tile pixel', () {
      final bus = Bus();
      final ppu = Ppu(bus);

      // mode 0, BG0 on. BG0CNT: screen base block 1 (0x800), char base 0.
      bus.write16(0x04000000, 0x0100);
      bus.write16(0x04000008, 0x0100); // BG0CNT screenBase=1

      bus.write16(0x05000000 + 1 * 2, 0x03e0); // palette[1] = green
      bus.write8(0x06000000, 0x01); // tile0 px(0,0) nibble = 1
      // map entry 0 at screen base 0x800 defaults to 0 (tile0, palBank0).

      ppu.renderLine(0);

      expect(ppu.buffer[0], abgr(0x03e0));
    });

    test('sprite renders above background with priority', () {
      final bus = Bus();
      final ppu = Ppu(bus);

      bus.write16(0x04000000, 0x1000); // OBJ enable, 2D mapping, mode 0

      // OBJ palette[1] = white.
      bus.write16(0x05000000 + (256 + 1) * 2, 0x7fff);
      // sprite tile 0 lives at 0x10000; px(0,0) nibble = 1.
      bus.write8(0x06010000, 0x01);

      // OAM sprite 0: y=0, x=0, 8x8, 4bpp, tile 0, priority 0.
      bus.write16(0x07000000, 0x0000); // attr0: y=0, normal, square
      bus.write16(0x07000002, 0x0000); // attr1: x=0, size0
      bus.write16(0x07000004, 0x0000); // attr2: tile0, prio0, pal0

      ppu.renderLine(0);

      expect(ppu.buffer[0], abgr(0x7fff));
    });
  });
}
