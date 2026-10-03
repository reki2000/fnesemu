import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import '../types.dart';
import 'bus.dart';

/// GBA Picture Processing Unit.
///
/// Scanline-based renderer producing a 240x160 ABGR8888 frame. Supports display
/// modes 0-5 (text/affine/bitmap backgrounds), sprites (regular + affine),
/// windows and the colour special effects (alpha blend / brightness).
class Ppu {
  final Bus bus;
  Ppu(this.bus);

  static const width = 240;
  static const height = 160;

  final buffer = Uint32List(width * height);

  ImageBuffer get imageBuffer =>
      // LCD with square pixels: display at the native 3:2 size
      ImageBuffer(width, height, buffer.buffer.asUint8List(),
          displayHeight: height);

  // BGR555 -> ABGR8888 lookup (32768 entries).
  static final Uint32List _rgba = _buildRgba();
  static Uint32List _buildRgba() {
    final t = Uint32List(0x8000);
    for (int c = 0; c < 0x8000; c++) {
      final r5 = c.mask5, g5 = c.shr5.mask5, b5 = c.shr10.mask5;
      final r = r5.shl3 | r5.shr2;
      final g = g5.shl3 | g5.shr2;
      final b = b5.shl3 | b5.shr2;
      t[c] = 0xff000000 | b.shl16 | g.shl8 | r;
    }
    return t;
  }

  // --- register / memory access --------------------------------------------

  int _io16(int r) => bus.io[r] | bus.io[r + 1].shl8;
  int _io32(int r) => _io16(r) | _io16(r + 2).shl16;
  int _vram16(int a) => bus.vram[a] | bus.vram[a + 1].shl8;
  int _oam16(int a) => bus.oam[a] | bus.oam[a + 1].shl8;

  /// palette entry [index] (0..511) as a BGR555 value.
  int _pal(int index) =>
      bus.paletteRam[index.shl1] | bus.paletteRam[index.shl1 + 1].shl8;

  // per-layer scanline buffers (BGR555 colour, -1 = transparent)
  final _bg = List.generate(4, (_) => Int32List(width), growable: false);
  final _bgPrio = List<int>.filled(4, 0);
  final _bgActive = List<bool>.filled(4, false);

  final _objColor = Int32List(width);
  final _objPrio = Uint8List(width);
  final _objSemi = Uint8List(width);
  final _objWindow = Uint8List(width);

  // internal affine reference points for BG2/BG3 (.8 fixed point), latched at
  // the start of the frame and advanced by dmx/dmy each scanline.
  final _refX = List<int>.filled(2, 0);
  final _refY = List<int>.filled(2, 0);

  void reset() {
    buffer.fillRange(0, buffer.length, 0xff000000);
    for (int i = 0; i < 2; i++) {
      _refX[i] = 0;
      _refY[i] = 0;
    }
  }

  // --- scanline rendering ---------------------------------------------------

  void renderLine(int line) {
    final dispcnt = _io16(0x00);

    if (line == 0) {
      _latchAffine(0);
      _latchAffine(1);
    } else {
      // a mid-frame write to BGxX/Y reloads the internal reference point
      if (bus.affineRefDirty[0]) _latchAffine(0);
      if (bus.affineRefDirty[1]) _latchAffine(1);
    }

    final base = line * width;

    // forced blank: output white.
    if (dispcnt.bit7) {
      for (int x = 0; x < width; x++) {
        buffer[base + x] = 0xffffffff;
      }
      _advanceAffine();
      return;
    }

    final mode = dispcnt.mask3;
    _renderBackgrounds(mode, dispcnt, line);
    _renderObjects(dispcnt, line);
    _composite(dispcnt, line, base);

    _advanceAffine();
  }

  void _latchAffine(int i) {
    _refX[i] = _io32(0x028 + i * 0x10).toSigned(28);
    _refY[i] = _io32(0x02c + i * 0x10).toSigned(28);
    bus.affineRefDirty[i] = false;
  }

  void _advanceAffine() {
    // dmx/dmy = BGxPB / BGxPD
    _refX[0] += _io16(0x022).toSigned(16);
    _refY[0] += _io16(0x026).toSigned(16);
    _refX[1] += _io16(0x032).toSigned(16);
    _refY[1] += _io16(0x036).toSigned(16);
  }

  void _renderBackgrounds(int mode, int dispcnt, int line) {
    for (int bg = 0; bg < 4; bg++) {
      _bgActive[bg] = false;
    }
    switch (mode) {
      case 0:
        for (int bg = 0; bg < 4; bg++) {
          if (dispcnt.bit(8 + bg)) _renderTextBg(bg, line);
        }
        break;
      case 1:
        if (dispcnt.bit8) _renderTextBg(0, line);
        if (dispcnt.bit9) _renderTextBg(1, line);
        if (dispcnt.bit10) _renderAffineBg(2, line);
        break;
      case 2:
        if (dispcnt.bit10) _renderAffineBg(2, line);
        if (dispcnt.bit11) _renderAffineBg(3, line);
        break;
      case 3:
      case 4:
      case 5:
        if (dispcnt.bit10) _renderBitmapBg(mode, dispcnt, line);
        break;
    }
  }

  // --- text (regular) background -------------------------------------------

  void _renderTextBg(int bg, int line) {
    final cnt = _io16(0x08 + bg * 2);
    final priority = cnt.mask2;
    final charBase = cnt.shr2.mask2 * 0x4000;
    final mosaic = cnt.bit6;
    final is8bpp = cnt.bit7;
    final screenBase = cnt.shr8.mask5 * 0x800;
    final size = cnt.shr14.mask2;

    final mapW = size.bit0 ? 512 : 256;
    final mapH = size.bit1 ? 512 : 256;

    final hofs = _io16(0x10 + bg * 4).mask9;
    final vofs = _io16(0x12 + bg * 4).mask9;

    final mosaicReg = _io16(0x4c);
    final mosaicH = mosaicReg.mask4 + 1;
    final mosaicV = mosaicReg.shr4.mask4 + 1;

    int sy = line;
    if (mosaic) sy = line - line % mosaicV;
    final py = (sy + vofs) & (mapH - 1);

    final out = _bg[bg];
    for (int x = 0; x < width; x++) {
      int sx = x;
      if (mosaic) sx = x - x % mosaicH;
      final px = (sx + hofs) & (mapW - 1);

      // pick the 256x256 screen block (each 0x800 bytes, 32x32 tiles).
      final blockX = px.shr8;
      final blockY = py.shr8;
      int block = 0;
      if (size == 1) {
        block = blockX;
      } else if (size == 2) {
        block = blockY;
      } else if (size == 3) {
        block = blockY * 2 + blockX;
      }

      final tileX = px.shr3.mask5;
      final tileY = py.shr3.mask5;
      final mapAddr = screenBase + block * 0x800 + (tileY * 32 + tileX) * 2;
      final entry = _vram16(mapAddr);
      final tileNum = entry.mask10;
      final hflip = entry.bit10;
      final vflip = entry.bit11;

      int inX = px.mask3;
      int inY = py.mask3;
      if (hflip) inX = 7 - inX;
      if (vflip) inY = 7 - inY;

      // BG tiles cannot reach OBJ VRAM (0x10000-); such pixels are blank.
      int color = -1;
      if (is8bpp) {
        final a = charBase + tileNum * 64 + inY * 8 + inX;
        final idx = a < 0x10000 ? bus.vram[a] : 0;
        if (idx != 0) color = _pal(idx);
      } else {
        final palBank = entry.shr12.mask4;
        final a = charBase + tileNum * 32 + inY * 4 + inX.shr1;
        final byte = a < 0x10000 ? bus.vram[a] : 0;
        final nibble = inX.bit0 ? byte.shr4 : byte.mask4;
        if (nibble != 0) color = _pal(palBank * 16 + nibble);
      }
      out[x] = color;
    }

    _bgPrio[bg] = priority;
    _bgActive[bg] = true;
  }

  // --- affine background ----------------------------------------------------

  void _renderAffineBg(int bg, int line) {
    final cnt = _io16(0x08 + bg * 2);
    final priority = cnt.mask2;
    final charBase = cnt.shr2.mask2 * 0x4000;
    final screenBase = cnt.shr8.mask5 * 0x800;
    final wrap = cnt.bit13;
    final size = cnt.shr14.mask2;

    final mapSize = 128 << size; // pixels (128/256/512/1024)
    final tilesWide = 16 << size;

    final i = bg - 2;
    final pa = _io16(0x20 + i * 0x10).toSigned(16);
    final pc = _io16(0x24 + i * 0x10).toSigned(16);

    int cx = _refX[i];
    int cy = _refY[i];

    final out = _bg[bg];
    for (int x = 0; x < width; x++) {
      int texX = cx.shr8;
      int texY = cy.shr8;
      cx += pa;
      cy += pc;

      if (wrap) {
        texX &= mapSize - 1;
        texY &= mapSize - 1;
      } else if (texX < 0 || texX >= mapSize || texY < 0 || texY >= mapSize) {
        out[x] = -1;
        continue;
      }

      final tileNum = bus.vram[screenBase + texY.shr3 * tilesWide + texX.shr3];
      final idx = bus.vram[charBase + tileNum * 64 + texY.mask3 * 8 + texX.mask3];
      out[x] = idx != 0 ? _pal(idx) : -1;
    }

    _bgPrio[bg] = priority;
    _bgActive[bg] = true;
  }

  // --- bitmap backgrounds (modes 3/4/5) ------------------------------------

  void _renderBitmapBg(int mode, int dispcnt, int line) {
    final cnt = _io16(0x0c); // BG2CNT
    final priority = cnt.mask2;

    final pa = _io16(0x20).toSigned(16);
    final pc = _io16(0x24).toSigned(16);
    int cx = _refX[0];
    int cy = _refY[0];

    final page = (mode != 3 && dispcnt.bit4) ? 0xa000 : 0;
    final bmpW = mode == 5 ? 160 : 240;
    final bmpH = mode == 5 ? 128 : 160;

    final out = _bg[2];
    for (int x = 0; x < width; x++) {
      final texX = cx.shr8;
      final texY = cy.shr8;
      cx += pa;
      cy += pc;

      if (texX < 0 || texX >= bmpW || texY < 0 || texY >= bmpH) {
        out[x] = -1;
        continue;
      }

      if (mode == 4) {
        final idx = bus.vram[page + texY * bmpW + texX];
        out[x] = idx != 0 ? _pal(idx) : -1;
      } else {
        // modes 3 and 5: direct 16-bit colour (always opaque).
        out[x] = _vram16(page + (texY * bmpW + texX) * 2).mask15;
      }
    }

    _bgPrio[2] = priority;
    _bgActive[2] = true;
  }

  // --- sprites --------------------------------------------------------------

  // [shape][size] -> (width, height) in pixels.
  static const _objSize = [
    [
      [8, 8],
      [16, 16],
      [32, 32],
      [64, 64]
    ],
    [
      [16, 8],
      [32, 8],
      [32, 16],
      [64, 32]
    ],
    [
      [8, 16],
      [8, 32],
      [16, 32],
      [32, 64]
    ],
  ];

  void _renderObjects(int dispcnt, int line) {
    _objColor.fillRange(0, width, -1);
    _objPrio.fillRange(0, width, 4);
    _objSemi.fillRange(0, width, 0);
    _objWindow.fillRange(0, width, 0);

    final objEnabled = dispcnt.bit12;
    final objWinEnabled = dispcnt.bit15;
    if (!objEnabled && !objWinEnabled) return; // no OBJ, no OBJ window

    final oneDim = dispcnt.bit6;
    final bitmapMode = dispcnt.mask3 >= 3;

    final mosaicReg = _io16(0x4c);
    final mosaicH = mosaicReg.shr8.mask4 + 1;
    final mosaicV = mosaicReg.shr12.mask4 + 1;

    for (int n = 0; n < 128; n++) {
      final a0 = _oam16(n * 8);
      final a1 = _oam16(n * 8 + 2);
      final a2 = _oam16(n * 8 + 4);

      final objMode = a0.shr8.mask2; // 0 normal,1 affine,2 hidden,3 affine x2
      if (objMode == 2) continue;
      final affine = objMode == 1 || objMode == 3;
      final doubled = objMode == 3;

      final shape = a0.shr14.mask2;
      final size = a1.shr14.mask2;
      if (shape == 3) continue; // reserved
      final w = _objSize[shape][size][0];
      final h = _objSize[shape][size][1];
      final boxW = doubled ? w * 2 : w;
      final boxH = doubled ? h * 2 : h;

      final y = a0.mask8;
      final dy = (line - y).mask8;
      if (dy >= boxH) continue;

      final gfx = a0.shr10.mask2; // 0 normal,1 semi-transparent,2 obj window
      if (gfx == 2 ? !objWinEnabled : !objEnabled) continue;
      final mosaic = a0.bit12;
      final color256 = a0.bit13;
      final priority = a2.shr10.mask2;
      final palBank = a2.shr12.mask4;
      final tileBase = a2.mask10;

      int pa = 0x100, pb = 0, pc = 0, pd = 0x100;
      bool hflip = false, vflip = false;
      if (affine) {
        final p = a1.shr9.mask5;
        pa = _oam16(p * 0x20 + 0x06).toSigned(16);
        pb = _oam16(p * 0x20 + 0x0e).toSigned(16);
        pc = _oam16(p * 0x20 + 0x16).toSigned(16);
        pd = _oam16(p * 0x20 + 0x1e).toSigned(16);
      } else {
        hflip = a1.bit12;
        vflip = a1.bit13;
      }

      final x0 = a1.mask9;
      final tilesWide = w.shr3;
      final halfW = boxW.shr1, halfH = boxH.shr1;

      int srcY = dy;
      if (mosaic) srcY = dy - dy % mosaicV;

      for (int col = 0; col < boxW; col++) {
        final sx = (x0 + col).mask9;
        if (sx >= width) continue;

        int srcX = col;
        if (mosaic) srcX = col - col % mosaicH;

        int texX, texY;
        if (affine) {
          final ox = srcX - halfW;
          final oy = srcY - halfH;
          texX = (pa * ox + pb * oy).shr8 + w.shr1;
          texY = (pc * ox + pd * oy).shr8 + h.shr1;
          if (texX < 0 || texX >= w || texY < 0 || texY >= h) continue;
        } else {
          texX = srcX;
          texY = srcY;
          if (hflip) texX = w - 1 - texX;
          if (vflip) texY = h - 1 - texY;
        }

        final tileX = texX.shr3, tileY = texY.shr3;
        // tile numbers wrap within the 32KB OBJ VRAM
        final tileNo = (oneDim
                ? tileBase + (tileY * tilesWide + tileX) * (color256 ? 2 : 1)
                : tileBase + tileY * 32 + tileX * (color256 ? 2 : 1)) &
            0x3ff;

        // in bitmap modes only the upper half of OBJ VRAM is usable.
        if (bitmapMode && tileNo < 512) continue;

        final inX = texX.mask3, inY = texY.mask3;
        int color = -1;
        if (color256) {
          final idx = bus.vram[0x10000 + tileNo * 32 + inY * 8 + inX];
          if (idx != 0) color = _pal(256 + idx);
        } else {
          final byte = bus.vram[0x10000 + tileNo * 32 + inY * 4 + inX.shr1];
          final nibble = inX.bit0 ? byte.shr4 : byte.mask4;
          if (nibble != 0) color = _pal(256 + palBank * 16 + nibble);
        }
        if (color < 0) continue;

        if (gfx == 2) {
          _objWindow[sx] = 1;
          continue;
        }

        // the higher priority wins; on a tie the lower OAM index (drawn first).
        if (_objColor[sx] < 0 || priority < _objPrio[sx]) {
          _objColor[sx] = color;
          _objPrio[sx] = priority;
          _objSemi[sx] = gfx == 1 ? 1 : 0;
        }
      }
    }
  }

  // --- window ---------------------------------------------------------------

  // returns a 6-bit enable mask: bits0-3 BG0-3, bit4 OBJ, bit5 colour effect.
  int _windowMask(int dispcnt, int x, int line) {
    final win0 = dispcnt.bit13;
    final win1 = dispcnt.bit14;
    final winObj = dispcnt.bit15;
    if (!win0 && !win1 && !winObj) return 0x3f;

    final winin = _io16(0x48);
    final winout = _io16(0x4a);

    if (win0 && _inWindow(x, line, 0x40, 0x44)) return winin.mask6;
    if (win1 && _inWindow(x, line, 0x42, 0x46)) return winin.shr8.mask6;
    if (winObj && _objWindow[x] != 0) return winout.shr8.mask6;
    return winout.mask6;
  }

  bool _inWindow(int x, int line, int hReg, int vReg) {
    final h = _io16(hReg);
    final v = _io16(vReg);
    return _inRange(x, h.shr8, h.mask8, width) &&
        _inRange(line, v.shr8, v.mask8, height);
  }

  // [a1, a2) window span; a2 beyond the screen clamps to its edge, and a1 > a2
  // wraps around (inside = before a2 or from a1 on).
  static bool _inRange(int p, int a1, int a2, int limit) {
    if (a2 > limit) a2 = limit;
    return a1 <= a2 ? p >= a1 && p < a2 : p >= a1 || p < a2;
  }

  // --- compositing & colour effects ----------------------------------------

  void _composite(int dispcnt, int line, int base) {
    final backdrop = _pal(0);
    final bldcnt = _io16(0x50);
    final bldalpha = _io16(0x52);
    final bldy = _io16(0x54);
    final effect = bldcnt.shr6.mask2;
    final eva = bldalpha.mask5.clamp(0, 16);
    final evb = bldalpha.shr8.mask5.clamp(0, 16);
    final evy = bldy.mask5.clamp(0, 16);

    final hasWindow = dispcnt.bit13 || dispcnt.bit14 || dispcnt.bit15;

    for (int x = 0; x < width; x++) {
      final mask = hasWindow ? _windowMask(dispcnt, x, line) : 0x3f;

      // find the top two visible layers by priority (OBJ above BG on ties).
      int firstColor = backdrop, firstKind = 5;
      int secondColor = backdrop, secondKind = 5;
      int found = 0;

      outer:
      for (int p = 0; p < 4 && found < 2; p++) {
        if (_objColor[x] >= 0 && _objPrio[x] == p && mask.bit4) {
          if (found == 0) {
            firstColor = _objColor[x];
            firstKind = 4;
            found = 1;
          } else {
            secondColor = _objColor[x];
            secondKind = 4;
            found = 2;
            break outer;
          }
        }
        for (int bg = 0; bg < 4; bg++) {
          if (_bgActive[bg] &&
              _bgPrio[bg] == p &&
              _bg[bg][x] >= 0 &&
              (mask & (1 << bg)) != 0) {
            if (found == 0) {
              firstColor = _bg[bg][x];
              firstKind = bg;
              found = 1;
            } else {
              secondColor = _bg[bg][x];
              secondKind = bg;
              found = 2;
              break outer;
            }
          }
        }
      }

      int color = firstColor;
      final effectEnabled = mask.bit5;
      if (effectEnabled) {
        final firstIsTarget1 = bldcnt.bit(firstKind);
        final secondIsTarget2 = bldcnt.bit(8 + secondKind);
        final semiTop = firstKind == 4 && _objSemi[x] != 0;

        if (semiTop && secondIsTarget2) {
          color = _alphaBlend(firstColor, secondColor, eva, evb);
        } else if (firstIsTarget1 && effect == 1 && secondIsTarget2) {
          color = _alphaBlend(firstColor, secondColor, eva, evb);
        } else if (firstIsTarget1 && effect == 2) {
          color = _brighten(firstColor, evy);
        } else if (firstIsTarget1 && effect == 3) {
          color = _darken(firstColor, evy);
        }
      }

      buffer[base + x] = _rgba[color.mask15];
    }
  }

  int _alphaBlend(int top, int bot, int eva, int evb) {
    int r = (top.mask5 * eva + bot.mask5 * evb).shr4;
    int g = (top.shr5.mask5 * eva + bot.shr5.mask5 * evb).shr4;
    int b = (top.shr10.mask5 * eva + bot.shr10.mask5 * evb).shr4;
    if (r > 31) r = 31;
    if (g > 31) g = 31;
    if (b > 31) b = 31;
    return r | g.shl5 | b.shl10;
  }

  int _brighten(int c, int evy) {
    final r = c.mask5, g = c.shr5.mask5, b = c.shr10.mask5;
    final nr = r + ((31 - r) * evy).shr4;
    final ng = g + ((31 - g) * evy).shr4;
    final nb = b + ((31 - b) * evy).shr4;
    return nr | ng.shl5 | nb.shl10;
  }

  int _darken(int c, int evy) {
    final r = c.mask5, g = c.shr5.mask5, b = c.shr10.mask5;
    final nr = r - (r * evy).shr4;
    final ng = g - (g * evy).shr4;
    final nb = b - (b * evy).shr4;
    return nr | ng.shl5 | nb.shl10;
  }

  // --- debug ----------------------------------------------------------------

  /// 16x32 swatch grid of the 512 palette entries (debugger view).
  ImageBuffer renderColorTable() {
    const cell = 8;
    const cols = 16;
    const rows = 32;
    final buf = Uint32List(cols * cell * rows * cell);
    for (int i = 0; i < 512; i++) {
      final cxp = (i % cols) * cell;
      final cyp = (i ~/ cols) * cell;
      final col = _rgba[_pal(i).mask15];
      for (int yy = 0; yy < cell; yy++) {
        final row = (cyp + yy) * cols * cell;
        for (int xx = 0; xx < cell; xx++) {
          buf[row + cxp + xx] = col;
        }
      }
    }
    return ImageBuffer(cols * cell, rows * cell, buf.buffer.asUint8List());
  }

  /// 4bpp tile sheet from the start of VRAM (32x32 tiles = 256x256 px), using
  /// background palette bank [paletteNo].
  ImageBuffer renderVram(bool useSecondBgColor, int paletteNo) {
    const tilesPerRow = 32;
    const tileRows = 32;
    const w = tilesPerRow * 8;
    const h = tileRows * 8;
    final buf = Uint32List(w * h);
    final palBase = paletteNo.mask4 * 16;

    for (int t = 0; t < tilesPerRow * tileRows; t++) {
      final tileX = (t % tilesPerRow) * 8;
      final tileY = (t ~/ tilesPerRow) * 8;
      final tileAddr = t * 32;
      for (int y = 0; y < 8; y++) {
        final row = (tileY + y) * w + tileX;
        for (int x = 0; x < 8; x++) {
          final byte = bus.vram[tileAddr + y * 4 + x.shr1];
          final nibble = x.bit0 ? byte.shr4 : byte.mask4;
          buf[row + x] = nibble == 0
              ? 0xff000000
              : _rgba[_pal(palBase + nibble).mask15];
        }
      }
    }
    return ImageBuffer(w, h, buf.buffer.asUint8List());
  }

  /// one line per OAM sprite describing its position, size and attributes.
  List<String> spriteInfo() {
    final out = <String>[];
    for (int n = 0; n < 128; n++) {
      final a0 = _oam16(n * 8);
      final a1 = _oam16(n * 8 + 2);
      final a2 = _oam16(n * 8 + 4);
      final objMode = a0.shr8.mask2;
      if (objMode == 2) continue; // hidden
      final shape = a0.shr14.mask2;
      final size = a1.shr14.mask2;
      if (shape == 3) continue;
      final w = _objSize[shape][size][0];
      final h = _objSize[shape][size][1];
      final x = a1.mask9;
      final y = a0.mask8;
      final tile = a2.mask10;
      final prio = a2.shr10.mask2;
      out.add("$n: ($x,$y) ${w}x$h tile:$tile pr:$prio "
          "${objMode == 1 || objMode == 3 ? 'aff' : ''}");
    }
    return out;
  }
}
