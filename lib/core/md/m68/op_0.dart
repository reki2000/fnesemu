import 'package:fnesemu/core/md/m68/alu.dart';
import 'package:fnesemu/util/int.dart';

import 'm68.dart';

extension Op0 on M68 {
  bool exec0(int op) {
    if (op & 0x0100 != 0) {
      if (op & 0x38 == 0x08) {
        // movep
        final size = op.bit6 ? 4 : 2;
        final memToReg = !op.bit7;
        final an = op & 0x07;
        final dn = op >> 9 & 0x07;
        addr0 = (a[an] + pc16().rel16).mask32;
        debug(
            "movep dn:$dn size:$size memToReg:$memToReg addr0:${addr0.hex32}");
        if (size == 2) {
          if (memToReg) {
            d[dn] =
                d[dn].setL16(read16(addr0) & 0xff00 | read16(addr0.inc2) >> 8);
          } else {
            write16(addr0, d[dn] & 0xff00);
            write16(addr0.inc2, d[dn] << 8 & 0xff00);
          }
        } else {
          if (memToReg) {
            d[dn] = read16(addr0) << 16 & 0xff000000 |
                read16(addr0.inc2) << 8 & 0x00ff0000 |
                read16(addr0.inc4) & 0xff00 |
                read16(addr0 + 6) >> 8;
          } else {
            write16(addr0, d[dn] >> 16 & 0xff00);
            write16(addr0.inc2, d[dn] >> 8 & 0xff00);
            write16(addr0.inc4, d[dn] & 0xff00);
            write16(addr0 + 6, d[dn] << 8 & 0xff00);
          }
        }

        return true;
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

        final im = immed(size);
        final ea = readAddr(size, mode, xn);
        writeAddr(size, mode, xn, or(im, ea, size));
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

        final im = immed(size);
        final ea = readAddr(size, mode, xn);
        writeAddr(size, mode, xn, and(im, ea, size));
        if (size == 4 && mode == 0) {
          clocks += 4;
        }

        return true;

      case 0x02: // subi
        final im = immed(size);
        final ea = readAddr(size, mode, xn);
        writeAddr(size, mode, xn, sub(ea, im, size));
        if (size == 4 && mode == 0) {
          clocks += 4;
        }

        return true;

      case 0x03: // addi
        final im = immed(size);
        final ea = readAddr(size, mode, xn);
        writeAddr(size, mode, xn, add(ea, im, size));
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

        final im = immed(size);
        final ea = readAddr(size, mode, xn);
        writeAddr(size, mode, xn, eor(im, ea, size));
        if (size == 4 && mode == 0) {
          clocks += 4;
        }

        return true;

      case 0x06: // cmpi
        final im = immed(size);
        final ea = readAddr(size, mode, xn);
        sub(ea, im, size, cmp: true);
        if (size == 4 && mode == 0) {
          clocks += 4;
        }

        return true;
    }

    return false;
  }
}
