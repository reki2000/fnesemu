import 'package:fnesemu/core/md/m68/op_alu.dart';
import 'package:fnesemu/util/int.dart';

import 'm68.dart';

extension Op0 on M68 {
  bool exec0(int op) {
    if (op & 0x0100 != 0) {
      if (op & 0x38 == 0x08) {
        // movep
        return false;
      }

      // bit
      final dn = op >> 9 & 0x07;
      final xn = op & 0x07;
      final mode = op >> 3 & 0x07;
      final size = (mode == 0 || mode == 1) ? 4 : 1;
      final bit = d[dn] & ((size == 4) ? 0x1f : 0x07);
      final mask = (1 << bit);
      final data = readAddr(size, mode, xn);
      zf = data & mask == 0;

      debug(
          "bit dn:$dn xn:$xn mode:$mode size:$size bit:$bit mask:${mask.hex8} data:${data.hex8}");

      switch (op >> 6 & 0x03) {
        case 0x00: // btst
          return true;
        case 0x01: // bchg
          writeAddr(size, mode, xn, data ^ mask);
          return true;
        case 0x02: // bclr
          writeAddr(size, mode, xn, data & ~mask);
          return true;
        case 0x03: // bset
          writeAddr(size, mode, xn, data | mask);
          return true;
      }

      return false;
    }

    final mode = op >> 3 & 0x07;
    final size = size0[op >> 6 & 0x03];
    final xn = op & 0x07;

    switch (op >> 9 & 0x07) {
      case 0x00: // ori
        if (op == 0x003c) {
          sr = sr.setL8(or(sr, immed(1), 1)); // ori ccr, imm
          return true;
        }
        if (op == 0x007c) {
          sr = sr.setL16(or(sr, immed(2), 2)); // ori sr, imm
          return true;
        }

        final a = immed(size);
        final b = readAddr(size, mode, xn);

        final r = or(a, b, size);

        writeAddr(size, mode, xn, r);
        if (size == 4 && mode == 0) {
          clocks += 4;
        }

        return true;

      case 0x01: // andi
        if (op == 0x023c) {
          sr = sr.setL8(and(sr, immed(1), 1)); // andi ccr, imm
          return true;
        } else if (op == 0x027c) {
          sr = sr.setL16(and(sr, immed(2), 2)); // andi sr, imm
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

      case 0x02: // subi
        return false;

      case 0x03: // addi
        final a = immed(size);
        final b = readAddr(size, mode, xn);

        final r = add(a, b, size);

        writeAddr(size, mode, xn, r);
        if (size == 4 && mode == 0) {
          clocks += 4;
        }

        return true;

      case 0x04: // bits
        final size = (mode == 0 || mode == 1) ? 4 : 1;
        final bit = pc16() & ((size == 4) ? 0x1f : 0x07);
        final mask = (1 << bit);
        final data = readAddr(size, mode, xn);
        zf = data & mask == 0;

        debug(
            "bit xn:$xn mode:$mode size:$size bit:$bit mask:${mask.hex8} data:${data.hex8}");

        switch (op >> 6 & 0x03) {
          case 0x00: // btst
            return true;
          case 0x01: // bchg
            writeAddr(size, mode, xn, data ^ mask);
            return true;
          case 0x02: // bclr
            writeAddr(size, mode, xn, data & ~mask);
            return true;
          case 0x03: // bset
            writeAddr(size, mode, xn, data | mask);
            return true;
        }

        return false;

      case 0x05: // eori
        if (op == 0x0a3c) {
          sr = sr.setL8(eor(sr, immed(1), 1)); // eori ccr, imm
          return true;
        }
        if (op == 0x0a7c) {
          sr = sr.setL16(eor(sr, immed(2), 2)); // eori sr, imm
          return true;
        }

        final a = immed(size);
        final b = readAddr(size, mode, xn);

        final r = eor(a, b, size);

        writeAddr(size, mode, xn, r);
        if (size == 4 && mode == 0) {
          clocks += 4;
        }

        return true;

      case 0x06: // cmpi
        return false;
    }

    return false;
  }
}
