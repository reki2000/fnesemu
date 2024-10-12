import 'package:fnesemu/util.dart';

import 'z80.dart';

extension OpDdFd on Z80 {
  bool execDdFd(int op, int xy) {
    if (op < 0x40) {
      switch (op) {
        case 0x09: // add ix, bc
          r.ixiy[xy] = add16(r.ixiy[xy], r.bc);
          return true;
        case 0x19: // add ix, de
          r.ixiy[xy] = add16(r.ixiy[xy], r.de);
          return true;
        case 0x29: // add ix, ix
          r.ixiy[xy] = add16(r.ixiy[xy], r.ixiy[xy]);
          return true;
        case 0x39: // add ix, sp
          r.ixiy[xy] = add16(r.ixiy[xy], r.sp);
          return true;
        case 0x21: // ld ix, nn
          r.ixiy[xy] = pc16();
          return true;
        case 0x22: // ld (nn), ix
          final addr = pc16();
          write(addr, r.ixiy[xy] & 0xff);
          write(addr + 1, r.ixiy[xy] >> 8);
          cycles += 6;
          return true;
        case 0x2a: // ld ix, (nn)
          final addr = pc16();
          r.ixiy[xy] = read(addr).withHighByte(read((addr + 1)));
          cycles += 6;
          return true;
        case 0x23: // inc ix
          r.ixiy[xy] = (r.ixiy[xy] + 1) & 0xffff;
          cycles += 2;
          return true;
        case 0x2b: // dec ix
          r.ixiy[xy] = (r.ixiy[xy] - 1) & 0xffff;
          cycles += 2;
          return true;
        default:
          final reg = (op & 0x38) >> 3;
          final rel = reg == 0x06 ? rel8() : 0;
          switch (op & 0x07) {
            case 0x04: // inc r
              writeRegXY(reg, xy, rel, inc8(readRegXY(reg, xy, rel)));
              if (reg == 0x06) cycles += 6;
              return true;
            case 0x05: // dec r
              writeRegXY(reg, xy, rel, dec8(readRegXY(reg, xy, rel)));
              if (reg == 0x06) cycles += 6;
              return true;
            case 0x06: // ld r, n
              writeRegXY(reg, xy, rel, pc8());
              if (reg == 0x06) cycles += 2;
              return true;
          }
      }

      return false;
    }

    // ld r, r'
    if (op < 0x80) {
      if (op == 0x76) {
        return true;
      }

      final src = op & 0x07;
      final dst = (op & 0x38) >> 3;
      int rel = 0;
      if (src == 0x06 || dst == 0x06) {
        cycles += 5;
        rel = rel8();
      }
      if (src == 0x06) {
        writeReg(dst, readRegXY(src, xy, rel));
        return true;
      }
      writeRegXY(
          dst, xy, rel, dst == 0x06 ? readReg(src) : readRegXY(src, xy, rel));
      return true;
    }

    if (op < 0xc0) {
      // alu r
      final reg = op & 0x07;
      int rel = 0;
      if (reg == 0x06) {
        cycles += 5;
        rel = rel8();
      }
      final val = readRegXY(reg, xy, rel);
      switch (op & 0x38) {
        case 0x00: // add
          add8(val, 0);
          return true;
        case 0x08: // adc
          add8(val, r.cf ? 1 : 0);
          return true;
        case 0x10: // sub
          sub8(val, 0);
          return true;
        case 0x18: // sbc
          sub8(val, r.cf ? 1 : 0);
          return true;
        case 0x20: // and
          and8(val);
          return true;
        case 0x28: // xor
          xor8(val);
          return true;
        case 0x30: // or
          or8(val);
          return true;
        case 0x38: // cp
          cp8(val);
          return true;
      }

      throw ("unreachable");
    }

    switch (op) {
      case 0xe1: // pop ix
        r.ixiy[xy] = pop();
        return true;
      case 0xe3: // ex (sp), ix
        final tmp = read(r.sp);
        write(r.sp, r.ixiy[xy] & 0xff);
        r.ixiy[xy] = (r.ixiy[xy] & 0xff00) | tmp;
        final sp2 = r.sp + 1;
        final tmp2 = read(sp2);
        write(sp2, r.ixiy[xy] >> 8);
        r.ixiy[xy] = (r.ixiy[xy] & 0x00ff) | (tmp2 << 8);
        cycles += 15;
        return true;
      case 0xe5: // push ix
        push(r.ixiy[xy]);
        return true;
      case 0xe9: // jp (ix)
        r.pc = r.ixiy[xy];
        return true;
      case 0xf9: // ld sp, ix
        r.sp = r.ixiy[xy];
        cycles += 2;
        return true;

      case 0xcb: // dd cb
        final addr = r.ixiy[xy] + rel8();
        final op2 = next();
        r.r = (r.r - 1) & 0x7f | r.r & 0x80;
        final dst = op2 & 0x07;
        final org = read(addr);

        switch (op2 & 0xc0) {
          case 0x00:
            int val = switch (op2 & 0x38) {
              0x00 => rlc8(org), // rlc (ix + d)
              0x08 => rrc8(org), // rrc (ix + d)
              0x10 => rl8(org), // rl (ix + d)
              0x18 => rr8(org), // rr (ix + d)
              0x20 => sla8(org), // sla (ix + d)
              0x28 => sra8(org), // sra (ix + d)
              0x30 => sll8(org), // sll (ix + d)
              0x38 => srl8(org), // srl (ix + d)
              _ => throw ("unreachable"),
            };
            write(addr, val);
            if (dst != 0x06) writeReg(dst, val);
            cycles += 8;
            return true;

          case 0x40:
            final bit = (op2 >> 3) & 0x07;
            final val = org & (1 << bit);
            r.setSZ(val);
            r.hf = true;
            r.nf = false;
            r.pvf = r.zf;
            cycles += 5;
            return true;

          case 0x80:
            final val = org & ~(1 << ((op2 >> 3) & 0x07));
            write(addr, val);
            if (dst != 0x06) writeReg(dst, val);
            cycles += 8;
            return true;

          case 0xc0:
            final val = org | (1 << ((op2 >> 3) & 0x07));
            write(addr, val);
            if (dst != 0x06) writeReg(dst, val);
            cycles += 8;
            return true;
        }

        throw ("unreachable");
    }

    return false;
  }
}
