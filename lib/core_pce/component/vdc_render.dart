import 'dart:typed_data';

import 'package:fnesemu/core_pce/component/cpu.dart';

import '../../spec.dart';
import 'vdc.dart';

class Sprite {
  late final int no;
  late final int x;
  late final int y;
  late final int patternNo;
  late final int paletteNo;
  late final int pttern;
  late final bool cgModeTreal01Zero;
  late final bool vFlip;
  late final bool hFlip;
  late final int height;
  late final int width;
  late final bool priority;

  Sprite.of(List<int> sat, int i) {
    no = i >> 2;
    y = sat[i] & 0x3ff;
    x = sat[i + 1] & 0x3ff;
    patternNo = (sat[i + 2] >> 1) & 0x3ff;
    cgModeTreal01Zero = sat[i + 2] & 0x01 != 0;
    vFlip = (sat[i + 3] & 0x8000) != 0;
    hFlip = (sat[i + 3] & 0x0800) != 0;
    height = switch ((sat[i + 3] >> 12) & 0x03) { 0 => 16, 1 => 32, _ => 64 };
    width = switch ((sat[i + 3] >> 8) & 0x01) { 0 => 16, _ => 32 };
    priority = (sat[i + 3] & 0x80) != 0;
    paletteNo = sat[i + 3] & 0x0f;
  }
}

// preliminary building an RGBA color map for all 512 colors
const _map3to8 = [
  0x00,
  0x24,
  0x49,
  0x6d,
  0x92,
  0xb6,
  0xdb,
  0xff,
];

final Uint32List _rgba = Uint32List.fromList(
  List.generate(512, (i) {
    final b = _map3to8[i & 0x07];
    final r = _map3to8[(i >> 3) & 0x07];
    final g = _map3to8[(i >> 6) & 0x07];
    return 0xff000000 | (b << 16) | (g << 8) | r;
  }, growable: false),
);

extension VdcRenderer on Vdc {
  static final buffer = Uint32List(Spec.width * Spec.height);

  static int renderLine = 0;
  static int x = 0;

  static int displayStartLine = 14;

  // render a line;
  void exec() {
    if (displayLine == displayStartLine) {
      renderLine = scrollY;
    }

    // 242 lines
    if (displayLine >= displayStartLine &&
        displayLine < displayStartLine + 242) {
      _fillSpriteBuffer();

      for (h = 0; h < Spec.width; h++) {
        // if (!(h == 0 && line == 15)) {
        //   continue;
        // }
        _render();
      }

      if (displayLine - displayStartLine == rasterCompareRegister - 0x40) {
        if (enableRasterCompareIrq) {
          status |= Vdc.rr;
          bus.cpu.holdInterrupt(Interrupt.irq1);
        }
      }

      renderLine++;
    }

    if (displayLine == 260) {
      if (enableVBlank) {
        status |= Vdc.vd;
        bus.cpu.holdInterrupt(Interrupt.irq1);
      }

      execDmaSatb();

      for (int i = 0; i < sprites.length; i++) {
        sprites[i] = Sprite.of(sat, i * 4);
      }
    }

    if (displayLine == 264) {
      displayLine = 0;
    }

    execDmaVram();

    displayLine++;
  }

  static int paletteNo = 0;
  static int pattern01 = 0;
  static int pattern23 = 0;

  void _render() {
    final spColor = enableSprite ? _renderSprite() : 0;
    final bgColor = enableBg ? _renderBg() : 0;

    buffer[(displayLine - 14) * Spec.width + h] =
        _rgba[colorTable[(spColor & 0x0f != 0) ? spColor : bgColor]];
  }

  int _renderBg() {
    final x = (h + scrollX);

    if (h == 0 || (x & 0x07) == 0) {
      final nameTableAddress =
          (((renderLine >> 3) & bgHeightMask) << bgWidthBits) |
              ((x >> 3) & bgWidthMask);
      // print(
      //     "h:$h, l:$line, x:$x, y:$y, sc:$scrollX, sy:$scrollY, addr: ${hex16(addr)}");
      final tile = vram[nameTableAddress];
      paletteNo = tile >> 12;

      if (vramDotWidth == 3) {
        final addr = ((tile & 0xfff) << 4) | renderLine & 0x07;
        if (bgTreatPlane23Zero) {
          pattern01 = (vram[addr]);
          pattern23 = 0;
        } else {
          pattern01 = 0;
          pattern23 = (vram[addr]);
        }
      } else {
        final addr = ((tile & 0xfff) << 4) | renderLine & 0x07;
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

    return (paletteNo << 4) | colorNo;
  }

  static final sprites =
      List<Sprite>.filled(64, Sprite.of(List.filled(4, 0), 0), growable: false);
  static final spriteBuf =
      List<Sprite>.filled(16, Sprite.of(List.filled(4, 0), 0), growable: false);
  static int spriteBufIndex = 0;

  _fillSpriteBuffer() {
    spriteBufIndex = 0;
    final y = displayLine - displayStartLine + 64;
    for (final sp in sprites) {
      if (sp.y <= y && y < sp.y + sp.height) {
        spriteBuf[spriteBufIndex++] = sp;
        if (spriteBufIndex == 16) {
          break;
        }
      }
    }
  }

  int _renderSprite() {
    for (int i = 0; i < spriteBufIndex; i++) {
      final sp = spriteBuf[i];
      final hh = h + 32 - sp.x;

      if (0 <= hh && hh < sp.width) {
        final flippedX = sp.hFlip ? sp.width - hh : hh;
        final x = flippedX & 0x0f;
        final x2 = flippedX >> 4;

        final vv = displayLine - displayStartLine + 64 - sp.y;
        final flippedY = sp.vFlip ? sp.height - vv : vv;
        final y = flippedY & 0x0f;
        final y2 = flippedY >> 4;

        // const borderColor = 0x100 | 0xff;
        // if (hh == 0 || hh == sp.width - 1) {
        //   return borderColor;
        // }

        // if (vv == 0 || vv == sp.height - 1) {
        //   return borderColor;
        // }

        int p0, p1, p2, p3;
        if (vramDotWidth == 3) {
          final addr = ((sp.patternNo + x2 + y2 * (sp.width >> 4)) << 5) + y;

          if (sp.cgModeTreal01Zero) {
            p0 = p1 = 0;
            p2 = vram[addr + 00];
            p3 = vram[addr + 16];
          } else {
            p0 = vram[addr + 00];
            p1 = vram[addr + 16];
            p2 = p3 = 0;
          }
        } else {
          final addr = ((sp.patternNo + x2 + y2 * (sp.width >> 4)) << 6) + y;
          p0 = vram[addr + 00];
          p1 = vram[addr + 16];
          p2 = vram[addr + 32];
          p3 = vram[addr + 48];
        }

        final shiftBits = 15 - x;
        final colorNo = ((p0 >> shiftBits) & 0x01) |
            (((p1 >> shiftBits) << 1) & 0x02) |
            (((p2 >> shiftBits) << 2) & 0x04) |
            (((p3 >> shiftBits) << 3) & 0x08);

        if (colorNo != 0) {
          return 0x100 | (sp.paletteNo << 4) | colorNo;
        }
      }
    }

    return 0;
  }
}
