import 'package:fnesemu/core/gba/bus.dart';
import 'package:fnesemu/core/gba/ppu.dart';
import 'package:fnesemu/util/int.dart';
import 'package:test/test.dart';
import 'package:fnesemu/core/gba/gba.dart';
import 'support/arm7_asm.dart';

// expected ABGR8888 value for a BGR555 colour (mirrors Ppu's internal table).
int abgr(int bgr555) {
  final r5 = bgr555.mask5, g5 = bgr555.shr5.mask5, b5 = bgr555.shr10.mask5;
  final r = r5.shl3 | r5.shr2;
  final g = g5.shl3 | g5.shr2;
  final b = b5.shl3 | b5.shr2;
  return 0xff000000 | b.shl16 | g.shl8 | r;
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

  test('DISPSTAT HBlank flag can be polled during the line', () {
    final gba = Gba()..setRom(wordBytes([aBSelf]));
    var sawHblank = false;
    while (gba.bus.vcount == 0) {
      gba.exec(false);
      if (gba.bus.read16(0x04000004).bit1) {
        sawHblank = true;
        expect(gba.bus.vcount, 0);
      }
    }
    expect(sawHblank, isTrue);
    expect(gba.bus.read16(0x04000004) & 2, 0);
  });

  group('Ppu', () {
    test('8bpp BG tiles beyond BG VRAM do not crash', () {
      final bus = Bus();
      final ppu = Ppu(bus);
      bus.write16(0x04000000, 0x0100); // mode 0, BG0
      bus.write16(0x04000008, 0x008c); // char base 3, 8bpp, screen base 0
      for (int i = 0; i < 0x800; i += 2) {
        bus.write16(0x06000000 + i, 0x03ff); // tile 1023
      }
      expect(() => ppu.renderLine(0), returnsNormally);
    });

    test('OBJ tile numbers wrap within OBJ VRAM', () {
      final bus = Bus();
      final ppu = Ppu(bus);
      bus.write16(0x04000000, 0x1040); // OBJ on, 1D mapping
      bus.write16(0x07000000, 0x2000); // y=0, 256 colours, square
      bus.write16(0x07000002, 0xc000); // x=0, 64x64
      bus.write16(0x07000004, 0x03f0); // tile 1008
      for (int y = 0; y < 64; y++) {
        expect(() => ppu.renderLine(y), returnsNormally);
      }
    });

    test('OBJ disabled hides sprites even with the OBJ window on', () {
      final bus = Bus();
      final ppu = Ppu(bus);
      bus.write16(0x04000000, 0x8040); // OBJ window on, OBJ off
      bus.write16(0x0400004a, 0x003f); // WINOUT: everything visible
      bus.write16(0x05000202, 0x001f); // OBJ palette 1 = red
      bus.write16(0x06010000, 0x1111); // tile 0: colour 1
      bus.write16(0x07000000, 0x0000);
      bus.write16(0x07000002, 0x0000);
      bus.write16(0x07000004, 0x0000);
      ppu.renderLine(0);
      expect(ppu.buffer[0], isNot(0xff0000ff));
    });

    test('mid-frame BG2Y write reloads the affine reference point', () {
      final bus = Bus();
      final ppu = Ppu(bus);
      bus.write16(0x04000000, 0x0403); // mode 3, BG2
      bus.write16(0x04000020, 0x0100);
      bus.write16(0x04000026, 0x0100);
      bus.write16(0x06000000, 0x001f); // (0,0) red

      for (int y = 0; y < 10; y++) {
        ppu.renderLine(y);
      }
      bus.write32(0x0400002c, 0); // BG2Y = 0 -> line 10 shows row 0
      ppu.renderLine(10);
      expect(ppu.buffer[10 * 240], 0xff0000ff);
    });
  });
}
