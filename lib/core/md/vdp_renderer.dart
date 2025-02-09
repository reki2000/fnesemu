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

class _Tile {
  int no = 0;
  int nameAddrBase = 0;
  int hScroll = 0;
  int vLow = 0;
  int vHigh = 0;
  int pattern = 0; // 32 bit c3c2c1c0 * 8
  bool prior = false;
  bool hFlip = false;
  bool vFlip = false;
  int palette = 0; // pp0000

  int fetchedHHigh = -1;

  _Tile(this.no, this.nameAddrBase, this.hScroll, int v)
      : vLow = v & 0x07,
        vHigh = v >> 3;
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

  bool get isVisible => color & 0x0f != 0;

  const PriorityColor(this.color, {this.isDirect = false, this.isPrior = true});
}

extension VdpRenderer on Vdp {
  static int vShift = 0;
  static int hMask = 0;
  static int hScrMask = 0;
  static int vMask = 0;
  static int vScrMask = 0;

  static int y = 0;

  static final spriteBuf =
      List<Sprite>.filled(20, Sprite.of(0, 0, 0, 0), growable: false);
  static int spriteBufIndex = 0;

  static final sprite0 = List<bool>.filled(32, false); // x of sprite 0

  static int max = 0;

  List<String> debugSpriteInfo() {
    final baseAddr = reg[5] << 9 & 0xfc00;
    final result = List.generate(80, (i) {
      final base = baseAddr + i * 8;
      final sp = Sprite.of(
          vram.getUInt16BE(base.mask16),
          vram.getUInt16BE((base + 2).mask16),
          vram.getUInt16BE((base + 4).mask16),
          vram.getUInt16BE((base + 6).mask16));
      final no = "${i.toString().padLeft(2)}->${sp.next.toString().padLeft(2)}";
      final flags =
          "${sp.vFlip ? "v" : "-"}${sp.hFlip ? "h" : "-"}${sp.priority ? "p" : "-"}";
      final xy = "${sp.x.toString().padLeft(3)},${sp.y.toString().padLeft(3)}";
      return "#$no $xy ${sp.patternAddr.hex16} $flags ${sp.width.toString().padLeft(2)}x${sp.height.toString().padLeft(2)} ";
    });
    return result;
  }

  _fillSpriteBuffer() {
    final baseAddr = reg[5] << 9 & 0xfc00;
    int spriteNo = 0;
    spriteBufIndex = 0;

    for (int i = 0; i < 80; i++) {
      final base = baseAddr + spriteNo * 8;
      final sp = Sprite.of(
          vram.getUInt16BE(base.mask16),
          vram.getUInt16BE((base + 2).mask16),
          vram.getUInt16BE((base + 4).mask16),
          vram.getUInt16BE((base + 6).mask16));

      if (sp.y - 128 <= y && y < sp.y + sp.height - 128) {
        spriteBuf[spriteBufIndex++] = sp;
        sp.fetchedX2 = -1;

        if (spriteBufIndex == 20) {
          break;
        }
      }

      if (sp.next == 0) {
        break;
      }

      spriteNo = sp.next;
    }
  }

  PriorityColor _spriteColor() {
    for (int i = 0; i < spriteBufIndex; i++) {
      final sp = spriteBuf[i];
      final hh = hCounter + 128 - sp.x;

      if (0 <= hh && hh < sp.width) {
        final flippedX = sp.hFlip ? sp.width - hh - 1 : hh;
        final x1 = flippedX & 0x07;
        final x2 = flippedX >> 3;

        final vv = y + 128 - sp.y;
        final flippedY = sp.vFlip ? sp.height - vv - 1 : vv;
        final y1 = flippedY & 0x07;
        final y2 = flippedY >> 3;

        // fetch pattern data if x2 is changed
        if (x2 != sp.fetchedX2) {
          sp.fetchedX2 = x2;

          final addr =
              sp.patternAddr + ((x2 * sp.vCells + y2) << 5) + (y1 << 2);
          sp.pattern = vram.getUInt32BE(addr.mask16);
        }

        final shift = 7 - x1;
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

  PriorityColor _windowColor(_Tile ctx) {
    final v = y;
    final hLow = hCounter & 0x07;
    final hHigh = hCounter >> 3;

    if (hHigh != ctx.fetchedHHigh) {
      ctx.fetchedHHigh = hHigh;
      // fetch pattern
      final name = ctx.nameAddrBase |
          (width == 256
              ? (hHigh & 0x1f) << 1 | (v >> 3) << 6
              : (hHigh & 0x3f) << 1 | (v >> 3) << 7);

      final d0 = vram[name];
      final d1 = vram[name.inc];

      ctx.prior = d0.bit7;
      ctx.palette = d0 >> 1 & 0x30;
      ctx.vFlip = d0.bit4;
      ctx.hFlip = d0.bit3;

      final offset = (ctx.vFlip ? 7 - (v & 0x07) : (v & 0x07)) << 2;
      final addr = (d0 << 8 & 0x0700 | d1) << 5 | offset;

      ctx.pattern = vram.getUInt32BE(addr);
    }

    final shift = ctx.hFlip ? hLow : 7 - hLow;
    return PriorityColor(ctx.palette | (ctx.pattern >> (shift << 2)) & 0x0f,
        isPrior: ctx.prior);
  }

  PriorityColor _planeColor(_Tile ctx) {
    final h = (hCounter - ctx.hScroll) & hScrMask;
    final hLow = h & 0x07;
    final hHigh = h >> 3;

    if (hHigh != ctx.fetchedHHigh) {
      ctx.fetchedHHigh = hHigh;
      // fetch pattern
      final name =
          ctx.nameAddrBase | (hHigh & hMask) << 1 | ctx.vHigh << (vShift + 1);

      final d0 = vram[name];
      final d1 = vram[name.inc];

      ctx.prior = d0.bit7;
      ctx.palette = d0 >> 1 & 0x30;
      ctx.vFlip = d0.bit4;
      ctx.hFlip = d0.bit3;

      final offset = (ctx.vFlip ? 7 - ctx.vLow : ctx.vLow) << 2;
      final addr = (d0 << 8 & 0x0700 | d1) << 5 | offset;

      ctx.pattern = vram.getUInt32BE(addr);
    }

    final shift = ctx.hFlip ? hLow : 7 - hLow;
    return PriorityColor(ctx.palette | (ctx.pattern >> (shift << 2)) & 0x0f,
        isPrior: ctx.prior);
  }

  // true: require rendering+hsync, false: retrace
  bool renderLine() {
    vCounter++;

    if (vCounter == Vdp.height + Vdp.retrace) {
      vCounter = 0;
    }

    status &= ~(Vdp.bitHBlank | Vdp.bitVBlank);

    y = vCounter - Vdp.retrace ~/ 2;

    _setBgSize();
    _fillSpriteBuffer();

    final requireRender = 0 <= y && y < Vdp.height;

    if (isDmaRunning) {
      execDma(requireRender ? 9 : 102);
    }

    if (requireRender) {
      final hScrollBase = reg[13] << 10 & 0xfc00;
      final isHScrollFull = !reg[11].bit1;
      final isHScrollLine = reg[11].bit0;
      final hScrollAddr = hScrollBase +
          (isHScrollFull
              ? 0
              : isHScrollLine
                  ? (y << 2)
                  : ((y & ~0x07) << 2));

      final isVFullScroll = !reg[11].bit3;
      final vScrollAddr = isVFullScroll ? 0 : y >> 3;

      final ctxA = _Tile(
          0, //
          reg[2] << 10 & 0xe000,
          vram[hScrollAddr] << 8 & 0x300 | vram[hScrollAddr.inc],
          (y + vsram[vScrollAddr] & 0x3ff) & vScrMask);

      final ctxB = _Tile(
          1, //
          reg[4] << 13 & 0xe000,
          vram[hScrollAddr.inc2] << 8 & 0x300 | vram[hScrollAddr.inc3],
          (y + vsram[vScrollAddr.inc] & 0x3ff) & vScrMask);

      final ctxWindow = _Tile(
          2, // window
          reg[3] << 10 & 0xf800,
          0,
          0);

      final windowH = reg[0x11].bit7
          ? [0, reg[0x11] << 4 & 0x1f0]
          : [reg[0x11] << 4 & 0x1f0, width];

      final windowV = reg[0x12].bit7
          ? [0, reg[0x12] << 3 & 0xf8]
          : [reg[0x12] << 3 & 0xf8, Vdp.height];

      final vInWindow = windowV[0] <= y && y < windowV[1];
      final bufferOffset = y * width;
      final bg = reg[7] & 0x3f;

      for (hCounter = 0; hCounter < width; hCounter++) {
        int color;

        final sprite = _spriteColor();
        if (sprite.isPrior && sprite.isVisible) {
          color = sprite.color;
        } else {
          final inWindow =
              windowH[0] <= hCounter && hCounter < windowH[1] && vInWindow;
          final planeAW =
              inWindow ? _planeColor(ctxA) : _windowColor(ctxWindow);
          if (planeAW.isPrior && planeAW.isVisible) {
            color = planeAW.color;
          } else {
            final planeB = _planeColor(ctxB);

            color = (planeB.isPrior && planeB.isVisible)
                ? planeB.color
                : sprite.isVisible
                    ? sprite.color
                    : planeAW.isVisible
                        ? planeAW.color
                        : planeB.isVisible
                            ? planeB.color
                            : bg;
          }
        }

        buffer[bufferOffset + hCounter] = rgba[cram[color]];
      }

      status &= ~Vdp.bitVBlank; // off: vblank
      return true;
    }

    if (y == Vdp.height && enableVInt) {
      status |= Vdp.bitVblankInt; // on: vsync int occureed
      bus.interrupt(6);
      busZ80.assertInt();
    }

    if (y == -1) {
      busZ80.deassertInt();
    }

    status |= Vdp.bitVBlank; // on: vblank
    return false;
  }

  void startHsync() {
    // print("status:${status.hex8} enableHInt:$enableHInt");
    if (!status.bit3 && enableHInt) {
      hSyncCounter--;

      if (hSyncCounter <= 0) {
        hSyncCounter = reg[10];
        status |= Vdp.bitHBlank; // start hblank
        bus.interrupt(4);
      }
    }
  }
}
