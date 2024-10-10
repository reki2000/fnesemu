import 'z80.dart';

extension OpC0ff on Z80 {
  bool cond(int op) => switch (op & 0xf0) {
        0xc0 => !regs.flagZ,
        0xd0 => !regs.flagC,
        0xe0 => !regs.flagPV,
        0xf0 => !regs.flagS,
        0xc8 => regs.flagZ,
        0xd8 => regs.flagC,
        0xe8 => regs.flagPV,
        0xf8 => regs.flagS,
        _ => false,
      };

  bool execC0ff(int op) {
    switch (op & 0x07) {
      case 0x00: // ret
        if (cond(op)) {
          regs.pc = pop();
          cycles += 11;
        } else {
          cycles += 5;
        }
        return true;
      case 0x01: // pop
        switch (op) {
          case 0xc1: // pop bc
            regs.bc = pop();
            cycles += 10;
            return true;
          case 0xd1: // pop de
            regs.de = pop();
            cycles += 10;
            return true;
          case 0xe1: // pop hl
            regs.hl = pop();
            cycles += 10;
            return true;
          case 0xf1: // pop af
            regs.af = pop();
            cycles += 10;
            return true;
          case 0xc9: // ret
            regs.pc = pop();
            cycles += 10;
            return true;
          case 0xd9: // exx
            final tmp = regs.bc;
            regs.bc = regs.bc2;
            regs.bc2 = tmp;
            final tmp2 = regs.de;
            regs.de = regs.de2;
            regs.de2 = tmp2;
            final tmp3 = regs.hl;
            regs.hl = regs.hl2;
            regs.hl2 = tmp3;
            cycles += 4;
            return true;
          case 0xe9: // jp hl
            regs.pc = regs.hl;
            cycles += 4;
            return true;
          case 0xf9: // ld sp, hl
            regs.sp = regs.hl;
            cycles += 6;
            return true;
        }
        break;
      case 0x02: // jp
        if (cond(op)) {
          regs.pc = pc16();
        }
        cycles += 10;
        return true;
      case 0x03: // jp2
        switch (op) {
          case 0xc3: // jp nn
            regs.pc = pc16();
            cycles += 10;
            return true;
          case 0xd3: // out (n), a
            output(pc(), regs.a);
            cycles += 11;
            return true;
          case 0xe3: // ex (sp), hl
            final tmp = read(regs.sp);
            write(regs.sp, regs.l);
            regs.l = tmp;
            final sp2 = regs.sp + 1;
            final tmp2 = read(sp2);
            write(sp2, regs.h);
            regs.h = tmp2;
            cycles += 19;
            return true;
          case 0xf3: // di
            iff1 = iff2 = false;
            cycles += 4;
            return true;
          case 0xdb: // in a, (n)
            regs.a = input(pc());
            cycles += 11;
            return true;
          case 0xeb: // ex de, hl
            final tmp = regs.de;
            regs.de = regs.hl;
            regs.hl = tmp;
            cycles += 4;
            return true;
          case 0xfb: // ei
            iff1 = iff2 = true;
            cycles += 4;
            return true;
        }
        return true;
      case 0x04: // call
        if (cond(op)) {
          push(regs.pc);
          regs.pc = pc16();
          cycles += 17;
        } else {
          cycles += 10;
        }
        return true;
      case 0x05: // push
        switch (op) {
          case 0xc5: // push bc
            push(regs.bc);
            cycles += 11;
            return true;
          case 0xd5: // push de
            push(regs.de);
            cycles += 11;
            return true;
          case 0xe5: // push hl
            push(regs.hl);
            cycles += 11;
            return true;
          case 0xf5: // push af
            push(regs.af);
            cycles += 11;
            return true;
          case 0xcd: // call nn
            push(regs.pc);
            regs.pc = pc16();
            cycles += 17;
            return true;
        }
        return true;
      case 0x06: // alu
        final val = pc();
        cycles += 7;
        switch (op) {
          case 0xc6: // add a, n
            add8(val, 0);
            return true;
          case 0xd6: // sub n
            sub8(val, 0);
            return true;
          case 0xe6: // and n
            and8(val);
            return true;
          case 0xf6: // or n
            or8(val);
            return true;
          case 0xce: // adc a, n
            add8(val, regs.flagC ? 1 : 0);
            return true;
          case 0xde: // sbc a, n
            sub8(val, regs.flagC ? 1 : 0);
            return true;
          case 0xee: // xor n
            xor8(val);
            return true;
          case 0xfe: // cp n
            cp8(val);
            return true;
        }
        return true;
      case 0x07: // rst
        final addr = op & 0x38;
        push(regs.pc);
        regs.pc = addr;
        cycles += 11;
        return true;
    }

    return false;
  }
}
