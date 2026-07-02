import 'package:fnesemu/util/int.dart';

import 'ppu.dart';

/// a single layer slot in a mode's front-to-back priority order.
/// isObj=true: `hi` is the OBJ priority level (0-3), `bg` unused.
/// isObj=false: `bg` is the BG index (0-3 = BG1-4), `hi` is the tile's own
/// priority bit (0 or 1) that this slot matches.
typedef _Layer = (bool isObj, int bg, int hi);

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
  // modes 5/6 (hi-res, 512px wide) are not in this map and fall back to a
  // backdrop-only scanline - see class doc in ppu.dart.
  static const _bgBpp = <int, List<int>>{
    0: [2, 2, 2, 2],
    1: [4, 4, 2, 0],
    2: [4, 4, 0, 0], // BG3 repurposed as offset-per-tile table
    3: [8, 4, 0, 0],
    4: [8, 2, 0, 0], // BG3 repurposed as offset-per-tile table
  };

  static List<_Layer> _priorityOrder(int mode, bool bg3prio) {
    const obj = true, bgL = false;
    switch (mode) {
      case 0:
        return [
          (obj, 0, 3), (bgL, 0, 1), (bgL, 1, 1), (obj, 0, 2),
          (bgL, 0, 0), (bgL, 1, 0), (obj, 0, 1), (bgL, 2, 1),
          (bgL, 3, 1), (obj, 0, 0), (bgL, 2, 0), (bgL, 3, 0), //
        ];
      case 1:
        if (bg3prio) {
          return [
            (bgL, 2, 1), (obj, 0, 3), (bgL, 0, 1), (bgL, 1, 1),
            (obj, 0, 2), (bgL, 0, 0), (bgL, 1, 0), (obj, 0, 1),
            (obj, 0, 0), (bgL, 2, 0), //
          ];
        }
        return [
          (obj, 0, 3), (bgL, 0, 1), (bgL, 1, 1), (obj, 0, 2),
          (bgL, 0, 0), (bgL, 1, 0), (obj, 0, 1), (bgL, 2, 1),
          (obj, 0, 0), (bgL, 2, 0), //
        ];
      case 2:
      case 3:
      case 4:
        return [
          (obj, 0, 3), (bgL, 0, 1), (obj, 0, 2), (bgL, 1, 1),
          (obj, 0, 1), (bgL, 0, 0), (obj, 0, 0), (bgL, 1, 0), //
        ];
      default:
        return const [];
    }
  }

  /// converts a CGRAM color index (0-255) into a 0xAABBGGRR pixel.
  int _rgba(int cgramIndex) {
    final base = (cgramIndex & 0xff) * 2;
    final c = cgram[base] | cgram[base + 1].shl8;
    final r5 = c & 0x1f;
    final g5 = c.shr5 & 0x1f;
    final b5 = c.shr10 & 0x1f;
    final r = (r5.shl3) | (r5.shr2);
    final g = (g5.shl3) | (g5.shr2);
    final b = (b5.shl3) | (b5.shr2);
    return 0xff000000 | b.shl16 | g.shl8 | r;
  }

  int _bgPaletteIndex(int mode, int bgIdx, int bpp, int paletteNum, int colorIndex) {
    if (bpp == 8) return colorIndex; // mode3 BG1: direct 256-color index
    if (mode == 0) return bgIdx * 32 + paletteNum * 4 + colorIndex;
    if (bpp == 2) return paletteNum * 4 + colorIndex;
    return paletteNum * 16 + colorIndex; // 4bpp
  }

  /// fetches one BG pixel at screen column/row; returns (colorIndex 1-255,
  /// paletteNum, tilePriorityBit) or null if transparent (colorIndex 0).
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
    final localCol = cellCol & 0x1f;
    final localRow = cellRow & 0x1f;

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

    final entryAddr = (bg.tilemapAddr + extra + localRow * 32 + localCol) & 0x7fff;
    return vram[entryAddr * 2] | vram[entryAddr * 2 + 1].shl8;
  }

  /// offset-per-tile (modes 2/4/6): BG3's tilemap is repurposed as a table
  /// of per-column scroll overrides for BG1/BG2. Based on community-derived
  /// (srg320, nesdev BBS) and bsnes-style pseudocode - not a primary
  /// hardware source, so double-check against real ROMs if visuals look off.
  (int, int) _optScroll(int bgIdx, int x, int y, int hofs, int vofs) {
    if (bgMode != 2 && bgMode != 4 && bgMode != 6) return (hofs, vofs);
    if (x - 8 < 0) return (hofs, vofs); // leftmost visible tile: unaffected

    final bg3 = bgs[2];
    final validMask = bgIdx == 0 ? 0x2000 : 0x4000;
    final lookupX = (hofs & 7) | (((x - 8) & ~7) + (bg3.hofs & ~7));
    final hval = _tilemapEntryRaw(2, lookupX, bg3.vofs);

    if (bgMode == 4) {
      // single OPT row: bit15 of the same word picks horizontal or vertical
      if (hval.bit15) {
        if (hval & validMask != 0) vofs = y + hval;
      } else {
        if (hval & validMask != 0) hofs = (hofs & 7) + ((x & ~7) + (hval & ~7));
      }
    } else {
      final vval = _tilemapEntryRaw(2, lookupX, bg3.vofs + 8);
      if (hval & validMask != 0) hofs = (hofs & 7) + ((x & ~7) + (hval & ~7));
      if (vval & validMask != 0) vofs = y + vval;
    }
    return (hofs, vofs);
  }

  (int, int, int)? _bgPixel(int bgIdx, int bpp, int x, int y) {
    final bg = bgs[bgIdx];
    final tileSizePx = bg.bigChar ? 16 : 8;
    final mapPxW = (bg.wideX ? 64 : 32) * tileSizePx;
    final mapPxH = (bg.wideY ? 64 : 32) * tileSizePx;

    var hofs = bg.hofs, vofs = bg.vofs;
    if (bgIdx == 0 || bgIdx == 1) {
      (hofs, vofs) = _optScroll(bgIdx, x, y, hofs, vofs);
    }

    final sx = (x + hofs) & (mapPxW - 1);
    final sy = (y + vofs) & (mapPxH - 1);

    final entry = _tilemapEntryRaw(bgIdx, sx, sy);
    final tileNum = entry & 0x3ff;
    final paletteNum = entry.shr10 & 0x07;
    final priority = entry.shr13 & 1;
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
    final byteBase = ((bg.charBase + subTile * wordsPerTile) * 2) & 0xffff;

    int colorIndex = 0;
    for (int p = 0; p < bpp ~/ 2; p++) {
      final byte0 = vram[(byteBase + p * 16 + row8 * 2) & 0xffff];
      final byte1 = vram[(byteBase + p * 16 + row8 * 2 + 1) & 0xffff];
      final bit0 = byte0.shr(7 - col8) & 1;
      final bit1 = byte1.shr(7 - col8) & 1;
      colorIndex |= (bit0 << (p * 2)) | (bit1 << (p * 2 + 1));
    }

    if (colorIndex == 0) return null;
    return (colorIndex, paletteNum, priority);
  }

  /// evaluates OAM for one scanline, filling per-column output arrays.
  /// outColor[x] stays -1 (transparent) where no sprite drew a pixel.
  void _evalSprites(
      int y, List<int> outColor, List<int> outPalette, List<int> outPriority) {
    rangeOver = false;
    timeOver = false;
    final sizes = _objSizeTable[objSizeSel & 0x07];

    int found = 0;
    int tileBudget = 34;

    for (int i = 0; i < 128; i++) {
      final base = i * 4;
      final hiByte = oam[512 + (i >> 2)];
      final hiShift = (i & 3) * 2;
      final xMsb = hiByte.shr(hiShift) & 1;
      final large = hiByte.shr(hiShift + 1) & 1 != 0;

      final rawX = oam[base] | xMsb.shl8;
      final x = rawX >= 256 ? rawX - 512 : rawX; // sign-extend 9-bit
      final oy = oam[base + 1];
      final tileLow = oam[base + 2];
      final attr = oam[base + 3];

      final w = large ? sizes[2] : sizes[0];
      final h = large ? sizes[3] : sizes[1];

      final dy = (y - oy) & 0xff;
      if (dy >= h) continue;
      if (x <= -w || x >= Ppu.width) continue; // fully off-screen

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
      final priority = attr.shr4 & 0x03;
      final palette = attr.shr1 & 0x07;
      final nameBit = attr & 1;

      final tileBase24 =
          (objBase.shl13 + (nameBit != 0 ? (objGap + 1).shl12 : 0)) & 0x7fff;

      final srcY = vFlip ? (h - 1 - dy) : dy;

      for (int sx = 0; sx < w; sx++) {
        final screenX = x + sx;
        if (screenX < 0 || screenX >= Ppu.width) continue;
        if (outColor[screenX] != -1) continue;

        final srcX = hFlip ? (w - 1 - sx) : sx;
        final cellCol = srcX ~/ 8;
        final cellRow = srcY ~/ 8;
        final col8 = srcX % 8;
        final row8 = srcY % 8;

        // OBJ name table wraps independently in each nibble (16-wide grid)
        final subTile =
            ((tileLow + cellRow.shl4) & 0xf0) | ((tileLow + cellCol) & 0x0f);

        final byteBase = ((tileBase24 + subTile.shl4) * 2) & 0xffff;

        int colorIndex = 0;
        for (int p = 0; p < 2; p++) {
          final byte0 = vram[(byteBase + p * 16 + row8 * 2) & 0xffff];
          final byte1 = vram[(byteBase + p * 16 + row8 * 2 + 1) & 0xffff];
          final bit0 = byte0.shr(7 - col8) & 1;
          final bit1 = byte1.shr(7 - col8) & 1;
          colorIndex |= (bit0 << (p * 2)) | (bit1 << (p * 2 + 1));
        }

        if (colorIndex == 0) continue;
        outColor[screenX] = colorIndex;
        outPalette[screenX] = palette;
        outPriority[screenX] = priority;
      }
    }
  }

  /// renders one scanline (1-based, matching the SNES's hidden-first-line
  /// convention) into `buffer`. lines outside 1..Ppu.height are ignored.
  void renderScanline(int line) {
    if (line < 1 || line > Ppu.height) return;
    final row = (line - 1) * Ppu.width;
    final y = line - 1;

    if (forcedBlank) {
      buffer.fillRange(row, row + Ppu.width, 0xff000000);
      return;
    }

    if (bgMode == 7) {
      _renderMode7Scanline(row, y);
      return;
    }

    final bpp = _bgBpp[bgMode];
    final backdrop = _rgba(0);

    if (bpp == null) {
      // unimplemented mode: backdrop only (see class doc)
      buffer.fillRange(row, row + Ppu.width, backdrop);
      return;
    }

    final objColor = List<int>.filled(Ppu.width, -1);
    final objPalette = List<int>.filled(Ppu.width, 0);
    final objPriority = List<int>.filled(Ppu.width, 0);
    if (mainScreenEnable.bit4) {
      _evalSprites(y, objColor, objPalette, objPriority);
    }

    final order = _priorityOrder(bgMode, bg3Priority);

    for (int x = 0; x < Ppu.width; x++) {
      int color = backdrop;
      for (final layer in order) {
        if (layer.$1) {
          if (objColor[x] != -1 && objPriority[x] == layer.$3) {
            color = _rgba(128 + objPalette[x] * 16 + objColor[x]);
            break;
          }
        } else {
          final bgIdx = layer.$2;
          if (bpp[bgIdx] == 0 || !mainScreenEnable.bit(bgIdx)) continue;
          final px = _bgPixel(bgIdx, bpp[bgIdx], x, y);
          if (px != null && px.$3 == layer.$3) {
            color = _rgba(_bgPaletteIndex(bgMode, bgIdx, bpp[bgIdx], px.$2, px.$1));
            break;
          }
        }
      }
      buffer[row + x] = color;
    }
  }

  /// fetches the mode7 tilemap byte (tile number 0-255) for tile cell
  /// (tileX,tileY), each 0-127. tilemap occupies the LOW byte of VRAM words
  /// $0000-$3FFF, one word per cell in row-major order.
  int _m7TilemapByte(int tileX, int tileY) {
    final word = (tileY & 0x7f) * 128 + (tileX & 0x7f);
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
  void _renderMode7Scanline(int row, int y) {
    final backdrop = _rgba(0);

    final objColor = List<int>.filled(Ppu.width, -1);
    final objPalette = List<int>.filled(Ppu.width, 0);
    final objPriority = List<int>.filled(Ppu.width, 0);
    if (mainScreenEnable.bit4) {
      _evalSprites(y, objColor, objPalette, objPriority);
    }

    final bg1Enabled = mainScreenEnable.bit0;
    final hFlipScreen = m7sel.bit0;
    final vFlipScreen = m7sel.bit1;
    final overMode = m7sel.shr6 & 0x03;

    final a = m7a.rel16, b = m7b.rel16, c = m7c.rel16, d = m7d.rel16;
    final x0 = m7x.rel13, y0 = m7y.rel13;
    final hofs = m7hofs.rel13, vofs = m7vofs.rel13;

    final sy = vFlipScreen ? (Ppu.height - 1 - y) : y;
    final dy = sy + vofs - y0;

    for (int x = 0; x < Ppu.width; x++) {
      int color = backdrop;

      // priority order (front->back): OBJ3, BG1 (single layer, no EXTBG),
      // OBJ2/1/0, backdrop - see the mode7 row of the priority table
      // referenced in ppu_render.dart's _priorityOrder doc.
      final hasObj = objColor[x] != -1;
      if (hasObj && objPriority[x] == 3) {
        color = _rgba(128 + objPalette[x] * 16 + objColor[x]);
      } else if (bg1Enabled) {
        final sx = hFlipScreen ? (Ppu.width - 1 - x) : x;
        final dx = sx + hofs - x0;
        final u = ((a * dx + b * dy) >> 8) + x0;
        final v = ((c * dx + d * dy) >> 8) + y0;
        final outOfRange = u < 0 || u >= 1024 || v < 0 || v >= 1024;

        int tileNum = -1;
        if (outOfRange && overMode == 2) {
          tileNum = -1; // transparent
        } else if (outOfRange && overMode == 3) {
          tileNum = 0; // fill with character 0
        } else {
          tileNum = _m7TilemapByte((u >> 3) & 0x7f, (v >> 3) & 0x7f);
        }

        int bg1Pixel = 0;
        if (tileNum >= 0) bg1Pixel = _m7CharByte(tileNum, u & 0x7, v & 0x7);

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
