import 'package:fnesemu/core/md/m68/op_alu.dart';
import 'package:fnesemu/util/int.dart';

import 'm68.dart';

extension Op0 on M68 {
  bool exec0(int op) {
    if (op & 0x0100 != 0) {
      final reg2 = op >> 9 & 0x07;
      // btst, bchg, bclr, bset, movep
      return true;
    }

    final mode = op >> 3 & 0x07;
    final size = size0[op >> 6 & 0x03];
    final xn = op & 0x07;

    switch (op >> 9 & 0x07) {
      case 0x03: // addi
        final a = immed(size);
        final b = readAddr(size, mode, xn);

        final r = add(a, b, size);

        writeAddr(size, mode, xn, r);
        if (size == 4 && mode == 0) {
          clocks += 4;
        }

        return true;

      case 0x01: // andi
        if (op == 0x023c) {
          // andi ccr, imm
          final aa = immed(1);
          final r = and(sr, aa, 1);
          sr = sr.setL8(r);
          return true;
        } else if (op == 0x027c) {
          // andi sr, imm
          final aa = immed(2);
          final r = and(sr, aa, 2);
          sr = sr.setL16(r);
          return true;
        }

        final a = immed(size);
        final b = readAddr(size, mode, xn);

        final r = and(a, b, size);

        writeAddr(size, mode, xn, r);
        if (size == 4 && mode == 0) {
          clocks += 4;
        }

        return true;

      case 0x00: // ORI
        if (op == 0x003c) {
          // ori ccr, imm
          return true;
        }
        if (op == 0x007c) {
          // ori sr, imm
          return true;
        }
        final val = readAddr(size, mode, xn);
        switch (size) {
          case 0x00:
            final newVal = a[xn].mask8 | val.mask8;
            a[xn] = a[xn].setL8(newVal);
            break;
          case 0x01:
            final newVal = a[xn].mask16 | val.mask16;
            a[xn] = a[xn].setL16(newVal);
            d[xn] |= val;
            break;
          case 0x02:
            final newVal = a[xn] | val;
            a[xn] = a[xn].setL8(newVal);
            a[xn] |= val;
            d[xn] |= val;
            break;
        }
        d[xn] |= val;
        return true;
      case 0x01: // ANDI
        return true;
      case 0x02: // SUBI
        return true;
    }

    return false;
  }
}
