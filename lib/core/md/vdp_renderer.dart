import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';

import 'vdp.dart';

// preliminary building an RGBA color map for all 512 colors
const _map3to8 = [0x00, 0x24, 0x49, 0x6d, 0x92, 0xb6, 0xdb, 0xff]; //

final Uint32List rgba = Uint32List.fromList(
  List.generate(512, (i) {
    final b = _map3to8[i & 0x07];
    final r = _map3to8[(i >> 3) & 0x07];
    final g = _map3to8[(i >> 6) & 0x07];
    return 0xff000000 | (b << 16) | (g << 8) | r;
  }, growable: false),
);

class _BgContext {
  int base = 0;
  int pattern = 0;
  bool prior = false;
  bool hFlip = false;
  bool vFlip = false;
  int palette = 0;

  _BgContext(this.base);
}

extension VdpRenderer on Vdp {
  static int vShift = 0;
  static int hMask = 0;
  static int vMask = 0;

  _setBgSize() {
    final hsz = reg[0x10] & 0x03;
    vShift = hsz == 0
        ? 5
        : hsz == 1
            ? 6
            : 7;
    hMask = hsz == 0
        ? 0x1f
        : hsz == 1
            ? 0x3f
            : 0x7f;

    final vsz = reg[0x10] >> 4 & 0x03;
    vMask = vsz == 0
        ? 0x1f
        : vsz == 1
            ? 0x3f
            : 0x7f;
  }

  int spriteColor() {
    return 0;
  }

  int _bgColor(_BgContext ctx) {
    final h = hCounter;
    final v = vCounter;

    final shift = ctx.hFlip ? (h & 0x07) : 7 - (h & 0x07);
    final offset = ctx.vFlip ? 7 - (v & 0x07) : (v & 0x07);

    if (hCounter == 0 || h & 0x0f == 0) {
      // fetch pattern
      final name = ctx.base | h >> 3 & hMask | v << vShift;

      final d0 = vram[name];
      final d1 = vram[name.inc];

      ctx.prior = d0.bit7;
      ctx.hFlip = d0.bit3;
      ctx.vFlip = d0.bit4;
      ctx.palette = d0 >> 5 & 0x03;

      final addr = (d0 << 8 & 0x07 | d1) << 5 | offset;

      ctx.pattern = vram[addr] << 24 |
          vram[addr.inc] << 16 |
          vram[addr.inc2] << 8 |
          vram[addr.inc3];
    }

    return ctx.pattern >> (shift << 2) & 0x0f;
  }

  void renderLine() {
    final y = vCounter;
    final ctx0 = _BgContext(reg[2] << 10 & 0xe000);
    final ctx1 = _BgContext(reg[3] << 13 & 0xe000);

    _setBgSize();

    for (hCounter = 0; hCounter < 256; hCounter++) {
      int color = spriteColor();
      color = (color == 0) ? _bgColor(ctx0) : color;
      color = (color == 0) ? _bgColor(ctx1) : color;

      buffer[vCounter * 256 + hCounter] = rgba[cram[color]];
    }

    vCounter++;

    if (vCounter == 240) {
      // render frame
      vCounter = 0;
    }
  }
}
