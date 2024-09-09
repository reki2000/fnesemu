import 'dart:typed_data';

import '../../spec.dart';
import 'vdc.dart';

mixin VdcRenderer on Vdc {
  final buffer = Uint32List(Spec.width * Spec.height);

  final Uint32List palette = Uint32List(16);

  int line = 0;
  int h = 0;

  bool initialized = false;

  initTest() {
    if (initialized) {
      return;
    }
    initialized = true;
    for (int c = 0; c < palette.length; c++) {
      final bright = ((c & 0x8) != 0 ? 0x80 : 0);
      final r = ((c & 0x04) != 0 ? 0x7f : 0) | bright;
      final g = ((c & 0x02) != 0 ? 0x7f : 0) | bright;
      final b = ((c & 0x01) != 0 ? 0x7f : 0) | bright;
      palette[c] = 0xff000000 | (r << 16) | (g << 8) | b;
    }

    for (var i = 0; i < 32 * 32; i++) {
      vram[i] = 0x400 + i;
    }
    for (var i = 0x4000; i < 0x8000; i++) {
      vram[i] = i - 0x4000;
    }
  }

  // render a line;
  void exec() {
    initTest();
    if (line >= 14 && line < 240) {
      for (h = 0; h < Spec.width; h++) {
        // if (h != 0 || line != 0) {
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
    final tile = vram[((line >> 3) << 5) | (h >> 3)];
    final paletteNo = tile >> 12;
    final addr = ((tile & 0xfff) << 4) | line & 0x07;
    final pattern0 = vram[addr];
    final pattern1 = vram[addr + 8];

    final shiftBits = (7 - (h & 7)) << 1;
    final colorNo =
        (pattern0 >> shiftBits) & 0x03 | ((pattern1 >> shiftBits) << 2) & 0xc;

    // print(
    //     "p:${palette[colorNo].toRadixString(16)}, colorNo:$colorNo, h:$h, line:$line, tile: ${hex16(tile)}, palette: $paletteNo, addr: ${hex16(addr)}, pattern0: $pattern0, pattern1: $pattern1");

    pset(h, line, paletteNo, colorNo);
  }

  pset(h, l, paletteNo, colorNo) {
    buffer[l * Spec.width + h] = palette[colorNo];
  }
}
