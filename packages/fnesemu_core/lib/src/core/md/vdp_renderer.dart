import 'dart:typed_data';

import '../../util/int.dart';

import 'vdp.dart';

// preliminary building an RGBA color map for all 512 colors
const _map3to8 = [0x00, 0x24, 0x49, 0x6d, 0x92, 0xb6, 0xdb, 0xff]; //

final Uint32List rgba = Uint32List.fromList(
  List.generate(512, (i) {
    final r = _map3to8[i.mask3];
    final g = _map3to8[i.shr3.mask3];
    final b = _map3to8[i.shr6.mask3];
    return 0xff000000 | b.shl16 | g.shl8 | r;
  }, growable: false),
);

class Sprite {
  late final int x;
  late final int y;
  late final int patternAddr;
  late final int paletteNo;
  late final bool vFlip;
  late final bool hFlip;
  late final int height;
  late final int width;
  late final int vCells;
  late final bool priority;
  late final int next;

  Sprite.of(int d0, int d1, int d2, int d3, {bool interlaced = false}) {
    y = d0 & (interlaced ? 0x3ff : 0x1ff);
    x = d3.mask9;

    vFlip = d2.bit12;
    hFlip = d2.bit11;
    priority = d2.bit15;
    paletteNo = d2.shr9 & 0x30;
    patternAddr = d2.shl5 & 0xffe0;

    next = d1.mask7;

    vCells = d1.shr8.mask2 + 1;
    height = vCells.shl3;

    final hCells = d1.shr10.mask2 + 1;
    width = hCells.shl3;
  }
}

// a pixel of a layer is encoded in an int: bit0-5: color (palette | color
// number), bit6: priority. it is visible when the color number is not 0.
const _pixelPriorityFlag = 0x40;
const _pixelColorNumberMask = 0x0f;
const _pixelPaletteMask = 0x30;
const _pixelColorMask = _pixelPaletteMask | _pixelColorNumberMask;
const _priorityAndColorNumberMask = _pixelPriorityFlag | _pixelColorNumberMask;
const _spriteHFlipFlag = 1;
const _spriteVFlipFlag = 2;

// A masked value exceeds the priority flag only when the flag is set and
// the color number is nonzero. Ignoring palette bits keeps color 0 transparent.
// One AND and one comparison retain the original per-pixel operation count.
@pragma('vm:prefer-inline')
bool _isPriorVisible(int pixel) =>
    (pixel & _priorityAndColorNumberMask) > _pixelPriorityFlag;

@pragma('vm:prefer-inline')
bool _isVisible(int pixel) => (pixel & _pixelColorNumberMask) != 0;

/// state of a plane (a, b or window) while rendering a line: the tile pattern
/// is fetched again only when the tile is changed
class _Plane {
  int nameAddrBase = 0;
  int hScroll = 0;
  int yOffsetInTile = 0; // scroll added
  int tileY = 0;
  int pattern = 0; // 32 bit c3c2c1c0 * 8
  int attr = 0; // palette (pp0000) | priority (_pixelPriorityFlag)
  int hFlipXor = 0;
  int fetchedHHigh = -1;

  void init(int nameAddrBase, int hScroll, int yOffsetInTile, int tileY) {
    this.nameAddrBase = nameAddrBase;
    this.hScroll = hScroll;
    this.yOffsetInTile = yOffsetInTile;
    this.tileY = tileY;
    pattern = 0;
    attr = 0;
    hFlipXor = 0;
    fetchedHHigh = -1;
  }

  @pragma('vm:prefer-inline')
  void fetch(Uint8List vram, int name, int maskTileYOffset, int bitsTileV) {
    final d0 = vram[name];
    final d1 = vram[name + 1];

    attr = d0.shr1 & _pixelPaletteMask |
        (d0.bit7 ? _pixelPriorityFlag : 0);
    hFlipXor = d0.bit3 ? 0 : 7;
    final vFlipXor = d0.bit4 ? maskTileYOffset : 0;

    final offset = yOffsetInTile ^ vFlipXor;
    final addr = ((d0.shl8 & 0x0700 | d1) << bitsTileV | offset).shl2;

    final a = addr.mask16;
    pattern =
        vram[a].shl24 | vram[a + 1].shl16 | vram[a + 2].shl8 | vram[a + 3];
  }

  @pragma('vm:prefer-inline')
  int pixel(int xOffsetInTile) =>
      attr |
      (pattern >> (xOffsetInTile ^ hFlipXor).shl2) & _pixelColorNumberMask;
}

/// per line work buffers of the renderer
class VdpLineState {
  int bitsBgWidth =
      0; // shift for scanline (doubled in interlace mode 2) to tile_y
  int maskBgWidth = 0; // mask for tile_x
  int maskScrollH = 0; // mask for hscroll+hcounter
  int maskScrollV = 0; // mask for vscroll+vcounter
  int maskTileYOffset = 0x07;
  int bitsTileV = 3; // shift for vscroll+vcounter to tile_y

  int y = 0;
  int yy = 0; // doubled when interlace mode

  // Parallel arrays share one sprite slot; only [0, spriteBufIndex) is valid.
  // storeSprite writes every attribute together before the slot becomes valid.
  // sprites on the line: x, y, pattern address, palette | priority,
  // flags (bit0: hflip, bit1: vflip), width, height, vertical cells
  final spX = Int32List(20);
  final spY = Int32List(20);
  final spPattern = Int32List(20);
  final spAttr = Int32List(20);
  final spFlags = Int32List(20);
  final spWidth = Int32List(20);
  final spHeight = Int32List(20);
  final spVCells = Int32List(20);
  int spriteBufIndex = 0;

  // Store every parallel-array attribute together; the renderer advances its
  // valid slot count only after this write. No sprite object is allocated.
  @pragma('vm:prefer-inline')
  void storeSprite(
    int slot, {
    required int x,
    required int y,
    required int pattern,
    required int attributes,
    required int flags,
    required int width,
    required int height,
    required int verticalCells,
  }) {
    spX[slot] = x;
    spY[slot] = y;
    spPattern[slot] = pattern;
    spAttr[slot] = attributes;
    spFlags[slot] = flags;
    spWidth[slot] = width;
    spHeight[slot] = height;
    spVCells[slot] = verticalCells;
  }

  // sprite pixels of the line
  final spLine = Int32List(320);

  final a = _Plane();
  final b = _Plane();
  final window = _Plane();
}

extension VdpRenderer on Vdp {
  void _fillSpriteBuffer() {
    final s = line;
    spriteOverflow = false;

    final overflowCount = h32 ? 16 : 20;
    final displayCount = h32 ? 64 : 80;
    final pixelCount = h32 ? 256 : 320;
    final interlaced = isInterlaced;
    final y = s.y;
    final yy = s.yy;

    final baseAddr = reg[5].shl9 & (h32 ? 0xfe00 : 0xfc00);
    int spriteNo = 0;
    int pixelsPerLine = 0;
    int n = 0;

    for (int i = 0; i < displayCount; i++) {
      final base = baseAddr + spriteNo * 8;
      final a0 = base.mask16;
      final a1 = (base + 2).mask16;
      final a2 = (base + 4).mask16;
      final a3 = (base + 6).mask16;
      final d0 = vram[a0].shl8 | vram[a0 + 1];
      final d1 = vram[a1].shl8 | vram[a1 + 1];
      final d2 = vram[a2].shl8 | vram[a2 + 1];
      final d3 = vram[a3].shl8 | vram[a3 + 1];

      final spY = d0 & (interlaced ? 0x3ff : 0x1ff);
      final vCells = d1.shr8.mask2 + 1;
      final height = vCells.shl3;
      final width = (d1.shr10.mask2 + 1).shl3;
      final next = d1.mask7;

      final isTarget = interlaced
          ? (spY - 256 <= yy && yy < spY - 256 + height * 2)
          : (spY - 128 <= y && y < spY - 128 + height);

      if (isTarget) {
        if (n == overflowCount) {
          spriteOverflow = true;
          break;
        }

        pixelsPerLine += width;
        if (pixelsPerLine >= pixelCount) {
          break;
        }

        s.storeSprite(n,
            x: d3.mask9,
            y: spY,
            pattern: d2.shl5 & 0xffe0,
            attributes: d2.shr9 & _pixelPaletteMask |
                (d2.bit15 ? _pixelPriorityFlag : 0),
            flags: (d2.bit11 ? _spriteHFlipFlag : 0) |
                (d2.bit12 ? _spriteVFlipFlag : 0),
            width: width,
            height: height,
            verticalCells: vCells);
        n++;
      }

      if (next == 0) {
        break;
      }

      spriteNo = next;
    }

    s.spriteBufIndex = n;
  }

  /// renders the sprite pixels of the line into spLine. where sprites
  /// overlap, the first one in the list with a non-transparent pixel wins.
  void _renderSprites(int width) {
    final s = line;
    final spLine = s.spLine;
    spLine.fillRange(0, width, 0);

    final interlaced = isInterlaced;
    final yShift1 = interlaced ? 1 : 0;
    final maskTileYOffset = s.maskTileYOffset;
    final bitsTileV = s.bitsTileV;

    // draw in the reverse order, so that the earlier sprites overwrite
    for (int i = s.spriteBufIndex - 1; i >= 0; i--) {
      final spX = s.spX[i];
      final spW = s.spWidth[i];
      final hFlip = s.spFlags[i] & _spriteHFlipFlag != 0;
      final vFlip = s.spFlags[i] & _spriteVFlipFlag != 0;
      final attr = s.spAttr[i];
      final vCells = s.spVCells[i];

      final vv = interlaced ? (s.yy + 256 - s.spY[i]) : (s.y + 128 - s.spY[i]);
      final flippedY = vFlip ? (s.spHeight[i] << yShift1) - vv - 1 : vv;
      final y1 = flippedY & maskTileYOffset;
      final y2 = flippedY >> bitsTileV;
      final patternBase = s.spPattern[i] << yShift1;

      int fetchedX2 = -1;
      int pattern = 0;

      // hh: x in the sprite, px: x on the screen
      int hh = 0;
      int px = spX - 128;
      if (px < 0) {
        hh = -px;
        px = 0;
      }

      for (; hh < spW && px < width; hh++, px++) {
        final flippedX = hFlip ? spW - hh - 1 : hh;
        final x1 = flippedX.mask3;
        final x2 = flippedX.shr3;

        // fetch pattern data if x2 is changed
        if (x2 != fetchedX2) {
          fetchedX2 = x2;
          final addr =
              (patternBase + ((x2 * vCells + y2) << bitsTileV | y1).shl2).mask16;
          pattern = vram[addr].shl24 |
              vram[addr + 1].shl16 |
              vram[addr + 2].shl8 |
              vram[addr + 3];
        }

        final colorNo = (pattern >> (7 - x1).shl2) & _pixelColorNumberMask;

        if (colorNo > 0) {
          spLine[px] = attr | colorNo;
        }
      }
    }
  }

  void _setBgSize() {
    final s = line;
    s.bitsBgWidth = const [5, 6, 7, 7][reg[16].mask2];
    s.maskBgWidth = (1 << s.bitsBgWidth) - 1;
    s.maskScrollH = (1 << (s.bitsBgWidth + 3)) - 1;

    s.bitsTileV = isInterlaced ? 4 : 3;
    s.maskTileYOffset = (1 << s.bitsTileV) - 1;

    final maskBgHeight = const [0x1f, 0x3f, 0x7f, 0x7f][reg[16].shr4.mask2];
    s.maskScrollV = maskBgHeight << s.bitsTileV | s.maskTileYOffset;
  }

  @pragma('vm:prefer-inline')
  void _setVScroll(_Plane ctx, int vScroll) {
    final s = line;
    final v = (s.yy + vScroll) & s.maskScrollV;
    final yOffsetInTile = v & s.maskTileYOffset;
    final tileY = v >> s.bitsTileV;

    if (yOffsetInTile != ctx.yOffsetInTile || tileY != ctx.tileY) {
      ctx.yOffsetInTile = yOffsetInTile;
      ctx.tileY = tileY;
      ctx.fetchedHHigh = -1; // force to fetch the pattern again
    }
  }

  @pragma('vm:prefer-inline')
  int _windowColor(_Plane ctx, int h) {
    final s = line;
    final hLow = h.mask3;
    final hHigh = h.shr3;

    if (hHigh != ctx.fetchedHHigh) {
      ctx.fetchedHHigh = hHigh;
      final v = s.y;
      final name = ctx.nameAddrBase |
          (width == 256
              ? hHigh.mask5.shl1 | v.shr3.shl6
              : hHigh.mask6.shl1 | v.shr3.shl7);
      ctx.fetch(vram, name, s.maskTileYOffset, s.bitsTileV);
    }

    return ctx.pixel(hLow);
  }

  @pragma('vm:prefer-inline')
  int _planeColor(_Plane ctx, int hc) {
    final s = line;
    final h = (hc - ctx.hScroll) & s.maskScrollH;
    final tileX = h.shr3;

    if (tileX != ctx.fetchedHHigh) {
      ctx.fetchedHHigh = tileX;
      final name = ctx.nameAddrBase |
          (tileX & s.maskBgWidth | ctx.tileY << s.bitsBgWidth).shl1;
      ctx.fetch(vram, name, s.maskTileYOffset, s.bitsTileV);
    }

    return ctx.pixel(h.mask3);
  }

  // true: require rendering+hsync, false: retrace
  bool renderLine() {
    final s = line;
    vCounter++;
    if (vCounter == Vdp.height + Vdp.retrace) {
      vCounter = 0;
      if (interlaceMode != 0) {
        oddFrame = !oddFrame;
      }
    }

    final y = s.y = vCounter - 2;
    final yy = s.yy = interlaceMode != 3 ? y : (y.shl1 + (oddFrame ? 1 : 0));

    hBlank = false;

    // z80 interrupt line is asserted only for about one line
    if (y == Vdp.height + 1) {
      busZ80.deassertInt();
    }

    final requireRender = 0 <= y && y < Vdp.height;

    if (isDmaRunning) {
      execDma(requireRender ? 9 : 102);
    }

    if (!requireRender) {
      vBlank = true; // during vblank
      return false;
    }

    _setBgSize();
    _fillSpriteBuffer();

    final width = this.width;
    final hScrollBase = reg[13].shl10 & 0xfc00;
    final isHScrollFull = !reg[11].bit1;
    final isHScrollLine = reg[11].bit0;
    final hScrollAddr = hScrollBase +
        (isHScrollFull
            ? 0
            : isHScrollLine
                ? y.shl2
                : (y & ~0x07).shl2);

    final ctxA = s.a
      ..init(reg[2].shl10 & 0xe000,
          (vram[hScrollAddr].shl8 | vram[hScrollAddr + 1]).mask10, 0, 0);
    _setVScroll(ctxA, vsram[0]);

    final ctxB = s.b
      ..init(reg[4].shl13 & 0xe000,
          (vram[hScrollAddr + 2].shl8 | vram[hScrollAddr + 3]).mask10, 0, 0);
    _setVScroll(ctxB, vsram[1]);

    final ctxWindow = s.window
      ..init(
          reg[3].shl10 & 0xf800, 0, yy & s.maskTileYOffset, yy >> s.bitsTileV);

    final r11 = reg[0x11];
    final windowH0 = r11.bit7 ? 0 : r11.shl4 & 0x1f0;
    final windowH1 = r11.bit7 ? r11.shl4 & 0x1f0 : width;

    final r12 = reg[0x12];
    final windowV0 = r12.bit7 ? 0 : r12.shl3 & 0xf8;
    final windowV1 = r12.bit7 ? r12.shl3 & 0xf8 : Vdp.height;

    final vInWindow = windowV0 <= y && y < windowV1;
    final bufferOffset = y * width;
    final bg = reg[7].mask6;

    if (!enableDisplay) {
      buffer.fillRange(bufferOffset, bufferOffset + width, rgba[cram[bg]]);
      if (trackOpacity) {
        opaque.fillRange(bufferOffset, bufferOffset + width, 0);
      }
      hCounter = width;
      vBlank = false;
      return true;
    }

    _renderSprites(width);

    final spLine = s.spLine;
    final buf = buffer;
    final cr = cram;
    final vsr = vsram;
    final track = trackOpacity;
    final opq = track ? opaque : null;
    final vScr2 = vScr2Cell;

    for (int hc = 0; hc < width; hc++) {
      int color;
      bool visible = true;

      // 2-cell vertical scroll: each 16 pixel column has its own vscroll
      if (vScr2 && hc.mask4 == 0) {
        final column = hc.shr4.shl1;
        _setVScroll(ctxA, vsr[column]);
        _setVScroll(ctxB, vsr[column + 1]);
      }

      final sprite = spLine[hc];
      if (_isPriorVisible(sprite)) {
        color = sprite;
      } else {
        final inWindow = windowH0 <= hc && hc < windowH1 && vInWindow;
        final planeAW =
            inWindow ? _planeColor(ctxA, hc) : _windowColor(ctxWindow, hc);
        if (_isPriorVisible(planeAW)) {
          color = planeAW;
        } else {
          final planeB = _planeColor(ctxB, hc);
          if (track) {
            visible =
                _isVisible(sprite) || _isVisible(planeAW) || _isVisible(planeB);
          }

          color = _isPriorVisible(planeB)
              ? planeB
              : _isVisible(sprite)
                  ? sprite
                  : _isVisible(planeAW)
                      ? planeAW
                      : _isVisible(planeB)
                          ? planeB
                          : bg;
        }
      }

      buf[bufferOffset + hc] = rgba[cr[color & _pixelColorMask]];
      if (opq != null) opq[bufferOffset + hc] = visible ? 1 : 0;
    }

    hCounter = width;
    vBlank = false;
    return true;
  }

  void startHBlank() {
    if (!vBlank) {
      hBlank = true;
    }
  }

  void finishLine() {
    final y = line.y;
    if (y == Vdp.height - 1) {
      vBlank = true;
      status |= Vdp.bitVblankInt; // on: vsync int occureed
      busZ80.assertInt(); // z80 int is not affected by the m68 vint enable
      if (enableVInt) {
        bus.interrupt(6);
      }
      return;
    }

    if (!vBlank) {
      if (enableHInt) {
        if (hIntCounter == 0) {
          hIntCounter = reg[10];
          bus.interrupt(4);
          return;
        }

        hIntCounter--;
      }

      return;
    }

    if (vCounter == 0 || y >= Vdp.height) {
      hIntCounter = reg[10];
    }
  }
}
