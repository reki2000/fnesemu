import 'dart:typed_data';

import 'package:fnesemu/core/pce/component/cpu.dart';
import 'package:fnesemu/util/util.dart';

import 'vdc.dart';

class Sprite {
  late final int no;
  late final int x;
  late final int y;
  late final int patternNo;
  late final int paletteNo;
  late final bool cgModeTreal01Zero;
  late final bool vFlip;
  late final bool hFlip;
  late final int height;
  late final int width;
  late final bool priority;
  int p0 = 0;
  int p1 = 0;
  int p2 = 0;
  int p3 = 0;
  int fetchedX2 = -1;

  Sprite.of(List<int> sat, int i) {
    no = i >> 2;
    y = sat[i] & 0x3ff;
    x = sat[i + 1] & 0x3ff;

    cgModeTreal01Zero = sat[i + 2] & 0x01 != 0;
    vFlip = (sat[i + 3] & 0x8000) != 0;
    hFlip = (sat[i + 3] & 0x0800) != 0;
    priority = (sat[i + 3] & 0x80) != 0;
    paletteNo = ((sat[i + 3] & 0x0f) << 4) | 0x100;

    height = switch ((sat[i + 3] >> 12) & 0x03) { 0 => 16, 1 => 32, _ => 64 };
    width = switch ((sat[i + 3] >> 8) & 0x01) { 0 => 16, _ => 32 };

    int patternMask = 0;
    if (height == 64) {
      patternMask |= 0x06;
    } else if (height == 32) {
      patternMask |= 0x02;
    }
    if (width == 32) {
      patternMask |= 0x01;
    }
    patternNo = (sat[i + 2] >> 1) & 0x3ff & ~patternMask;
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

final Uint32List rgba = Uint32List.fromList(
  List.generate(512, (i) {
    final b = _map3to8[i & 0x07];
    final r = _map3to8[(i >> 3) & 0x07];
    final g = _map3to8[(i >> 6) & 0x07];
    return 0xff000000 | (b << 16) | (g << 8) | r;
  }, growable: false),
);

extension VdcRenderer on Vdc {
  static bool debug = false;

  static Uint32List buffer = Uint32List(0);

  static int bgRenderLine = 0;

  static int displayStartLine = 14;
  static int displayLine = 0;
  static int displayX = 0;

  static int frames = 0;

  resetRenderer() {
    bgRenderLine = 0;
    frames = 0;
    buffer = Uint32List(hSize * vSize);
  }

  // render a line;
  void exec() {
    displayLine = scanLine - displayStartLine;

    if (displayLine == 0) {
      bgRenderLine = scrollY & bgScrollMaskY;
      // buffer = Uint32List(hSize * vSize);
    }

    // 242 lines
    if (0 <= displayLine && displayLine < 242) {
      _fillSpriteBuffer();

      for (scanX = 0; scanX < hSize; scanX++) {
        // if (!(h == 0 && line == 15)) {
        //   continue;
        // }
        _render();
      }

      // debug: show line counter by 16 lines
      if (debug &&
          displayLine >= 0x10 &&
          0 <= displayLine & 0x0f &&
          displayLine & 0x0f < 5) {
        for (int x = 0; x < 4 * 2; x++) {
          if ((displayLine & 0xf0).drawHexValue(x, displayLine & 0x0f, 2)) {
            buffer[(displayLine - 5) * hSize + 1 + x] = 0xffffffff;
          }
        }
      }

      if (displayLine + 0x40 == rasterCompareRegister) {
        if (enableRasterCompareIrq) {
          status |= Vdc.statusRasterCompare;
          bus.cpu.holdInterrupt(Interrupt.irq1);
        }
      }
    }

    if (scanLine == 260) {
      if (enableVBlank) {
        status |= Vdc.statusVBlank;
        bus.cpu.holdInterrupt(Interrupt.irq1);
      }
    }

    if (scanLine == 261) {
      execDmaSatb();
    }

    execDmaVram();

    scanLine++;
    bgRenderLine = (bgRenderLine + 1) & bgScrollMaskY;

    if (scanLine == 263) {
      scanLine = 0;
      frames++;
    }
  }

  void _render() {
    final spColor =
        enableSprite ? _renderSprite() : const SpriteColor(0, isPrior: false);
    final bgColor = enableBg ? _renderBg() : 0;

    final colorNo = spColor.isPrior
        ? spColor.color
        : (bgColor & 0x0f == 0)
            ? spColor.color
            : bgColor;

    int color = rgba[colorTable[colorNo]];

    buffer[displayLine * hSize + scanX] =
        spColor.isDirect ? spColor.color : color;
  }

  static int paletteNo = 0;
  static int pattern01 = 0;
  static int pattern23 = 0;

  int _renderBg() {
    final x = (scanX + scrollX) & bgScrollMaskX;

    if (scanX == 0 || (x & 0x07) == 0) {
      final nameTableAddress =
          (((bgRenderLine >> 3) & bgHeightMask) << bgWidthBits) |
              ((x >> 3) & bgWidthMask);
      // print(
      //     "h:$h, l:$line, x:$x, y:$y, sc:$scrollX, sy:$scrollY, addr: ${hex16(addr)}");
      final tile = vram[nameTableAddress];
      paletteNo = tile >> 12 << 4;

      if (vramDotWidth == 3) {
        final addr = ((tile & 0xfff) << 4) | bgRenderLine & 0x07;
        if (bgTreatPlane23Zero) {
          pattern01 = (vram[addr]);
          pattern23 = 0;
        } else {
          pattern01 = 0;
          pattern23 = (vram[addr]);
        }
      } else {
        final addr = ((tile & 0xfff) << 4) | bgRenderLine & 0x07;
        pattern01 = vram[addr];
        pattern23 = vram[addr + 8];
      }
    }

    final shiftBits = (7 - (x & 7));
    final p01 = pattern01 >> shiftBits;
    final p23 = pattern23 >> shiftBits;

    final colorNo = (p01 & 0x01) |
        (p01 >> 7) & 0x02 |
        (p23 << 2) & 0x04 |
        (p23 >> 5) & 0x08;

    return paletteNo | colorNo;
  }

  static final sprites =
      List<Sprite>.filled(64, Sprite.of(List.filled(4, 0), 0), growable: false);
  static final spriteBuf =
      List<Sprite>.filled(16, Sprite.of(List.filled(4, 0), 0), growable: false);
  static int spriteBufIndex = 0;

  static final sprite0 = List<bool>.filled(32, false); // x of sprite 0

  static int max = 0;

  fetchSatb() {
    for (int i = 0; i < sprites.length; i++) {
      sprites[i] = Sprite.of(sat, i * 4);
    }
  }

  _fillSpriteBuffer() {
    spriteBufIndex = 0;
    final y = displayLine + 64;

    for (final sp in sprites) {
      if (sp.y <= y && y < sp.y + sp.height) {
        if (spriteBufIndex == 16) {
          if (enableSpriteOverflow &&
              (status & Vdc.statusSpriteOverflow) == 0) {
            status |= Vdc.statusSpriteOverflow;
            bus.cpu.holdInterrupt(Interrupt.irq1);
          }
          break;
        }
        spriteBuf[spriteBufIndex++] = sp;
        sp.fetchedX2 = -1;
      }
    }

    if (enalbeSpriteCollision) {
      for (int i = 0; i < sprite0.length; i++) {
        sprite0[i] = false;
      }
    }
  }

  SpriteColor _renderSprite() {
    for (int i = 0; i < spriteBufIndex; i++) {
      final sp = spriteBuf[i];
      final hh = scanX + 32 - sp.x;

      if (0 <= hh && hh < sp.width) {
        final flippedX = sp.hFlip ? sp.width - hh - 1 : hh;
        final x = flippedX & 0x0f;
        final x2 = flippedX >> 4;

        final vv = displayLine + 64 - sp.y;
        final flippedY = sp.vFlip ? sp.height - vv - 1 : vv;
        final y = flippedY & 0x0f;
        final y2 = flippedY >> 4;

        if (debug) {
          // if (0 == hh && 0 == vv && sp.no == 0) {
          //   print(
          //       "sp: ${sp.no}, x: ${sp.x}, y: ${sp.y}, p: ${sp.patternNo}, pal: ${sp.paletteNo}, cg: ${sp.cgModeTreal01Zero}, v: ${sp.vFlip}, h: ${sp.hFlip}, h: ${sp.height}, w: ${sp.width}, p: ${sp.priority}");
          // }

          if (hh == 0 ||
              hh == sp.width - 1 ||
              vv == 0 ||
              vv == sp.height - 1 ||
              sp.no.drawValue(hh - 2, vv - 2, 2)) {
            return const SpriteColor(0xffffffff, isDirect: true);
          }
        }

        // fetch pattern data if x2 is changed
        if (x2 != sp.fetchedX2) {
          sp.fetchedX2 = x2;

          if (vramDotWidth == 3) {
            final addr = ((sp.patternNo + x2 + y2 * (sp.width >> 4)) << 5) + y;

            if (sp.cgModeTreal01Zero) {
              sp.p0 = sp.p1 = 0;
              sp.p2 = vram[addr + 00];
              sp.p3 = vram[addr + 16];
            } else {
              sp.p0 = vram[addr + 00];
              sp.p1 = vram[addr + 16];
              sp.p2 = sp.p3 = 0;
            }
          } else {
            final addr = ((sp.patternNo + x2 + (y2 << 1)) << 6) + y;
            sp.p0 = vram[addr + 00];
            sp.p1 = vram[addr + 16];
            sp.p2 = vram[addr + 32];
            sp.p3 = vram[addr + 48];
          }
        }

        final shiftBits = 15 - x;
        final colorNo = ((sp.p0 >> shiftBits) & 0x01) |
            (((sp.p1 >> shiftBits) << 1) & 0x02) |
            (((sp.p2 >> shiftBits) << 2) & 0x04) |
            (((sp.p3 >> shiftBits) << 3) & 0x08);

        if (enalbeSpriteCollision) {
          if (sp.no == 0) {
            sprite0[hh] = true;
          } else {
            if (colorNo != 0 &&
                sprite0[hh] &&
                status & Vdc.statusSpriteCollision == 0) {
              status |= Vdc.statusSpriteCollision;
              bus.cpu.holdInterrupt(Interrupt.irq1);
            }
          }
        }

        if (colorNo > 0) {
          return SpriteColor(sp.paletteNo | colorNo, isPrior: sp.priority);
        }
      }
    }

    return const SpriteColor(0, isPrior: false);
  }
}

class SpriteColor {
  final int color;
  final bool isDirect;
  final bool isPrior;

  const SpriteColor(this.color, {this.isDirect = false, this.isPrior = true});
}
