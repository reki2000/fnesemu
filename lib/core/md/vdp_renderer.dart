import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

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

extension VdpRenderer on Vdp {
  static int vShift = 0;
  static int hMask = 0;
  static int hScrMask = 0;
  static int vMask = 0;
  static int vScrMask = 0;

  _setBgSize() {
    vShift = [5, 6, 7, 7][reg[16] & 0x03];
    hMask = (1 << vShift) - 1;
    hScrMask = (1 << (vShift + 3)) - 1;

    vMask = [0x1f, 0x3f, 0x7f, 0x7f][reg[16] >> 4 & 0x03];
    vScrMask = vMask << 3 | 0x07;
  }

  int spriteColor() {
    return 0;
  }

  static int y = 0;

  int _bgColor(_BgPattern ctx) {
    final h = (hCounter + ctx.hScroll) % width;
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

      ctx.pattern = vram[addr] << 24 |
          vram[addr.inc] << 16 |
          vram[addr.inc2] << 8 |
          vram[addr.inc3];

      // if (y & 7 == 0 && hCounter == 8) {
      //   print("y:$y addr:${addr.hex16} pattern:${ctx.pattern.hex32}");
      // }
    }

    final shift = ctx.hFlip ? (h & 0x07) : 7 - (h & 0x07);
    return ctx.palette | (ctx.pattern >> (shift << 2)) & 0x0f;
  }

  // true: require rendering+hsync, false: retrace
  bool renderLine() {
    vCounter++;

    if (vCounter == Vdp.height + Vdp.retrace) {
      vCounter = 0;
    }

    status &= ~0x84; // end hsync, off: vsync int occureed

    y = vCounter - Vdp.retrace ~/ 2;

    _setBgSize();

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
          vram[hScrollAddr] << 8 | vram[hScrollAddr.inc],
          vsram[vScrollAddr]);
      final ctx1 = _BgPattern(
          1, //
          reg[4] << 13 & 0xe000,
          vram[hScrollAddr.inc2] << 8 | vram[hScrollAddr.inc3],
          vsram[vScrollAddr + 1]);

      for (hCounter = 0; hCounter < width; hCounter++) {
        int color = spriteColor();
        int bg0 = _bgColor(ctx0);
        int bg1 = _bgColor(ctx1);
        color = color != 0
            ? color
            : (bg0 != 0 ? bg0 : (bg1 != 0 ? bg1 : reg[7] & 0x3f));

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
