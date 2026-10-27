import 'dart:typed_data';

/// Memory interface of the IOP.
abstract class IopBus {
  int read8(int address);
  int read16(int address);
  int read32(int address);
  void write8(int address, int value);
  void write16(int address, int value);
  void write32(int address, int value);
}

/// The I/O processor: a MIPS I (R3000A class) CPU without the GTE.
/// Exceptions and the load delay slot follow the MIPS I architecture.
class Iop {
  static const cop0BadVAddr = 8, cop0Status = 12, cop0Cause = 13, cop0Epc = 14;
  static const cop0PrId = 15;
  static const resetVector = 0xbfc00000;

  static const excInterrupt = 0, excAdEL = 4, excAdES = 5, excSyscall = 8;
  static const excBreak = 9, excReserved = 10, excCopUnusable = 11;
  static const excOverflow = 12;

  final IopBus bus;
  final r = Uint32List(32);
  int pc = resetVector;
  int nextPc = resetVector + 4;
  int hi = 0, lo = 0;
  final cop0 = Uint32List(32);

  /// the number of instructions executed
  int clocks = 0;

  bool _inDelaySlot = false;

  /// set by a branch or jump: the next instruction is its delay slot
  bool _isBranch = false;

  /// a load in flight: the register becomes visible after the next instruction
  int _loadReg = 0, _loadValue = 0;

  /// the load issued by the previous instruction, still invisible to it
  int _flightReg = 0, _flightValue = 0;

  /// the address of the instruction being executed
  int _currentPc = resetVector;

  bool _hwInterrupt = false;

  Iop(this.bus) {
    reset();
  }

  void reset() {
    r.fillRange(0, 32, 0);
    cop0.fillRange(0, 32, 0);
    cop0[cop0Status] = 0x00400000; // BEV
    cop0[cop0PrId] = 0x1f;
    pc = resetVector;
    nextPc = resetVector + 4;
    hi = lo = 0;
    _inDelaySlot = _isBranch = false;
    _loadReg = _flightReg = 0;
    _hwInterrupt = false;
  }

  /// the interrupt line, seen as Cause.IP2
  void setInterrupt(bool asserted) {
    _hwInterrupt = asserted;
  }

  void jump(int address) {
    pc = address;
    nextPc = address + 4;
    _inDelaySlot = _isBranch = false;
  }

  bool get _isolated => cop0[cop0Status] & 0x10000 != 0;

  void _exception(int code, {int coprocessor = 0}) {
    final sr = cop0[cop0Status];
    final bev = sr & 0x00400000 != 0;
    var cause = cop0[cop0Cause] & ~0x8000007c & ~0x30000000;
    cause |= code << 2;
    cause |= coprocessor << 28;
    if (_inDelaySlot) {
      cop0[cop0Epc] = _currentPc - 4;
      cause |= 0x80000000;
    } else {
      cop0[cop0Epc] = _currentPc;
    }
    cop0[cop0Cause] = cause;
    cop0[cop0Status] = (sr & ~0x3f) | ((sr << 2) & 0x3c);
    final vector = bev ? 0xbfc00180 : 0x80000080;
    pc = vector;
    nextPc = vector + 4;
    _inDelaySlot = _isBranch = false;
    _loadReg = 0;
  }

  void _setReg(int n, int v) {
    if (n != 0) r[n] = v;
  }

  void _load(int n, int v) {
    // a load overrides a pending load to the same register
    _loadReg = n;
    _loadValue = v;
  }

  /// Executes one instruction.
  void step() {
    clocks++;
    final cause = cop0[cop0Cause];
    final ip = (cause & 0x300) | (_hwInterrupt ? 0x400 : 0);
    cop0[cop0Cause] = (cause & ~0x400) | (_hwInterrupt ? 0x400 : 0);
    final sr = cop0[cop0Status];
    final at = pc;
    _currentPc = at;
    _inDelaySlot = _isBranch;
    if (sr & 1 != 0 && (ip & sr & 0xff00) != 0) {
      // the interrupted instruction is not executed; EPC points at it. The
      // load of the previous instruction still completes.
      if (_loadReg != 0) r[_loadReg] = _loadValue;
      r[0] = 0;
      _exception(excInterrupt);
      return;
    }

    final ir = bus.read32(at);
    pc = nextPc;
    nextPc = pc + 4;
    _isBranch = false;

    // The load issued by the previous instruction lands after this one reads
    // its operands, so it is applied once this instruction is done.
    _flightReg = _loadReg;
    _flightValue = _loadValue;
    _loadReg = 0;
    _execute(ir, at);
    if (_flightReg != 0 && _loadReg != _flightReg) {
      r[_flightReg] = _flightValue;
    }
    _flightReg = 0;
    r[0] = 0;
  }

  void _branch(bool taken, int at, int imm) {
    _isBranch = true;
    if (taken) nextPc = (at + 4 + (imm << 2)) & 0xffffffff;
  }

  void _takeBranch(int target) {
    _isBranch = true;
    nextPc = target;
  }

  void _execute(int ir, int at) {
    final op = ir >>> 26;
    final rs = (ir >> 21) & 31, rt = (ir >> 16) & 31, rd = (ir >> 11) & 31;
    final imm = (ir & 0xffff).toSigned(16);
    final immu = ir & 0xffff;
    switch (op) {
      case 0:
        _special(ir, at, rs, rt, rd);
      case 1:
        final link = (rt & 0x1e) == 0x10;
        final neg = r[rs].toSigned(32) < 0;
        final taken = (rt & 1) != 0 ? !neg : neg;
        if (link) _setReg(31, at + 8);
        _branch(taken, at, imm);
      case 2:
        _takeBranch(((at + 4) & 0xf0000000) | ((ir & 0x3ffffff) << 2));
      case 3:
        _setReg(31, at + 8);
        _takeBranch(((at + 4) & 0xf0000000) | ((ir & 0x3ffffff) << 2));
      case 4:
        _branch(r[rs] == r[rt], at, imm);
      case 5:
        _branch(r[rs] != r[rt], at, imm);
      case 6:
        _branch(r[rs].toSigned(32) <= 0, at, imm);
      case 7:
        _branch(r[rs].toSigned(32) > 0, at, imm);
      case 8: // ADDI
        final a = r[rs].toSigned(32), v = a + imm;
        if (v != v.toSigned(32)) {
          _exception(excOverflow);
        } else {
          _setReg(rt, v & 0xffffffff);
        }
      case 9:
        _setReg(rt, (r[rs] + imm) & 0xffffffff);
      case 10:
        _setReg(rt, r[rs].toSigned(32) < imm ? 1 : 0);
      case 11:
        _setReg(rt, r[rs] < (imm & 0xffffffff) ? 1 : 0);
      case 12:
        _setReg(rt, r[rs] & immu);
      case 13:
        _setReg(rt, r[rs] | immu);
      case 14:
        _setReg(rt, r[rs] ^ immu);
      case 15:
        _setReg(rt, immu << 16);
      case 16:
        _cop0(ir, rs, rt, rd);
      case 17 || 19:
        _exception(excCopUnusable, coprocessor: op & 3);
      case 18:
        // COP2 (GTE) does not exist on the IOP
        _exception(excCopUnusable, coprocessor: 2);
      case 32: // LB
        final a = (r[rs] + imm) & 0xffffffff;
        _load(rt, bus.read8(a).toSigned(8) & 0xffffffff);
      case 33: // LH
        final a = (r[rs] + imm) & 0xffffffff;
        if (a & 1 != 0) {
          cop0[cop0BadVAddr] = a;
          _exception(excAdEL);
        } else {
          _load(rt, bus.read16(a).toSigned(16) & 0xffffffff);
        }
      case 34: // LWL
        final a = (r[rs] + imm) & 0xffffffff;
        final word = bus.read32(a & ~3);
        final cur = _flightReg == rt ? _flightValue : r[rt];
        final s = (a & 3) * 8;
        _load(rt,
            ((word << (24 - s)) & 0xffffffff) | (cur & ((1 << (24 - s)) - 1)));
      case 35: // LW
        final a = (r[rs] + imm) & 0xffffffff;
        if (a & 3 != 0) {
          cop0[cop0BadVAddr] = a;
          _exception(excAdEL);
        } else {
          _load(rt, bus.read32(a));
        }
      case 36:
        _load(rt, bus.read8((r[rs] + imm) & 0xffffffff));
      case 37:
        final a = (r[rs] + imm) & 0xffffffff;
        if (a & 1 != 0) {
          cop0[cop0BadVAddr] = a;
          _exception(excAdEL);
        } else {
          _load(rt, bus.read16(a));
        }
      case 38: // LWR
        final a = (r[rs] + imm) & 0xffffffff;
        final word = bus.read32(a & ~3);
        final cur = _flightReg == rt ? _flightValue : r[rt];
        final s = (a & 3) * 8;
        final keep = s == 0 ? 0 : (0xffffffff << (32 - s)) & 0xffffffff;
        _load(rt, (word >>> s) | (cur & keep));
      case 40: // SB
        if (!_isolated) bus.write8((r[rs] + imm) & 0xffffffff, r[rt] & 0xff);
      case 41: // SH
        final a = (r[rs] + imm) & 0xffffffff;
        if (a & 1 != 0) {
          cop0[cop0BadVAddr] = a;
          _exception(excAdES);
        } else if (!_isolated) {
          bus.write16(a, r[rt] & 0xffff);
        }
      case 42: // SWL
        final a = (r[rs] + imm) & 0xffffffff;
        final word = bus.read32(a & ~3);
        final s = (a & 3) * 8;
        final keep = s == 24 ? 0 : (0xffffffff << (s + 8)) & 0xffffffff;
        if (!_isolated) {
          bus.write32(a & ~3, (word & keep) | (r[rt] >>> (24 - s)));
        }
      case 43: // SW
        final a = (r[rs] + imm) & 0xffffffff;
        if (a & 3 != 0) {
          cop0[cop0BadVAddr] = a;
          _exception(excAdES);
        } else if (!_isolated) {
          bus.write32(a, r[rt]);
        }
      case 46: // SWR
        final a = (r[rs] + imm) & 0xffffffff;
        final word = bus.read32(a & ~3);
        final s = (a & 3) * 8;
        final keep = (1 << s) - 1;
        if (!_isolated) {
          bus.write32(a & ~3, (word & keep) | ((r[rt] << s) & 0xffffffff));
        }
      default:
        _exception(excReserved);
    }
  }

  void _special(int ir, int at, int rs, int rt, int rd) {
    final sa = (ir >> 6) & 31;
    switch (ir & 0x3f) {
      case 0:
        _setReg(rd, (r[rt] << sa) & 0xffffffff);
      case 2:
        _setReg(rd, r[rt] >>> sa);
      case 3:
        _setReg(rd, (r[rt].toSigned(32) >> sa) & 0xffffffff);
      case 4:
        _setReg(rd, (r[rt] << (r[rs] & 31)) & 0xffffffff);
      case 6:
        _setReg(rd, r[rt] >>> (r[rs] & 31));
      case 7:
        _setReg(rd, (r[rt].toSigned(32) >> (r[rs] & 31)) & 0xffffffff);
      case 8: // JR
        _takeBranch(r[rs]);
      case 9: // JALR
        final target = r[rs];
        _setReg(rd, at + 8);
        _takeBranch(target);
      case 12:
        _exception(excSyscall);
      case 13:
        _exception(excBreak);
      case 16:
        _setReg(rd, hi);
      case 17:
        hi = r[rs];
      case 18:
        _setReg(rd, lo);
      case 19:
        lo = r[rs];
      case 24: // MULT
        final p = r[rs].toSigned(32) * r[rt].toSigned(32);
        lo = p & 0xffffffff;
        hi = (p >> 32) & 0xffffffff;
      case 25: // MULTU
        final a = r[rs], b = r[rt];
        lo = (a * b) & 0xffffffff;
        // the 64-bit product can exceed a Dart int, so split it
        final aLo = a & 0xffff, aHi = a >>> 16;
        final p0 = aLo * b, p1 = aHi * b;
        hi = ((p1 + (p0 >>> 16)) >>> 16) & 0xffffffff;
      case 26: // DIV
        final a = r[rs].toSigned(32), b = r[rt].toSigned(32);
        if (b == 0) {
          lo = a < 0 ? 1 : 0xffffffff;
          hi = a & 0xffffffff;
        } else if (a == -0x80000000 && b == -1) {
          lo = 0x80000000;
          hi = 0;
        } else {
          lo = (a ~/ b) & 0xffffffff;
          hi = a.remainder(b) & 0xffffffff;
        }
      case 27: // DIVU
        final a = r[rs], b = r[rt];
        if (b == 0) {
          lo = 0xffffffff;
          hi = a;
        } else {
          lo = a ~/ b;
          hi = a % b;
        }
      case 32: // ADD
        final v = r[rs].toSigned(32) + r[rt].toSigned(32);
        if (v != v.toSigned(32)) {
          _exception(excOverflow);
        } else {
          _setReg(rd, v & 0xffffffff);
        }
      case 33:
        _setReg(rd, (r[rs] + r[rt]) & 0xffffffff);
      case 34: // SUB
        final v = r[rs].toSigned(32) - r[rt].toSigned(32);
        if (v != v.toSigned(32)) {
          _exception(excOverflow);
        } else {
          _setReg(rd, v & 0xffffffff);
        }
      case 35:
        _setReg(rd, (r[rs] - r[rt]) & 0xffffffff);
      case 36:
        _setReg(rd, r[rs] & r[rt]);
      case 37:
        _setReg(rd, r[rs] | r[rt]);
      case 38:
        _setReg(rd, r[rs] ^ r[rt]);
      case 39:
        _setReg(rd, ~(r[rs] | r[rt]) & 0xffffffff);
      case 42:
        _setReg(rd, r[rs].toSigned(32) < r[rt].toSigned(32) ? 1 : 0);
      case 43:
        _setReg(rd, r[rs] < r[rt] ? 1 : 0);
      default:
        _exception(excReserved);
    }
  }

  void _cop0(int ir, int rs, int rt, int rd) {
    switch (rs) {
      case 0: // MFC0
        _load(rt, cop0[rd]);
      case 4: // MTC0
        final v = r[rt];
        switch (rd) {
          case cop0Cause:
            cop0[rd] = (cop0[rd] & ~0x300) | (v & 0x300);
          case cop0Status:
            cop0[rd] = v;
          case 3 || 5 || 6 || 7 || 9 || 11:
            cop0[rd] = v; // breakpoint registers: stored only
          default:
            break;
        }
      default:
        if (ir & 0x3f == 0x10) {
          // RFE: pop the mode stack
          final sr = cop0[cop0Status];
          cop0[cop0Status] = (sr & ~0xf) | ((sr >> 2) & 0xf);
        } else {
          _exception(excReserved);
        }
    }
  }
}
