import 'package:fnesemu_core/src/core/gba/bus.dart';
import 'package:fnesemu_core/src/core/gba/gba.dart';
import 'package:fnesemu_core/src/core/gba/ppu.dart';
import 'package:fnesemu_core/src/util/int.dart';
import 'package:test/test.dart';

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

  });

  group('Ppu', () {

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
