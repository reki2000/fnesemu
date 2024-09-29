// Project imports:
import '../../../util.dart';
import '../nes.dart';
import 'ppu.dart';

class _BG {
  final int char1;
  final int char2;
  final int palette;
  const _BG({required this.char1, required this.char2, required this.palette});
}

class _Obj {
  static const int _unusedIndex = 64;
  bool unused() => index == _unusedIndex;

  int index = _unusedIndex; // OAM index: 64 means unused
  int x = 0;
  bool isPrior = false;
  int palette = 0;
  int pattern0 = 0;
  int pattern1 = 0;
}

extension Take3<T> on List<T> {
  List<R> take3<R>(R Function(T, T, T) transform) => [
        for (int i = 0; i < length - 1; i += 3)
          transform(this[i], this[i + 1], this[i + 2]),
      ];
}

extension PpuRenderer on Ppu {
  // base vram address for palette
  static const paletteBase = 0x3f00;

  // https://wiki.nesdev.org/w/index.php/PPU_palettes
  static final _colorRGB = """
 84  84  84    0  30 116    8  16 144   48   0 136   68   0 100   92   0  48   84   4   0   60  24   0   32  42   0    8  58   0    0  64   0    0  60   0    0  50  60    0   0   0  0 0 0  0 0 0
152 150 152    8  76 196   48  50 236   92  30 228  136  20 176  160  20 100  152  34  32  120  60   0   84  90   0   40 114   0    8 124   0    0 118  40    0 102 120    0   0   0  0 0 0  0 0 0
236 238 236   76 154 236  120 124 236  176  98 236  228  84 236  236  88 180  236 106 100  212 136  32  160 170   0  116 196   0   76 208  32   56 204 108   56 180 204   60  60  60  0 0 0  0 0 0
236 238 236  168 204 236  188 188 236  212 178 236  236 174 236  236 174 212  236 180 176  228 196 144  204 210 120  180 222 120  168 226 144  152 226 180  160 214 228  160 162 160  0 0 0  0 0 0
"""
      .split(RegExp(r'\s+'))
      .where((s) => s.isNotEmpty)
      .map((s) => int.parse(s))
      .toList(growable: false);

  // pre-calculate ARGB value
  static final _colorRGBA = _colorRGB
      .take3((r, g, b) => 0xff000000 | (b << 16) | (g << 8) | r)
      .toList(growable: false);

  void _wrapAroundX() {
    if (vramAddr & 0x1f == 31) {
      vramAddr &= ~0x001F;
      vramAddr ^= 0x0400;
    } else {
      vramAddr++;
    }
  }

  void _wrapAroundY() {
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

  static final objs = [
    _Obj(),
    _Obj(),
    _Obj(),
    _Obj(),
    _Obj(),
    _Obj(),
    _Obj(),
    _Obj()
  ];

  List<_Obj> _fetchObj() {
    // sprite
    final objBase = objTable() ? 0x1000 : 0;
    final objVSize = objSize16() ? 16 : 8;

    for (final obj in objs) {
      obj.index = _Obj._unusedIndex;
    }

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
        readVram(objSize16() ? 0x1000 : objBase);
        continue;
      }

      final objNo = obj.index;
      final objY = objRam[objNo * 4];
      final pattern = objRam[objNo * 4 + 1];

      // attribute
      // 76543210
      // ||||||||
      // ||||||++- Palette (4 to 7) of sprite
      // |||+++--- Unimplemented
      // ||+------ Priority (0: in front of background; 1: behind background)
      // |+------- Flip sprite horizontally
      // +-------- Flip sprite vertically
      final attribute = objRam[objNo * 4 + 2];

      final objScanY = scanLine - objY - 1;
      final objFineY = objScanY & 0x07;
      final flipV = bit7(attribute);

      // pattern address
      // size8x8:
      //   +0000 (00a 00b) x8 (01a 01b) x8 (02a 02b) x8 ... (a,b is plane0,1)
      // size8x16:
      //   +0000 (00a 00b) x8 (00c 00d) x8 (02a 02b) x8 ... (c,d is plane0,1 for the lower half)
      //   +1000 (01a 01b) x8 (01c 01d) x8 (03a 03b) x8 ....
      late final int objAddr;
      if (objSize16()) {
        final lowerOffset = ((objScanY >= 8) ? 1 : 0) ^ (flipV ? 1 : 0);
        objAddr =
            (((pattern & 0xfe) + lowerOffset) << 4) | ((pattern & 0x01) << 12);
      } else {
        objAddr = objBase | (pattern << 4);
      }

      final offset = flipV ? (7 - objFineY) : objFineY;

      final p0 = readVram(objAddr + offset);
      final p1 = readVram(objAddr + offset + 8);

      final flipH = bit6(attribute);
      obj.pattern0 = flipH ? flip8(p0) : p0;
      obj.pattern1 = flipH ? flip8(p1) : p1;
      obj.pattern1 <<= 1;

      obj.isPrior = !bit5(attribute);
      obj.palette = attribute & 0x03;
      obj.x = objRam[objNo * 4 + 3];
    }

    return objs;
  }

  int _fetchBGPalette() {
    // vram:      0yyy PPYY YYYX XXXX
    // colorBase: 0010 PP11 11YY YXXX
    final colorBase = 0x23c0 |
        (vramAddr & 0x0c00) |
        ((vramAddr >> 4) & 0x38) |
        ((vramAddr >> 2) & 0x07);
    return readVram(colorBase);
  }

  _BG _fetchBG(int bgBase, int fineY) {
    final nameBase = 0x2000 | (vramAddr & 0x0fff);
    final bgChar = readVram(nameBase);
    final patternAddr = bgBase + bgChar * 16 + fineY;
    final bgChar1 = readVram(patternAddr);
    final bgChar2 = readVram(patternAddr + 8);
    final palette =
        _fetchBGPalette() >> ((vramAddr & 0x02) | ((vramAddr >> 4) & 0x04));
    final bgPalette = palette & 0x03;
    _wrapAroundX();
    return _BG(char1: bgChar1, char2: bgChar2, palette: bgPalette);
  }

  int _renderObjs(List<_Obj> objs, int x, int bgColorNum, int color) {
    for (final o in objs) {
      if (!o.unused() && o.x <= x && x < o.x + 8) {
        final objColorNum = ((o.pattern0 & 0x80) | (o.pattern1 & 0x100)) >> 7;
        o.pattern0 <<= 1;
        o.pattern1 <<= 1;

        if (objColorNum == 0) {
          continue;
        }

        if (bgColorNum != 0) {
          if (o.index == 0 && objColorNum != 0) {
            detectObj0 = true;
          }

          if (!o.isPrior) {
            return color;
          }
        }

        return readVram(paletteBase + 0x10 + o.palette * 4 + objColorNum);
      }
    }
    return color;
  }

  void renderLine() {
    if (showBg()) {
      // dot 257 of prev line: reset horizontal position
      // v: ....A.. ...BCDEF <- t: ....A.. ...BCDEF
      vramAddr = vramAddr & ~0x41f | tmpVramAddr & 0x41f;

      if (scanLine == 0) {
        // dot 280 to 304 of prev line: reset vertical position at pre-render line
        // v: GHIA.BC DEF..... <- t: GHIA.BC DEF.....
        vramAddr = vramAddr & ~0x7be0 | tmpVramAddr & 0x7be0;
      }
    }

    final fineY = (vramAddr >> 12) & 0x07;

    // dot 257-320 of prev line: obj read
    final objs = _fetchObj();

    final bgBase = bgTable() ? 0x1000 : 0x0000;
    final color0 = readVram(paletteBase);

    int bgChar1 = 0;
    int bgChar2 = 0;
    int bgPalette = 0;
    int bgPaletteNext = 0;

    // dot 321-336 of previ line: read the first pattern
    if (showBg()) {
      final bg = _fetchBG(bgBase, fineY);
      bgChar1 = bg.char1 << 8;
      bgChar2 = bg.char2 << 8;
      bgPalette = bg.palette;
    }

    // dot 337-340
    // todo: dummy vram fetch for mmc5

    // dot 0:

    // dot 1-256: draw each pixel
    for (int x = 0; x < 256; x++) {
      var bgColorNum = 0;
      var color = color0;
      final xand7 = x & 0x07;

      if (showBg()) {
        if (xand7 == 0) {
          final bg = _fetchBG(bgBase, fineY);
          bgChar1 |= bg.char1;
          bgChar2 |= bg.char2;
          bgPaletteNext = bg.palette;
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
        color = _renderObjs(objs, x, bgColorNum, color);
      }

      buffer[scanLine * Nes.imageWidth + x] = _colorRGBA[color & 0x3f];
    }

    // wrap around Y
    if (showBg()) {
      _wrapAroundY();
    }
  }
}
