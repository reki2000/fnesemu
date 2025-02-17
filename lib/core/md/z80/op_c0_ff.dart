import 'z80.dart';

extension OpC0ff on Z80 {
  bool cond(int op) => switch (op & 0xf8) {
        0xc0 => !r.zf,
        0xd0 => !r.cf,
        0xe0 => !r.pvf,
        0xf0 => !r.sf,
        0xc8 => r.zf,
        0xd8 => r.cf,
        0xe8 => r.pvf,
        0xf8 => r.sf,
        _ => throw ("unreachable"),
      };

  bool execC0ff(int op) {
    switch (op & 0x07) {
      case 0x00: // ret
        if (cond(op)) {
          r.pc = pop();
        }
        cycles += 1;
        return true;
      case 0x01: // pop
        switch (op) {
          case 0xc1: // pop bc
            r.bc = pop();
            return true;
          case 0xd1: // pop de
            r.de = pop();
            return true;
          case 0xe1: // pop hl
            r.hl = pop();
            return true;
          case 0xf1: // pop af
            r.af = pop();
            return true;
          case 0xc9: // ret
            r.pc = pop();
            return true;
          case 0xd9: // exx
            final tmp = r.bc;
            r.bc = r.bc2;
            r.bc2 = tmp;
            final tmp2 = r.de;
            r.de = r.de2;
            r.de2 = tmp2;
            final tmp3 = r.hl;
            r.hl = r.hl2;
            r.hl2 = tmp3;
            return true;
          case 0xe9: // jp (hl)
            r.pc = r.hl;
            return true;
          case 0xf9: // ld sp, hl
            r.sp = r.hl;
            cycles += 2;
            return true;
        }

        throw ("unreachable");

      case 0x02: // jp
        final addr = pc16();
        if (cond(op)) {
          r.pc = addr;
        }
        return true;

      case 0x03: // jp2
        switch (op) {
          case 0xc3: // jp nn
            r.pc = pc16();
            return true;
          case 0xd3: // out (n), a
            output(pc8(), r.a);
            cycles += 4;
            return true;
          case 0xe3: // ex (sp), hl
            final tmp = read(r.sp);
            write(r.sp, r.l);
            r.l = tmp;
            final sp2 = r.sp + 1;
            final tmp2 = read(sp2);
            write(sp2, r.h);
            r.h = tmp2;
            cycles += 15;
            return true;
          case 0xf3: // di
            iff1 = false;
            iff2 = false;
            return true;
          case 0xdb: // in a, (n)
            r.a = input(pc8());
            cycles += 4;
            return true;
          case 0xeb: // ex de, hl
            final tmp = r.de;
            r.de = r.hl;
            r.hl = tmp;
            return true;
          case 0xfb: // ei
            eiDelay = true;
            return true;
        }

        throw ("unreachable");

      case 0x04: // call
        final addr = pc16();
        if (cond(op)) {
          push(r.pc);
          r.pc = addr;
        }
        return true;

      case 0x05: // push
        switch (op) {
          case 0xc5: // push bc
            push(r.bc);
            return true;
          case 0xd5: // push de
            push(r.de);
            return true;
          case 0xe5: // push hl
            push(r.hl);
            return true;
          case 0xf5: // push af
            push(r.af);
            return true;
          case 0xcd: // call nn
            final addr = pc16();
            push(r.pc);
            r.pc = addr;
            return true;
        }

        throw ("unreachable");

      case 0x06: // alu
        final val = pc8();
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
            add8(val, r.cf ? 1 : 0);
            return true;
          case 0xde: // sbc a, n
            sub8(val, r.cf ? 1 : 0);
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
        push(r.pc);
        r.pc = op & 0x38;
        return true;
    }

    return false;
  }
}
