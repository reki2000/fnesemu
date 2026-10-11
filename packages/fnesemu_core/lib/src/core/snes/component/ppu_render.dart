import 'dart:typed_data';

import '../../../util/int.dart';

import 'ppu.dart';

/// a single layer slot in a mode's front-to-back priority order.
/// isObj=true: `hi` is the OBJ priority level (0-3), `bg` unused.
/// isObj=false: `bg` is the BG index (0-3 = BG1-4), `hi` is the tile's own
/// priority bit (0 or 1) that this slot matches.
typedef _Layer = (bool isObj, int bg, int hi);

/// BG sample stored as an int: color [7:0], palette [10:8], priority [11].
/// Zero means transparent; -1 marks a scanline-cache entry not yet fetched.
/// These static helpers keep the representation allocation-free.
abstract final class _BgSample {
  static const colorMask = 0xff;
  static const paletteMask = 0x7;
  static const paletteShift = 8;
  static const priorityShift = 11;
  static const transparent = 0;
  static const notFetched = -1;

  @pragma('vm:prefer-inline')
  static int pack(int colorIndex, int palette, int priority) =>
      colorIndex | (palette << paletteShift) | (priority << priorityShift);

  @pragma('vm:prefer-inline')
  static int colorIndex(int sample) => sample & colorMask;

  @pragma('vm:prefer-inline')
  static int palette(int sample) => (sample >> paletteShift) & paletteMask;

  @pragma('vm:prefer-inline')
  static int priority(int sample) => sample >> priorityShift;
}

/// Composited screen pixel: CGRAM index [7:0], source [10:8], OBJ palette [13:11].
/// Source 0-3 selects BG1-4, 4 selects OBJ, and 5 selects the backdrop.
/// This differs from _BgSample: the middle field identifies the winning layer,
/// and the upper field is its OBJ palette, not a BG priority bit.
abstract final class _ScreenPixel {
  static const cgramMask = 0xff;
  static const sourceMask = 0x7;
  static const sourceShift = 8;
  static const objPaletteShift = 11;
  static const objSource = 4;
  static const backdropSource = 5;
  static const backdrop = backdropSource << sourceShift;

  @pragma('vm:prefer-inline')
  static int pack(int cgramIndex, int source, int objPalette) =>
      cgramIndex | (source << sourceShift) | (objPalette << objPaletteShift);

  @pragma('vm:prefer-inline')
  static int cgramIndex(int pixel) => pixel & cgramMask;

  @pragma('vm:prefer-inline')
  static int source(int pixel) => (pixel >> sourceShift) & sourceMask;

  @pragma('vm:prefer-inline')
  static int objPalette(int pixel) => pixel >> objPaletteShift;
}

extension PpuRenderer on Ppu {
  // OBJ size table indexed by OBSEL's size-select field: [smallW,smallH,largeW,largeH]
  static const _objSizeTable = [
    [8, 8, 16, 16],
    [8, 8, 32, 32],
    [8, 8, 64, 64],
    [16, 16, 32, 32],
    [16, 16, 64, 64],
    [32, 32, 64, 64],
    [16, 32, 32, 64], // undocumented
    [16, 32, 32, 32], // undocumented
  ];

  // BG bit depth per implemented mode; index 0-3 = BG1-4, 0 = BG not present.
  // Modes 5/6 sample 512-wide BG rows; OBJ remains 256-wide and is stretched.
  static const _bgBpp = <int, List<int>>{
    0: [2, 2, 2, 2],
    1: [4, 4, 2, 0],
    2: [4, 4, 0, 0], // BG3 repurposed as offset-per-tile table
    3: [8, 4, 0, 0],
    4: [8, 2, 0, 0], // BG3 repurposed as offset-per-tile table
    5: [4, 2, 0, 0], // hi-res (512px); see class doc for the approximation
    6: [4, 0, 0, 0], // hi-res; BG3 repurposed as offset-per-tile table
  };

  static List<_Layer> _priorityOrder(int mode, bool bg3prio) {
    const obj = true, bgL = false;
    switch (mode) {
      case 0:
        return const [
          (obj, 0, 3), (bgL, 0, 1), (bgL, 1, 1), (obj, 0, 2),
          (bgL, 0, 0), (bgL, 1, 0), (obj, 0, 1), (bgL, 2, 1),
          (bgL, 3, 1), (obj, 0, 0), (bgL, 2, 0), (bgL, 3, 0), //
        ];
      case 1:
        if (bg3prio) {
          return const [
            (bgL, 2, 1), (obj, 0, 3), (bgL, 0, 1), (bgL, 1, 1),
            (obj, 0, 2), (bgL, 0, 0), (bgL, 1, 0), (obj, 0, 1),
            (obj, 0, 0), (bgL, 2, 0), //
          ];
        }
        return const [
          (obj, 0, 3), (bgL, 0, 1), (bgL, 1, 1), (obj, 0, 2),
          (bgL, 0, 0), (bgL, 1, 0), (obj, 0, 1), (bgL, 2, 1),
          (obj, 0, 0), (bgL, 2, 0), //
        ];
      case 2:
      case 3:
      case 4:
      case 5:
        return const [
          (obj, 0, 3), (bgL, 0, 1), (obj, 0, 2), (bgL, 1, 1),
          (obj, 0, 1), (bgL, 0, 0), (obj, 0, 0), (bgL, 1, 0), //
        ];
      case 6:
        return const [
          (obj, 0, 3), (bgL, 0, 1), (obj, 0, 2), //
          (obj, 0, 1), (bgL, 0, 0), (obj, 0, 0), //
        ];
      default:
        return const [];
    }
  }

  /// converts a CGRAM color index (0-255) into a 0xAABBGGRR pixel.
  int _rgba(int cgramIndex) {
    final base = cgramIndex.mask8 * 2;
    final c = cgram[base] | cgram[base + 1].shl8;
    final r5 = c.mask5;
    final g5 = c.shr5.mask5;
    final b5 = c.shr10.mask5;
    final r = (r5.shl3) | (r5.shr2);
    final g = (g5.shl3) | (g5.shr2);
    final b = (b5.shl3) | (b5.shr2);
    return 0xff000000 | b.shl16 | g.shl8 | r;
  }

  int _bgPaletteIndex(
      int mode, int bgIdx, int bpp, int paletteNum, int colorIndex) {
    if (bpp == 8) return colorIndex; // mode3 BG1: direct 256-color index
    if (mode == 0) return bgIdx * 32 + paletteNum * 4 + colorIndex;
    if (bpp == 2) return paletteNum * 4 + colorIndex;
    return paletteNum * 16 + colorIndex; // 4bpp
  }

  /// raw 16-bit tilemap entry for BG [bgIdx] at map pixel position (px,py),
  /// respecting that BG's own tilemap address/size. used both for normal
  /// tile lookup and, for BG3, as the offset-per-tile source table.
  int _tilemapEntryRaw(int bgIdx, int px, int py) {
    final bg = bgs[bgIdx];
    final tileSizePx = bg.bigChar ? 16 : 8;
    final mapPxW = (bg.wideX ? 64 : 32) * tileSizePx;
    final mapPxH = (bg.wideY ? 64 : 32) * tileSizePx;

    final sx = px & (mapPxW - 1);
    final sy = py & (mapPxH - 1);
    final cellCol = sx ~/ tileSizePx;
    final cellRow = sy ~/ tileSizePx;
    final quadX = (bg.wideX && cellCol >= 32) ? 1 : 0;
    final quadY = (bg.wideY && cellRow >= 32) ? 1 : 0;
    final localCol = cellCol.mask5;
    final localRow = cellRow.mask5;

    int extra;
    if (bg.wideX && bg.wideY) {
      extra = quadY * 0x800 + quadX * 0x400;
    } else if (bg.wideX) {
      extra = quadX * 0x400;
    } else if (bg.wideY) {
      extra = quadY * 0x400;
    } else {
      extra = 0;
    }

    final entryAddr =
        (bg.tilemapAddr + extra + localRow * 32 + localCol).mask15;
    return vram[entryAddr * 2] | vram[entryAddr * 2 + 1].shl8;
  }

  /// offset-per-tile (modes 2/4/6): BG3's tilemap is repurposed as a table
  /// of per-column scroll overrides for BG1/BG2, with the entry format of
  /// the fullsnes documentation (bit 13/14 = apply to BG1/BG2, bit 15 = H or
  /// V in mode 4, bits 0-9 = the offset, its low 3 bits ignored for H).
  ///
  /// returns the (x,y) position in BG [bgIdx]'s map for screen pixel (x,y):
  /// normally (x+hofs, y+vofs), with the OPT overrides applied in 2/4/6.
  (int, int) _bgMapPos(int bgIdx, int x, int y) {
    final bg = bgs[bgIdx];
    var mapX = x + bg.hofs, mapY = y + bg.vofs;
    if (bgIdx > 1 || (bgMode != 2 && bgMode != 4 && bgMode != 6)) {
      return (mapX, mapY);
    }

    final offsetX = x + bg.hofs.mask3;
    if (offsetX < 8) return (mapX, mapY); // leftmost tile column: unaffected

    final bg3 = bgs[2];
    final validMask = bgIdx == 0 ? 0x2000 : 0x4000;
    final lookupX = (offsetX - 8) + (bg3.hofs & ~7);
    final hval = _tilemapEntryRaw(2, lookupX, bg3.vofs);

    if (bgMode == 4) {
      // single OPT row: bit15 of the same word picks horizontal or vertical
      if (hval & validMask != 0) {
        if (hval.bit15) {
          mapY = y + hval.mask10;
        } else {
          mapX = offsetX + (hval & 0x3f8);
        }
      }
    } else {
      final vval = _tilemapEntryRaw(2, lookupX, bg3.vofs + 8);
      if (hval & validMask != 0) mapX = offsetX + (hval & 0x3f8);
      if (vval & validMask != 0) mapY = y + vval.mask10;
    }
    return (mapX, mapY);
  }

  // Spread four plane bits into four bytes, in left-to-right pixel order.
  // For example, 0b1010 becomes [1, 0, 1, 0], packed as 0x00010001.
  // Each byte will hold one pixel's color after the planes are ORed together.
  static final _expandPlane = List<int>.generate(
      16,
      (bits) =>
          bits.shr3.mask1 |
          bits.shr2.mask1.shl8 |
          bits.shr1.mask1.shl16 |
          bits.mask1.shl24);

  /// Fills the packed _BgSamples of BG [bgIdx] for the whole line [y], with
  /// the same result as _bgPixel for each column. The tilemap entry and the
  /// decoded row change only every 8 columns. Not for offset-per-tile or
  /// mosaic, which move columns individually.
  void _fillBgLine(int bgIdx, int bpp, int y, Int32List out) {
    final bg = bgs[bgIdx];
    final big = bg.bigChar;
    final tileSizePx = big ? 16 : 8;
    final mapPxW = (bg.wideX ? 64 : 32) * tileSizePx;
    final mapPxH = (bg.wideY ? 64 : 32) * tileSizePx;
    final sy = (y + bg.vofs) & (mapPxH - 1);
    final yInCell = sy % tileSizePx;
    final wordsPerTile = bpp * 4;

    var group = -1; // 8-column group of the decoded row
    var low = 0, high = 0, attr = 0;
    var hFlip = false;
    for (var x = 0; x < width; x++) {
      final sx = (x + bg.hofs) & (mapPxW - 1);
      if (sx.shr3 != group) {
        group = sx.shr3;
        final entry = _tilemapEntryRaw(bgIdx, sx, sy);
        final tileNum = entry.mask10;
        hFlip = entry.bit14;
        final vFlip = entry.bit15;
        attr = _BgSample.pack(0, entry.shr10.mask3, entry.shr13.mask1);
        final xInCell = sx % tileSizePx;
        final srcX = hFlip ? (tileSizePx - 1 - xInCell) : xInCell;
        final srcY = vFlip ? (tileSizePx - 1 - yInCell) : yInCell;
        final subTile = tileNum + (srcX ~/ 8) + (srcY ~/ 8) * 16;
        final byteBase = ((bg.charBase + subTile * wordsPerTile) * 2).mask16;
        final rowAddress = (byteBase + (srcY % 8) * 2).mask16;
        low = 0;
        high = 0;
        for (var plane = 0; plane < bpp; plane += 2) {
          final addr = (rowAddress + plane * 8).mask16;
          final a = vram[addr], b = vram[(addr + 1).mask16];
          low |= (_expandPlane[a.shr4] | _expandPlane[b.shr4].shl1) << plane;
          high |= (_expandPlane[a.mask4] | _expandPlane[b.mask4].shl1) << plane;
        }
      }
      final col8 = hFlip ? 7 - sx.mask3 : sx.mask3;
      final rowPixels = col8 < 4 ? low : high;
      final colorIndex = (rowPixels >> (col8.mask2 * 8)) & _BgSample.colorMask;
      out[x] = colorIndex == 0 ? _BgSample.transparent : attr | colorIndex;
    }
  }

  /// Fetches a packed _BgSample, including its palette and tile priority.
  int _bgPixel(int bgIdx, int bpp, int x, int y) {
    final bg = bgs[bgIdx];
    final tileSizePx = bg.bigChar ? 16 : 8;
    final mapPxW = (bg.wideX ? 64 : 32) * tileSizePx;
    final mapPxH = (bg.wideY ? 64 : 32) * tileSizePx;

    final (mapX, mapY) = _bgMapPos(bgIdx, x, y);
    final sx = mapX & (mapPxW - 1);
    final sy = mapY & (mapPxH - 1);

    final entry = _tilemapEntryRaw(bgIdx, sx, sy);
    final tileNum = entry.mask10;
    final paletteNum = entry.shr10.mask3;
    final priority = entry.shr13.mask1;
    final hFlip = entry.bit14;
    final vFlip = entry.bit15;

    final xInCell = sx % tileSizePx;
    final yInCell = sy % tileSizePx;
    final srcX = hFlip ? (tileSizePx - 1 - xInCell) : xInCell;
    final srcY = vFlip ? (tileSizePx - 1 - yInCell) : yInCell;
    final subTile = tileNum + (srcX ~/ 8) + (srcY ~/ 8) * 16;
    final col8 = srcX % 8;
    final row8 = srcY % 8;

    final wordsPerTile = bpp * 4;
    final byteBase = ((bg.charBase + subTile * wordsPerTile) * 2).mask16;

    final rowAddress = (byteBase + row8 * 2).mask16;
    // The cache key combines the 16-bit VRAM row address with its bit depth.
    final key = rowAddress | bpp.shl16;
    if (bgRowKey[bgIdx] != key) {
      var low = 0, high = 0;
      for (var plane = 0; plane < bpp; plane += 2) {
        final addr = (rowAddress + plane * 8).mask16;
        final a = vram[addr], b = vram[(addr + 1).mask16];
        low |= (_expandPlane[a.shr4] | _expandPlane[b.shr4].shl1) << plane;
        high |= (_expandPlane[a.mask4] | _expandPlane[b.mask4].shl1) << plane;
      }
      bgRowKey[bgIdx] = key;
      bgRowLow[bgIdx] = low;
      bgRowHigh[bgIdx] = high;
    }
    final rowPixels = col8 < 4 ? bgRowLow[bgIdx] : bgRowHigh[bgIdx];
    final colorIndex = (rowPixels >> (col8.mask2 * 8)) & _BgSample.colorMask;
    if (colorIndex == 0) return _BgSample.transparent;
    return _BgSample.pack(colorIndex, paletteNum, priority);
  }

  /// evaluates OAM for one scanline, filling per-column output arrays.
  /// outColor[x] stays -1 (transparent) where no sprite drew a pixel.
  void _evalSprites(
      int y, List<int> outColor, List<int> outPalette, List<int> outPriority) {
    rangeOver = false;
    timeOver = false;
    final sizes = _objSizeTable[objSizeSel.mask3];

    int found = 0;
    int tileBudget = 34;

    for (int i = 0; i < 128; i++) {
      final base = i * 4;
      final hiByte = oam[512 + i.shr2];
      final hiShift = i.mask2 * 2;
      final xMsb = hiByte.shr(hiShift).mask1;
      final large = hiByte.bit(hiShift + 1);

      final rawX = oam[base] | xMsb.shl8;
      final x = rawX >= 256 ? rawX - 512 : rawX; // sign-extend 9-bit
      final oy = oam[base + 1];
      final tileLow = oam[base + 2];
      final attr = oam[base + 3];

      final w = large ? sizes[2] : sizes[0];
      final h = large ? sizes[3] : sizes[1];

      final dy = (y - oy).mask8;
      if (dy >= h) continue;
      // fully off-screen (OBJ is always 256px)
      if (x <= -w || x >= Ppu.widthNormal) continue;

      if (found >= 32) {
        rangeOver = true;
        break;
      }
      found++;

      final tilesWide = w ~/ 8;
      if (tileBudget <= 0) {
        timeOver = true;
        continue; // still counts for Range, but draws nothing more
      }
      tileBudget -= tilesWide;

      final vFlip = attr.bit7;
      final hFlip = attr.bit6;
      final priority = attr.shr4.mask2;
      final palette = attr.shr1.mask3;
      final nameBit = attr.mask1;

      final tileBase24 =
          (objBase.shl13 + (nameBit != 0 ? (objGap + 1).shl12 : 0)).mask15;

      final srcY = vFlip ? (h - 1 - dy) : dy;

      for (int sx = 0; sx < w; sx++) {
        final screenX = x + sx;
        if (screenX < 0 || screenX >= Ppu.widthNormal) continue;
        if (outColor[screenX] != -1) continue;

        final srcX = hFlip ? (w - 1 - sx) : sx;
        final cellCol = srcX ~/ 8;
        final cellRow = srcY ~/ 8;
        final col8 = srcX % 8;
        final row8 = srcY % 8;

        // OBJ name table wraps independently in each nibble (16-wide grid)
        final subTile =
            (tileLow + cellRow.shl4) & 0xf0 | (tileLow + cellCol).mask4;

        final byteBase = ((tileBase24 + subTile.shl4) * 2).mask16;

        int colorIndex = 0;
        for (int p = 0; p < 2; p++) {
          final byte0 = vram[(byteBase + p * 16 + row8 * 2).mask16];
          final byte1 = vram[(byteBase + p * 16 + row8 * 2 + 1).mask16];
          final bit0 = byte0.shr(7 - col8).mask1;
          final bit1 = byte1.shr(7 - col8).mask1;
          colorIndex |= bit0.shl(p * 2) | bit1.shl(p * 2 + 1);
        }

        if (colorIndex == 0) continue;
        outColor[screenX] = colorIndex;
        outPalette[screenX] = palette;
        outPriority[screenX] = priority;
      }
    }
  }

  /// layer: 0-3=BG1-4, 4=OBJ, 5=color window (the ccmm bits of CGWSEL).
  /// the area of a line is computed once (windows only change between lines)
  @pragma('vm:prefer-inline')
  bool _insideWindow(int layer, int x) {
    final line = windowLine[layer];
    if (windowLineReady & (1 << layer) == 0) {
      _fillWindowLine(layer, line);
      windowLineReady |= 1 << layer;
    }
    return line[x] != 0;
  }

  /// the window area of [layer] for the whole line. a column is inside a
  /// window when it is in its raw range ($2126-2129), combined per the
  /// layer's select bits and logic. window bounds are always 8-bit (0-255); in
  /// hi-res mode (width==512) this means windows only ever cover the left half
  /// of the screen - not modeled precisely, documented simplification
  /// alongside the rest of modes 5/6's approximation (see renderScanline's doc).
  void _fillWindowLine(int layer, Uint8List line) {
    final (wsel4, logic2) = switch (layer) {
      0 => (w12sel.mask4, wbglog.mask2),
      1 => (w12sel.shr4.mask4, wbglog.shr2.mask2),
      2 => (w34sel.mask4, wbglog.shr4.mask2),
      3 => (w34sel.shr4.mask4, wbglog.shr6.mask2),
      4 => (wobjsel.mask4, wobjlog.mask2),
      _ => (wobjsel.shr4.mask4, wobjlog.shr2.mask2),
    };
    final inv1 = wsel4.bit0, en1 = wsel4.bit1;
    final inv2 = wsel4.bit2, en2 = wsel4.bit3;
    if (!en1 && !en2) {
      line.fillRange(0, width, 0);
      return;
    }
    final l1 = w1Left, r1 = w1Right, l2 = w2Left, r2 = w2Right;
    for (var x = 0; x < width; x++) {
      final a = en1 && ((x >= l1 && x <= r1) != inv1);
      final b = en2 && ((x >= l2 && x <= r2) != inv2);
      final inside = !en2
          ? a
          : !en1
              ? b
              : switch (logic2) {
                  0 => a || b,
                  1 => a && b,
                  2 => a != b,
                  _ => a == b,
                };
      line[x] = inside ? 1 : 0;
    }
  }


  /// whether a layer's pixel is masked (hidden) at column x for the given
  /// screen (TMW for main / TSW for sub): masked when that screen's window
  /// bit is set for the layer AND the column is inside its window.
  bool _layerMasked(int layer, int x, int windowApplyMask) =>
      windowApplyMask.bit(layer) && _insideWindow(layer, x);

  /// Composites one screen (main or sub) at column x, returning _ScreenPixel's
  /// packed int format. Its OBJ palette is meaningful only for an OBJ source.
  /// bgX is the BG-side column (0..width-1, hires-aware); objX is the
  /// OBJ-side column (always 0..255 - sprites stay 256px-wide and are
  /// stretched 2x when width==512, matching real hardware).
  int _compositePixel(
    int bgX,
    int objX,
    int y,
    int screenEnable,
    int windowApplyMask,
    List<_Layer> order,
    List<int> bpp,
    List<int> objColor,
    List<int> objPalette,
    List<int> objPriority,
  ) {
    for (var i = 0; i < order.length; i++) {
      final layer = order[i];
      if (layer.$1) {
        if (!screenEnable.bit4) continue;
        if (objColor[objX] != -1 &&
            objPriority[objX] == layer.$3 &&
            !_layerMasked(4, bgX, windowApplyMask)) {
          return _ScreenPixel.pack(128 + objPalette[objX] * 16 + objColor[objX],
              _ScreenPixel.objSource, objPalette[objX]);
        }
      } else {
        final bgIdx = layer.$2;
        if (bpp[bgIdx] == 0 || !screenEnable.bit(bgIdx)) continue;
        if (_layerMasked(bgIdx, bgX, windowApplyMask)) continue;
        final pixels = bgLinePixels[bgIdx];
        var sample = pixels[bgX];
        if (sample == _BgSample.notFetched) {
          final mx = (mosaicEnable.bit(bgIdx) && mosaicSize > 0)
              ? (bgX ~/ (mosaicSize + 1)) * (mosaicSize + 1)
              : bgX;
          sample = _bgPixel(bgIdx, bpp[bgIdx], mx, y);
          pixels[bgX] = sample;
        }
        if (sample != _BgSample.transparent &&
            _BgSample.priority(sample) == layer.$3) {
          final cgramIndex = _bgPaletteIndex(bgMode, bgIdx, bpp[bgIdx],
              _BgSample.palette(sample), _BgSample.colorIndex(sample));
          return _ScreenPixel.pack(cgramIndex, bgIdx, 0);
        }
      }
    }
    return _ScreenPixel.backdrop;
  }

  /// clamped RGB channel add/subtract for color math, 5-bit channels.
  /// halving applies to both addition and subtraction.
  int _mathChannel(int a, int b, bool subtract, bool half) {
    int r = subtract ? (a - b).max(0) : a + b;
    if (half) r >>= 1;
    return r.clamp(0, 31);
  }

  int _colorMath(
    int mainIdx,
    int sourceKind,
    int objPalette,
    int x,
    int subR,
    int subG,
    int subB,
    bool subIsBackdrop,
  ) {
    final subtract = cgadsub.bit7;

    // does this main-screen source permit color math? (CGADSUB bits5-0)
    bool allowed;
    switch (sourceKind) {
      case _ScreenPixel.backdropSource:
        allowed = cgadsub.bit5; // backdrop
        break;
      case _ScreenPixel.objSource:
        allowed = cgadsub.bit4 && objPalette >= 4; // OBJ, palette 4-7 only
        break;
      default:
        allowed = cgadsub.bit(sourceKind); // BG1-4
    }

    final ccBits = cgwsel.shr6.mask2;
    final mmBits = cgwsel.shr4.mask2;
    final insideColorWindow = _insideWindow(5, x);
    final clipToBlack = switch (ccBits) {
      1 => !insideColorWindow,
      2 => insideColorWindow,
      3 => true,
      _ => false,
    };
    // CGWSEL bits5-4 select where math is *allowed*: 0=always,
    // 1=inside the color window, 2=outside, 3=never
    final mathEnabled = switch (mmBits) {
      0 => true,
      1 => insideColorWindow,
      2 => !insideColorWindow,
      _ => false,
    };
    // no halving when the main pixel is clipped to black or when the sub
    // screen shows its backdrop (the fixed color)
    final half = cgadsub.bit6 && !clipToBlack && !subIsBackdrop;

    final base = clipToBlack
        ? 0
        : cgram[mainIdx.mask8 * 2] | cgram[mainIdx.mask8 * 2 + 1].shl8;
    var r = base.mask5, g = base.shr5.mask5, b = base.shr10.mask5;

    if (!allowed || !mathEnabled) return _rgb555(r, g, b);

    r = _mathChannel(r, subR, subtract, half);
    g = _mathChannel(g, subG, subtract, half);
    b = _mathChannel(b, subB, subtract, half);
    return _rgb555(r, g, b);
  }

  int _rgb555(int r5, int g5, int b5) {
    final r = (r5.shl3) | (r5.shr2);
    final g = (g5.shl3) | (g5.shr2);
    final b = (b5.shl3) | (b5.shr2);
    return 0xff000000 | b.shl16 | g.shl8 | r;
  }

  /// renders one scanline (1-based, matching the SNES's hidden-first-line
  /// convention) into `buffer`. lines outside 1..Ppu.height are ignored.
  ///
  /// modes 5/6 render at [Ppu.widthHires] (512px): BG1/BG2 pixels are
  /// sampled directly at the 512-wide column (so a full 512-pixel tilemap's
  /// worth of content shows), while OBJ stays 256px-wide and is stretched
  /// 2x. This is a simplification - real hardware interleaves separate
  /// main/sub-screen content on even/odd columns for a pseudo-hires
  /// transparency effect, which isn't reproduced here.
  ///
  /// BG layers show map row `line + vofs` (so the first visible line shows
  /// row vofs+1), while OBJ are evaluated against `line - 1`: a sprite at
  /// OAM y=0 starts on the first visible line, one row below the BG.
  void renderScanline(int line) {
    if (line < 1 || line > Ppu.height) return;
    windowLineReady = 0;
    final y = line - 1; // output row and OBJ line
    final bgY = line;

    if (bgMode == 5 || bgMode == 6) {
      width = Ppu.widthHires;
    } else {
      width = Ppu.widthNormal;
    }
    final row = y * width;

    if (forcedBlank) {
      buffer.fillRange(row, row + width, 0xff000000);
      return;
    }

    if (bgMode == 7) {
      _renderMode7Scanline(row, y, bgY);
      _applyBrightness(row, width);
      return;
    }

    final bpp = _bgBpp[bgMode];
    final backdrop = _rgba(0);

    if (bpp == null) {
      // unimplemented mode: backdrop only (see class doc)
      buffer.fillRange(row, row + width, backdrop);
      _applyBrightness(row, width);
      return;
    }

    final objColor = objLineColor..fillRange(0, Ppu.widthNormal, -1);
    final objPalette = objLinePalette..fillRange(0, Ppu.widthNormal, 0);
    final objPriority = objLinePriority..fillRange(0, Ppu.widthNormal, 0);
    if (mainScreenEnable.bit4 || subScreenEnable.bit4) {
      _evalSprites(y, objColor, objPalette, objPriority);
    }

    // VRAM and registers can change between lines, so caches never survive
    // a scanline. Main/sub screens and priority slots share each BG sample.
    bgRowKey.fillRange(0, 4, -1);
    final shown = mainScreenEnable | (cgwsel.bit1 ? subScreenEnable : 0);
    final opt = bgMode == 2 || bgMode == 4 || bgMode == 6;
    for (var i = 0; i < 4; i++) {
      final pixels = bgLinePixels[i];
      if (bpp[i] != 0 &&
          shown.bit(i) &&
          !(opt && i < 2) &&
          !(mosaicEnable.bit(i) && mosaicSize > 0)) {
        _fillBgLine(i, bpp[i], bgY, pixels);
      } else {
        pixels.fillRange(0, width, _BgSample.notFetched);
      }
    }
    final order = _priorityOrder(bgMode, bg3Priority);
    final subscreenMode = cgwsel.bit1;
    final hires = width == Ppu.widthHires;

    for (int x = 0; x < width; x++) {
      final objX = hires ? x ~/ 2 : x;
      final main = _compositePixel(x, objX, bgY, mainScreenEnable, tmw, order,
          bpp, objColor, objPalette, objPriority);
      final mainIdx = _ScreenPixel.cgramIndex(main);
      final mainKind = _ScreenPixel.source(main);
      final mainObjPal = _ScreenPixel.objPalette(main);

      int subR = fixedColorR, subG = fixedColorG, subB = fixedColorB;
      bool subIsBackdrop = false;
      if (subscreenMode) {
        final sub = _compositePixel(x, objX, bgY, subScreenEnable, tsw, order,
            bpp, objColor, objPalette, objPriority);
        // the sub screen's backdrop is the fixed color, not CGRAM[0]
        final subIdx = _ScreenPixel.cgramIndex(sub);
        subIsBackdrop = _ScreenPixel.source(sub) == _ScreenPixel.backdropSource;
        if (!subIsBackdrop) {
          final c = cgram[subIdx.mask8 * 2] | cgram[subIdx.mask8 * 2 + 1].shl8;
          subR = c.mask5;
          subG = c.shr5.mask5;
          subB = c.shr10.mask5;
        }
      }

      buffer[row + x] = _colorMath(
          mainIdx, mainKind, mainObjPal, x, subR, subG, subB, subIsBackdrop);
    }
    _applyBrightness(row, width);
  }

  /// scales one rendered row by the INIDISP master brightness (0-15).
  void _applyBrightness(int row, int w) {
    if (brightness == 15) return;
    for (int i = row; i < row + w; i++) {
      final c = buffer[i];
      final r = c.mask8 * brightness ~/ 15;
      final g = c.shr8.mask8 * brightness ~/ 15;
      final b = c.shr16.mask8 * brightness ~/ 15;
      buffer[i] = 0xff000000 | b.shl16 | g.shl8 | r;
    }
  }

  /// fetches the mode7 tilemap byte (tile number 0-255) for tile cell
  /// (tileX,tileY), each 0-127. tilemap occupies the LOW byte of VRAM words
  /// $0000-$3FFF, one word per cell in row-major order.
  int _m7TilemapByte(int tileX, int tileY) {
    final word = tileY.mask7 * 128 + tileX.mask7;
    return vram[word * 2];
  }

  /// fetches one pixel (0-255, direct CGRAM index) from mode7 character
  /// (tile graphics) data: 8bpp, occupies the HIGH byte of 64 consecutive
  /// VRAM words per tile (8x8 pixels, row-major).
  int _m7CharByte(int tileNum, int px, int py) {
    final word = tileNum * 64 + py * 8 + px;
    return vram[word * 2 + 1];
  }

  /// renders one scanline in BG mode 7 (rotation/scaling). BG1 only -
  /// EXTBG (mode7 BG2) is not implemented; see Ppu's class doc.
  void _renderMode7Scanline(int row, int y, int bgY) {
    final backdrop = _rgba(0);

    final objColor = objLineColor..fillRange(0, Ppu.widthNormal, -1);
    final objPalette = objLinePalette..fillRange(0, Ppu.widthNormal, 0);
    final objPriority = objLinePriority..fillRange(0, Ppu.widthNormal, 0);
    if (mainScreenEnable.bit4) {
      _evalSprites(y, objColor, objPalette, objPriority);
    }

    final bg1Enabled = mainScreenEnable.bit0;
    final hFlipScreen = m7sel.bit0;
    final vFlipScreen = m7sel.bit1;
    final overMode = m7sel.shr6.mask2;

    final a = m7a.rel16, b = m7b.rel16, c = m7c.rel16, d = m7d.rel16;
    final x0 = m7x.rel13, y0 = m7y.rel13;
    final hofs = m7hofs.rel13, vofs = m7vofs.rel13;

    final sy = vFlipScreen ? (255 - bgY) : bgY;

    // the hardware formula: the scroll offsets relative to the center are
    // wrapped to a signed 10 bit range, and every product is truncated to a
    // multiple of 64 before summing.
    // https://wiki.superfamicom.org/mode-7
    int clip(int v) => v.bit13 ? (v | ~0x3ff) : v.mask10;
    final h = clip(hofs - x0), vv = clip(vofs - y0);
    final baseX =
        ((a * h) & ~63) + ((b * vv) & ~63) + ((b * sy) & ~63) + x0.shl8;
    final baseY =
        ((c * h) & ~63) + ((d * vv) & ~63) + ((d * sy) & ~63) + y0.shl8;

    for (int x = 0; x < Ppu.widthNormal; x++) {
      int color = backdrop;

      // priority order (front->back): OBJ3, OBJ2, OBJ1, BG1 (single layer,
      // no EXTBG), OBJ0, backdrop
      final hasObj = objColor[x] != -1;
      if (hasObj && objPriority[x] >= 1) {
        color = _rgba(128 + objPalette[x] * 16 + objColor[x]);
      } else if (bg1Enabled) {
        final sx = hFlipScreen ? (Ppu.widthNormal - 1 - x) : x;
        final u = (baseX + a * sx).shr8;
        final v = (baseY + c * sx).shr8;
        final outOfRange = u < 0 || u >= 1024 || v < 0 || v >= 1024;

        int tileNum = -1;
        if (outOfRange && overMode == 2) {
          tileNum = -1; // transparent
        } else if (outOfRange && overMode == 3) {
          tileNum = 0; // fill with character 0
        } else {
          tileNum = _m7TilemapByte(u.shr3.mask7, v.shr3.mask7);
        }

        int bg1Pixel = 0;
        if (tileNum >= 0) bg1Pixel = _m7CharByte(tileNum, u.mask3, v.mask3);

        if (bg1Pixel != 0) {
          color = _rgba(bg1Pixel);
        } else if (hasObj) {
          color = _rgba(128 + objPalette[x] * 16 + objColor[x]);
        }
      } else if (hasObj) {
        color = _rgba(128 + objPalette[x] * 16 + objColor[x]);
      }

      buffer[row + x] = color;
    }
  }
}
