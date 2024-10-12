import 'package:fnesemu/util.dart';

import 'z80.dart';

extension OpDdFd on Z80 {
  bool execDdFd(int op, int xy) {
    if (op < 0x40) {
      switch (op) {
        case 0x09: // add ix, bc
          r.ixiy[xy] = add16(r.ixiy[xy], r.bc);
          cycles += 4;
          return true;
        case 0x19: // add ix, de
          r.ixiy[xy] = add16(r.ixiy[xy], r.de);
          cycles += 4;
          return true;
        case 0x29: // add ix, ix
          r.ixiy[xy] = add16(r.ixiy[xy], r.ixiy[xy]);
          cycles += 4;
          return true;
        case 0x39: // add ix, sp
          r.ixiy[xy] = add16(r.ixiy[xy], r.sp);
          cycles += 4;
          return true;
        case 0x21: // ld ix, nn
          r.ixiy[xy] = pc16();
          cycles += 14;
          return true;
        case 0x22: // ld (nn), ix
          final addr = pc16();
          write(addr, r.ixiy[xy] & 0xff);
          write(addr + 1, r.ixiy[xy] >> 8);
          cycles += 20;
          return true;
        case 0x2a: // ld ix, (nn)
          final addr = pc16();
          r.ixiy[xy] = read(addr).withHighByte(read((addr + 1)));
          cycles += 20;
          return true;
        case 0x23: // inc ix
          r.ixiy[xy] = (r.ixiy[xy] + 1) & 0xffff;
          cycles += 10;
          return true;
        case 0x2b: // dec ix
          r.ixiy[xy] = (r.ixiy[xy] - 1) & 0xffff;
          cycles += 10;
          return true;
        default:
          final reg = (op & 0x38) >> 3;
          final rel = reg == 0x06 ? rel8() : 0;
          switch (op & 0x07) {
            case 0x04: // inc r
              cycles += 4;
              writeRegXY(reg, xy, rel, inc8(readRegXY(reg, xy, rel)));
              return true;
            case 0x05: // dec r
              cycles += 4;
              writeRegXY(reg, xy, rel, dec8(readRegXY(reg, xy, rel)));
              return true;
            case 0x06: // ld r, n
              cycles += 11;
              writeRegXY(reg, xy, rel, pc());
              return true;
          }
      }

      cycles += 8;
      return false;
    }

    if (op < 0xc0) {
      cycles += 8;

      if (op == 0x76) {
        return true;
      }

      // ld r, r'
      if (op < 0x80) {
        final src = op & 0x07;
        final dst = (op & 0x38) >> 3;
        final rel = src == 0x06 || dst == 0x06 ? rel8() : 0;
        writeRegXY(dst, xy, rel, readRegXY(src, xy, rel));
        return true;
      }

      // alu r
      final reg = op & 0x07;
      final rel = reg == 0x06 ? rel8() : 0;
      final val = readRegXY(reg, rel, xy);
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
        cycles += 14;
        return true;
      case 0xe3: // ex (sp), ix
        final tmp = read(r.sp);
        write(r.sp, r.ixiy[xy] & 0xff);
        r.ixiy[xy] = (r.ixiy[xy] & 0xff00) | tmp;
        final sp2 = r.sp + 1;
        final tmp2 = read(sp2);
        write(sp2, r.ixiy[xy] >> 8);
        r.ixiy[xy] = (r.ixiy[xy] & 0x00ff) | (tmp2 << 8);
        cycles += 23;
        return true;
      case 0xe5: // push ix
        push(r.ixiy[xy]);
        cycles += 15;
        return true;
      case 0xe9: // jp (ix)
        r.pc = r.ixiy[xy];
        cycles += 8;
        return true;
      case 0xf9: // ld sp, ix
        r.sp = r.ixiy[xy];
        cycles += 10;
        return true;

      case 0xcb: // dd cb
        final op = pc();
        final addr = r.ixiy[xy] + rel8();
        switch (op) {
          case 0x06: // rlc (ix + d)
            write(addr, rlc8(read(addr)));
            cycles += 23;
            return true;
          case 0x0e: // rrc (ix + d)
            write(addr, rrc8(read(addr)));
            cycles += 23;
            return true;
          case 0x16: // rl (ix + d)
            write(addr, rl8(read(addr)));
            cycles += 23;
            return true;
          case 0x1e: // rr (ix + d)
            write(addr, rr8(read(addr)));
            cycles += 23;
            return true;
          case 0x26: // sla (ix + d)
            write(addr, sla8(read(addr)));
            cycles += 23;
            return true;
          case 0x2e: // sra (ix + d)
            write(addr, sra8(read(addr)));
            cycles += 23;
            return true;
          case 0x36: // sll (ix + d)
            write(addr, sll8(read(addr)));
            cycles += 23;
            return true;
          case 0x3e: // srl (ix + d)
            write(addr, srl8(read(addr)));
            cycles += 23;
            return true;
          case 0x46: // bit 0, (ix + d)
          case 0x4e: // bit 1, (ix + d)
          case 0x56: // bit 2, (ix + d)
          case 0x5e: // bit 3, (ix + d)
          case 0x66: // bit 4, (ix + d)
          case 0x6e: // bit 5, (ix + d)
          case 0x76: // bit 6, (ix + d)
          case 0x7e: // bit 7, (ix + d)
            final bit = (op >> 3) & 0x07;
            r.zf = (read(addr) & (1 << bit)) == 0;
            r.hf = true;
            r.nf = false;
            cycles += 20;
            return true;
          case 0x86: // res 0, (ix + d)
          case 0x8e: // res 1, (ix + d)
          case 0x96: // res 2, (ix + d)
          case 0x9e: // res 3, (ix + d)
          case 0xa6: // res 4, (ix + d)
          case 0xae: // res 5, (ix + d)
          case 0xb6: // res 6, (ix + d)
          case 0xbe: // res 7, (ix + d)
            write(addr, read(addr) & ~(1 << ((op >> 3) & 0x07)));
            cycles += 23;
            return true;
          case 0xc6: // set 0, (ix + d)
          case 0xce: // set 1, (ix + d)
          case 0xd6: // set 2, (ix + d)
          case 0xde: // set 3, (ix + d)
          case 0xe6: // set 4, (ix + d)
          case 0xee: // set 5, (ix + d)
          case 0xf6: // set 6, (ix + d)
          case 0xfe: // set 7, (ix + d)
            write(addr, read(addr) | (1 << ((op >> 3) & 0x07)));
            cycles += 23;
            return true;
        }
    }

    cycles += 8;
    return false;
  }
}
