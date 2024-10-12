import 'z80.dart';

extension Op003f on Z80 {
  bool exec003f(int op) {
    switch (op) {
      case 0x00: // nop
        cycles += 4;
        return true;

      case 0x10: // djnz
        final rel = pc();
        r.b = (r.b - 1) & 0xff;
        if (r.b != 0) {
          cycles += 13;
          r.pc = (r.pc + (rel >= 128 ? rel - 256 : rel)) & 0xffff;
        } else {
          cycles += 8;
        }
        return true;

      case 0x08: // ex af, af'
        final tmp = r.af2;
        r.af2 = r.af;
        r.af = tmp;
        cycles += 4;
        return true;

      default:
        switch (op & 0x0f) {
          case 0x00: // jr
          case 0x08:
            final rel = pc();
            final addr = (r.pc + (rel >= 128 ? rel - 256 : rel)) & 0xffff;
            final flag = switch (op & 0x38) {
              0x20 => !r.zf,
              0x30 => !r.cf,
              0x18 => true,
              0x28 => r.zf,
              0x38 => r.cf,
              _ => false,
            };
            if (flag) {
              cycles += 12;
              r.pc = addr;
            } else {
              cycles += 7;
            }
            return true;

          case 0x01: // ld16
            cycles += 10;
            switch (op) {
              case 0x01: // ld bc, nn
                r.bc = pc16();
                return true;
              case 0x11: // ld de, nn
                r.de = pc16();
                return true;
              case 0x21: // ld hl, nn
                r.hl = pc16();
                return true;
              case 0x31: // ld sp, nn
                r.sp = pc16();
                return true;
            }
            break;

          case 0x09: // add16
            switch (op) {
              case 0x09: // add hl, bc
                r.hl = add16(r.hl, r.bc);
                return true;
              case 0x19: // add hl, de
                r.hl = add16(r.hl, r.de);
                return true;
              case 0x29: // add hl, hl
                r.hl = add16(r.hl, r.hl);
                return true;
              case 0x39: // add hl, sp
                r.hl = add16(r.hl, r.sp);
                return true;
            }
            return true;

          case 0x02: // ld (16)
            switch (op) {
              case 0x02: // ld (bc), a
                write(r.bc, r.a);
                cycles += 7;
                return true;
              case 0x12: // ld (de), a
                write(r.de, r.a);
                cycles += 7;
                return true;
              case 0x22: // ld (nn), hl
                final addr = pc16();
                write(addr, r.l);
                write(addr + 1, r.h);
                cycles += 16;
                return true;
              case 0x32: // ld (nn), a
                final addr = pc16();
                write(addr, r.a);
                cycles += 13;
                return true;
            }
            return true;

          case 0x0a: // ld (16)
            switch (op) {
              case 0x0a: // ld a, (bc)
                r.a = read(r.bc);
                cycles += 7;
                return true;
              case 0x1a: // ld a, (de)
                r.a = read(r.de);
                cycles += 7;
                return true;
              case 0x2a: // ld hl, (nn)
                final addr = pc16();
                r.l = read(addr);
                r.h = read(addr + 1);
                cycles += 16;
                return true;
              case 0x3a: // ld a, (nn)
                final addr = pc16();
                r.a = read(addr);
                cycles += 13;
                return true;
            }
            return true;

          case 0x03: // inc16
          case 0x0b: // dec16
            cycles += 6;
            switch (op) {
              case 0x03: // inc bc
                r.bc = (r.bc + 1) & 0xffff;
                return true;
              case 0x13: // inc de
                r.de = (r.de + 1) & 0xffff;
                return true;
              case 0x23: // inc hl
                r.hl = (r.hl + 1) & 0xffff;
                return true;
              case 0x33: // inc sp
                r.sp = (r.sp + 1) & 0xffff;
                return true;
              case 0x0b: // dec bc
                r.bc = (r.bc - 1) & 0xffff;
                return true;
              case 0x1b: // dec de
                r.de = (r.de - 1) & 0xffff;
                return true;
              case 0x2b: // dec hl
                r.hl = (r.hl - 1) & 0xffff;
                return true;
              case 0x3b: // dec sp
                r.sp = (r.sp - 1) & 0xffff;
                return true;
            }
            return true;

          case 0x04: // inc8
          case 0x0c: // inc8
            final reg = (op & 0x38) >> 3;
            writeReg(reg, inc8(readReg(reg)));
            if (reg == 6) {
              cycles++;
            }
            return true;
          case 0x05: // dec8
          case 0x0d: // dec8
            final reg = (op & 0x38) >> 3;
            writeReg(reg, dec8(readReg(reg)));
            if (reg == 6) {
              cycles++;
            }
            return true;

          case 0x06: // ld r,n
          case 0x0e: // ld r,n
            final reg = (op & 0x38) >> 3;
            writeReg(reg, pc());
            cycles += 7;
            return true;

          case 0x07: // alu
          case 0x0f: // alu
            switch (op) {
              case 0x07: // rlca
                r.a = rlc8(r.a, setSZP: false);
                cycles += 4;
                return true;
              case 0x17: // rla
                r.a = rl8(r.a, setSZP: false);
                cycles += 4;
                return true;
              case 0x27: // daa SZ-H-PNC
                final lowOver = (r.a & 0x0f) > 0x09;
                final highOver = (r.a & 0xf0) > (lowOver ? 0x80 : 0x90);
                int d = 0;
                d |= (r.hf || lowOver) ? 0x06 : 0x00;
                d |= (r.cf || highOver) ? 0x60 : 0x00;
                if (r.nf) {
                  d = r.a - d;
                } else {
                  d = r.a + d;
                }
                d &= 0xff;
                r.hf = (r.a ^ d) & 0x10 != 0;
                r.a = d;
                r.setP(r.a);
                r.setSZ(r.a);
                r.cf = r.cf || highOver;
                cycles += 4;
                return true;
              case 0x37: // scf
                r.cf = true;
                r.hf = false;
                r.nf = false;
                cycles += 4;
                return true;
              case 0x0f: // rrca
                r.a = rrc8(r.a, setSZP: false);
                cycles += 4;
                return true;
              case 0x1f: // rra
                r.a = rr8(r.a, setSZP: false);
                cycles += 4;
                return true;
              case 0x2f: // cpl
                r.a = ~r.a & 0xff;
                r.hf = true;
                r.nf = true;
                cycles += 4;
                return true;
              case 0x3f: // ccf
                r.hf = r.cf;
                r.cf = !r.cf;
                r.nf = false;
                cycles += 4;
                return true;
            }
            return true;
        }
    }

    return false;
  }
}
