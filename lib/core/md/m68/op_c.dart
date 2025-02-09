import 'package:fnesemu/core/md/m68/alu.dart';
import 'package:fnesemu/util/int.dart';

import 'm68.dart';

extension OpC on M68 {
  bool execC(int op) {
    final ry = op & 0x07;
    final rx = op >> 9 & 0x07;

    if (op & 0x01f0 == 0x0100) {
      // abcd
      final cl = clocks;
      final mode = op.bit3;
      final src = mode ? read8(preDec(ry, 1)) : d[ry].mask8;
      final dst = mode ? read8(preDec(rx, 1)) : d[rx].mask8;

      final low = (src & 0x0f) + (dst & 0x0f) + (xf ? 1 : 0);
      final r1 = (src & 0xf0) + (dst & 0xf0) + low;
      int r = r1 + ((low > 0x09) ? 0x06 : 0);
      r += (r > 0x9f) ? 0x60 : 0;
      zf = zf && r.mask8 == 0;
      xf = cf = r & 0x300 != 0;
      nf = r.bit7;
      vf = ~r1 & r & 0x80 != 0;

      if (mode) {
        write8(a[rx], r);
        clocks = cl + 14;
      } else {
        d[rx] = d[rx].setL8(r);
        clocks = cl + 2;
      }

      return true;
    }

    if (op & 0x01c0 == 0x00c0) {
      // mulu
      final mode = op >> 3 & 0x07;
      final src = readAddr(2, mode, ry);
      final val = d[rx].mask16 * src;
      d[rx] = val.mask32;
      zf = val.mask32 == 0;
      cf = false;
      nf = val.bit31;
      vf = false;

      return true;
    }

    if (op & 0x01c0 == 0x01c0) {
      // muls
      final mode = op >> 3 & 0x07;
      final src = readAddr(2, mode, ry).rel16;
      final val = d[rx].mask16.rel16 * src;
      d[rx] = val.mask32;
      zf = val.mask32 == 0;
      cf = false;
      nf = val.bit31;
      vf = false;
      return true;
    }

    if (op & 0x0130 == 0x0100) {
      // exg
      final rx = op >> 9 & 0x07;
      final ry = op & 0x07;
      switch (op >> 3 & 0x1f) {
        case 0x08: // dx - dx
          final r = d[rx];
          d[rx] = d[ry];
          d[ry] = r;
          return true;
        case 0x09: // ax - ax
          final r = a[rx];
          a[rx] = a[ry];
          a[ry] = r;
          return true;
        case 0x11: // ax - dx
          final r = a[ry];
          a[ry] = d[rx];
          d[rx] = r;
          return true;
      }

      return false;
    }

    // and
    final size = size0[op >> 6 & 0x03];
    final directionEa = op.bit8;
    final mode = op >> 3 & 0x07;

    int aa = d[rx].mask(size);
    int b = readAddr(size, mode, ry);

    final r = and(aa, b, size);

    if (directionEa) {
      write(addr0, size, r);
    } else {
      if (size == 4) {
        clocks += (mode == 0 || mode == 1 || mode == 7 && ry == 4) ? 4 : 2;
      }
      d[rx] = d[rx].setL(r, size);
    }

    return true;
  }
}
