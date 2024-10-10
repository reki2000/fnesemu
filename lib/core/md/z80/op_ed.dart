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
        write(regs.de, read(regs.hl));
        regs.de = (regs.de + repDirection) & 0xffff;
        regs.hl = (regs.hl + repDirection) & 0xffff;
        regs.bc = (regs.bc - 1) & 0xffff;
        regs.flagN = false;
        regs.flagH = false;
        regs.flagPV = true;
        if (regs.bc == 0) {
          regs.flagPV = false;
          repLoop = false;
        }
        break;

      case Z80.repCp: // cp
        final val = read(regs.hl);
        regs.hl = (regs.hl + repDirection) & 0xffff;
        regs.bc = (regs.bc - 1) & 0xffff;
        regs.flagN = true;
        regs.flagH = false; // todo
        regs.flagPV = true;
        regs.setFlagsSZ(regs.a);
        if (regs.a == val) {
          repLoop = false;
        }
        if (regs.bc == 0) {
          repLoop = false;
          regs.flagPV = false;
        }
        break;

      case Z80.repIn: // in
        write(regs.hl, input(regs.c));
        regs.hl = (regs.hl + repDirection) & 0xffff;
        regs.b = (regs.b - 1) & 0xff;
        regs.flagN = true;
        regs.flagZ = false;
        if (regs.b == 0) {
          repMode = 0;
          regs.flagZ = true;
        }
        break;

      case Z80.repOut: // out
        output(regs.c, read(regs.hl));
        regs.hl = (regs.hl + repDirection) & 0xffff;
        regs.b = (regs.b - 1) & 0xff;
        regs.flagN = true;
        regs.flagZ = false;
        if (regs.b == 0) {
          repMode = 0;
          regs.flagZ = true;
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
        regs.hl = sbc16(regs.hl, regs.bc);
        cycles += 15;
        return true;
      case 0x52: // sbc hl, de
        regs.hl = sbc16(regs.hl, regs.de);
        cycles += 15;
        return true;
      case 0x62: // sbc hl, hl
        regs.hl = sbc16(regs.hl, regs.hl);
        cycles += 15;
        return true;
      case 0x72: // sbc hl, sp
        regs.hl = sbc16(regs.hl, regs.sp);
        cycles += 15;
        return true;
      case 0x4a: // adc hl, bc
        regs.hl = add16(regs.hl, regs.bc, c: 1);
        cycles += 15;
        return true;
      case 0x5a: // adc hl, de
        regs.hl = add16(regs.hl, regs.de, c: 1);
        cycles += 15;
        return true;
      case 0x6a: // adc hl, hl
        regs.hl = add16(regs.hl, regs.hl, c: 1);
        cycles += 15;
        return true;
      case 0x7a: // adc hl, sp
        regs.hl = add16(regs.hl, regs.sp, c: 1);
        cycles += 15;
        return true;

      case 0x43: // ld (nn), bc
        final addr = pc16();
        write(addr, regs.c);
        write(addr + 1, regs.b);
        cycles += 20;
        return true;
      case 0x53: // ld (nn), de
        final addr = pc16();
        write(addr, regs.e);
        write(addr + 1, regs.d);
        cycles += 20;
        return true;
      case 0x63: // ld (nn), hl
        final addr = pc16();
        write(addr, regs.l);
        write(addr + 1, regs.h);
        cycles += 20;
        return true;
      case 0x73: // ld (nn), sp
        final addr = pc16();
        write(addr, regs.sp & 0xff);
        write(addr + 1, regs.sp >> 8);
        cycles += 20;
        return true;
      case 0x4b: // ld bc, (nn)
        final addr = pc16();
        regs.c = read(addr);
        regs.b = read(addr + 1);
        cycles += 20;
        return true;
      case 0x5b: // ld de, (nn)
        final addr = pc16();
        regs.e = read(addr);
        regs.d = read(addr + 1);
        cycles += 20;
        return true;
      case 0x6b: // ld hl, (nn)
        final addr = pc16();
        regs.l = read(addr);
        regs.h = read(addr + 1);
        cycles += 20;
        return true;
      case 0x7b: // ld sp, (nn)
        final addr = pc16();
        regs.sp = read(addr) | (read(addr + 1) << 8);
        cycles += 20;
        return true;

      case 0x44: // neg
        sub8(0, regs.a);
        cycles += 8;
        return true;

      case 0x4d: // reti
        regs.pc = pop();
        iff1 = iff2;
        cycles += 14;
        return true;
      case 0x45: // retn
        regs.pc = pop();
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
        regs.i = regs.a;
        cycles += 9;
        return true;
      case 0x4f: // ld r, a
        cycles += 9;
        return true;
      case 0x57: // ld a, i
        regs.a = regs.i;
        regs.setFlagsSZ(regs.a);
        regs.flagPV = iff2;
        regs.flagH = false;
        regs.flagN = false;
        cycles += 9;
        return true;
      case 0x5f: // ld a, r
        regs.a = regs.r; // todo: random
        cycles += 9;
        return true;

      case 0x67: // rrd
        final addr = regs.hl;
        final val = read(addr);
        write(addr, (regs.a >> 4) | ((val & 0x0f) << 4));
        regs.a = (regs.a & 0xf0) | (val >> 4);
        regs.setFlagsSZ(regs.a);
        regs.setFlagsP(regs.a);
        regs.flagH = false;
        regs.flagN = false;
        cycles += 18;
        return true;
      case 0x6f: // rld
        final addr = regs.hl;
        final val = read(addr);
        write(addr, ((regs.a & 0x0f) << 4) | (val >> 4));
        regs.a = (regs.a & 0xf0) | (val & 0x0f);
        regs.setFlagsSZ(regs.a);
        regs.setFlagsP(regs.a);
        regs.flagH = false;
        regs.flagN = false;
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
        final result = input(regs.c);
        regs.r8[reg] = result;
        regs.setFlagsSZ(result);
        regs.setFlagsP(result);
        regs.flagN = false;
        regs.flagH = false;
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
        output(regs.c, regs.r8[reg]);
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
