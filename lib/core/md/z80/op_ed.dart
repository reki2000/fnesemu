import 'package:fnesemu/util/util.dart';

import 'z80.dart';

extension OpEd on Z80 {
  bool repLd(int repDirection) {
    write(r.de, read(r.hl));
    cycles += 6;
    r.de = (r.de + repDirection) & 0xffff;
    r.hl = (r.hl + repDirection) & 0xffff;
    r.bc = (r.bc - 1) & 0xffff;
    r.nf = false;
    r.hf = false;
    r.pvf = true;

    cycles += 2;
    if (r.bc == 0) {
      r.pvf = false;
      return false;
    }
    return true;
  }

  bool repCp(int repDirection) {
    final val = read(r.hl);
    cycles += 6;
    r.hl = (r.hl + repDirection) & 0xffff;
    r.bc = (r.bc - 1) & 0xffff;

    final res = r.a - val;
    r.hf = (r.a ^ val ^ res) & Regs.H != 0;
    r.nf = true;
    r.pvf = true;
    r.setSZ(res);

    cycles += 2;
    if (r.a == val) {
      return false;
    } else if (r.bc == 0) {
      r.pvf = false;
      return false;
    }
    return true;
  }

  bool repIn(int repDirection) {
    final val = input(r.c);
    write(r.hl, val);
    cycles += 6;
    r.hl = (r.hl + repDirection) & 0xffff;
    r.b = (r.b - 1) & 0xff;

    final t = ((r.c + repDirection) & 0xff) + val;
    r.nf = val & Regs.S != 0;
    r.cf = r.hf = t & 0x100 != 0;
    r.setP((t & 0x07) ^ r.b);
    r.setSZ(r.b);

    cycles += 2;
    if (r.b == 0) {
      return false;
    }
    return true;
  }

  bool repOut(int repDirection) {
    final val = read(r.hl);
    output(r.c, val);
    cycles += 6;
    r.hl = (r.hl + repDirection) & 0xffff;
    r.b = (r.b - 1) & 0xff;

    final t = r.l + val;
    r.nf = val & Regs.S != 0;
    r.cf = r.hf = t & 0x100 != 0;
    r.setP((t & 0x07) ^ r.b);
    r.setSZ(r.b);

    cycles += 2;
    if (r.b == 0) {
      return false;
    }
    return true;
  }

  bool execEd(int op) {
    switch (op) {
      case 0x42: // sbc hl, bc
        final oldH = r.h;
        r.hl = sbc16(r.hl, r.bc);
        r.setSZ(r.h);
        r.setV(oldH, r.b, r.h, sub: true);
        return true;
      case 0x52: // sbc hl, de
        final oldH = r.h;
        r.hl = sbc16(r.hl, r.de);
        r.setSZ(r.h);
        r.setV(oldH, r.d, r.h, sub: true);
        return true;
      case 0x62: // sbc hl, hl
        final oldH = r.h;
        r.hl = sbc16(r.hl, r.hl);
        r.setSZ(r.h);
        r.setV(oldH, oldH, r.h, sub: true);
        return true;
      case 0x72: // sbc hl, sp
        final oldH = r.h;
        r.hl = sbc16(r.hl, r.sp);
        r.setV(oldH, r.sp >> 8, r.h, sub: true);
        r.setSZ(r.h);
        return true;
      case 0x4a: // adc hl, bc
        final oldH = r.h;
        r.hl = add16(r.hl, r.bc, c: r.cf ? 1 : 0);
        r.setV(oldH, r.b, r.h);
        r.setSZ(r.h);
        return true;
      case 0x5a: // adc hl, de
        final oldH = r.h;
        r.hl = add16(r.hl, r.de, c: r.cf ? 1 : 0);
        r.setV(oldH, r.d, r.h);
        r.setSZ(r.h);
        return true;
      case 0x6a: // adc hl, hl
        final oldH = r.h;
        r.hl = add16(r.hl, r.hl, c: r.cf ? 1 : 0);
        r.setV(oldH, oldH, r.h);
        r.setSZ(r.h);
        return true;
      case 0x7a: // adc hl, sp
        final oldH = r.h;
        r.hl = add16(r.hl, r.sp, c: r.cf ? 1 : 0);
        r.setV(oldH, r.sp >> 8, r.h);
        r.setSZ(r.h);
        return true;

      case 0x43: // ld (nn), bc
        final addr = pc16();
        write(addr, r.c);
        write(addr + 1, r.b);
        cycles += 6;
        return true;
      case 0x53: // ld (nn), de
        final addr = pc16();
        write(addr, r.e);
        write(addr + 1, r.d);
        cycles += 6;
        return true;
      case 0x63: // ld (nn), hl
        final addr = pc16();
        write(addr, r.l);
        write(addr + 1, r.h);
        cycles += 6;
        return true;
      case 0x73: // ld (nn), sp
        final addr = pc16();
        write(addr, r.sp & 0xff);
        write(addr + 1, r.sp >> 8);
        cycles += 6;
        return true;
      case 0x4b: // ld bc, (nn)
        final addr = pc16();
        r.c = read(addr);
        r.b = read(addr + 1);
        cycles += 6;
        return true;
      case 0x5b: // ld de, (nn)
        final addr = pc16();
        r.e = read(addr);
        r.d = read(addr + 1);
        cycles += 6;
        return true;
      case 0x6b: // ld hl, (nn)
        final addr = pc16();
        r.l = read(addr);
        r.h = read(addr + 1);
        cycles += 6;
        return true;
      case 0x7b: // ld sp, (nn)
        final addr = pc16();
        r.sp = read(addr).withHighByte(read(addr + 1));
        cycles += 6;
        return true;

      case 0x44: // neg
      case 0x4c: // undocumented neg
      case 0x54:
      case 0x5c:
      case 0x64:
      case 0x6c:
      case 0x74:
      case 0x7c:
        final result = 0 - r.a;
        r.setSZ(result);
        r.setV(r.a, r.a, result, sub: true);
        r.hf = 0 < (r.a & 0xf);
        r.nf = true;
        r.cf = result < 0;
        r.a = result & 0xff;
        return true;

      case 0x4d: // reti
      case 0x5d:
      case 0x6d:
      case 0x7d:
        r.pc = pop();
        return true;
      case 0x45: // retn
      case 0x55:
      case 0x65:
      case 0x75:
        r.pc = pop();
        iff1 = iff2;
        return true;
      case 0x46: // im 0
      case 0x4e: // im 0 undocumented
      case 0x66:
        im = 0;
        return true;
      case 0x56: // im 1
      case 0x76:
        im = 1;
        return true;
      case 0x5e: // im 2
      case 0x7e:
        im = 2;
        return true;

      case 0x47: // ld i, a
        r.i = r.a;
        cycles += 1;
        return true;
      case 0x4f: // ld r, a
        r.r = r.a;
        cycles += 1;
        return true;
      case 0x57: // ld a, i
        r.a = r.i;
        r.setSZ(r.a);
        r.pvf = iff2;
        r.hf = false;
        r.nf = false;
        cycles += 1;
        return true;
      case 0x5f: // ld a, r
        r.a = r.r; // todo: random
        r.setSZ(r.a);
        r.nf = false;
        r.hf = false;
        r.pvf = false;
        cycles += 1;
        return true;

      case 0x67: // rrd
        final addr = r.hl;
        final val = read(addr);
        write(addr, (val >> 4) | (r.a << 4) & 0xf0);
        r.a = (r.a & 0xf0) | (val & 0x0f);
        r.setSZ(r.a);
        r.setP(r.a);
        r.hf = false;
        r.nf = false;
        cycles += 10;
        return true;
      case 0x6f: // rld
        final addr = r.hl;
        final val = read(addr);
        write(addr, r.a & 0x0f | (val << 4) & 0xf0);
        r.a = (r.a & 0xf0) | (val >> 4);
        r.setSZ(r.a);
        r.setP(r.a);
        r.hf = false;
        r.nf = false;
        cycles += 10;
        return true;

      case 0x40: // in b, (c)
      case 0x48: // in c, (c)
      case 0x50: // in d, (c)
      case 0x58: // in e, (c)
      case 0x60: // in h, (c)
      case 0x68: // in l, (c)
      case 0x78: // in a, (c)
        final reg = (op & 0x38) >> 3;
        final result = input(r.c);
        r.r8[reg] = result;
        r.setSZ(result);
        r.setP(result);
        r.nf = false;
        r.hf = false;
        cycles += 4;
        return true;
      case 0x070: // in (c)
        final result = input(r.c);
        r.setSZ(result);
        r.setP(result);
        r.nf = false;
        r.hf = false;
        cycles += 4;
        return true;

      case 0x41: // out (c), b
      case 0x49: // out (c), c
      case 0x51: // out (c), d
      case 0x59: // out (c), e
      case 0x61: // out (c), h
      case 0x69: // out (c), l
      case 0x79: // out (c), a
        final reg = (op & 0x38 >> 3);
        output(r.c, r.r8[reg]);
        cycles += 4;
        return true;
      case 0x71: // out (c), 0
        output(r.c, 0);
        cycles += 4;
        return true;

      case 0xa0: // ldi
        repLd(1);
        return true;
      case 0xa8: // ldd
        repLd(-1);
        return true;
      case 0xb0: // ldir
        if (repLd(1)) {
          cycles += 5;
          r.pc = (r.pc - 2) & 0xffff;
        }
        return true;
      case 0xb8: // lddr
        if (repLd(-1)) {
          cycles += 5;
          r.pc = (r.pc - 2) & 0xffff;
        }
        return true;

      case 0xa1: // cpi
        repCp(1);
        return true;
      case 0xa9: // cpd
        repCp(-1);
        return true;
      case 0xb1: // cpir
        if (repCp(1)) {
          cycles += 5;
          r.pc = (r.pc - 2) & 0xffff;
        }
        return true;
      case 0xb9: // cpdr
        if (repCp(-1)) {
          cycles += 5;
          r.pc = (r.pc - 2) & 0xffff;
        }
        return true;

      case 0xa2: // ini
        repIn(1);
        return true;
      case 0xaa: // ind
        repIn(-1);
        return true;
      case 0xb2: // inir
        if (repIn(1)) {
          cycles += 5;
          r.pc = (r.pc - 2) & 0xffff;
        }
        return true;
      case 0xba: // indr
        if (repIn(-1)) {
          cycles += 5;
          r.pc = (r.pc - 2) & 0xffff;
        }
        return true;

      case 0xa3: // outi
        repOut(1);
        return true;
      case 0xab: // outd
        repOut(-1);
        return true;
      case 0xb3: // otir
        if (repOut(1)) {
          cycles += 5;
          r.pc = (r.pc - 2) & 0xffff;
        }
        return true;
      case 0xbb: // otdr
        if (repOut(-1)) {
          cycles += 5;
          r.pc = (r.pc - 2) & 0xffff;
        }
        return true;
    }

    return false;
  }
}
