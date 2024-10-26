import 'package:fnesemu/core/md/m68/alu.dart';
import 'package:fnesemu/util/int.dart';

import 'm68.dart';

extension Op4 on M68 {
  bool exec4(int op) {
    final xn = op & 0x07;
    final dn = op >> 9 & 0x07;

    if (op & 0xb80 == 0x880 && (op >> 3 & 0x07) != 0) {
      // movem
      final memToReg = op.bit10;
      final mode = op >> 3 & 0x07;
      final size = op.bit6 ? 4 : 2;
      int regMask = pc16();
      addr0 = addressing(size, mode, xn);
      if (mode == 4) {
        a[xn] = (addr0 + size).mask32;
      }

      for (var i = 0; i < 16; i++, regMask >>= 1) {
        if (!regMask.bit0) {
          continue;
        }

        if (memToReg) {
          final val = read(addr0, size).rel(size).mask32;
          if (i < 8) {
            d[i] = val;
          } else {
            a[i - 8] = val;
          }
          addr0 = (addr0 + size).mask32;
          if (mode == 3) {
            a[xn] = addr0;
          }
        } else {
          if (mode == 4) {
            write(addr0, size, i < 8 ? a[7 - i] : d[15 - i]);
            addr0 = (addr0 - size).mask32;
          } else {
            write(addr0, size, i < 8 ? d[i] : a[i - 8]);
            addr0 = (addr0 + size).mask32;
          }
        }
      }

      if (mode == 4) {
        a[xn] = (addr0 + size).mask32;
      }

      return true;
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
      case 0x00:
        if (op & 0x00c0 == 0x00c0) {
          // movefromsr
          if (mod != 0 && mod != 1) {
            addr0 = addressing(2, mod, reg);
          }
          writeAddr(2, mod, reg, sr);
          if (mod == 3) {
            postInc(reg, 2);
          }
          return true;
        }

        // negx
        final src = readAddr(size, mod, reg);
        final r = sub(0, src, size, useXf: true);
        writeAddr(size, mod, reg, r);
        return true;

      case 0x02:
        // clr
        readAddr(size, mod, reg); // to set addr0
        writeAddr(size, mod, reg, 0);
        nf = cf = vf = false;
        zf = true;
        return true;

      case 0x04:
        if (op & 0x00c0 == 0x00c0) {
          // movetoccr
          sr = sr.setL8(readAddr(2, mod, reg));
          return true;
        }

        // neg
        final src = readAddr(size, mod, reg);
        final r = sub(0, src, size);
        writeAddr(size, mod, reg, r);
        return true;

      case 0x06:
        if (op & 0x00c0 == 0x00c0) {
          // movetosr
          sr = sr.setL16(readAddr(2, mod, reg));
          return true;
        }

        // not
        final src = readAddr(size, mod, reg);
        final r = not(src, size);
        writeAddr(size, mod, reg, r);
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

        if (op & 0xc0 == 0x00) {
          // nbcd
          final src = readAddr(1, mod, reg);

          final diff = 0 - src - (xf ? 1 : 0);
          final high = 0 - (src & 0xf0) - (0x60 & (diff >> 4));
          final low = 0 - (src & 0x0f) - (xf ? 1 : 0);
          final lowBorrow = 0x06 & (low >> 4); // 0x06 if low < 0x0a else 0x00
          final r = low + high - lowBorrow;

          xf = cf = (diff - lowBorrow) & 0x300 != 0;
          zf = zf && r.mask8 == 0;
          nf = r.bit7;
          vf = diff & ~r & 0x80 != 0;

          writeAddr(1, mod, reg, r);
          return true;
        }

        if (op & 0xf8 == 0x40) {
          // swap
          final tmp = d[reg];
          d[reg] = (tmp >> 16).mask16.setH16(tmp);
          nf = d[reg].msb(4);
          zf = d[reg].mask(4) == 0;
          vf = cf = false;

          return true;
        }

        // pea
        final addr = addressing(4, mod, reg);
        if (mod == 3) postInc(reg, 4);
        push32(addr);
        return true;

      case 0x0a:
        if (op & 0xc0 == 0xc0) {
          // tas
          final src = readAddr(1, mod, reg);
          nf = src.msb(1);
          zf = src.mask(1) == 0;
          vf = cf = false;
          writeAddr(1, mod, reg, src | 0x80);
          return true;
        }

        // tst
        final src = readAddr(size, mod, reg);
        nf = src.msb(size);
        zf = src.mask(size) == 0;
        vf = cf = false;

        return true;

      case 0x0e:
        switch (op & 0xff) {
          case 0x70: // reset
            return true;

          case 0x71: // nop
            return true;

          case 0x72: // stop
            return false;

          case 0x73: // rte
            final newSr = pop16();
            pc = pop32();
            sr = sr.setL16(newSr);
            return true;

          case 0x75: // rts
            pc = pop32();
            return true;

          case 0x76: // trapv
            if (vf) {
              trap(0x07 << 2);
            }
            return true;

          case 0x77: // rtr
            final newSr = pop16();
            pc = pop32();
            sr = sr.setL8(newSr);
            return true;
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
          trap(op << 2 & 0x03c | 0x80);
          return true;
        }

        if (op & 0xf0 == 0x60) {
          // move usp
          if (op.bit3) {
            a[reg] = usp;
          } else {
            usp = a[reg];
          }
          return true;
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
