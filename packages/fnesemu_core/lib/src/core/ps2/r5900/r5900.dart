import 'dart:typed_data';

import '../bus.dart';
import 'fpu.dart';
import 'mmi.dart';

/// The EE core. General registers are 128 bits wide and are stored as two
/// adjacent 64-bit words: register `n` occupies `gpr[2n]` (bits 63..0) and
/// `gpr[2n + 1]` (bits 127..64). Most instructions touch only the low word.
///
/// Not implemented yet: TLB, COP2, address and trap exceptions
/// other than arithmetic overflow, and timing beyond one clock per
/// instruction.
class R5900 {
  static const resetVector = 0xbfc00000;
  static const _signBit = -0x8000000000000000;

  // COP0 registers and bits
  static const cop0Count = 9, cop0Status = 12, cop0Cause = 13, cop0Epc = 14;
  static const cop0ErrorEpc = 30;
  static const _statusExl = 1 << 1, _statusErl = 1 << 2, _statusBev = 1 << 22;
  static const _statusEie = 1 << 16;
  static const _causeBd = 1 << 31;

  // exception codes
  static const excInterrupt = 0, excOverflow = 12, excSyscall = 8;
  static const excBreak = 9;

  final Ps2Bus bus;
  final Int64List gpr = Int64List(64);
  int hi = 0, lo = 0, hi1 = 0, lo1 = 0;
  int sa = 0;
  int pc = resetVector;
  int nextPc = resetVector + 4;
  final Uint32List cop0 = Uint32List(32);

  /// COP1 registers: 32 single precision images, the accumulator and FCR31
  final Uint32List fpr = Uint32List(32);
  int facc = 0;
  int fcr31 = 0;

  /// elapsed clocks
  int clocks = 0;

  /// set when an instruction this core does not implement was fetched
  int? unimplementedInstruction;
  int unimplementedPc = 0;

  bool _branchPending = false;
  bool _inDelaySlot = false;

  R5900(this.bus) {
    reset();
  }

  void reset() {
    gpr.fillRange(0, gpr.length, 0);
    hi = lo = hi1 = lo1 = sa = 0;
    pc = resetVector;
    nextPc = resetVector + 4;
    cop0.fillRange(0, 32, 0);
    fpr.fillRange(0, 32, 0);
    facc = fcr31 = 0;
    cop0[cop0Status] = _statusBev | _statusErl | 0x70000000;
    clocks = 0;
    _branchPending = _inDelaySlot = false;
    unimplementedInstruction = null;
  }

  /// the low 64 bits of register [n]
  int reg(int n) => gpr[n * 2];

  void setReg(int n, int value) {
    if (n != 0) gpr[n * 2] = value;
  }

  void jumpTo(int address) {
    pc = address;
    nextPc = address + 4;
    _branchPending = false;
  }

  /// Runs one instruction. Returns false when it is not implemented; the
  /// state then still points at it.
  bool step() {
    final at = pc;
    final ir = bus.read32(at);
    _inDelaySlot = _branchPending;
    _branchPending = false;
    pc = nextPc;
    nextPc = pc + 4;
    clocks++;
    cop0[cop0Count]++;
    final ok = _execute(ir, at);
    gpr[0] = 0;
    gpr[1] = 0;
    if (!ok) {
      unimplementedInstruction = ir;
      unimplementedPc = at;
      pc = at;
      nextPc = at + 4;
      clocks--;
      _branchPending = _inDelaySlot;
    }
    return ok;
  }

  void _exception(int code, int at) {
    final status = cop0[cop0Status];
    var cause = cop0[cop0Cause] & ~(0x1f << 2) & ~_causeBd;
    cause |= code << 2;
    if (status & _statusExl == 0) {
      cop0[cop0Epc] = _inDelaySlot ? at - 4 : at;
      if (_inDelaySlot) cause |= _causeBd;
    }
    cop0[cop0Cause] = cause;
    cop0[cop0Status] = status | _statusExl;
    jumpTo(status & _statusBev != 0 ? 0xbfc00380 : 0x80000180);
    _branchPending = false;
  }

  void _branch(bool taken, int at, int imm) {
    _branchPending = true;
    if (taken) nextPc = (at + 4 + (imm.toSigned(16) << 2)) & 0xffffffff;
  }

  /// branch likely: a not-taken branch skips its delay slot
  void _branchLikely(bool taken, int at, int imm) {
    if (taken) {
      _branch(true, at, imm);
    } else {
      pc = nextPc;
      nextPc = pc + 4;
    }
  }

  bool _lessUnsigned(int a, int b) => (a ^ _signBit) < (b ^ _signBit);

  int _signExtend32(int v) => v.toSigned(32);

  bool _execute(int ir, int at) {
    final op = ir >>> 26;
    final rs = (ir >>> 21) & 31, rt = (ir >>> 16) & 31, rd = (ir >>> 11) & 31;
    final imm = ir & 0xffff;
    final simm = imm.toSigned(16);
    switch (op) {
      case 0:
        return _special(ir, at, rs, rt, rd);
      case 1:
        return _regimm(at, rs, rt, imm);
      case 2:
        _branchPending = true;
        nextPc = (at & 0xf0000000) | ((ir & 0x3ffffff) << 2);
      case 3:
        setReg(31, at + 8);
        _branchPending = true;
        nextPc = (at & 0xf0000000) | ((ir & 0x3ffffff) << 2);
      case 4:
        _branch(reg(rs) == reg(rt), at, imm);
      case 5:
        _branch(reg(rs) != reg(rt), at, imm);
      case 6:
        _branch(reg(rs) <= 0, at, imm);
      case 7:
        _branch(reg(rs) > 0, at, imm);
      case 8: // ADDI
        final r = reg(rs) + simm;
        if (r != r.toSigned(32)) {
          _exception(excOverflow, at);
        } else {
          setReg(rt, r);
        }
      case 9: // ADDIU
        setReg(rt, _signExtend32(reg(rs) + simm));
      case 10:
        setReg(rt, reg(rs) < simm ? 1 : 0);
      case 11:
        setReg(rt, _lessUnsigned(reg(rs), simm) ? 1 : 0);
      case 12:
        setReg(rt, reg(rs) & imm);
      case 13:
        setReg(rt, reg(rs) | imm);
      case 14:
        setReg(rt, reg(rs) ^ imm);
      case 15:
        setReg(rt, _signExtend32(imm << 16));
      case 16:
        return _cop0(ir, at, rs, rt, rd);
      case 28:
        return executeMmi(ir, at);
      case 17:
        if (rs == 8) {
          final c = fcr31 & R5900Fpu.conditionBit != 0;
          switch (rt) {
            case 0:
              _branch(!c, at, imm);
            case 1:
              _branch(c, at, imm);
            case 2:
              _branchLikely(!c, at, imm);
            case 3:
              _branchLikely(c, at, imm);
            default:
              return false;
          }
          break;
        }
        return executeCop1(ir);
      case 49: // LWC1
        fpr[rt] = bus.read32(reg(rs) + simm);
      case 57: // SWC1
        bus.write32(reg(rs) + simm, fpr[rt]);
      case 20:
        _branchLikely(reg(rs) == reg(rt), at, imm);
      case 21:
        _branchLikely(reg(rs) != reg(rt), at, imm);
      case 22:
        _branchLikely(reg(rs) <= 0, at, imm);
      case 23:
        _branchLikely(reg(rs) > 0, at, imm);
      case 24: // DADDI
        final a = reg(rs), r = a + simm;
        if (((a ^ r) & (simm ^ r)) < 0) {
          _exception(excOverflow, at);
        } else {
          setReg(rt, r);
        }
      case 25:
        setReg(rt, reg(rs) + simm);
      case 26:
        setReg(rt, _loadLeftRight(reg(rs) + simm, 8, true, reg(rt)));
      case 27:
        setReg(rt, _loadLeftRight(reg(rs) + simm, 8, false, reg(rt)));
      case 32:
        setReg(rt, bus.read8(reg(rs) + simm).toSigned(8));
      case 33:
        setReg(rt, bus.read16(reg(rs) + simm).toSigned(16));
      case 34:
        setReg(rt,
            _signExtend32(_loadLeftRight(reg(rs) + simm, 4, true, reg(rt))));
      case 35:
        setReg(rt, _signExtend32(bus.read32(reg(rs) + simm)));
      case 36:
        setReg(rt, bus.read8(reg(rs) + simm));
      case 37:
        setReg(rt, bus.read16(reg(rs) + simm));
      case 38:
        final addr = reg(rs) + simm;
        final v = _loadLeftRight(addr, 4, false, reg(rt));
        setReg(
            rt,
            addr & 3 == 0
                ? _signExtend32(v)
                : (reg(rt) & ~0xffffffff) | (v & 0xffffffff));
      case 39:
        setReg(rt, bus.read32(reg(rs) + simm));
      case 40:
        bus.write8(reg(rs) + simm, reg(rt));
      case 41:
        bus.write16(reg(rs) + simm, reg(rt));
      case 42:
        _storeLeftRight(reg(rs) + simm, 4, true, reg(rt));
      case 43:
        bus.write32(reg(rs) + simm, reg(rt));
      case 44:
        _storeLeftRight(reg(rs) + simm, 8, true, reg(rt));
      case 45:
        _storeLeftRight(reg(rs) + simm, 8, false, reg(rt));
      case 46:
        _storeLeftRight(reg(rs) + simm, 4, false, reg(rt));
      case 47: // CACHE
        break;
      case 51: // PREF
        break;
      case 30: // LQ
        final addr = (reg(rs) + simm) & ~15;
        setReg(rt, bus.read64(addr));
        if (rt != 0) gpr[rt * 2 + 1] = bus.read64(addr + 8);
      case 31: // SQ
        final addr = (reg(rs) + simm) & ~15;
        bus.write64(addr, reg(rt));
        bus.write64(addr + 8, gpr[rt * 2 + 1]);
      case 55:
        setReg(rt, bus.read64(reg(rs) + simm));
      case 63:
        bus.write64(reg(rs) + simm, reg(rt));
      default:
        return false;
    }
    return true;
  }

  bool _special(int ir, int at, int rs, int rt, int rd) {
    final fn = ir & 63;
    final shift = (ir >>> 6) & 31;
    final a = reg(rs), b = reg(rt);
    switch (fn) {
      case 0:
        setReg(rd, _signExtend32(b << shift));
      case 2:
        setReg(rd, _signExtend32((b & 0xffffffff) >>> shift));
      case 3:
        setReg(rd, _signExtend32(b) >> shift);
      case 4:
        setReg(rd, _signExtend32(b << (a & 31)));
      case 6:
        setReg(rd, _signExtend32((b & 0xffffffff) >>> (a & 31)));
      case 7:
        setReg(rd, _signExtend32(b) >> (a & 31));
      case 8:
        _branchPending = true;
        nextPc = a & 0xffffffff;
      case 9:
        final target = a & 0xffffffff;
        setReg(rd, at + 8);
        _branchPending = true;
        nextPc = target;
      case 10:
        if (b == 0) setReg(rd, a);
      case 11:
        if (b != 0) setReg(rd, a);
      case 12:
        _exception(excSyscall, at);
      case 13:
        _exception(excBreak, at);
      case 15: // SYNC
        break;
      case 16:
        setReg(rd, hi);
      case 17:
        hi = a;
      case 18:
        setReg(rd, lo);
      case 19:
        lo = a;
      case 20:
        setReg(rd, b << (a & 63));
      case 22:
        setReg(rd, b >>> (a & 63));
      case 23:
        setReg(rd, b >> (a & 63));
      case 24: // MULT; the R5900 also writes the low word to rd
        final p = _signExtend32(a) * _signExtend32(b);
        lo = _signExtend32(p);
        hi = p >> 32;
        setReg(rd, lo);
      case 25: // MULTU
        final p = (a & 0xffffffff) * (b & 0xffffffff);
        lo = _signExtend32(p);
        hi = _signExtend32(p >> 32);
        setReg(rd, lo);
      case 26:
        _divide(a, b);
      case 27:
        _divideUnsigned(a, b);
      case 32:
        final r = _signExtend32(a) + _signExtend32(b);
        if (r != r.toSigned(32)) {
          _exception(excOverflow, at);
        } else {
          setReg(rd, r);
        }
      case 33:
        setReg(rd, _signExtend32(a + b));
      case 34:
        final r = _signExtend32(a) - _signExtend32(b);
        if (r != r.toSigned(32)) {
          _exception(excOverflow, at);
        } else {
          setReg(rd, r);
        }
      case 35:
        setReg(rd, _signExtend32(a - b));
      case 36:
        setReg(rd, a & b);
      case 37:
        setReg(rd, a | b);
      case 38:
        setReg(rd, a ^ b);
      case 39:
        setReg(rd, ~(a | b));
      case 40: // MFSA
        setReg(rd, sa);
      case 41: // MTSA
        sa = a & 15;
      case 42:
        setReg(rd, a < b ? 1 : 0);
      case 43:
        setReg(rd, _lessUnsigned(a, b) ? 1 : 0);
      case 44:
        final r = a + b;
        if (((a ^ r) & (b ^ r)) < 0) {
          _exception(excOverflow, at);
        } else {
          setReg(rd, r);
        }
      case 45:
        setReg(rd, a + b);
      case 46:
        final r = a - b;
        if (((a ^ b) & (a ^ r)) < 0) {
          _exception(excOverflow, at);
        } else {
          setReg(rd, r);
        }
      case 47:
        setReg(rd, a - b);
      case 56:
        setReg(rd, b << shift);
      case 58:
        setReg(rd, b >>> shift);
      case 59:
        setReg(rd, b >> shift);
      case 60:
        setReg(rd, b << (shift + 32));
      case 62:
        setReg(rd, b >>> (shift + 32));
      case 63:
        setReg(rd, b >> (shift + 32));
      default:
        return false;
    }
    return true;
  }

  void _divide(int a, int b) {
    final n = _signExtend32(a), d = _signExtend32(b);
    if (d == 0) {
      lo = n < 0 ? 1 : -1;
      hi = n;
    } else if (n == -0x80000000 && d == -1) {
      lo = n;
      hi = 0;
    } else {
      lo = n ~/ d;
      hi = n.remainder(d);
    }
  }

  void _divideUnsigned(int a, int b) {
    final n = a & 0xffffffff, d = b & 0xffffffff;
    if (d == 0) {
      lo = -1;
      hi = _signExtend32(n);
    } else {
      lo = _signExtend32(n ~/ d);
      hi = _signExtend32(n % d);
    }
  }

  bool _regimm(int at, int rs, int rt, int imm) {
    final a = reg(rs);
    switch (rt) {
      case 0:
        _branch(a < 0, at, imm);
      case 1:
        _branch(a >= 0, at, imm);
      case 2:
        _branchLikely(a < 0, at, imm);
      case 3:
        _branchLikely(a >= 0, at, imm);
      case 16:
        setReg(31, at + 8);
        _branch(a < 0, at, imm);
      case 17:
        setReg(31, at + 8);
        _branch(a >= 0, at, imm);
      case 18:
        setReg(31, at + 8);
        _branchLikely(a < 0, at, imm);
      case 19:
        setReg(31, at + 8);
        _branchLikely(a >= 0, at, imm);
      default:
        return false;
    }
    return true;
  }

  bool _cop0(int ir, int at, int rs, int rt, int rd) {
    switch (rs) {
      case 0:
        setReg(rt, _signExtend32(cop0[rd]));
      case 4:
        cop0[rd] = reg(rt);
      case 16:
        switch (ir & 63) {
          case 0x18: // ERET
            final status = cop0[cop0Status];
            if (status & _statusErl != 0) {
              cop0[cop0Status] = status & ~_statusErl;
              jumpTo(cop0[cop0ErrorEpc]);
            } else {
              cop0[cop0Status] = status & ~_statusExl;
              jumpTo(cop0[cop0Epc]);
            }
          case 0x38: // EI
            cop0[cop0Status] |= _statusEie;
          case 0x39: // DI
            cop0[cop0Status] &= ~_statusEie;
          default:
            return false;
        }
      default:
        return false;
    }
    return true;
  }

  /// LDL/LDR/LWL/LWR: merges the bytes from [addr] to the end of its aligned
  /// [size]-byte unit into [current]
  int _loadLeftRight(int addr, int size, bool left, int current) {
    final k = addr & (size - 1);
    final aligned = addr - k;
    var result = current;
    if (left) {
      for (var j = 0; j <= k; j++) {
        final shift = (size - 1 - k + j) * 8;
        result =
            (result & ~(0xff << shift)) | (bus.read8(aligned + j) << shift);
      }
    } else {
      for (var j = 0; j < size - k; j++) {
        result =
            (result & ~(0xff << (j * 8))) | (bus.read8(addr + j) << (j * 8));
      }
    }
    return result;
  }

  void _storeLeftRight(int addr, int size, bool left, int value) {
    final k = addr & (size - 1);
    final aligned = addr - k;
    if (left) {
      for (var j = 0; j <= k; j++) {
        bus.write8(aligned + j, value >>> ((size - 1 - k + j) * 8));
      }
    } else {
      for (var j = 0; j < size - k; j++) {
        bus.write8(addr + j, value >>> (j * 8));
      }
    }
  }
}
