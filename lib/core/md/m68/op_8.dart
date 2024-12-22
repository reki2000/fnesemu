import 'package:fnesemu/core/md/m68/alu.dart';
import 'package:fnesemu/util/int.dart';

import 'm68.dart';

extension Op8 on M68 {
  bool exec8(int op) {
    final ry = op & 0x07;
    final rx = op >> 9 & 0x07;

    if (op & 0x01c0 == 0x01c0) {
      // divs
      final mode = op >> 3 & 0x07;
      final src = readAddr(2, mode, ry).rel16;
      final dst = d[rx].rel32;

      if (src == 0) {
        cf = vf = nf = zf = false;
        pc = pc.dec4.mask32;
        trap(0x14);
        return true;
      }

      final q = dst ~/ src;
      final r = dst - src * q;

      // debug(
      //     "divs src:${src.hex32} $src dst:${dst.hex32} $dst q:${q.hex32} $q r:${r.hex32} $r ${q * src + r}");

      cf = false;
      vf = (q < -0x8000 || 0x8000 <= q);

      if (!vf) {
        zf = q == 0;
        nf = q.bit15;
        d[rx] = r.mask16 << 16 | q.mask16;
      }

      return true;
    }

    if (op & 0x01c0 == 0x00c0) {
      // divu
      final mode = op >> 3 & 0x07;
      final src = readAddr(2, mode, ry);
      final dst = d[rx];

      if (src == 0) {
        cf = vf = nf = zf = false;
        pc = pc.dec4.mask32;
        trap(0x14);
        return true;
      }

      final q = dst ~/ src;
      final r = dst - src * q;

      // debug(
      //     "divu src:${src.hex32} $src dst:${dst.hex32} $dst q:${q.hex32} $q r:${r.hex32} $r ${q * src + r}");

      cf = false;
      vf = q >= 0x10000;

      if (!vf) {
        zf = q == 0;
        nf = q.bit15;
        d[rx] = r.mask16 << 16 | q.mask16;
      }

      return true;
    }

    if (op & 0x01f0 == 0x0100) {
      // sbcd rx(dst) - ry(src) - xf --> rx(dst)
      final cl = clocks;
      final mode = op.bit3;
      final src = mode ? read8(preDec(ry, 1)) : d[ry].mask8;
      final dst = mode ? read8(preDec(rx, 1)) : d[rx].mask8;

      final diff = dst - src - (xf ? 1 : 0);
      final high = (dst & 0xf0) - (src & 0xf0) - (0x60 & (diff >> 4));
      final low = (dst & 0x0f) - (src & 0x0f) - (xf ? 1 : 0);
      final lowBorrow = 0x06 & (low >> 4); // 0x06 if low < 0x0a else 0x00
      final r = low + high - lowBorrow;

      xf = cf = (diff - lowBorrow) & 0x300 != 0;
      zf = zf && r.mask8 == 0;
      nf = r.bit7;
      vf = diff & ~r & 0x80 != 0;
      // debug(
      //     "sbcd r:${r.mask16.hex16} r1:${high.mask16..hex16} rx:$rx ry:$ry src:${src.hex8} dst:${dst.hex8} xf:$xf");

      if (mode) {
        write8(a[rx], r);
        clocks = cl + 14;
      } else {
        d[rx] = d[rx].setL8(r);
        clocks = cl + 2;
      }

      return true;
    }

    // or
    final size = size0[op >> 6 & 0x03];
    final mode = op >> 3 & 0x07;
    final directionEa = op.bit8;

    int aa = d[rx].mask(size);
    int b = readAddr(size, mode, ry);

    final r = or(aa, b, size);

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
