import 'package:fnesemu/core/md/m68/op_alu.dart';
import 'package:fnesemu/util/int.dart';

import 'm68.dart';

extension OpC on M68 {
  bool execC(int op) {
    final ry = op & 0x07;
    final rx = op >> 9 & 0x07;
    // abcd
    if (op & 0x01f0 == 0x0100) {
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

    return false;
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

    final a = readAddr(size, mode, reg);
    final b = data == 0 ? 8 : data;

    final r = op.bit8 ? sub(a, b, size) : add(a, b, size);

    writeAddr(size, mode, reg, r);
    return true;
  }

  bool execD(int op) {
    final ry = op & 0x07;
    final rx = op >> 9 & 0x07;
    final s0 = op >> 6 & 0x03;
    final size = size0[s0];
    // adda
    if (s0 == 0x03) {
      return true;
    }

    // addx
    if (op & 0x130 == 0x100) {
      return true;
    }

    // add
    final mode = op >> 3 & 0x07;
    final directionEa = op.bit8;

    int a = d[rx].mask(size);
    int b = readAddr(size, mode, ry);
    print("mod:$mode, reg:$ry addr:${addr0.mask24.hex24}");

    final r = add(a, b, size);

    if (directionEa) {
      write(addr0, size, r);
    } else {
      d[rx] = d[rx].setL(r, size);
    }

    return true;
  }
}
