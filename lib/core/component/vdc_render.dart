import 'dart:typed_data';

import '../../spec.dart';
import 'vdc.dart';

extension VdcRenderer on Vdc {
  static final buffer = Uint32List(Spec.width * Spec.height);

  static int line = 0;
  static int h = 0;

  // render a line;
  void exec() {
    if (line >= 14 && line < 256) {
      for (h = 0; h < Spec.width; h++) {
        // if (h != 0 || line != 14) {
        //   continue;
        // }
        _render();
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

  void _render() {
    final tile = vram[((line >> 3) << bgWidthBits) | (h >> 3)];
    final paletteNo = tile >> 12;
    int colorNo = 0;

    final shiftBits = (7 - (h & 7));
    if (vramDotWidth == 3) {
      final addr = ((tile & 0xfff) << 3) | line & 0x07;
      final pattern01 = (vram[addr]) >> shiftBits;
      colorNo = bgTreatPlane23Zero
          ? ((pattern01 & 0x01) | (pattern01 << 7) & 0x02)
          : ((pattern01 << 2) & 0x04 | (pattern01 << 5) & 0x08);
    } else {
      final addr = ((tile & 0xfff) << 4) | line & 0x07;
      final pattern01 = (vram[addr]) >> shiftBits;
      final pattern23 = (vram[addr + 8]) >> shiftBits;

      colorNo = (pattern01 & 0x01) |
          (pattern01 >> 7) & 0x02 |
          (pattern23 << 2) & 0x04 |
          (pattern23 << 5) & 0x08;
    }

    final c = colorTable[(paletteNo << 4) | colorNo];
    buffer[line * Spec.width + h] = _rgba[c];
  }

  // preliminary building an RGBA color map for all 512 colors
  static const _map3to8 = [
    0x00,
    0x24,
    0x49,
    0x6d,
    0x92,
    0xb6,
    0xdb,
    0xff,
  ];

  static final Uint32List _rgba = Uint32List.fromList(
    List.generate(512, (i) {
      final r = _map3to8[i & 0x07];
      final g = _map3to8[(i >> 3) & 0x07];
      final b = _map3to8[(i >> 6) & 0x07];
      return 0xff000000 | r | (g << 8) | (b << 16);
    }, growable: false),
  );
}
