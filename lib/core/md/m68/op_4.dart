import 'package:fnesemu/util/int.dart';

import 'm68.dart';

extension Op4 on M68 {
  bool exec4(int op) {
    final xn = op & 0x07;
    final dn = op >> 9 & 0x07;

    if (op & 0xb80 == 0x88) {
      // movem
      return false;
    }

    if (op & 0x01c0 == 0x01c0) {
      // lea
      final addr = addressing(4, op >> 3 & 0x07, xn);
      a[dn] = addr.mask32;
      return true;
    }

    if (op & 0x01c0 == 0x0180) {
      // chk
      final mode = op >> 3 & 0x07;
      final bound = readAddr(2, mode, xn).rel16;
      final data = d[dn].mask16.rel16;
      zf = vf = cf = false;
      nf = (data < 0)
          ? true
          : (data > bound)
              ? false
              : nf;
      debug(
          "chk dn:$dn xn:$xn mode:$mode bound:${bound.hex16} data:${data.hex16}");
      if (data < 0 || bound < data) {
        trap(0x18);
      }

      return true;
    }

    final size = size0[op >> 6 & 0x03];
    final mod = op >> 3 & 0x07;
    final reg = op & 0x07;

    switch (op >> 8 & 0x0f) {
      case 0x02:
        // clr
        readAddr(size, mod, reg); // to set addr0
        writeAddr(size, mod, reg, 0);
        nf = cf = vf = false;
        zf = true;
        return true;

      case 0x08:
        if (op & 0xb8 == 0x80) {
          // ext
          final size0 = op.bit6 ? 2 : 1;
          final size = op.bit6 ? 4 : 2;
          final data = readAddr(size0, mod, reg).rel(size0).mask32;
          writeAddr(size, mod, reg, data);
          nf = data.msb(size);
          zf = data.mask(size) == 0;
          vf = cf = false;

          return true;
        }

        return false;

      case 0x0e:
        switch (op & 0xff) {
          case 0x70: // reset
            return false;
          case 0x71: // nop
            return true;
          case 0x72: // stop
            return false;
          case 0x73: // rte
            return false;
          case 0x75: // rts
            return false;
          case 0x76: // trapv
            return false;
          case 0x77: // rtr
            return false;
        }

        if (op & 0xc0 == 0x80) {
          // jsr
          final addr = addressing(4, mod, reg);
          final pc0 = pc;
          pc = addr;
          push32(pc0);
          return true;
        }

        if (op & 0xc0 == 0xc0) {
          // jmp
          final addr = addressing(4, mod, reg);
          pc = addr;
          return true;
        }

        if (op & 0xf0 == 0x40) {
          // trap
          return false;
        }

        if (op & 0xf0 == 0x60) {
          // move usp
          return false;
        }

        if (op & 0xf8 == 0x50) {
          // link
          final sp = (reg == 7) ? a[7].dec4.mask32 : a[reg];
          push32(sp);
          a[reg] = a[7];
          a[7] = (a[7] + immed(2).rel16).mask32;
          return true;
        }

        if (op & 0xf8 == 0x58) {
          // unlk
          a[7] = a[reg];
          a[reg] = pop32();
          return true;
        }

        return false;

      default:
        return false;
    }
  }
}
