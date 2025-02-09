import 'package:fnesemu/util/int.dart';

import 'alu.dart';
import 'm68.dart';
import 'op_0.dart';
import 'op_4.dart';
import 'op_8.dart';
import 'op_c.dart';
import 'op_e.dart';

extension Op on M68 {
  bool exec() {
    if (halt) {
      if (0 < assertedIntLevel) {
        halt = false;
      } else {
        clocks += 4;
        return true;
      }
    }

    if (0 < assertedIntLevel && assertedIntLevel > maskedIntLevel) {
      trap((assertedIntLevel << 2) + 0x60,
          sr & ~0x700 | assertedIntLevel << 8 & 0x700);
      assertedIntLevel = 0;
      return true;
    }

    pc0 = pc;
    final op = op0 = pc16();

    try {
      switch (op >> 12) {
        case 0x00:
          return exec0(op);
        case 0x01:
        case 0x02:
        case 0x03:
          final size = size2[op >> 12 & 0x03];
          final src = op & 0x07;
          final modeSrc = op >> 3 & 0x07;
          final dst = op >> 9 & 0x07;
          final modeDst = op >> 6 & 0x07;

          final value = readAddr(size, modeSrc, src);

          if (modeDst != 1) {
            nf = value.msb(size);
            zf = value.mask(size) == 0;
            vf = cf = false;
          }

          // debug(
          //     "size:$size src:$src modeSrc:$modeSrc dst:$dst modeDst:$modeDst");

          if (modeDst != 0 && modeDst != 1) {
            addr0 = addressing(size, modeDst, dst);
            // debug("addr0:${addr0.hex32}");
          } else if (modeDst == 1) {
            a[dst] = value.rel(size).mask32;
            return true;
          }

          writeAddr(size, modeDst, dst, value);
          if (modeDst == 3) {
            postInc(dst, size);
          }

          return true;

        case 0x04:
          return exec4(op);
        case 0x05:
          return exec5(op);
        case 0x06:
          return exec6(op);

        case 0x07:
          // moveq
          final val = op.mask8.rel8.mask32;
          d[op >> 9 & 0x07] = val;
          nf = val.msb(4);
          zf = val == 0;
          vf = cf = false;
          return true;

        case 0x08:
          return exec8(op);

        case 0x09:
          return exec9(op);

        case 0x0a:
          return execA(op);
        case 0x0b:
          return execB(op);
        case 0x0c:
          return execC(op);
        case 0x0d:
          return execD(op);
        case 0x0e:
          return execE(op);
        case 0x0f:
          return execF(op);
      }
    } catch (e) {
      if (e is BusError) {
        busError(e.addr, e.pc, op, e.read, e.inst);
        return true;
      }

      rethrow;
    }

    return false;
  }

  bool exec5(int op) {
    if (op & 0x00c0 == 0x00c0) {
      final mode = op >> 3 & 0x07;
      final cc = op >> 8 & 0x0f;
      final dx = op & 0x07;

      if (mode == 0x01) {
        // dbcc
        final disp = pc16().rel16;

        if (!cond(cc)) {
          final counter = d[dx].dec.mask16;
          d[dx] = d[dx].setL16(counter);
          if (counter != 0xffff) {
            pc = pc + disp - 2;
            clocks += 2;
          } else {
            clocks += 6;
          }
        } else {
          clocks += 2;
        }

        return true;
      }

      // scc
      if (mode != 0x00) {
        addr0 = addressing(1, mode, dx);
      }
      writeAddr(1, mode, dx, cond(cc) ? 0xffffffff : 0);
      if (mode == 3) postInc(dx, 1);

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
      // debug("clock:$clocks size:$size mod:$mode reg:$reg addr:${addr0.hex24}");
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

  bool exec6(int op) {
    final cc = op >> 8 & 0x0f;
    final pc0 = pc;
    final disp = switch (op.mask8) {
      0x00 => pc16().rel16,
      // 0xff => pc32().rel32,
      _ => op.mask8.rel8
    };

    if (cc == 0x01) {
      // bsr
      push32(pc);
      pc = pc0 + disp;
      return true;
    }

    if (cond(cc)) {
      clocks += 2;
      pc = pc0 + disp;
    }
    return true;
  }

  bool exec9(int op) {
    final xn = op & 0x07;
    final dn = op >> 9 & 0x07;
    final s0 = op >> 6 & 0x03;
    final mode = op >> 3 & 0x07;

    if (s0 == 0x03) {
      // suba
      final size = op.bit8 ? 4 : 2;

      final aa = readAddr(size, mode, xn);
      // debug(
      //     "size:$size mod:$mode reg:$xn addr:${addr0.hex24} aa:$aa clock:$clocks");

      final r = a[dn] - aa.smask(size);
      clocks +=
          (size == 2 || mode == 0 || mode == 1 || mode == 7 && xn == 4) ? 4 : 2;

      a[dn] = r.mask32;
      return true;
    }

    if (op & 0x130 == 0x100) {
      // subx
      final size = size0[s0];

      if (op.bit3) {
        int a, b = 0;
        b = read(preDec(xn, size), size);
        addr0 = preDec(dn, size);
        a = read(addr0, size);

        final r = sub(a, b, size, useXf: true);
        write(addr0, size, r);
      } else {
        final r = sub(d[dn].mask(size), d[xn].mask(size), size, useXf: true);
        if (size == 4) {
          clocks += 4;
        }
        d[dn] = d[dn].setL(r, size);
      }
      return true;
    }

    // sub
    final size = size0[s0];
    final directionEa = op.bit8;

    int dd = d[dn].mask(size);
    int ea = readAddr(size, mode, xn);

    if (directionEa) {
      write(addr0, size, sub(ea, dd, size));
    } else {
      if (size == 4) {
        clocks += (mode == 0 || mode == 1 || mode == 7 && xn == 4) ? 4 : 2;
      }
      d[dn] = d[dn].setL(sub(dd, ea, size), size);
    }
    return true;
  }

  bool execB(int op) {
    final ry = op & 0x07;
    final rx = op >> 9 & 0x07;
    final size = size0[op >> 6 & 0x03];
    final mode = op >> 3 & 0x07;

    if (op & 0x00c0 == 0x00c0) {
      //cmpa
      final size = size1[op >> 8 & 0x01];
      final src = readAddr(size, mode, ry);
      final dst = a[rx];
      sub(dst, (size == 2) ? src.rel16.mask32 : src, 4, cmp: true);
      return true;
    }

    if (op & 0x0100 == 0x0000) {
      // cmp
      final src = readAddr(size, mode, ry);
      final dst = d[rx].mask(size);
      sub(dst, src, size, cmp: true);
      return true;
    }

    if (op & 0x0138 == 0x0108) {
      // cmpm
      final src = read(postInc(ry, size), size);
      final dst = read(postInc(rx, size), size);
      sub(dst, src, size, cmp: true);
      return true;
    }

    // eor
    final aa = d[rx].mask(size);
    final ea = readAddr(size, mode, ry);
    writeAddr(size, mode, ry, eor(aa, ea, size));

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
      // debug(
      //     "size:$size mod:$mode reg:$xn addr:${addr0.hex24} aa:$aa clock:$clocks");

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
        final b = read(preDec(xn, size), size);
        addr0 = preDec(dn, size);
        final a = read(addr0, size);

        final r = add(a, b, size, useXf: true);
        write(addr0, size, r);
      } else {
        final r = add(d[xn].mask(size), d[dn].mask(size), size, useXf: true);
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

  bool exec1(int op) => false;
  bool exec2(int op) => false;

  bool execA(int op) => false;

  bool execF(int op) => false;
}
