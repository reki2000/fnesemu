import 'dart:typed_data';

import '../../spec.dart';
import 'vdc.dart';

mixin VdcRenderer on Vdc {
  final buffer = Uint32List(Spec.width * Spec.height);

  final Uint32List palette = Uint32List(16);

  int line = 0;
  int h = 0;

  // render a line;
  void exec() {
    if (line >= 14 && line < 256) {
      for (h = 0; h < Spec.width; h++) {
        // if (h != 0 || line != 14) {
        //   continue;
        // }
        render();
      }
    }
    line++;
    if (line == 261) {
      vd = 0x20;
    }
    if (line == 261) {
      line = 0;
    }
  }

  void render() {
    final tile = vram[((line >> 3) << bgWidthBits) | (h >> 3)];
    final paletteNo = tile >> 12;
    int colorNo = 0;

    final shiftBits = (7 - (h & 7));
    if (vramDotWidth == 3) {
      final addr = ((tile & 0xfff) << 3) | line & 0x07;
      final pattern0 = (vram[addr]) >> (shiftBits + 8);
      final pattern1 = (vram[addr]) >> shiftBits;
      colorNo = bgTreatPlane23Zero
          ? ((pattern0 & 0x01) | (pattern1 << 1) & 0x02)
          : ((pattern0 << 2) & 0x04 | (pattern1 << 3) & 0x08);
    } else {
      final addr = ((tile & 0xfff) << 4) | line & 0x07;
      final pattern01 = (vram[addr]) >> shiftBits;
      final pattern23 = (vram[addr + 8]) >> shiftBits;

      colorNo = (pattern01 & 0x01) |
          (pattern01 >> 7) & 0x02 |
          (pattern23 << 2) & 0x04 |
          (pattern23 << 5) & 0x08;
    }

    // print(
    //     "p:${palette[colorNo].toRadixString(16)}, colorNo:$colorNo, h:$h, line:$line, tile: ${hex16(tile)}, palette: $paletteNo, addr: ${hex16(addr)}, pattern0: $pattern0, pattern1: $pattern1");

    pset(h, line, paletteNo, colorNo);
  }

  static const map3to8 = [
    0x00,
    0x24,
    0x49,
    0x6d,
    0x92,
    0xb6,
    0xdb,
    0xff,
  ];

  pset(h, l, paletteNo, colorNo) {
    final c = colorTable[(paletteNo << 4) | colorNo];
    final r = map3to8[c & 0x07];
    final g = map3to8[(c >> 3) & 0x07];
    final b = map3to8[(c >> 6) & 0x07];
    buffer[l * Spec.width + h] = 0xff000000 | r | (g << 8) | (b << 16);
  }
}
