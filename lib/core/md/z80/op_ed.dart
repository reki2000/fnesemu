import 'z80.dart';

extension OpEd on Z80 {
  bool _rep(int mode, int direction, bool loop) {
    repMode = mode;
    repDirection = direction;
    repLoop = loop;
    return true;
  }

  void doRep() {
    switch (repMode) {
      case Z80.repLd: // ld
        write(r.de, read(r.hl));
        r.de = (r.de + repDirection) & 0xffff;
        r.hl = (r.hl + repDirection) & 0xffff;
        r.bc = (r.bc - 1) & 0xffff;
        r.nf = false;
        r.hf = false;
        r.pvf = true;
        if (r.bc == 0) {
          r.pvf = false;
          repLoop = false;
        }
        break;

      case Z80.repCp: // cp
        final val = read(r.hl);
        r.hl = (r.hl + repDirection) & 0xffff;
        r.bc = (r.bc - 1) & 0xffff;
        r.nf = true;
        r.hf = false; // todo
        r.pvf = true;
        r.setSZ(r.a);
        if (r.a == val) {
          repLoop = false;
        }
        if (r.bc == 0) {
          repLoop = false;
          r.pvf = false;
        }
        break;

      case Z80.repIn: // in
        write(r.hl, input(r.c));
        r.hl = (r.hl + repDirection) & 0xffff;
        r.b = (r.b - 1) & 0xff;
        r.nf = true;
        r.zf = false;
        if (r.b == 0) {
          repMode = 0;
          r.zf = true;
        }
        break;

      case Z80.repOut: // out
        output(r.c, read(r.hl));
        r.hl = (r.hl + repDirection) & 0xffff;
        r.b = (r.b - 1) & 0xff;
        r.nf = true;
        r.zf = false;
        if (r.b == 0) {
          repMode = 0;
          r.zf = true;
        }
        break;

      default:
        throw Exception('Invalid rep mode');
    }

    if (!repLoop) {
      repMode = 0;
    }
    cycles += 5;
  }

  bool execEd(int op) {
    switch (op) {
      case 0x42: // sbc hl, bc
        r.hl = sbc16(r.hl, r.bc);
        cycles += 15;
        return true;
      case 0x52: // sbc hl, de
        r.hl = sbc16(r.hl, r.de);
        cycles += 15;
        return true;
      case 0x62: // sbc hl, hl
        r.hl = sbc16(r.hl, r.hl);
        cycles += 15;
        return true;
      case 0x72: // sbc hl, sp
        r.hl = sbc16(r.hl, r.sp);
        cycles += 15;
        return true;
      case 0x4a: // adc hl, bc
        r.hl = add16(r.hl, r.bc, c: 1);
        cycles += 15;
        return true;
      case 0x5a: // adc hl, de
        r.hl = add16(r.hl, r.de, c: 1);
        cycles += 15;
        return true;
      case 0x6a: // adc hl, hl
        r.hl = add16(r.hl, r.hl, c: 1);
        cycles += 15;
        return true;
      case 0x7a: // adc hl, sp
        r.hl = add16(r.hl, r.sp, c: 1);
        cycles += 15;
        return true;

      case 0x43: // ld (nn), bc
        final addr = pc16();
        write(addr, r.c);
        write(addr + 1, r.b);
        cycles += 20;
        return true;
      case 0x53: // ld (nn), de
        final addr = pc16();
        write(addr, r.e);
        write(addr + 1, r.d);
        cycles += 20;
        return true;
      case 0x63: // ld (nn), hl
        final addr = pc16();
        write(addr, r.l);
        write(addr + 1, r.h);
        cycles += 20;
        return true;
      case 0x73: // ld (nn), sp
        final addr = pc16();
        write(addr, r.sp & 0xff);
        write(addr + 1, r.sp >> 8);
        cycles += 20;
        return true;
      case 0x4b: // ld bc, (nn)
        final addr = pc16();
        r.c = read(addr);
        r.b = read(addr + 1);
        cycles += 20;
        return true;
      case 0x5b: // ld de, (nn)
        final addr = pc16();
        r.e = read(addr);
        r.d = read(addr + 1);
        cycles += 20;
        return true;
      case 0x6b: // ld hl, (nn)
        final addr = pc16();
        r.l = read(addr);
        r.h = read(addr + 1);
        cycles += 20;
        return true;
      case 0x7b: // ld sp, (nn)
        final addr = pc16();
        r.sp = read(addr) | (read(addr + 1) << 8);
        cycles += 20;
        return true;

      case 0x44: // neg
        sub8(0, r.a);
        cycles += 8;
        return true;

      case 0x4d: // reti
        r.pc = pop();
        iff1 = iff2;
        cycles += 14;
        return true;
      case 0x45: // retn
        r.pc = pop();
        iff1 = iff2;
        cycles += 14;
        return true;
      case 0x46: // im 0
        im = 0;
        cycles += 8;
        return true;
      case 0x56: // im 1
        im = 1;
        cycles += 8;
        return true;
      case 0x5e: // im 2
        im = 2;
        cycles += 8;
        return true;

      case 0x47: // ld i, a
        r.i = r.a;
        cycles += 9;
        return true;
      case 0x4f: // ld r, a
        cycles += 9;
        return true;
      case 0x57: // ld a, i
        r.a = r.i;
        r.setSZ(r.a);
        r.pvf = iff2;
        r.hf = false;
        r.nf = false;
        cycles += 9;
        return true;
      case 0x5f: // ld a, r
        r.a = r.r; // todo: random
        cycles += 9;
        return true;

      case 0x67: // rrd
        final addr = r.hl;
        final val = read(addr);
        write(addr, (r.a >> 4) | ((val & 0x0f) << 4));
        r.a = (r.a & 0xf0) | (val >> 4);
        r.setSZ(r.a);
        r.setP(r.a);
        r.hf = false;
        r.nf = false;
        cycles += 18;
        return true;
      case 0x6f: // rld
        final addr = r.hl;
        final val = read(addr);
        write(addr, ((r.a & 0x0f) << 4) | (val >> 4));
        r.a = (r.a & 0xf0) | (val & 0x0f);
        r.setSZ(r.a);
        r.setP(r.a);
        r.hf = false;
        r.nf = false;
        cycles += 18;
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
        cycles += 12;
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
        cycles += 12;
        return true;

      case 0xa0: // ldi
        return _rep(Z80.repLd, 1, false);
      case 0xa8: // ldd
        return _rep(Z80.repLd, -1, false);
      case 0xb0: // ldir
        return _rep(Z80.repLd, 1, true);
      case 0xb8: // lddr
        return _rep(Z80.repLd, -1, true);
      case 0xa1: // cpi
        return _rep(Z80.repCp, 1, false);
      case 0xa9: // cpd
        return _rep(Z80.repCp, -1, false);
      case 0xb1: // cpir
        return _rep(Z80.repCp, 1, true);
      case 0xb9: // cpdr
        return _rep(Z80.repCp, -1, true);
      case 0xa2: // ini
        return _rep(Z80.repIn, 1, false);
      case 0xaa: // ind
        return _rep(Z80.repIn, -1, false);
      case 0xb2: // inir
        return _rep(Z80.repIn, 1, true);
      case 0xba: // indr
        return _rep(Z80.repIn, -1, true);
      case 0xa3: // outi
        return _rep(Z80.repOut, 1, false);
      case 0xab: // outd
        return _rep(Z80.repOut, -1, false);
      case 0xb3: // otir
        return _rep(Z80.repOut, 1, true);
      case 0xbb: // otdr
        return _rep(Z80.repOut, -1, true);
    }

    return false;
  }
}
