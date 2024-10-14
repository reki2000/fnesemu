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

    final mod = op >> 3 & 0x07;
    final size = size0[op >> 6 & 0x03];
    final reg = op & 0x07;

    switch (op >> 9 & 0x07) {
      case 0x03: // addi
        final a = immed(size);
        final b = readAddr(size, mod, reg);

        final r = add(a, b, size);

        writeAddr(size, mod, reg, r);

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
        final val = readAddr(size, mod, reg);
        switch (size) {
          case 0x00:
            final newVal = a[reg].mask8 | val.mask8;
            a[reg] = a[reg].setL8(newVal);
            break;
          case 0x01:
            final newVal = a[reg].mask16 | val.mask16;
            a[reg] = a[reg].setL16(newVal);
            d[reg] |= val;
            break;
          case 0x02:
            final newVal = a[reg] | val;
            a[reg] = a[reg].setL8(newVal);
            a[reg] |= val;
            d[reg] |= val;
            break;
        }
        d[reg] |= val;
        return true;
      case 0x01: // ANDI
        return true;
      case 0x02: // SUBI
        return true;
    }

    return false;
  }

  bool exec1(int op) => false;
  bool exec2(int op) => false;
  bool exec3(int op) => false;
  bool exec4(int op) => false;

  bool exec6(int op) => false;
  bool exec7(int op) => false;
  bool exec8(int op) => false;
  bool exec9(int op) => false;
  bool execA(int op) => false;
  bool execB(int op) => false;

  bool execE(int op) => false;
  bool execF(int op) => false;
}
