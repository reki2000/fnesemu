import 'package:fnesemu/util.dart';

import 'z80.dart';

extension OpDdFd on Z80 {
  bool execDdFd(int op, int xy) {
    switch (op) {
      case 0x09: // add ix, bc
        regs.ixiy[xy] = add16(regs.ixiy[xy], regs.bc);
        cycles += 4;
        return true;
      case 0x19: // add ix, de
        regs.ixiy[xy] = add16(regs.ixiy[xy], regs.de);
        cycles += 4;
        return true;
      case 0x21: // ld ix, nn
        regs.ixiy[xy] = pc16();
        cycles += 14;
        return true;
      case 0x22: // ld (nn), ix
        final addr = pc16();
        write(addr, regs.ixiy[xy] & 0xff);
        write(addr + 1, regs.ixiy[xy] >> 8);
        cycles += 20;
        return true;
      case 0x23: // inc ix
        regs.ixiy[xy] = (regs.ixiy[xy] + 1) & 0xffff;
        cycles += 10;
        return true;
      case 0x29: // add ix, ix
        regs.ixiy[xy] = add16(regs.ixiy[xy], regs.ixiy[xy]);
        cycles += 4;
        return true;
      case 0x2a: // ld ix, (nn)
        final addr = pc16();
        regs.ixiy[xy] = read(addr).withHighByte(read((addr + 1)));
        cycles += 16;
        return true;
      case 0x2b: // dec ix
        regs.ixiy[xy] = (regs.ixiy[xy] - 1) & 0xffff;
        cycles += 10;
        return true;
      case 0x34: // inc (ix + d)
        final addr = regs.ixiy[xy] + rel8();
        write(addr, inc8(read(addr)));
        cycles += 19;
        return true;
      case 0x35: // dec (ix + d)
        final addr = regs.ixiy[xy] + rel8();
        write(addr, dec8(read(addr)));
        cycles += 19;
        return true;
      case 0x36: // ld (ix + d), n
        final addr = regs.ixiy[xy] + rel8();
        write(addr, pc());
        cycles += 19;
        return true;
      case 0x39: // add ix, sp
        regs.ixiy[xy] = add16(regs.ixiy[xy], regs.sp);
        cycles += 4;
        return true;
      case 0x46: // ld b, (ix + d)
      case 0x4e: // ld c, (ix + d)
      case 0x56: // ld d, (ix + d)
      case 0x5e: // ld e, (ix + d)
      case 0x66: // ld h, (ix + d)
      case 0x6e: // ld l, (ix + d)
      case 0x7e: // ld a, (ix + d)
        final reg = (op & 0x38) >> 3;
        writeReg(reg, read(regs.ixiy[xy] + rel8()));
        cycles += 19;
        return true;
      case 0x70: // ld (ix + d), b
      case 0x71: // ld (ix + d), c
      case 0x72: // ld (ix + d), d
      case 0x73: // ld (ix + d), e
      case 0x74: // ld (ix + d), h
      case 0x75: // ld (ix + d), l
      case 0x77: // ld (ix + d), a
        write(regs.ixiy[xy] + rel8(), readReg(op & 0x07));
        cycles += 19;
        return true;
      case 0x86: // add a, (ix + d)
        final val = read(regs.ixiy[xy] + rel8());
        cycles += 19;
        add8(val, 0);
        return true;
      case 0x8e: // adc a, (ix + d)
        final val = read(regs.ixiy[xy] + rel8());
        cycles += 19;
        add8(val, regs.flagC ? 1 : 0);
        return true;
      case 0x96: // sub (ix + d)
        final val = read(regs.ixiy[xy] + rel8());
        cycles += 19;
        sub8(val, 0);
        return true;
      case 0x9e: // sbc a, (ix + d)
        final val = read(regs.ixiy[xy] + rel8());
        cycles += 19;
        sub8(val, regs.flagC ? 1 : 0);
        return true;
      case 0xa6: // and (ix + d)
        final val = read(regs.ixiy[xy] + rel8());
        cycles += 19;
        and8(val);
        return true;
      case 0xae: // xor (ix + d)
        final val = read(regs.ixiy[xy] + rel8());
        cycles += 19;
        xor8(val);
        return true;
      case 0xb6: // or (ix + d)
        final val = read(regs.ixiy[xy] + rel8());
        cycles += 19;
        or8(val);
        return true;
      case 0xbe: // cp (ix + d)
        final val = read(regs.ixiy[xy] + rel8());
        cycles += 19;
        cp8(val);
        return true;
      case 0xe1: // pop ix
        regs.ixiy[xy] = pop();
        cycles += 14;
        return true;
      case 0xe3: // ex (sp), ix
        final tmp = read(regs.sp);
        write(regs.sp, regs.ixiy[xy] & 0xff);
        regs.ixiy[xy] = (regs.ixiy[xy] & 0xff00) | tmp;
        final sp2 = regs.sp + 1;
        final tmp2 = read(sp2);
        write(sp2, regs.ixiy[xy] >> 8);
        regs.ixiy[xy] = (regs.ixiy[xy] & 0x00ff) | (tmp2 << 8);
        cycles += 23;
        return true;
      case 0xe5: // push ix
        push(regs.ixiy[xy]);
        cycles += 15;
        return true;
      case 0xe9: // jp (ix)
        regs.pc = regs.ixiy[xy];
        cycles += 8;
        return true;
      case 0xf9: // ld sp, ix
        regs.sp = regs.ixiy[xy];
        cycles += 10;
        return true;
      case 0xcb: // dd cb
        final op = pc();
        final addr = regs.ixiy[xy] + rel8();
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
            regs.flagZ = (read(addr) & (1 << bit)) == 0;
            regs.flagH = true;
            regs.flagN = false;
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
    return false;
  }
}
