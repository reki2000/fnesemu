// import '../../../util/debug.dart';
import 'dart:typed_data';

import '../../../util/int.dart';
import 'vdc.dart';

// final _log = DebugLog('pce.vdc_render');

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
    no = i.shr2;
    y = sat[i].mask10;
    x = sat[i + 1].mask10;

    cgModeTreal01Zero = sat[i + 2].bit0;
    vFlip = sat[i + 3].bit15;
    hFlip = sat[i + 3].bit11;
    priority = sat[i + 3].bit7;
    paletteNo = sat[i + 3].mask4.shl4 | 0x100;

    height = switch (sat[i + 3].shr12.mask2) { 0 => 16, 1 => 32, _ => 64 };
    width = switch (sat[i + 3].shr8.mask1) { 0 => 16, _ => 32 };

    int patternMask = 0;
    if (height == 64) {
      patternMask |= 0x06;
    } else if (height == 32) {
      patternMask |= 0x02;
    }
    if (width == 32) {
      patternMask |= 0x01;
    }
    patternNo = sat[i + 2].shr1.mask10 & ~patternMask;
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
    final b = _map3to8[i.mask3];
    final r = _map3to8[i.shr3.mask3];
    final g = _map3to8[i.shr6.mask3];
    return 0xff000000 | b.shl16 | g.shl8 | r;
  }, growable: false),
);

extension VdcRenderer on Vdc {
  static bool debug = false;

  // renders pixel by pixel as the reference of the line renderer (tests)
  static bool perPixel = false;

  static int displayStartLine = 14;

  static int frames = 0;

  resetRenderer() {
    bgRenderLine = 0;
    displayLine = 0;
    spriteBufIndex = 0;
    renderedSpriteEnabled.fillRange(0, renderedSpriteEnabled.length, null);
    sprite0.fillRange(0, sprite0.length, false);
    paletteNo = 0;
    pattern01 = 0;
    pattern23 = 0;
    frames = 0;
    indexBuffer = Uint16List(hSize * vSize);
  }

  // render a line;
  void exec() {
    displayLine = scanLine - displayStartLine;

    if (displayLine == 0) {
      if (pendingHSize != hSize) {
        hSize = pendingHSize;
        indexBuffer = Uint16List(hSize * vSize);
      }
      pendingHSize = hdrWidth;
      bgRenderLine = scrollY & bgScrollMaskY;
      // buffer = Uint32List(hSize * vSize);
    }

    // 242 lines
    if (0 <= displayLine && displayLine < 242) {
      renderedSpriteEnabled[displayLine] = enableSprite;
      _fillSpriteBuffer();

      if (debug || perPixel) {
        for (scanX = 0; scanX < hSize; scanX++) {
          _render();
        }
      } else {
        _renderLine();
        scanX = hSize;
      }

      // debug: show line counter by 16 lines
      if (debug &&
          displayLine >= 0x10 &&
          0 <= displayLine.mask4 &&
          displayLine.mask4 < 5) {
        for (int x = 0; x < 4 * 2; x++) {
          if ((displayLine & 0xf0).drawHexValue(x, displayLine.mask4, 2)) {
            indexBuffer[(displayLine - 5) * hSize + 1 + x] = 0xffff;
          }
        }
      }

      if (displayLine + 0x40 == rasterCompareRegister) {
        if (enableRasterCompareIrq) {
          raiseIrq(Vdc.statusRasterCompare);
        }
      }
    }

    if (scanLine == 260) {
      if (enableVBlank) {
        raiseIrq(Vdc.statusVBlank);
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
      if (priority == 0) frames++;
    }
  }

  // renders the current line at once. same output as calling _render() for
  // each pixel (which is kept for the debug overlay), without per-pixel calls
  // and allocations.
  void _renderLine() {
    final w = hSize;
    final buf = indexBuffer;
    final base = displayLine * w;
    final spl = spriteLine;
    final sprite = enableSprite;

    if (sprite) _renderSpriteLine(w);

    if (!enableBg) {
      // no bg: the bg color is 0 (transparent), so the sprite color is used
      for (int x = 0; x < w; x++) {
        buf[base + x] = sprite ? spl[x].mask9 : 0;
      }
      return;
    }

    final vram = this.vram;
    final sx = scrollX;
    final maskX = bgScrollMaskX;
    final row = (bgRenderLine.shr3 & bgHeightMask) << bgWidthBits;
    final maskW = bgWidthMask;
    final fineY = bgRenderLine.mask3;
    final dot3 = vramDotWidth == 3;
    final zero23 = bgTreatPlane23Zero;
    final expand = _planeBitsToPixels;
    int pal = paletteNo;
    int p01 = pattern01;
    int p23 = pattern23;
    // a tile at a time: bx wraps at a multiple of 8, so every tile starts
    // with a fetch, as the per-pixel renderer does at x == 0 or bx & 7 == 0
    for (int x = 0; x < w;) {
      final bx = (x + sx) & maskX;
      final tile = vram[row | (bx.shr3 & maskW)];
      pal = tile.shr12.shl4;
      final addr = tile.mask12.shl4 | fineY;
      if (dot3) {
        if (zero23) {
          p01 = vram[addr];
          p23 = 0;
        } else {
          p01 = 0;
          p23 = vram[addr];
        }
      } else {
        p01 = vram[addr];
        p23 = vram[addr + 8];
      }
      // the 8 pixels of the tile, 4 bits each: pixel of shift s at bit s * 4
      final chunky = expand[p01.mask8] |
          expand[p01.shr8].shl1 |
          expand[p23.mask8].shl2 |
          expand[p23.shr8].shl3;

      int shift = 7 - bx.mask3;
      final end = x + shift + 1 < w ? x + shift + 1 : w;
      if (sprite) {
        for (; x < end; x++, shift--) {
          final c = (chunky >> shift.shl2).mask4;
          final sp = spl[x];
          // the sprite is in front when it has the priority or the bg is clear
          buf[base + x] =
              (sp & _spritePriorityFlag) != 0 || c == 0 ? sp.mask9 : pal | c;
        }
      } else {
        for (; x < end; x++, shift--) {
          final c = (chunky >> shift.shl2).mask4;
          buf[base + x] = c == 0 ? 0 : pal | c;
        }
      }
    }

    paletteNo = pal;
    pattern01 = p01;
    pattern23 = p23;
  }

  // Bit n of a plane byte moves to bit n * 4 in eight 4-bit pixel slots.
  // Example: 0b00000011 -> 0x00000011; four planes are ORed at shifts 0..3.
  // Higher input bits represent the pixels drawn first (left to right).
  static final _planeBitsToPixels = Uint32List.fromList(List.generate(256, (b) {
    int v = 0;
    for (int n = 0; n < 8; n++) {
      v |= (b >> n).mask1 << (n * 4);
    }
    return v;
  }));

  static const _spritePriorityFlag = 0x10000;

  // whether a sprite of the line buffer has a non-transparent pixel
  static final _spriteOpaque = List<bool>.filled(16, false);

  // fills spriteLine[0..w) with the sprite pixel of each x: the 9-bit color
  // (palette | color no, color no != 0) | _spritePriorityFlag, or 0 when there is none.
  // the first opaque sprite in the buffer wins, as in _renderSprite().
  void _renderSpriteLine(int w) {
    final spl = spriteLine;
    spl.fillRange(0, w, 0);
    final n = spriteBufIndex;
    if (n == 0) return;

    final vram = this.vram;
    final pix = spritePixels;
    final dot3 = vramDotWidth == 3;

    final expand = _planeBitsToPixels;
    final opaque = _spriteOpaque;

    // decode the pixels of each sprite of this line, 16 at a time
    for (int i = 0; i < n; i++) {
      final sp = spriteBuf[i];
      final width = sp.width;
      final vv = displayLine + 64 - sp.y;
      final flippedY = sp.vFlip ? sp.height - vv - 1 : vv;
      final y = flippedY.mask4;
      final y2 = flippedY.shr4;
      final hFlip = sp.hFlip;
      final off = i * 32;
      int any = 0;

      for (int x2 = 0; x2 < width.shr4; x2++) {
        int p0, p1, p2, p3;
        if (dot3) {
          final addr = (sp.patternNo + x2 + y2 * width.shr4).shl5 + y;
          if (sp.cgModeTreal01Zero) {
            p0 = p1 = 0;
            p2 = vram[addr];
            p3 = vram[addr + 16];
          } else {
            p0 = vram[addr];
            p1 = vram[addr + 16];
            p2 = p3 = 0;
          }
        } else {
          final addr = (sp.patternNo + x2 + y2.shl1).shl6 + y;
          p0 = vram[addr];
          p1 = vram[addr + 16];
          p2 = vram[addr + 32];
          p3 = vram[addr + 48];
        }
        any |= p0 | p1 | p2 | p3;

        // pixel fx (0: left) of the column is bit 15 - fx of the planes
        final left = expand[p0.shr8] |
            expand[p1.shr8].shl1 |
            expand[p2.shr8].shl2 |
            expand[p3.shr8].shl3;
        final right = expand[p0.mask8] |
            expand[p1.mask8].shl1 |
            expand[p2.mask8].shl2 |
            expand[p3.mask8].shl3;
        final fx0 = x2.shl4;
        for (int fx = 0; fx < 8; fx++) {
          final hh = hFlip ? width - 1 - (fx0 + fx) : fx0 + fx;
          pix[off + hh] = (left >> (7 - fx).shl2).mask4;
        }
        for (int fx = 8; fx < 16; fx++) {
          final hh = hFlip ? width - 1 - (fx0 + fx) : fx0 + fx;
          pix[off + hh] = (right >> (15 - fx).shl2).mask4;
        }
      }
      opaque[i] = any != 0;
    }

    if (!enalbeSpriteCollision) {
      // paint from the last sprite so that the first opaque one stays
      for (int i = n - 1; i >= 0; i--) {
        if (!opaque[i]) continue;
        final sp = spriteBuf[i];
        final xs = sp.x - 32 < 0 ? 0 : sp.x - 32;
        final xe = sp.x - 32 + sp.width > w ? w : sp.x - 32 + sp.width;
        final attr = sp.paletteNo | (sp.priority ? _spritePriorityFlag : 0);
        final off = i * 32 + 32 - sp.x;
        for (int x = xs; x < xe; x++) {
          final c = pix[off + x];
          if (c != 0) spl[x] = attr | c;
        }
      }
      return;
    }

    // sprite collision: visit the sprites of each pixel in order, as
    // _renderSprite() does, since sprite 0 marks the pixels it covers
    for (int x = 0; x < w; x++) {
      for (int i = 0; i < n; i++) {
        final sp = spriteBuf[i];
        final hh = x + 32 - sp.x;
        if (hh < 0 || hh >= sp.width) continue;
        final c = pix[i * 32 + hh];
        if (sp.no == 0) {
          sprite0[hh] = true;
        } else if (c != 0 &&
            sprite0[hh] &&
            status & Vdc.statusSpriteCollision == 0) {
          raiseIrq(Vdc.statusSpriteCollision);
        }
        if (c > 0) {
          spl[x] = sp.paletteNo | c | (sp.priority ? _spritePriorityFlag : 0);
          break;
        }
      }
    }
  }

  void _render() {
    final spColor =
        enableSprite ? _renderSprite() : const SpriteColor(0, isPrior: false);
    final bgColor = enableBg ? _renderBg() : 0;

    final colorNo = spColor.isPrior
        ? spColor.color
        : (bgColor.mask4 == 0)
            ? spColor.color
            : bgColor;

    // output the 9-bit VCE palette index; Vpc does the VCE->RGBA conversion
    // (and, in sgx mode, priority composition with the other VDC).
    // 0xffff is a sentinel for the debug direct-white pixel.
    indexBuffer[displayLine * hSize + scanX] =
        spColor.isDirect ? 0xffff : colorNo;
  }

  int _renderBg() {
    final x = (scanX + scrollX) & bgScrollMaskX;

    if (scanX == 0 || x.mask3 == 0) {
      final nameTableAddress =
          ((bgRenderLine.shr3 & bgHeightMask) << bgWidthBits) |
              (x.shr3 & bgWidthMask);
      // _log.debugc(() =>
      //     "h:$h, l:$line, x:$x, y:$y, sc:$scrollX, sy:$scrollY, addr: ${addr.x4}");
      final tile = vram[nameTableAddress];
      paletteNo = tile.shr12.shl4;

      if (vramDotWidth == 3) {
        final addr = tile.mask12.shl4 | bgRenderLine.mask3;
        if (bgTreatPlane23Zero) {
          pattern01 = (vram[addr]);
          pattern23 = 0;
        } else {
          pattern01 = 0;
          pattern23 = (vram[addr]);
        }
      } else {
        final addr = tile.mask12.shl4 | bgRenderLine.mask3;
        pattern01 = vram[addr];
        pattern23 = vram[addr + 8];
      }
    }

    final shiftBits = (7 - x.mask3);
    final p01 = pattern01 >> shiftBits;
    final p23 = pattern23 >> shiftBits;

    final colorNo =
        p01.mask1 | p01.shr7 & 0x02 | p23.shl2 & 0x04 | p23.shr5 & 0x08;

    return paletteNo | colorNo;
  }

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
            raiseIrq(Vdc.statusSpriteOverflow);
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
        final x = flippedX.mask4;
        final x2 = flippedX.shr4;

        final vv = displayLine + 64 - sp.y;
        final flippedY = sp.vFlip ? sp.height - vv - 1 : vv;
        final y = flippedY.mask4;
        final y2 = flippedY.shr4;

        if (debug) {
          // if (0 == hh && 0 == vv && sp.no == 0) {
          //   _log.debugc(() =>
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
            final addr = (sp.patternNo + x2 + y2 * sp.width.shr4).shl5 + y;

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
            final addr = (sp.patternNo + x2 + y2.shl1).shl6 + y;
            sp.p0 = vram[addr + 00];
            sp.p1 = vram[addr + 16];
            sp.p2 = vram[addr + 32];
            sp.p3 = vram[addr + 48];
          }
        }

        final shiftBits = 15 - x;
        final colorNo = (sp.p0 >> shiftBits).mask1 |
            ((sp.p1 >> shiftBits).shl1 & 0x02) |
            ((sp.p2 >> shiftBits).shl2 & 0x04) |
            ((sp.p3 >> shiftBits).shl3 & 0x08);

        if (enalbeSpriteCollision) {
          if (sp.no == 0) {
            sprite0[hh] = true;
          } else {
            if (colorNo != 0 &&
                sprite0[hh] &&
                status & Vdc.statusSpriteCollision == 0) {
              raiseIrq(Vdc.statusSpriteCollision);
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
