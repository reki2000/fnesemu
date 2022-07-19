// Project imports:
import 'ppu.dart';
import 'util.dart';

extension PpuRenderer on Ppu {
  void putRGBPixel(int y, int x, int r, int g, int b) {
    final index = (y * screenWidth + x) * 4;
    buffer[index + 0] = r;
    buffer[index + 1] = g;
    buffer[index + 2] = b;
    buffer[index + 3] = 0xff;
  }

  // https://wiki.nesdev.org/w/index.php/PPU_palettes
  static final colorRGB = """
 84  84  84    0  30 116    8  16 144   48   0 136   68   0 100   92   0  48   84   4   0   60  24   0   32  42   0    8  58   0    0  64   0    0  60   0    0  50  60    0   0   0  0 0 0  0 0 0
152 150 152    8  76 196   48  50 236   92  30 228  136  20 176  160  20 100  152  34  32  120  60   0   84  90   0   40 114   0    8 124   0    0 118  40    0 102 120    0   0   0  0 0 0  0 0 0
236 238 236   76 154 236  120 124 236  176  98 236  228  84 236  236  88 180  236 106 100  212 136  32  160 170   0  116 196   0   76 208  32   56 204 108   56 180 204   60  60  60  0 0 0  0 0 0
236 238 236  168 204 236  188 188 236  212 178 236  236 174 236  236 174 212  236 180 176  228 196 144  204 210 120  180 222 120  168 226 144  152 226 180  160 214 228  160 162 160  0 0 0  0 0 0
"""
      .split(RegExp(r'\s+'))
      .where((s) => s.isNotEmpty)
      .map((s) => int.parse(s))
      .toList(growable: false);

  // color: 0-0x3f
  void putPixel(int y, int x, int color) {
    color &= 0x3f;
    final index = color * 3;
    final r = colorRGB[index];
    final g = colorRGB[index + 1];
    final b = colorRGB[index + 2];

    putRGBPixel(y, x, r, g, b);
  }

  List<ObjBuffer> fetchObjBuffer() {
    // sprite
    final objBase = objTable() ? 0x1000 : 0;
    final objVSize = objSize() ? 16 : 8;

    final objs = List.generate(8, (_) => ObjBuffer());

    if (!showSprite()) {
      return objs;
    }

    // detect objects on this scanline
    int objCount = 0;
    for (int i = 0; i < 64; i++) {
      final objy = objRam[i * 4];
      if (objy < scanLine && scanLine <= objy + objVSize) {
        objs[objCount++].index = i;
        if (objCount == 8) {
          break;
        }
      }
    }

    // fetch object pattern data from vram
    for (final obj in objs) {
      if (obj.unused()) {
        // read vram anyway for mapper rom's edge detection
        readVram(objSize() ? 0x1000 : objBase);
        continue;
      }

      final objNo = obj.index;
      final objY = objRam[objNo * 4];
      final pattern = objRam[objNo * 4 + 1];
      final attribute = objRam[objNo * 4 + 2];

      final objScanY = scanLine - objY - 1;
      final lowerOffset = (objScanY >= 8) ? 1 : 0;
      final objAddr = objSize()
          ? (((pattern & 0xfe) + lowerOffset) * 16 | (pattern & 0x01) << 12)
          : objBase | (pattern * 16);

      // flip vertically
      final objFineY = objScanY & 0x07;
      final offset = bit7(attribute) ? ((objVSize - 1) - objFineY) : objFineY;

      final p0 = readVram(objAddr + offset);
      final p1 = readVram(objAddr + offset + 8);

      final needHFlip = bit6(attribute);
      obj.pattern0 = needHFlip ? flip8(p0) : p0;
      obj.pattern1 = (needHFlip ? flip8(p1) : p1) << 1;

      obj.isPrior = !bit5(attribute);
      obj.palette = attribute & 0x03;
      obj.x = objRam[objNo * 4 + 3];
    }

    return objs;
  }

  void vramAddrWrapAroundX() {
    if (vramAddr & 0x1f == 31) {
      vramAddr &= ~0x001F;
      vramAddr ^= 0x0400;
    } else {
      vramAddr++;
    }
  }

  void vramAddrWrapAroundY() {
    if (((vramAddr >> 12) & 0x07) < 7) {
      vramAddr += 0x1000;
    } else {
      vramAddr &= 0xfff;
      var y = (vramAddr >> 5) & 0x1f;
      if (y == 29) {
        // line 240
        y = 0;
        vramAddr ^= 0x800;
      } else if (y == 31) {
        // line 256
        y = 0;
      } else {
        y++;
      }
      vramAddr = (vramAddr & ~0x03E0) | (y << 5);
    }
  }

  int fetchBgPalette() {
    // vram:      0yyy PPYY YYYX XXXX
    // colorBase: 0010 PP11 11YY YXXX
    final colorBase = 0x23c0 |
        (vramAddr & 0x0c00) |
        ((vramAddr >> 4) & 0x38) |
        ((vramAddr >> 2) & 0x07);
    return readVram(colorBase);
  }

  void renderLine() {
    if (showBg()) {
      // reset horizontal position
      // v: ....A.. ...BCDEF <- t: ....A.. ...BCDEF
      vramAddr = vramAddr & ~0x41f | tmpVramAddr & 0x41f;

      // reset vertical position at pre-render line
      // v: GHIA.BC DEF..... <- t: GHIA.BC DEF.....
      if (scanLine == 0) {
        vramAddr = vramAddr & ~0x7be0 | tmpVramAddr & 0x7be0;
      }
    }

    final fineY = (vramAddr >> 12) & 0x07;

    final objs = fetchObjBuffer();

    final bgBase = bgTable() ? 0x1000 : 0x0000;
    const paletteBase = 0x3f00;
    final color0 = readVram(paletteBase);

    int bgChar1 = 0;
    int bgChar2 = 0;
    int bgPalette = 0;
    int bgPaletteNext = 0;

    // at previous scan line's cycle 257-342
    if (showBg()) {
      final nameBase = 0x2000 | (vramAddr & 0x0fff);
      final bgChar = readVram(nameBase);
      final patternAddr = bgBase + bgChar * 16 + fineY;
      bgChar1 = readVram(patternAddr) << 8;
      bgChar2 = readVram(patternAddr + 8) << 8;
      final palette =
          fetchBgPalette() >> ((vramAddr & 0x02) | ((vramAddr >> 4) & 0x04));
      bgPalette = palette & 0x03;
      vramAddrWrapAroundX();
    }

    // draw each pixel
    for (int x = 0; x < 256; x++) {
      var bgColorNum = 0;
      var color = color0;
      final xand7 = x & 0x07;

      if (showBg()) {
        if (xand7 == 0) {
          final nameBase = 0x2000 | (vramAddr & 0x0fff);
          final bgChar = readVram(nameBase);
          final patternAddr = bgBase + bgChar * 16 + fineY;
          bgChar1 |= readVram(patternAddr);
          bgChar2 |= readVram(patternAddr + 8);
          final palette = fetchBgPalette() >>
              ((vramAddr & 0x02) | ((vramAddr >> 4) & 0x04));
          bgPaletteNext = palette & 0x03;
          vramAddrWrapAroundX();
        }

        if (!(clipLeftEdgeBg() && 0 <= x && x < 8)) {
          bgColorNum = ((bgChar1 >> (15 - fineX)) & 0x01) |
              ((bgChar2 >> (14 - fineX)) & 0x02);
          if (bgColorNum != 0) {
            final bgPaletteNum =
                (xand7 + fineX) >= 8 ? bgPaletteNext : bgPalette;
            color = readVram(paletteBase + (bgPaletteNum << 2) + bgColorNum);
          }
        }

        // shift pattern register
        bgChar1 <<= 1;
        bgChar2 <<= 1;
        if (xand7 == 7) {
          bgPalette = bgPaletteNext;
        }
      }

      // overwrite dot color by obj
      if (!(clipLeftEdgeSprite() && 1 <= x && x <= 8) && showSprite()) {
        for (final o in objs) {
          if (o.unused()) {
            continue;
          }
          if (o.x <= x && x < o.x + 8) {
            final objColorNum =
                ((o.pattern0 & 0x80) | (o.pattern1 & 0x100)) >> 7;
            o.pattern0 <<= 1;
            o.pattern1 <<= 1;

            if (o.index == 0 && objColorNum != 0 && bgColorNum != 0) {
              detectObj0 = true;
            }

            if (objColorNum == 0 || (!o.isPrior && bgColorNum != 0)) {
              continue;
            }

            color = readVram(paletteBase + 0x10 + o.palette * 4 + objColorNum);
            break;
          }
        }
      }

      putPixel(scanLine, x, color);
    }

    // wrap around Y
    if (showBg()) {
      vramAddrWrapAroundY();
    }
  }
}

// 76543210
// ||||||||
// ||||||++- Palette (4 to 7) of sprite
// |||+++--- Unimplemented
// ||+------ Priority (0: in front of background; 1: behind background)
// |+------- Flip sprite horizontally
// +-------- Flip sprite vertically

class ObjBuffer {
  static const int _unusedIndex = 64;
  bool unused() => index == _unusedIndex;

  int index = _unusedIndex; // OAM index: 64 means unused
  int x = 0;
  bool isPrior = false;
  int palette = 0;
  int pattern0 = 0;
  int pattern1 = 0;
}
