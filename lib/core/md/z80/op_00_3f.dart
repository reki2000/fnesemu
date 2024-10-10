import 'z80.dart';

extension Op003f on Z80 {
  bool exec003f(int op) {
    switch (op) {
      case 0x00: // nop
        cycles += 4;
        return true;
      case 0x10: // djnz
        regs.b--;
        if (regs.b != 0) {
          cycles += 12;
          final rel = pc();
          regs.pc = regs.pc - 2 + (rel >= 128 ? rel - 128 : rel);
        }
        cycles += 8;
        return true;
      case 0x08: // ex af, af'
        final tmp = regs.af2;
        regs.af2 = regs.af;
        regs.af = tmp;
        cycles += 4;
        return true;
      default:
        switch (op & 0x0f) {
          case 0x00: // jr
          case 0x08:
            final rel = pc();
            final addr = regs.pc - 2 + (rel >= 128 ? rel - 128 : rel);
            final flag = switch (op & 0x38) {
              0x20 => !regs.flagZ,
              0x30 => !regs.flagC,
              0x18 => true,
              0x28 => regs.flagZ,
              0x38 => regs.flagC,
              _ => false,
            };
            if (flag) {
              cycles += 12;
              regs.pc = addr;
            }
            cycles += 7;
            return true;
          case 0x01: // ld16
            cycles += 10;
            switch (op) {
              case 0x01: // ld bc, nn
                regs.bc = pc16();
                return true;
              case 0x11: // ld de, nn
                regs.de = pc16();
                return true;
              case 0x21: // ld hl, nn
                regs.hl = pc16();
                return true;
              case 0x31: // ld sp, nn
                regs.sp = pc16();
                return true;
            }
            break;
          case 0x09: // add16
            switch (op) {
              case 0x09: // add hl, bc
                regs.hl = add16(regs.hl, regs.bc);
                return true;
              case 0x19: // add hl, de
                regs.hl = add16(regs.hl, regs.de);
                return true;
              case 0x29: // add hl, hl
                regs.hl = add16(regs.hl, regs.hl);
                return true;
              case 0x39: // add hl, sp
                regs.hl = add16(regs.hl, regs.sp);
                return true;
            }
            return true;
          case 0x02: // ld (16)
            switch (op) {
              case 0x02: // ld (bc), a
                write(regs.bc, regs.a);
                cycles += 7;
                return true;
              case 0x12: // ld (de), a
                write(regs.de, regs.a);
                cycles += 7;
                return true;
              case 0x22: // ld (nn), hl
                final addr = pc16();
                write(addr, regs.l);
                write(addr + 1, regs.h);
                cycles += 16;
                return true;
              case 0x32: // ld (nn), a
                final addr = pc16();
                write(addr, regs.a);
                cycles += 13;
                return true;
            }
          case 0x0a: // ld (16)
            switch (op) {
              case 0x0a: // ld a, (bc)
                regs.a = read(regs.bc);
                cycles += 7;
                return true;
              case 0x1a: // ld a, (de)
                regs.a = read(regs.de);
                cycles += 7;
                return true;
              case 0x2a: // ld hl, (nn)
                final addr = pc16();
                regs.l = read(addr);
                regs.h = read(addr + 1);
                cycles += 16;
                return true;
              case 0x3a: // ld a, (nn)
                final addr = pc16();
                regs.a = read(addr);
                cycles += 13;
                return true;
            }
          case 0x03: // inc16
          case 0x0b: // dec16
            cycles += 6;
            switch (op) {
              case 0x03: // inc bc
                regs.bc = (regs.bc + 1) & 0xffff;
                return true;
              case 0x13: // inc de
                regs.de = (regs.de + 1) & 0xffff;
                return true;
              case 0x23: // inc hl
                regs.hl = (regs.hl + 1) & 0xffff;
                return true;
              case 0x33: // inc sp
                regs.sp = (regs.sp + 1) & 0xffff;
                return true;
              case 0x0b: // dec bc
                regs.bc = (regs.bc - 1) & 0xffff;
                return true;
              case 0x1b: // dec de
                regs.de = (regs.de - 1) & 0xffff;
                return true;
              case 0x2b: // dec hl
                regs.hl = (regs.hl - 1) & 0xffff;
                return true;
              case 0x3b: // dec sp
                regs.sp = (regs.sp - 1) & 0xffff;
                return true;
            }
          case 0x04: // inc8
          case 0x0c: // inc8
            final reg = op & 0x38 >> 3;
            writeReg(reg, inc8(readReg(reg)));
            return true;
          case 0x05: // dec8
          case 0x0d: // dec8
            final reg = op & 0x38 >> 3;
            writeReg(reg, dec8(readReg(reg)));
            return true;
          case 0x06: // ld r,n
          case 0x0e: // ld r,n
            final reg = op & 0x38 >> 3;
            writeReg(reg, pc());
            cycles += 7;
            return true;
          case 0x07: // alu
          case 0x0f: // alu
            switch (op) {
              case 0x07: // rlca
                regs.a = rlc8(regs.a);
                cycles += 4;
                return true;
              case 0x17: // rla
                regs.a = rl8(regs.a);
                cycles += 4;
                return true;
              case 0x27: // daa
                int a = regs.a;
                if (regs.flagN) {
                  a -= (regs.flagH || (a & 0x0f) > 0x09) ? 0x06 : 0x00;
                  a -= (regs.flagC || (a & 0xf0) > 0x90) ? 0x60 : 0x00;
                } else {
                  a += (regs.flagH || (a & 0x0f) > 0x09) ? 0x06 : 0x00;
                  a += (regs.flagC || (a & 0xf0) > 0x90) ? 0x60 : 0x00;
                }
                regs.flagC = (a & 0x100) != 0;
                regs.flagH = (regs.a ^ a) & 0x10 != 0;
                regs.a &= 0xff;
                regs.setFlagsP(regs.a);
                regs.setFlagsSZ(regs.a);
                cycles += 4;
                return true;
              case 0x37: // scf
                regs.flagC = true;
                regs.flagH = false;
                regs.flagN = false;
                cycles += 4;
                return true;
              case 0x0f: // rrca
                regs.a = rrc8(regs.a);
                cycles += 4;
                return true;
              case 0x1f: // rra
                regs.a = rr8(regs.a);
                cycles += 4;
                return true;
              case 0x2f: // cpl
                regs.a = ~regs.a & 0xff;
                regs.flagH = true;
                regs.flagN = true;
                cycles += 4;
                return true;
              case 0x3f: // ccf
                regs.flagC = !regs.flagC;
                regs.flagH = false;
                regs.flagN = false;
                cycles += 4;
                return true;
            }
            return true;
        }
    }

    return false;
  }
}
