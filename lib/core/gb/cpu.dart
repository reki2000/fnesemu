import 'package:fnesemu/util/int.dart';

import 'bus.dart';

/// SM83 cpu core. every memory access consumes one machine cycle (4 clocks)
/// by calling the bus, and internal delays are ticked explicitly.
class Cpu {
  static const flagZ = 0x80;
  static const flagN = 0x40;
  static const flagH = 0x20;
  static const flagC = 0x10;

  final Bus bus;

  int a = 0, f = 0, b = 0, c = 0, d = 0, e = 0, h = 0, l = 0;
  int sp = 0, pc = 0;

  bool ime = false;
  bool halted = false;

  // counts instructions until IME becomes enabled after EI
  int _eiDelay = 0;

  // HALT bug: the next opcode fetch does not increment PC
  bool _haltBug = false;

  Cpu(this.bus);

  int get af => a.shl8 | f;
  int get bc => b.shl8 | c;
  int get de => d.shl8 | e;
  int get hl => h.shl8 | l;

  set af(int v) {
    a = v.shr8.mask8;
    f = v & 0xf0;
  }

  set bc(int v) {
    b = v.shr8.mask8;
    c = v.mask8;
  }

  set de(int v) {
    d = v.shr8.mask8;
    e = v.mask8;
  }

  set hl(int v) {
    h = v.shr8.mask8;
    l = v.mask8;
  }

  /// sets the register state which the boot program leaves
  void reset() {
    af = 0x01b0;
    bc = 0x0013;
    de = 0x00d8;
    hl = 0x014d;
    sp = 0xfffe;
    pc = 0x0100;
    ime = false;
    halted = false;
    _eiDelay = 0;
    _haltBug = false;
  }

  @pragma('vm:prefer-inline')
  int _read(int addr) => bus.readTick(addr);

  @pragma('vm:prefer-inline')
  void _write(int addr, int data) => bus.writeTick(addr, data);

  @pragma('vm:prefer-inline')
  void _idle() => bus.tick();

  @pragma('vm:prefer-inline')
  int _fetch() {
    final v = bus.readTick(pc);
    pc = (pc + 1).mask16;
    return v;
  }

  int _fetch16() {
    final lo = _fetch();
    return _fetch().shl8 | lo;
  }

  void _push(int v) {
    sp = (sp - 1).mask16;
    _write(sp, v.shr8.mask8);
    sp = (sp - 1).mask16;
    _write(sp, v.mask8);
  }

  int _pop() {
    final lo = _read(sp);
    sp = (sp + 1).mask16;
    final hi = _read(sp);
    sp = (sp + 1).mask16;
    return hi.shl8 | lo;
  }

  /// executes one instruction, one halted cycle, or an interrupt dispatch.
  /// returns false when the cpu is locked up by an illegal opcode.
  bool exec() {
    final pending = bus.ie & bus.intFlag.mask5;

    if (halted) {
      if (pending == 0) {
        _idle();
        return true;
      }
      halted = false;
      _idle();
    }

    if (ime && pending != 0) {
      _interrupt();
      return true;
    }

    final op = _fetch();
    if (_haltBug) {
      pc = (pc - 1).mask16;
      _haltBug = false;
    }

    final ok = _execOp(op);

    if (_eiDelay > 0) {
      _eiDelay--;
      if (_eiDelay == 0) {
        ime = true;
      }
    }

    return ok;
  }

  void _interrupt() {
    ime = false;
    _idle();
    _idle();

    sp = (sp - 1).mask16;
    _write(sp, pc.shr8);

    // the vector is determined after the upper byte push (it may overwrite IE)
    final pending = bus.ie & bus.intFlag.mask5;

    sp = (sp - 1).mask16;
    _write(sp, pc.mask8);

    if (pending == 0) {
      pc = 0;
    } else {
      for (int i = 0; i < 5; i++) {
        if (pending & (1 << i) != 0) {
          bus.intFlag &= ~(1 << i);
          pc = 0x40 + i * 8;
          break;
        }
      }
    }

    _idle();
  }

  // register access by 3bit index: B C D E H L (HL) A
  int _getR(int i) => switch (i) {
        0 => b,
        1 => c,
        2 => d,
        3 => e,
        4 => h,
        5 => l,
        6 => _read(hl),
        _ => a,
      };

  void _setR(int i, int v) {
    switch (i) {
      case 0:
        b = v;
      case 1:
        c = v;
      case 2:
        d = v;
      case 3:
        e = v;
      case 4:
        h = v;
      case 5:
        l = v;
      case 6:
        _write(hl, v);
      default:
        a = v;
    }
  }

  // 16bit register pair by 2bit index: BC DE HL SP
  int _getRR(int i) => switch (i) { 0 => bc, 1 => de, 2 => hl, _ => sp };

  void _setRR(int i, int v) {
    switch (i) {
      case 0:
        bc = v;
      case 1:
        de = v;
      case 2:
        hl = v;
      default:
        sp = v.mask16;
    }
  }

  bool _cond(int i) => switch (i) {
        0 => f & flagZ == 0,
        1 => f & flagZ != 0,
        2 => f & flagC == 0,
        _ => f & flagC != 0,
      };

  // ALU

  void _alu(int op, int v) {
    switch (op) {
      case 0: // ADD
        final r = a + v;
        f = (r.mask8 == 0 ? flagZ : 0) |
            (a.mask4 + v.mask4 > 0xf ? flagH : 0) |
            (r > 0xff ? flagC : 0);
        a = r.mask8;
      case 1: // ADC
        final cy = f.shr4.mask1;
        final r = a + v + cy;
        f = (r.mask8 == 0 ? flagZ : 0) |
            (a.mask4 + v.mask4 + cy > 0xf ? flagH : 0) |
            (r > 0xff ? flagC : 0);
        a = r.mask8;
      case 2: // SUB
        final r = a - v;
        f = flagN |
            (r.mask8 == 0 ? flagZ : 0) |
            (a.mask4 - v.mask4 < 0 ? flagH : 0) |
            (r < 0 ? flagC : 0);
        a = r.mask8;
      case 3: // SBC
        final cy = f.shr4.mask1;
        final r = a - v - cy;
        f = flagN |
            (r.mask8 == 0 ? flagZ : 0) |
            (a.mask4 - v.mask4 - cy < 0 ? flagH : 0) |
            (r < 0 ? flagC : 0);
        a = r.mask8;
      case 4: // AND
        a &= v;
        f = (a == 0 ? flagZ : 0) | flagH;
      case 5: // XOR
        a ^= v;
        f = a == 0 ? flagZ : 0;
      case 6: // OR
        a |= v;
        f = a == 0 ? flagZ : 0;
      default: // CP
        final r = a - v;
        f = flagN |
            (r.mask8 == 0 ? flagZ : 0) |
            (a.mask4 - v.mask4 < 0 ? flagH : 0) |
            (r < 0 ? flagC : 0);
    }
  }

  int _inc8(int v) {
    final r = (v + 1).mask8;
    f = f & flagC | (r == 0 ? flagZ : 0) | (r.mask4 == 0 ? flagH : 0);
    return r;
  }

  int _dec8(int v) {
    final r = (v - 1).mask8;
    f = (f & flagC) |
        flagN |
        (r == 0 ? flagZ : 0) |
        (r.mask4 == 0xf ? flagH : 0);
    return r;
  }

  void _addHl(int v) {
    final r = hl + v;
    f = (f & flagZ) |
        (hl.mask12 + v.mask12 > 0xfff ? flagH : 0) |
        (r > 0xffff ? flagC : 0);
    hl = r.mask16;
  }

  // SP + signed 8bit, flags are computed from the unsigned lower byte
  int _addSp(int e8) {
    f = (sp.mask4 + e8.mask4 > 0xf ? flagH : 0) |
        (sp.mask8 + e8 > 0xff ? flagC : 0);
    return (sp + e8.rel8).mask16;
  }

  void _daa() {
    var r = a;
    var carry = f & flagC != 0;
    if (f & flagN == 0) {
      if (carry || r > 0x99) {
        r += 0x60;
        carry = true;
      }
      if (f & flagH != 0 || r.mask4 > 9) {
        r += 0x06;
      }
    } else {
      if (carry) {
        r -= 0x60;
      }
      if (f & flagH != 0) {
        r -= 0x06;
      }
    }
    a = r.mask8;
    f = (f & flagN) | (a == 0 ? flagZ : 0) | (carry ? flagC : 0);
  }

  // rotate/shift of CB-prefixed instructions
  int _rot(int op, int v) {
    int r;
    int cy;
    switch (op) {
      case 0: // RLC
        cy = v.shr7;
        r = (v.shl1 | cy).mask8;
      case 1: // RRC
        cy = v.mask1;
        r = v.shr1 | cy.shl7;
      case 2: // RL
        cy = v.shr7;
        r = (v.shl1 | f.shr4.mask1).mask8;
      case 3: // RR
        cy = v.mask1;
        r = v.shr1 | f.shr4.mask1.shl7;
      case 4: // SLA
        cy = v.shr7;
        r = v.shl1.mask8;
      case 5: // SRA
        cy = v.mask1;
        r = v.shr1 | v & 0x80;
      case 6: // SWAP
        cy = 0;
        r = (v.shl4 | v.shr4).mask8;
      default: // SRL
        cy = v.mask1;
        r = v.shr1;
    }
    f = (r == 0 ? flagZ : 0) | (cy != 0 ? flagC : 0);
    return r;
  }

  void _execCb() {
    final op = _fetch();
    final reg = op.mask3;
    final bit = op.shr3.mask3;

    switch (op.shr6) {
      case 0:
        _setR(reg, _rot(bit, _getR(reg)));
      case 1: // BIT
        final v = _getR(reg);
        f = (f & flagC) | flagH | (v & (1 << bit) == 0 ? flagZ : 0);
      case 2: // RES
        _setR(reg, _getR(reg) & ~(1 << bit));
      default: // SET
        _setR(reg, _getR(reg) | (1 << bit));
    }
  }

  bool _execOp(int op) {
    // LD r, r' / HALT
    if (op >= 0x40 && op < 0x80) {
      if (op == 0x76) {
        _halt();
      } else {
        _setR(op.shr3.mask3, _getR(op.mask3));
      }
      return true;
    }

    // ALU A, r
    if (op >= 0x80 && op < 0xc0) {
      _alu(op.shr3.mask3, _getR(op.mask3));
      return true;
    }

    switch (op) {
      case 0x00: // NOP
        break;

      case 0x01 || 0x11 || 0x21 || 0x31: // LD rr, d16
        _setRR(op.shr4, _fetch16());

      case 0x02: // LD (BC), A
        _write(bc, a);
      case 0x12: // LD (DE), A
        _write(de, a);
      case 0x22: // LD (HL+), A
        _write(hl, a);
        hl = (hl + 1).mask16;
      case 0x32: // LD (HL-), A
        _write(hl, a);
        hl = (hl - 1).mask16;

      case 0x0a: // LD A, (BC)
        a = _read(bc);
      case 0x1a: // LD A, (DE)
        a = _read(de);
      case 0x2a: // LD A, (HL+)
        a = _read(hl);
        hl = (hl + 1).mask16;
      case 0x3a: // LD A, (HL-)
        a = _read(hl);
        hl = (hl - 1).mask16;

      case 0x03 || 0x13 || 0x23 || 0x33: // INC rr
        _setRR(op.shr4, (_getRR(op.shr4) + 1).mask16);
        _idle();
      case 0x0b || 0x1b || 0x2b || 0x3b: // DEC rr
        _setRR(op.shr4, (_getRR(op.shr4) - 1).mask16);
        _idle();

      case 0x04 || 0x0c || 0x14 || 0x1c || 0x24 || 0x2c || 0x34 || 0x3c:
        final r = op.shr3.mask3; // INC r
        _setR(r, _inc8(_getR(r)));
      case 0x05 || 0x0d || 0x15 || 0x1d || 0x25 || 0x2d || 0x35 || 0x3d:
        final r = op.shr3.mask3; // DEC r
        _setR(r, _dec8(_getR(r)));
      case 0x06 || 0x0e || 0x16 || 0x1e || 0x26 || 0x2e || 0x36 || 0x3e:
        final v = _fetch(); // LD r, d8
        _setR(op.shr3.mask3, v);

      case 0x07: // RLCA
        a = _rot(0, a);
        f &= flagC;
      case 0x0f: // RRCA
        a = _rot(1, a);
        f &= flagC;
      case 0x17: // RLA
        a = _rot(2, a);
        f &= flagC;
      case 0x1f: // RRA
        a = _rot(3, a);
        f &= flagC;

      case 0x08: // LD (a16), SP
        final addr = _fetch16();
        _write(addr, sp.mask8);
        _write((addr + 1).mask16, sp.shr8);

      case 0x09 || 0x19 || 0x29 || 0x39: // ADD HL, rr
        _addHl(_getRR(op.shr4));
        _idle();

      case 0x10: // STOP
        _fetch();
        bus.timer.writeDiv();

      case 0x18: // JR r8
        final e8 = _fetch();
        pc = (pc + e8.rel8).mask16;
        _idle();
      case 0x20 || 0x28 || 0x30 || 0x38: // JR cc, r8
        final e8 = _fetch();
        if (_cond(op.shr3.mask2)) {
          pc = (pc + e8.rel8).mask16;
          _idle();
        }

      case 0x27: // DAA
        _daa();
      case 0x2f: // CPL
        a ^= 0xff;
        f |= flagN | flagH;
      case 0x37: // SCF
        f = (f & flagZ) | flagC;
      case 0x3f: // CCF
        f = (f & flagZ) | ((f & flagC) ^ flagC);

      case 0xc0 || 0xc8 || 0xd0 || 0xd8: // RET cc
        _idle();
        if (_cond(op.shr3.mask2)) {
          pc = _pop();
          _idle();
        }
      case 0xc9: // RET
        pc = _pop();
        _idle();
      case 0xd9: // RETI
        pc = _pop();
        _idle();
        ime = true;
        _eiDelay = 0;

      case 0xc1 || 0xd1 || 0xe1: // POP rr
        _setRR(op.shr4.mask2, _pop());
      case 0xf1: // POP AF
        af = _pop();
      case 0xc5 || 0xd5 || 0xe5: // PUSH rr
        _idle();
        _push(_getRR(op.shr4.mask2));
      case 0xf5: // PUSH AF
        _idle();
        _push(af);

      case 0xc2 || 0xca || 0xd2 || 0xda: // JP cc, a16
        final addr = _fetch16();
        if (_cond(op.shr3.mask2)) {
          pc = addr;
          _idle();
        }
      case 0xc3: // JP a16
        pc = _fetch16();
        _idle();
      case 0xe9: // JP HL
        pc = hl;

      case 0xc4 || 0xcc || 0xd4 || 0xdc: // CALL cc, a16
        final addr = _fetch16();
        if (_cond(op.shr3.mask2)) {
          _idle();
          _push(pc);
          pc = addr;
        }
      case 0xcd: // CALL a16
        final addr = _fetch16();
        _idle();
        _push(pc);
        pc = addr;

      case 0xc7 || 0xcf || 0xd7 || 0xdf || 0xe7 || 0xef || 0xf7 || 0xff:
        _idle(); // RST
        _push(pc);
        pc = op & 0x38;

      case 0xc6 || 0xce || 0xd6 || 0xde || 0xe6 || 0xee || 0xf6 || 0xfe:
        _alu(op.shr3.mask3, _fetch()); // ALU A, d8

      case 0xcb:
        _execCb();

      case 0xe0: // LDH (a8), A
        _write(0xff00 | _fetch(), a);
      case 0xf0: // LDH A, (a8)
        a = _read(0xff00 | _fetch());
      case 0xe2: // LD (C), A
        _write(0xff00 | c, a);
      case 0xf2: // LD A, (C)
        a = _read(0xff00 | c);
      case 0xea: // LD (a16), A
        _write(_fetch16(), a);
      case 0xfa: // LD A, (a16)
        a = _read(_fetch16());

      case 0xe8: // ADD SP, r8
        sp = _addSp(_fetch());
        _idle();
        _idle();
      case 0xf8: // LD HL, SP+r8
        hl = _addSp(_fetch());
        _idle();
      case 0xf9: // LD SP, HL
        sp = hl;
        _idle();

      case 0xf3: // DI
        ime = false;
        _eiDelay = 0;
      case 0xfb: // EI
        if (!ime && _eiDelay == 0) {
          _eiDelay = 2;
        }

      default: // illegal opcodes lock up the cpu
        pc = (pc - 1).mask16;
        return false;
    }

    return true;
  }

  void _halt() {
    if (!ime && bus.ie & bus.intFlag.mask5 != 0) {
      _haltBug = true;
    } else {
      halted = true;
    }
  }

  String dump() => "A:${a.x2} F:${_flags()} BC:${bc.x4} DE:${de.x4} "
      "HL:${hl.x4} SP:${sp.x4} PC:${pc.x4} "
      "IME:${ime ? 1 : 0}${halted ? " HALT" : ""}";

  String _flags() => [
        f & flagZ != 0 ? "Z" : "-",
        f & flagN != 0 ? "N" : "-",
        f & flagH != 0 ? "H" : "-",
        f & flagC != 0 ? "C" : "-",
      ].join();
}
