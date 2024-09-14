import 'dart:typed_data';

import 'package:fnesemu/core/component/cpu.dart';

import '../../spec.dart';
import 'vdc.dart';

extension VdcRenderer on Vdc {
  static final buffer = Uint32List(Spec.width * Spec.height);

  static int line = 0;
  static int h = 0;

  static int y = 0;
  static int x = 0;

  // render a line;
  void exec() {
    if (line >= 14 && line < 256) {
      y = (line - 14 + scrollY);
      // 242 lines
      for (h = 0; h < Spec.width; h++) {
        // if (!(h == 0 && line == 15)) {
        //   continue;
        // }
        _render();
      }

      if (line == rasterCompareRegister - 0x40) {
        if (enableRasterCompareIrq) {
          status |= Vdc.rr;
          bus.cpu.holdInterrupt(Interrupt.irq1);
        }
      }
    }

    if (line == 260) {
      if (enableVBlank) {
        status |= Vdc.vd;
        bus.cpu.holdInterrupt(Interrupt.irq1);
      }
      execDmaSatb();
    }

    if (line == 264) {
      line = 0;
    }

    execDmaVram();

    line++;
  }

  static int paletteNo = 0;
  static int pattern01 = 0;
  static int pattern23 = 0;

  void _render() {
    final x = (h + scrollX);

    if (h == 0 || (x & 0x07) == 0) {
      final nameTableAddress =
          (((y >> 3) & bgHeightMask) << bgWidthBits) | ((x >> 3) & bgWidthMask);
      // print(
      //     "h:$h, l:$line, x:$x, y:$y, sc:$scrollX, sy:$scrollY, addr: ${hex16(addr)}");
      final tile = vram[nameTableAddress];
      paletteNo = tile >> 12;

      if (vramDotWidth == 3) {
        final addr = ((tile & 0xfff) << 4) | y & 0x07;
        if (bgTreatPlane23Zero) {
          pattern01 = (vram[addr]);
          pattern23 = 0;
        } else {
          pattern01 = 0;
          pattern23 = (vram[addr]);
        }
      } else {
        final addr = ((tile & 0xfff) << 4) | y & 0x07;
        pattern01 = (vram[addr]);
        pattern23 = (vram[addr + 8]);
      }
    }

    final shiftBits = (7 - (x & 7));
    final p01 = pattern01 >> shiftBits;
    final p23 = pattern23 >> shiftBits;

    final colorNo = (p01 & 0x01) |
        (p01 >> 7) & 0x02 |
        (p23 << 2) & 0x04 |
        (p23 >> 5) & 0x08;

    final c = colorTable[(paletteNo << 4) | colorNo];
    buffer[(y % Spec.height) * Spec.width + (x % Spec.width)] = _rgba[c];
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
      final b = _map3to8[i & 0x07];
      final r = _map3to8[(i >> 3) & 0x07];
      final g = _map3to8[(i >> 6) & 0x07];
      return 0xff000000 | (b << 16) | (g << 8) | r;
      //return (r << 24) | (g << 16) | (b << 8) | 0xff;
    }, growable: false),
  );
}
