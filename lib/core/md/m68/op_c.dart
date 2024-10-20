import 'package:fnesemu/core/md/m68/op_alu.dart';
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

    if (op & 0x00c0 == 0x00c0) {
      // mulu, muls
      return false;
    }

    if (op & 0x0130 == 0x0100) {
      // exg
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

  bool exec8(int op) {
    final ry = op & 0x07;
    final rx = op >> 9 & 0x07;

    if (op & 0x00c0 == 0x00c0) {
      // divu, divs
      return false;
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
      debug(
          "sbcd r:${r.mask16.hex16} r1:${high.mask16..hex16} rx:$rx ry:$ry src:${src.hex8} dst:${dst.hex8} xf:$xf");

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

  bool execB(int op) {
    final ry = op & 0x07;
    final rx = op >> 9 & 0x07;

    if (op & 0x00c0 == 0x00c0) {
      //cmpa
      return false;
    }

    if (op & 0x0100 == 0x0000) {
      // cmp
      return false;
    }

    if (op & 0x0138 == 0x0108) {
      // cmpm
      return false;
    }

    // eor
    final size = size0[op >> 6 & 0x03];
    final mode = op >> 3 & 0x07;

    int aa = d[rx].mask(size);
    int b = readAddr(size, mode, ry);

    final r = eor(aa, b, size);

    writeAddr(size, mode, ry, r);

    return true;
  }

  bool exec5(int op) {
    if (op & 0x00c0 == 0x00c0) {
      // scc, brcc
      return true;
    }

    // addq, subq
    final reg = op & 0x07;
    final data = op >> 9 & 0x07;
    final size = size0[op >> 6 & 0x03];
    final mode = op >> 3 & 0x07;

    final b = data == 0 ? 8 : data;

    if (mode == 1) {
      clocks += size == 4 ? 2 : 4;
      final r = op.bit8 ? a[reg] - b : a[reg] + b;
      a[reg] = r.mask32;
    } else {
      debug("clock:$clocks size:$size mod:$mode reg:$reg addr:${addr0.hex24}");
      final a = readAddr(size, mode, reg);
      final r = op.bit8 ? sub(a, b, size) : add(a, b, size);
      if (size == 4) {
        clocks += (mode == 0 || mode == 1) ? 4 : 0;
      } else {
        clocks += (mode == 1) ? 4 : 0;
      }

      writeAddr(size, mode, reg, r);
    }
    return true;
  }

  bool execD(int op) {
    final xn = op & 0x07;
    final dn = op >> 9 & 0x07;
    final s0 = op >> 6 & 0x03;
    final mode = op >> 3 & 0x07;

    // adda
    if (s0 == 0x03) {
      final size = op.bit8 ? 4 : 2;

      final aa = readAddr(size, mode, xn);
      debug(
          "size:$size mod:$mode reg:$xn addr:${addr0.mask24.hex24} aa:$aa clock:$clocks");

      final r = a[dn] + aa.smask(size);
      clocks +=
          (size == 2 || mode == 0 || mode == 1 || mode == 7 && xn == 4) ? 4 : 2;

      a[dn] = r.mask32;
      return true;
    }

    // addx
    if (op & 0x130 == 0x100) {
      final size = size0[s0];

      if (op.bit3) {
        int a, b = 0;
        if (size == 4) {
          b = read16(preDec(xn, 2));
          b |= read16(preDec(xn, 2)) << 16;
          a = read16(preDec(dn, 2));
          addr0 = preDec(dn, 2);
          a |= read16(addr0) << 16;
        } else {
          b = read(preDec(xn, size), size);
          addr0 = preDec(dn, size);
          a = read(addr0, size);
        }

        final r = addx(a, b, size);
        write(addr0, size, r);
      } else {
        final r = addx(d[xn].mask(size), d[dn].mask(size), size);
        if (size == 4) {
          clocks += 4;
        }
        d[dn] = d[dn].setL(r, size);
      }

      return true;
    }

    // add
    final size = size0[s0];
    final directionEa = op.bit8;

    int aa = d[dn].mask(size);
    int b = readAddr(size, mode, xn);

    final r = add(aa, b, size);

    if (directionEa) {
      write(addr0, size, r);
    } else {
      if (size == 4) {
        clocks += (mode == 0 || mode == 1 || mode == 7 && xn == 4) ? 4 : 2;
      }
      d[dn] = d[dn].setL(r, size);
    }

    return true;
  }
}
