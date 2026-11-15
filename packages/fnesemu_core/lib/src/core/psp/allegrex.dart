import 'dart:math' as math;
import 'dart:typed_data';

import 'memory.dart';
import 'vfpu.dart';

/// A saved processor state, swapped in and out by the thread scheduler.
class AllegrexState {
  final r = Int32List(32);
  final f = Float32List(32);
  final cop0 = Int32List(32);
  int hi = 0, lo = 0;
  int pc = 0, nextPc = 0;
  int fcr31 = 0;
  int fcc = 0; // eight condition bits, bit n is FCCn
  bool linked = false;

  /// The multimedia coprocessor register file: eight 4x4 matrices in
  /// row-major order, element (matrix, row, column) at
  /// `matrix * 16 + row * 4 + column`. The elements are raw float
  /// bit patterns: NaN payloads and signs are part of the state, and
  /// a detour through a Dart double would lose both. A fresh context
  /// holds the canonical NaN pattern, as the system's does.
  final v = Uint32List(128)..fillRange(0, 128, 0x7f800001);

  /// The pending operand prefixes, set by the prefix instructions and
  /// consumed by the next computational instruction. The defaults are
  /// the identity swizzle with no negation, absolute value, write mask
  /// or saturation.
  static const pfxDefault = 0x000000e4;
  static const pfxdDefault = 0x00000000;
  int vpfxs = pfxDefault, vpfxt = pfxDefault, vpfxd = pfxdDefault;

  /// The eight multimedia condition codes, bit n is code n.
  int vcc = 0;

  /// Result lanes an operation must write as zero, accumulated while
  /// it reads its sources through their prefixes (see vfpu.dart).
  int vfpuZeroLanes = 0;

  /// The state of the multimedia random generator: the eight control
  /// registers RCX0 to RCX7, each holding a float in [1, 2) whose
  /// mantissa carries the generator's state.
  final rcx = Uint32List(8);

  void copyFrom(AllegrexState other) {
    r.setAll(0, other.r);
    f.setAll(0, other.f);
    cop0.setAll(0, other.cop0);
    hi = other.hi;
    lo = other.lo;
    pc = other.pc;
    nextPc = other.nextPc;
    fcr31 = other.fcr31;
    fcc = other.fcc;
    linked = other.linked;
    v.setAll(0, other.v);
    vpfxs = other.vpfxs;
    vpfxt = other.vpfxt;
    vpfxd = other.vpfxd;
    vcc = other.vcc;
    vfpuZeroLanes = other.vfpuZeroLanes;
    rcx.setAll(0, other.rcx);
  }
}

/// The main processor: a MIPS32r2 integer core with a single / double
/// precision FPU, the bit manipulation instructions of the second
/// release and the multimedia coprocessor (see vfpu.dart). Branches have
/// one delay slot and loads have none, as on the hardware. One instruction
/// is one clock; the surrounding core owns all timing decisions.
class Allegrex extends AllegrexState {
  final PspMemory mem;
  int clocks = 0;

  /// Invoked for the SYSCALL instruction with its 20-bit code field; the
  /// core answers through the kernel. A null handler makes SYSCALL a nop.
  void Function(int code)? onSyscall;

  Allegrex(this.mem);

  static int _u(int v) => v & 0xffffffff;
  static int _s(int v) => v.toSigned(32);

  void _set(int reg, int value) {
    if (reg != 0) r[reg] = _s(value);
  }

  void jumpTo(int addr) {
    pc = addr;
    nextPc = addr + 4;
  }

  /// Executes one instruction. Returns false for an instruction this core
  /// does not implement. Skips the delay slot of a missed branch-likely
  /// instruction: at this
  /// point [pc] addresses the delay slot and [nextPc] the instruction
  /// behind it, so both advance by one instruction.
  void _annul() {
    pc = nextPc;
    nextPc = pc + 4;
  }

  /// The address and word of the most recent instruction [step] could
  /// not execute, for diagnostics; -1 when nothing has failed yet.
  int failedAt = -1;
  int failedWord = 0;

  bool step() {
    final at = pc;
    final word = mem.read32(at);
    pc = nextPc;
    nextPc = pc + 4;
    clocks++;
    final ok = _exec(word);
    if (!ok) {
      failedAt = at;
      failedWord = word;
    }
    return ok;
  }

  bool _exec(int w) {
    final op = w >>> 26;
    final rs = (w >>> 21) & 31, rt = (w >>> 16) & 31, rd = (w >>> 11) & 31;
    final sa = (w >>> 6) & 31, fn = w & 63;
    final imm = (w & 0xffff).toSigned(16);
    final uimm = w & 0xffff;
    switch (op) {
      case 0x00: // SPECIAL
        return _special(rs, rt, rd, sa, fn);
      case 0x01: // REGIMM
        if (rt == 0x1f) return true; // SYNCI is a nop without caches
        final link = rt >= 0x10;
        final likely = rt & 0x02 != 0;
        final taken = switch (rt & 0xf) {
          0x00 => r[rs] < 0, // BLTZ / BLTZAL
          0x01 => r[rs] >= 0, // BGEZ / BGEZAL
          0x02 => r[rs] < 0, // BLTZL / BLTZALL
          0x03 => r[rs] >= 0, // BGEZL / BGEZALL
          _ => null,
        };
        if (taken == null) return false;
        if (link && (taken || !likely)) _set(31, pc + 4);
        if (taken) {
          nextPc = pc + (imm << 2);
        } else if (likely) {
          _annul();
        }
        return true;
      case 0x02: // J
        nextPc = (pc & 0xf0000000) | ((w & 0x3ffffff) << 2);
        return true;
      case 0x03: // JAL
        _set(31, pc + 4);
        nextPc = (pc & 0xf0000000) | ((w & 0x3ffffff) << 2);
        return true;
      case 0x04: // BEQ
        if (r[rs] == r[rt]) nextPc = pc + (imm << 2);
        return true;
      case 0x05: // BNE
        if (r[rs] != r[rt]) nextPc = pc + (imm << 2);
        return true;
      case 0x06: // BLEZ
        if (r[rs] <= 0) nextPc = pc + (imm << 2);
        return true;
      case 0x07: // BGTZ
        if (r[rs] > 0) nextPc = pc + (imm << 2);
        return true;
      case 0x14: // BEQL: a missed likely branch annuls its delay slot
        if (r[rs] == r[rt]) {
          nextPc = pc + (imm << 2);
        } else {
          _annul();
        }
        return true;
      case 0x15: // BNEL
        if (r[rs] != r[rt]) {
          nextPc = pc + (imm << 2);
        } else {
          _annul();
        }
        return true;
      case 0x16: // BLEZL
        if (r[rs] <= 0) {
          nextPc = pc + (imm << 2);
        } else {
          _annul();
        }
        return true;
      case 0x17: // BGTZL
        if (r[rs] > 0) {
          nextPc = pc + (imm << 2);
        } else {
          _annul();
        }
        return true;
      case 0x08: // ADDI; the kernel ABI raises no overflow trap
      case 0x09: // ADDIU
        _set(rt, r[rs] + imm);
        return true;
      case 0x0a: // SLTI
        _set(rt, r[rs] < imm ? 1 : 0);
        return true;
      case 0x0b: // SLTIU
        _set(rt, _u(r[rs]) < _u(imm) ? 1 : 0);
        return true;
      case 0x0c: // ANDI
        _set(rt, r[rs] & uimm);
        return true;
      case 0x0d: // ORI
        _set(rt, r[rs] | uimm);
        return true;
      case 0x0e: // XORI
        _set(rt, r[rs] ^ uimm);
        return true;
      case 0x0f: // LUI
        _set(rt, uimm << 16);
        return true;
      case 0x10: // COP0
        return _cop0(w, rs, rt, rd, fn);
      case 0x11: // COP1
        return _cop1(w, rs, rt, rd, fn);
      case 0x1c: // SPECIAL2
        return _special2(rs, rt, rd, fn);
      case 0x1f: // SPECIAL3
        return _special3(rs, rt, rd, sa, fn);
      case 0x20: // LB
        _set(rt, mem.read8(r[rs] + imm).toSigned(8));
        return true;
      case 0x21: // LH
        _set(rt, mem.read16(r[rs] + imm).toSigned(16));
        return true;
      case 0x22: // LWL
        final addr = r[rs] + imm;
        _set(rt, _mergeLoad(r[rt], mem.read32(addr & ~3), addr & 3, true));
        return true;
      case 0x23: // LW
        _set(rt, mem.read32(r[rs] + imm));
        return true;
      case 0x24: // LBU
        _set(rt, mem.read8(r[rs] + imm));
        return true;
      case 0x25: // LHU
        _set(rt, mem.read16(r[rs] + imm));
        return true;
      case 0x26: // LWR
        final addr = r[rs] + imm;
        _set(rt, _mergeLoad(r[rt], mem.read32(addr & ~3), addr & 3, false));
        return true;
      case 0x28: // SB
        mem.write8(r[rs] + imm, r[rt]);
        linked = false;
        return true;
      case 0x29: // SH
        mem.write16(r[rs] + imm, r[rt]);
        linked = false;
        return true;
      case 0x2a: // SWL
        _mergeStore(r[rs] + imm, r[rt], true);
        linked = false;
        return true;
      case 0x2b: // SW
        mem.write32(r[rs] + imm, r[rt]);
        linked = false;
        return true;
      case 0x2e: // SWR
        _mergeStore(r[rs] + imm, r[rt], false);
        linked = false;
        return true;
      case 0x2f: // CACHE operates on a cache this core does not model
        return true;
      case 0x30: // LL
        _set(rt, mem.read32(r[rs] + imm));
        linked = true;
        return true;
      case 0x31: // LWC1
        _setF(rt, mem.read32(r[rs] + imm));
        return true;
      case 0x33: // PREF
        return true;
      case 0x12: // COP2: multimedia transfers, control and branches
      case 0x18: // VFPU0
      case 0x19: // VFPU1
      case 0x1b: // VFPU3
      case 0x32: // LV.S
      case 0x34: // VFPU4
      case 0x35: // LVL.Q / LVR.Q (this processor has no LDC1)
      case 0x36: // LV.Q
      case 0x37: // VFPU5: prefixes and immediates
      case 0x3a: // SV.S
      case 0x3c: // VFPU6: matrix operations
      case 0x3d: // SVL.Q / SVR.Q (this processor has no SDC1)
      case 0x3e: // SV.Q
      case 0x3f: // VNOP and the multimedia synchronisation words
        return execVfpu(w);
      case 0x38: // SC
        if (linked) mem.write32(r[rs] + imm, r[rt]);
        _set(rt, linked ? 1 : 0);
        linked = false;
        return true;
      case 0x39: // SWC1
        mem.write32(r[rs] + imm, _fBits(rt));
        return true;
      default:
        return false;
    }
  }

  /// Merges the bytes an unaligned load takes from the aligned word into
  /// [old]; [left] selects the LWL direction. Byte lanes follow the
  /// little-endian memory layout.
  int _mergeLoad(int old, int aligned, int lane, bool left) {
    if (left) {
      // LWL places the bytes from the base through the addressed byte
      // into the top of the register and keeps the low bytes of [old].
      final shift = (3 - lane) * 8;
      final keep = shift == 0 ? 0 : (1 << shift) - 1;
      return _s((aligned << shift) | (old & keep));
    }
    // LWR places the bytes from the addressed byte through the top of
    // the word into the bottom of the register and keeps the high bytes.
    final shift = lane * 8;
    final keep = shift == 0 ? 0 : (0xffffffff << (32 - shift)) & 0xffffffff;
    return _s((aligned >>> shift) | (old & keep));
  }

  void _mergeStore(int addr, int value, bool left) {
    final base = addr & ~3, lane = addr & 3;
    if (left) {
      // SWL stores the top bytes of the register from the base through
      // the addressed byte.
      for (var i = 0; i <= lane; i++) {
        mem.write8(base + i, value >>> ((3 - lane + i) * 8));
      }
    } else {
      // SWR stores the low bytes of the register from the addressed
      // byte through the top of the word.
      for (var i = lane; i < 4; i++) {
        mem.write8(base + i, value >>> ((i - lane) * 8));
      }
    }
  }

  bool _special(int rs, int rt, int rd, int sa, int fn) {
    switch (fn) {
      case 0x00: // SLL
        _set(rd, r[rt] << sa);
        return true;
      case 0x02: // SRL, or ROTR when the rs field is one
        final v = _u(r[rt]);
        if (rs == 1) {
          _set(rd, sa == 0 ? v : (v >>> sa) | _u(v << (32 - sa)));
        } else {
          _set(rd, v >>> sa);
        }
        return true;
      case 0x03: // SRA
        _set(rd, r[rt] >> sa);
        return true;
      case 0x04: // SLLV
        _set(rd, r[rt] << (r[rs] & 31));
        return true;
      case 0x06: // SRLV, or ROTRV when the low bit of the sa field is set
        final v = _u(r[rt]), by = r[rs] & 31;
        if (sa & 1 != 0) {
          _set(rd, by == 0 ? v : (v >>> by) | _u(v << (32 - by)));
        } else {
          _set(rd, v >>> by);
        }
        return true;
      case 0x07: // SRAV
        _set(rd, r[rt] >> (r[rs] & 31));
        return true;
      case 0x16: // CLZ counts the leading zero bits of rs into rd
        _set(rd, _u(r[rs]) == 0 ? 32 : _leadingZeros(_u(r[rs])));
        return true;
      case 0x17: // CLO counts the leading one bits
        _set(rd, _u(~r[rs]) == 0 ? 32 : _leadingZeros(_u(~r[rs])));
        return true;
      case 0x08: // JR
        nextPc = r[rs];
        return true;
      case 0x09: // JALR
        final target = r[rs];
        _set(rd, pc + 4);
        nextPc = target;
        return true;
      case 0x0a: // MOVZ
        if (r[rt] == 0) _set(rd, r[rs]);
        return true;
      case 0x0b: // MOVN
        if (r[rt] != 0) _set(rd, r[rs]);
        return true;
      case 0x0c: // SYSCALL; the code field spans the rs..sa fields
        onSyscall?.call((rs << 15) | (rt << 10) | (rd << 5) | sa);
        return true;
      case 0x0d: // BREAK is a nop outside a debugger
        return true;
      case 0x0f: // SYNC
        return true;
      case 0x10: // MFHI
        _set(rd, hi);
        return true;
      case 0x11: // MTHI
        hi = r[rs];
        return true;
      case 0x12: // MFLO
        _set(rd, lo);
        return true;
      case 0x13: // MTLO
        lo = r[rs];
        return true;
      case 0x18: // MULT
        final (h, l) = _mulS32(r[rs], r[rt]);
        hi = h;
        lo = l;
        return true;
      case 0x19: // MULTU
        final (h, l) = _mulU32(_u(r[rs]), _u(r[rt]));
        hi = _s(h);
        lo = _s(l);
        return true;
      case 0x1a: // DIV
        _divide(r[rs], r[rt], signed: true);
        return true;
      case 0x1b: // DIVU
        _divide(_u(r[rs]), _u(r[rt]), signed: false);
        return true;
      case 0x20: // ADD; the kernel ABI raises no overflow trap
      case 0x21: // ADDU
        _set(rd, r[rs] + r[rt]);
        return true;
      case 0x22: // SUB
      case 0x23: // SUBU
        _set(rd, r[rs] - r[rt]);
        return true;
      case 0x2c: // MAX keeps the larger signed operand
        _set(rd, r[rs] > r[rt] ? r[rs] : r[rt]);
        return true;
      case 0x2d: // MIN keeps the smaller signed operand
        _set(rd, r[rs] < r[rt] ? r[rs] : r[rt]);
        return true;
      case 0x24: // AND
        _set(rd, r[rs] & r[rt]);
        return true;
      case 0x25: // OR
        _set(rd, r[rs] | r[rt]);
        return true;
      case 0x26: // XOR
        _set(rd, r[rs] ^ r[rt]);
        return true;
      case 0x27: // NOR
        _set(rd, ~(r[rs] | r[rt]));
        return true;
      case 0x2a: // SLT
        _set(rd, r[rs] < r[rt] ? 1 : 0);
        return true;
      case 0x2b: // SLTU
        _set(rd, _u(r[rs]) < _u(r[rt]) ? 1 : 0);
        return true;
      default:
        return false;
    }
  }

  void _divide(int a, int b, {required bool signed}) {
    if (signed) {
      if (b == 0) {
        lo = a < 0 ? 1 : -1;
        hi = a;
      } else if (a == -0x80000000 && b == -1) {
        lo = a;
        hi = 0;
      } else {
        lo = a ~/ b;
        hi = a - lo * b;
      }
    } else {
      if (b == 0) {
        lo = -1;
        hi = a;
      } else {
        lo = _s(a ~/ b);
        hi = _s(a % b);
      }
    }
    lo = _s(lo);
    hi = _s(hi);
  }

  /// The exact 64-bit product of two unsigned 32-bit values as a (hi, lo)
  /// pair of unsigned 32-bit words, computed in 16-bit parts so the result
  /// is exact on every host number model.
  static (int, int) _mulU32(int a, int b) {
    final al = a & 0xffff, ah = a >>> 16;
    final bl = b & 0xffff, bh = b >>> 16;
    final p0 = al * bl, p1 = al * bh, p2 = ah * bl;
    final mid = (p0 >>> 16) + (p1 & 0xffff) + (p2 & 0xffff);
    final lo = (p0 & 0xffff) | ((mid & 0xffff) << 16);
    final hi = ah * bh + (p1 >>> 16) + (p2 >>> 16) + (mid >>> 16);
    return (hi & 0xffffffff, lo & 0xffffffff);
  }

  /// The signed product as a (hi, lo) pair of signed 32-bit words.
  static (int, int) _mulS32(int a, int b) {
    final (hi, lo) = _mulU32(_u(a), _u(b));
    var h = hi;
    if (a < 0) h -= _u(b);
    if (b < 0) h -= _u(a);
    return (_s(h), _s(lo));
  }

  bool _special2(int rs, int rt, int rd, int fn) {
    switch (fn) {
      case 0x00: // MADD
        final (h, l) = _mulS32(r[rs], r[rt]);
        _accumulate(h, l);
        return true;
      case 0x01: // MADDU
        final (h, l) = _mulU32(_u(r[rs]), _u(r[rt]));
        _accumulate(_s(h), _s(l));
        return true;
      case 0x02: // MUL
        _set(rd, r[rs] * r[rt]);
        return true;
      case 0x04: // MSUB subtracts the product: negate the (hi, lo) pair
        final (h, l) = _mulS32(r[rs], r[rt]);
        _accumulate(_s(l == 0 ? -h : ~h), _s(-l));
        return true;
      case 0x05: // MSUBU
        final (h, l) = _mulU32(_u(r[rs]), _u(r[rt]));
        _accumulate(l == 0 ? _s(-h) : _s(~h), _s(-l));
        return true;
      case 0x20: // CLZ: the destination rides in the rt field
        _set(rt, _u(r[rs]) == 0 ? 32 : _leadingZeros(_u(r[rs])));
        return true;
      case 0x21: // CLO
        _set(rt, _u(~r[rs]) == 0 ? 32 : _leadingZeros(_u(~r[rs])));
        return true;
      default:
        return false;
    }
  }

  /// Adds the signed 64-bit product (h, l) into the HI/LO accumulator.
  /// MSUB passes the two's complement of the product: negating a 64-bit
  /// pair negates the low word and complements the high word, borrowing
  /// one from the high word when the low word is not zero.
  void _accumulate(int h, int l) {
    final sumLo = _u(lo) + _u(l);
    lo = _s(sumLo);
    hi = _s(hi + h + (sumLo >>> 32));
  }

  static int _leadingZeros(int v) {
    var n = 0;
    for (var bit = 31; bit >= 0; bit--) {
      if (v & (1 << bit) != 0) break;
      n++;
    }
    return n;
  }

  bool _special3(int rs, int rt, int rd, int sa, int fn) {
    switch (fn) {
      case 0x00: // EXT: the rd field holds the size minus one
        final size = rd + 1;
        final mask = size == 32 ? 0xffffffff : (1 << size) - 1;
        _set(rt, (_u(r[rs]) >>> sa) & mask);
        return true;
      case 0x04: // INS: the rd field holds position plus size minus one
        final size = rd - sa + 1;
        final field =
            ((size == 32 ? 0xffffffff : (1 << size) - 1) << sa) & 0xffffffff;
        _set(rt, (r[rt] & ~field) | ((r[rs] << sa) & field));
        return true;
      case 0x20: // BSHFL
        final v = _u(r[rt]);
        switch (sa) {
          case 0x02: // WSBH swaps the bytes inside each halfword
            _set(rd, ((v >>> 8) & 0x00ff00ff) | ((v << 8) & 0xff00ff00));
            return true;
          case 0x0d: // BITREV reverses the bit order
            var rev = 0, x = v;
            for (var i = 0; i < 32; i++) {
              rev = (rev << 1) | (x & 1);
              x >>>= 1;
            }
            _set(rd, rev);
            return true;
          case 0x10: // SEB
            _set(rd, (v & 0xff).toSigned(8));
            return true;
          case 0x18: // SEH
            _set(rd, (v & 0xffff).toSigned(16));
            return true;
          default:
            return false;
        }
      default:
        return false;
    }
  }

  bool _cop0(int w, int rs, int rt, int rd, int fn) {
    switch (rs) {
      case 0x00: // MFC0
        _set(rt, cop0[rd]);
        return true;
      case 0x04: // MTC0
        cop0[rd] = r[rt];
        return true;
      case 0x0b: // EI / DI toggle the interrupt enable in Status
        cop0[12] = (w & 0x20) != 0 ? cop0[12] | 1 : cop0[12] & ~1;
        return true;
      case 0x10: // ERET
        if (fn == 0x18) {
          nextPc = cop0[14];
          return true;
        }
        return false;
      default:
        return false;
    }
  }

  // The FPU register file is raw bits in a Float32List; a scratch ByteData
  // over the same buffer gives bit access and double assembly.
  ByteData? _fData;
  ByteData get _fd => _fData ??= ByteData.sublistView(
      f.buffer.asUint8List(f.offsetInBytes, f.lengthInBytes));

  int _fBits(int i) => _fd.getUint32(i * 4, Endian.little);
  void _setF(int i, int bits) => _fd.setUint32(i * 4, bits, Endian.little);
  double _d(int i) => _fd.getFloat64((i & ~1) * 4, Endian.little);
  void _setD(int i, double v) => _fd.setFloat64((i & ~1) * 4, v, Endian.little);

  int _fcrWithFcc() =>
      (fcr31 & ~0xfe000000 & ~(1 << 23)) |
      ((fcc & 1) << 23) |
      ((fcc >> 1) << 25);

  bool _cop1(int w, int rs, int rt, int rd, int fn) {
    final fs = rd, fd = (w >>> 6) & 31;
    switch (rs) {
      case 0x00: // MFC1
        _set(rt, _fBits(fs));
        return true;
      case 0x01: // DMFC1 reads the low word on this 32-bit core
        _set(rt, _fBits(fs));
        return true;
      case 0x02: // CFC1
        _set(rt, rd == 31 ? _fcrWithFcc() : 0);
        return true;
      case 0x04: // MTC1
        _setF(fs, r[rt]);
        return true;
      case 0x05: // DMTC1
        _setF(fs, r[rt]);
        return true;
      case 0x06: // CTC1
        if (rd == 31) {
          fcr31 = r[rt] & 0x0183ffff;
          fcc = ((fcr31 >> 23) & 1) | (((fcr31 >> 25) & 0x7f) << 1);
        }
        return true;
      case 0x08: // BC1 branches on FCC[cc]
        final cc = (w >>> 18) & 7;
        final set = (fcc >> cc) & 1 != 0;
        if ((rt & 1) == 0 ? !set : set) {
          nextPc = pc + (((w & 0xffff).toSigned(16)) << 2);
        } else if (rt & 0x02 != 0) {
          _annul(); // the likely forms annul a missed delay slot
        }
        return true;
      case 0x10: // S arithmetic
        return _fpu(fs, fd, rt, fn, single: true);
      case 0x11: // D arithmetic
        return _fpu(fs, fd, rt, fn, single: false);
      case 0x14: // W conversions
        switch (fn) {
          case 0x20: // CVT.S.W
            f[fd] = _fBits(fs).toSigned(32).toDouble();
            return true;
          case 0x21: // CVT.D.W
            _setD(fd, _fBits(fs).toSigned(32).toDouble());
            return true;
          default:
            return false;
        }
      default:
        return false;
    }
  }

  bool _fpu(int fs, int fd, int ft, int fn, {required bool single}) {
    final a = single ? f[fs].toDouble() : _d(fs);
    final b = single ? f[ft].toDouble() : _d(ft);
    void store(double v) {
      if (single) {
        f[fd] = v;
      } else {
        _setD(fd, v);
      }
    }

    switch (fn) {
      case 0x00:
        store(a + b);
        return true;
      case 0x01:
        store(a - b);
        return true;
      case 0x02:
        store(a * b);
        return true;
      case 0x03:
        store(a / b);
        return true;
      case 0x04:
        store(math.sqrt(a));
        return true;
      case 0x05:
        store(a.abs());
        return true;
      case 0x06:
        store(a);
        return true;
      case 0x07:
        store(-a);
        return true;
      case 0x0c: // ROUND.W rounds to nearest
        _setF(fd, _roundToInt(a, 0));
        return true;
      case 0x0d: // TRUNC.W rounds toward zero
        _setF(fd, _roundToInt(a, 1));
        return true;
      case 0x0e: // CEIL.W
        _setF(fd, _roundToInt(a, 2));
        return true;
      case 0x0f: // FLOOR.W
        _setF(fd, _roundToInt(a, 3));
        return true;
      case 0x21: // CVT.D.S widens exactly
        if (single) _setD(fd, a);
        return single;
      case 0x20: // CVT.S.D narrows with rounding
        if (!single) f[fd] = a;
        return !single;
      case 0x24: // CVT.W converts by the FCSR rounding mode
        _setF(fd, _roundToInt(a, fcr31 & 3));
        return true;
      default:
        if (fn >= 0x30) {
          _compare(fn & 0xf, a, b, (fd >> 2) & 7);
          return true;
        }
        return false;
    }
  }

  void _compare(int cond, double a, double b, int cc) {
    final unordered = a.isNaN || b.isNaN;
    final less = !unordered && a < b;
    final equal = !unordered && a == b;
    // Conditions 8-15 are the signaling forms of 0-7 with the same truth
    // values; without exception delivery they compare identically.
    final result = switch (cond & 7) {
      0 => false,
      1 => unordered,
      2 => equal,
      3 => unordered || equal,
      4 => less,
      5 => unordered || less,
      6 => less || equal,
      7 => unordered || less || equal,
      _ => false,
    };
    fcc = result ? fcc | (1 << cc) : fcc & ~(1 << cc);
  }

  int _roundToInt(double v, int mode) {
    if (v.isNaN) return 0x7fffffff;
    final t = switch (mode) {
      1 => v.truncateToDouble(),
      2 => v.ceilToDouble(),
      3 => v.floorToDouble(),
      _ => v.roundToDouble(),
    };
    if (t >= 2147483648.0) return 0x7fffffff;
    if (t < -2147483648.0) return -0x80000000;
    return t.toInt();
  }
}
