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
  int nameAddrBase = 0;
  int pattern = 0; // 32 bit c3c2c1c0 * 8
  bool prior = false;
  bool hFlip = false;
  bool vFlip = false;
  int palette = 0; // pp0000

  _BgPattern(this.nameAddrBase);
}

extension VdpRenderer on Vdp {
  static int vShift = 0;
  static int hMask = 0;
  static int vMask = 0;

  _setBgSize() {
    final hsz = reg[16] & 0x03;
    vShift = hsz == 0
        ? 5
        : hsz == 1
            ? 6
            : 7;
    hMask = (1 << vShift) - 1;

    final vsz = reg[16] >> 4 & 0x03;
    vMask = vsz == 0
        ? 0x1f
        : vsz == 1
            ? 0x3f
            : 0x7f;
  }

  int spriteColor() {
    return 0;
  }

  static int y = 0;

  int _bgColor(_BgPattern ctx) {
    final h = hCounter;
    final v = y;

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

  // true: rendered, false: retrace
  bool renderLine() {
    vCounter++;

    if (vCounter == Vdp.height + Vdp.retrace) {
      vCounter = 0;
    }

    status &= ~0x04; // end hsync
    status &= ~0x80; // off: vsync int occureed

    y = vCounter - Vdp.retrace ~/ 2;
    final ctx0 = _BgPattern(reg[2] << 10 & 0xe000);
    final ctx1 = _BgPattern(reg[3] << 13 & 0xe000);

    _setBgSize();

    if (0 <= y && y < Vdp.height) {
      for (hCounter = 0; hCounter < width; hCounter++) {
        int color = spriteColor();
        color = (color == 0) ? _bgColor(ctx0) : color;
        color = (color == 0) ? _bgColor(ctx1) : color;
        color = (color == 0) ? reg[7] & 0x3f : color;

        buffer[y * 320 + hCounter] = rgba[cram[color]];
      }
      status &= ~0x08;
    } else {
      status |= 0x08;
    }

    if (y == Vdp.height && enableVInt) {
      status |= 0x80;
      bus.interrupt(6);
    }

    return status.bit3;
  }

  void startHsync() {
    // print("status:${status.hex8} enableHInt:$enableHInt");
    if (!status.bit3 && enableHInt) {
      status |= 0x04; // start hsync
      bus.interrupt(4);
    }
  }
}
