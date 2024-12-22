import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';
import 'package:fnesemu/util/util.dart';

import 'vdp.dart';

// preliminary building an RGBA color map for all 512 colors
const _map3to8 = [0x00, 0x24, 0x49, 0x6d, 0x92, 0xb6, 0xdb, 0xff]; //

final Uint32List rgba = Uint32List.fromList(
  List.generate(512, (i) {
    final r = _map3to8[i & 0x07];
    final g = _map3to8[i >> 3 & 0x07];
    final b = _map3to8[i >> 6 & 0x07];
    return 0xff000000 | (b << 16) | (g << 8) | r;
  }, growable: false),
);

class _BgPattern {
  int no = 0;
  int nameAddrBase = 0;
  int hScroll = 0;
  int vScroll = 0;
  int pattern = 0; // 32 bit c3c2c1c0 * 8
  bool prior = false;
  bool hFlip = false;
  bool vFlip = false;
  int palette = 0; // pp0000

  _BgPattern(this.no, this.nameAddrBase, this.hScroll, this.vScroll);
}

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

  int pattern = 0;
  int fetchedX2 = -1;

  Sprite.of(int d0, int d1, int d2, int d3) {
    y = d0 & 0x3ff;
    x = d3 & 0x1ff;

    vFlip = d2 & 0x1000 != 0;
    hFlip = d2 & 0x0800 != 0;
    priority = d2 & 0x8000 != 0;
    paletteNo = d2 >> 9 & 0x30;
    patternAddr = d2 << 5 & 0xffe0;

    next = d1 & 0x7f;

    vCells = (d1 >> 8 & 3) + 1;
    height = vCells << 3;

    final hCells = (d1 >> 10 & 3) + 1;
    width = hCells << 3;
  }
}

class PriorityColor {
  final int color;
  final bool isDirect;
  final bool isPrior;

  const PriorityColor(this.color, {this.isDirect = false, this.isPrior = true});
}

extension VdpRenderer on Vdp {
  static int vShift = 0;
  static int hMask = 0;
  static int hScrMask = 0;
  static int vMask = 0;
  static int vScrMask = 0;

  static int y = 0;

  static final sprites =
      List<Sprite>.filled(64, Sprite.of(0, 0, 0, 0), growable: false);
  static final spriteBuf =
      List<Sprite>.filled(20, Sprite.of(0, 0, 0, 0), growable: false);
  static int spriteBufIndex = 0;

  static final sprite0 = List<bool>.filled(32, false); // x of sprite 0

  static int max = 0;

  _fetchSat() {
    final addr = reg[5] << 9 & 0xfc00;
    for (int i = 0; i < sprites.length; i++) {
      final base = addr + i * 8;
      sprites[i] = Sprite.of(
          vram.getUInt16BE(base.mask16),
          vram.getUInt16BE((base + 2).mask16),
          vram.getUInt16BE((base + 4).mask16),
          vram.getUInt16BE((base + 6).mask16));
    }
  }

  _fillSpriteBuffer() {
    spriteBufIndex = 0;
    final y = vCounter + 128;

    for (final sp in sprites) {
      if (sp.y <= y && y < sp.y + sp.height) {
        if (spriteBufIndex == 20) {
          break;
        }
        spriteBuf[spriteBufIndex++] = sp;
        sp.fetchedX2 = -1;
      }
    }
  }

  PriorityColor spriteColor() {
    for (int i = 0; i < spriteBufIndex; i++) {
      final sp = spriteBuf[i];
      final hh = hCounter + 128 - sp.x;

      if (0 <= hh && hh < sp.width) {
        final flippedX = sp.hFlip ? sp.width - hh - 1 : hh;
        final x = flippedX & 0x07;
        final x2 = flippedX >> 3;

        final vv = vCounter + 128 - sp.y;
        final flippedY = sp.vFlip ? sp.height - vv - 1 : vv;
        final y = flippedY & 0x07;
        final y2 = flippedY >> 3;

        // fetch pattern data if x2 is changed
        if (x2 != sp.fetchedX2) {
          sp.fetchedX2 = x2;

          final addr = sp.patternAddr + ((x2 * sp.vCells + y2) << 5) + (y << 2);
          sp.pattern = vram.getUInt32BE(addr);
        }

        final shift = 7 - x;
        final colorNo = (sp.pattern >> (shift << 2)) & 0x0f;

        if (colorNo > 0) {
          return PriorityColor(sp.paletteNo | colorNo, isPrior: sp.priority);
        }
      }
    }

    return const PriorityColor(0, isPrior: false);
  }

  _setBgSize() {
    vShift = [5, 6, 7, 7][reg[16] & 0x03];
    hMask = (1 << vShift) - 1;
    hScrMask = (1 << (vShift + 3)) - 1;

    vMask = [0x1f, 0x3f, 0x7f, 0x7f][reg[16] >> 4 & 0x03];
    vScrMask = vMask << 3 | 0x07;
  }

  int _windowColor(_BgPattern ctx) {
    final h = hCounter;
    final v = y;

    if (hCounter == 0 || h & 0x07 == 0) {
      // fetch pattern
      final name = ctx.nameAddrBase |
          (width == 256
              ? (h >> 3 & 0x1f) << 1 | (v >> 3) << 6
              : (h >> 3 & 0x3f) << 1 | (v >> 3) << 7);

      final d0 = vram[name];
      final d1 = vram[name.inc];

      ctx.prior = d0.bit7;
      ctx.palette = d0 >> 1 & 0x30;
      ctx.vFlip = d0.bit4;
      ctx.hFlip = d0.bit3;

      final offset = (ctx.vFlip ? 7 - (v & 0x07) : (v & 0x07)) << 2;
      final addr = (d0 << 8 & 0x07 | d1) << 5 | offset;

      ctx.pattern = vram.getUInt32BE(addr);
    }

    final shift = ctx.hFlip ? (h & 0x07) : 7 - (h & 0x07);
    return ctx.palette | (ctx.pattern >> (shift << 2)) & 0x0f;
  }

  int _bgColor(_BgPattern ctx) {
    final h = (hCounter + ctx.hScroll) & hScrMask;
    final v = (y + ctx.vScroll) & vScrMask;

    if (hCounter == 0 || h & 0x07 == 0) {
      // fetch pattern
      final name =
          ctx.nameAddrBase | (h >> 3 & hMask) << 1 | (v >> 3) << (vShift + 1);

      final d0 = vram[name];
      final d1 = vram[name.inc];

      ctx.prior = d0.bit7;
      ctx.palette = d0 >> 1 & 0x30;
      ctx.vFlip = d0.bit4;
      ctx.hFlip = d0.bit3;

      final offset = (ctx.vFlip ? 7 - (v & 0x07) : (v & 0x07)) << 2;
      final addr = (d0 << 8 & 0x07 | d1) << 5 | offset;

      ctx.pattern = vram.getUInt32BE(addr);
    }

    final shift = ctx.hFlip ? (h & 0x07) : 7 - (h & 0x07);
    return ctx.palette | (ctx.pattern >> (shift << 2)) & 0x0f;
  }

  // true: require rendering+hsync, false: retrace
  bool renderLine() {
    vCounter++;

    if (vCounter == Vdp.height + Vdp.retrace) {
      vCounter = 0;
      _fetchSat();
    }

    status &= ~0x84; // end hsync, off: vsync int occureed

    y = vCounter - Vdp.retrace ~/ 2;

    _setBgSize();
    _fillSpriteBuffer();

    final requireRender = 0 <= y && y < Vdp.height;

    if (requireRender) {
      final hScrollBase = reg[13] << 10 & 0xfc00;
      final isHFullScroll = !reg[11].bit1;
      final isHLineScroll = reg[11].bit0;
      final hScrollAddr = hScrollBase +
          (isHFullScroll
              ? 0
              : isHLineScroll
                  ? (y >> 3 << 1)
                  : (y << 1));

      final isVFullScroll = !reg[11].bit3;
      final vScrollAddr = isVFullScroll ? 0 : y >> 3;

      final ctx0 = _BgPattern(
          0, //
          reg[2] << 10 & 0xe000,
          vram[hScrollAddr] << 8 & 0x300 | vram[hScrollAddr.inc],
          vsram[vScrollAddr] & 0x3ff);
      final ctx1 = _BgPattern(
          1, //
          reg[4] << 13 & 0xe000,
          vram[hScrollAddr.inc2] << 8 & 0x300 | vram[hScrollAddr.inc3],
          vsram[vScrollAddr + 1] & 0x3ff);

      final ctxWindow = _BgPattern(
          2, // window
          reg[3] << 10 & 0xf800,
          0,
          0);
      final windowH = reg[0x11].bit7
          ? [0, reg[0x11] << 4 & 0x1f0]
          : [reg[0x11] << 4 & 0x1f0, width];

      final windowV = reg[0x12].bit7
          ? [0, reg[0x12] << 3 & 0xf8]
          : [reg[0x12] << 3 & 0x1f0, Vdp.height];

      for (hCounter = 0; hCounter < width; hCounter++) {
        final spColor = spriteColor();
        final bg0 = _bgColor(ctx0);
        final bg1 = _bgColor(ctx1);
        int window = _windowColor(ctxWindow);

        int color = 0;
        int bg = reg[7] & 0x3f;

        if (spColor.color != 0) {
          if (spColor.isPrior) {
            color = spColor.color;
          } else {
            bg = spColor.color;
          }
        } else {
          final inWindow = (windowH[0] <= hCounter &&
              hCounter < windowH[1] &&
              windowV[0] <= y &&
              y < windowV[1]);
          color = inWindow ? bg0 : window;

          if (color == 0) {
            color = bg1;
          }
        }

        if (color == 0) {
          color = bg;
        }

        buffer[y * 320 + hCounter] = rgba[cram[color]];
      }

      status &= ~0x08; // off: vblank
      return true;
    }

    if (y == Vdp.height && enableVInt) {
      status |= 0x80; // on: vsync int occureed
      bus.interrupt(6);
    }

    status |= 0x08; // on: vblank
    return false;
  }

  void startHsync() {
    // print("status:${status.hex8} enableHInt:$enableHInt");
    if (!status.bit3 && enableHInt) {
      hSyncCounter--;

      if (hSyncCounter <= 0) {
        hSyncCounter = reg[10];
        status |= 0x04; // start hsync
        bus.interrupt(4);
      }
    }
  }
}
