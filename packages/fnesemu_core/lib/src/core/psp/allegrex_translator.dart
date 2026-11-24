import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import 'vfpu.dart';

/// Lowers instructions with the same state and clock model as Allegrex.step.
final class AllegrexTranslator {
  static const ctxRegs = JitCtx.user;
  static const ctxHi = ctxRegs + 32;
  static const ctxLo = ctxHi + 1;
  static const ctxLinked = ctxLo + 1;
  static const ctxFcc = ctxLinked + 1;
  static const ctxVfpuZeroLanes = ctxFcc + 1;
  static const ctxFpr = ctxVfpuZeroLanes + 1;
  static const ctxVfpr = ctxFpr + 32;
  static const ctxWords = ctxVfpr + 128;
  static const maxInstructions = 32;

  static const reasonInterpret = JitReason.user;
  static const reasonStore = JitReason.user + 1;

  final int? Function(int pc) fetch;
  final int pageBytes;
  final bool Function(int pc) isReleased;

  AllegrexTranslator(this.fetch, this.pageBytes, this.isReleased);

  IrBlock? translate(int pc) => _Block(this, pc).translate();
}

final class _Block {
  final AllegrexTranslator t;
  final int pc;
  final IrBuilder b;
  final _values =
      List<IrValue?>.filled(AllegrexTranslator.ctxWords - JitCtx.user, null);
  final _dirty = <int>{};
  int _count = 0;

  _Block(this.t, this.pc) : b = IrBuilder(pc);

  IrValue _get(int index) {
    if (index == AllegrexTranslator.ctxRegs) return b.c32(0);
    return _values[index - JitCtx.user] ??= b.ctxLoad(index);
  }

  void _set(int index, IrValue value) {
    if (index == AllegrexTranslator.ctxRegs) return;
    _values[index - JitCtx.user] = value;
    _dirty.add(index);
  }

  List<(int, IrValue)> _stores() => [
        for (final index in _dirty) (index, _values[index - JitCtx.user]!),
      ];

  IrExit _interpret(int at) => IrExit(AllegrexTranslator.reasonInterpret, at,
      spent: _count, stores: _stores());

  IrBlock _finish(IrTerm term) {
    for (final index in _dirty) {
      b.ctxStore(index, _values[index - JitCtx.user]!);
    }
    return b.finish(term, cost: _count);
  }

  int? _fetch(int at) {
    final word = t.fetch(at);
    if (word != null) b.guard(at, word);
    return word;
  }

  IrBlock? translate() {
    // A block on a released page ends after a store. Keeping all its words
    // on one page lets the next entry guard check any modified instruction.
    final pageEnd = (pc & -t.pageBytes) + t.pageBytes;
    final stopAfterStore = t.isReleased(pc);
    var at = pc;
    while (at < pageEnd && _count < AllegrexTranslator.maxInstructions) {
      final word = _fetch(at);
      if (word == null) break;
      if (_isBranch(word)) {
        if (at + 4 < pageEnd &&
            _count + 2 <= AllegrexTranslator.maxInstructions) {
          return _branch(word, at);
        }
        break;
      }
      if (!_lower(word, at)) {
        if (_count == 0) return null;
        return _finish(
            IrExitTerm(IrExit(AllegrexTranslator.reasonInterpret, at)));
      }
      _count++;
      at += 4;
      if (stopAfterStore && _writesMemory(word)) break;
    }
    return _count == 0 ? null : _finish(IrJump(at));
  }

  static bool _isBranch(int word) => switch (word >>> 26) {
        0 => (word & 63) == 8 || (word & 63) == 9,
        1 => (word >>> 16 & 15) <= 3,
        >= 2 && <= 7 || >= 0x14 && <= 0x17 => true,
        0x11 => (word >>> 21 & 31) == 8,
        _ => false,
      };

  IrBlock _branch(int word, int at) {
    final before = _interpret(at);
    final slot = _fetch(at + 4);
    if (slot == null) return b.finish(IrExitTerm(before), cost: _count);

    final op = word >>> 26, rs = word >>> 21 & 31, rt = word >>> 16 & 31;
    final source = _get(AllegrexTranslator.ctxRegs + rs);
    final zero = b.c32(0);
    final afterSlot = at + 8;
    final IrTerm term;
    if (op == 0) {
      // JR and JALR take the signed register value in the interpreter.
      // Leave negative destinations to it so their PC representation survives.
      b.exitIf(b.ltS(source, zero), before);
      if ((word & 63) == 9) {
        _set(AllegrexTranslator.ctxRegs + (word >>> 11 & 31), b.c32(afterSlot));
      }
      term = IrJumpDyn(source);
    } else if (op == 2 || op == 3) {
      if (op == 3) _set(AllegrexTranslator.ctxRegs + 31, b.c32(afterSlot));
      term = IrJump(((at + 4) & 0xf0000000) | ((word & 0x3ffffff) << 2));
    } else {
      final other = _get(AllegrexTranslator.ctxRegs + rt);
      final cond = switch (op) {
        1 => (rt & 1) == 0 ? b.ltS(source, zero) : b.ltS(b.c32(-1), source),
        4 || 0x14 => b.eq(source, other),
        5 || 0x15 => b.ne(source, other),
        6 || 0x16 => b.ltS(source, b.c32(1)),
        0x11 => _fpBranchCondition(rt),
        _ => b.ltS(zero, source),
      };
      final target = at + 4 + ((word & 0xffff).toSigned(16) << 2);
      final likely = op == 1 || op == 0x11 ? (rt & 2) != 0 : op >= 0x14;
      if (likely) {
        b.exitIf(
            b.eq(cond, zero),
            IrExit(AllegrexTranslator.reasonInterpret, afterSlot,
                spent: _count + 1, stores: before.stores, link: true));
      }
      if (op == 1 && rt >= 0x10) {
        _set(AllegrexTranslator.ctxRegs + 31, b.c32(afterSlot));
      }
      term = likely ? IrJump(target) : IrBranch(cond, target, afterSlot);
    }

    // A fault or an unsupported instruction in the slot replays the branch
    // from its original registers, including the link register.
    if (!_lower(slot, at + 4, before: before)) {
      return b.finish(IrExitTerm(before), cost: _count + 1);
    }
    _count += 2;
    return _finish(term);
  }

  IrValue _fpBranchCondition(int rt) {
    final mask = 1 << (rt >>> 2);
    return b.eq(b.and(_get(AllegrexTranslator.ctxFcc), b.c32(mask)),
        b.c32(rt & 1 == 0 ? 0 : mask));
  }

  bool _lower(int word, int at, {IrExit? before}) {
    final op = word >>> 26;
    final rs = word >>> 21 & 31, rt = word >>> 16 & 31, rd = word >>> 11 & 31;
    final sa = word >>> 6 & 31, fn = word & 63;
    final imm = (word & 0xffff).toSigned(16);
    final uimm = word & 0xffff;
    IrValue source() => _get(AllegrexTranslator.ctxRegs + rs);
    IrValue other() => _get(AllegrexTranslator.ctxRegs + rt);
    final IrValue result;
    var dest = rt;
    switch (op) {
      case 0:
        dest = rd;
        switch (fn) {
          case 0x00:
            result = b.shl(other(), b.c32(sa));
          case 0x02:
            result = rs == 1
                ? _rotate(other(), b.c32(sa))
                : b.shrU(other(), b.c32(sa));
          case 0x03:
            result = b.shrS(other(), b.c32(sa));
          case 0x04:
            result = b.shl(other(), _shift(source()));
          case 0x06:
            final by = _shift(source());
            result = (sa & 1) != 0 ? _rotate(other(), by) : b.shrU(other(), by);
          case 0x07:
            result = b.shrS(other(), _shift(source()));
          case 0x0a || 0x0b:
            final cond =
                fn == 0x0a ? b.eq(other(), b.c32(0)) : b.ne(other(), b.c32(0));
            result =
                b.select(cond, source(), _get(AllegrexTranslator.ctxRegs + rd));
          case 0x0d || 0x0f:
            return true; // BREAK and SYNC
          case 0x10:
            result = _get(AllegrexTranslator.ctxHi);
          case 0x11:
            _set(AllegrexTranslator.ctxHi, source());
            return true;
          case 0x12:
            result = _get(AllegrexTranslator.ctxLo);
          case 0x13:
            _set(AllegrexTranslator.ctxLo, source());
            return true;
          case 0x18 || 0x19:
            final a = source(), v = other();
            _set(AllegrexTranslator.ctxHi,
                fn == 0x18 ? b.mulHiS(a, v) : b.mulHiU(a, v));
            _set(AllegrexTranslator.ctxLo, b.mul(a, v));
            return true;
          case 0x1a || 0x1b:
            _divide(source(), other(), signed: fn == 0x1a);
            return true;
          case 0x20 || 0x21:
            result = b.add(source(), other());
          case 0x22 || 0x23:
            result = b.sub(source(), other());
          case 0x24:
            result = b.and(source(), other());
          case 0x25:
            result = b.or(source(), other());
          case 0x26:
            result = b.xor(source(), other());
          case 0x27:
            result = b.not(b.or(source(), other()));
          case 0x2a:
            result = b.ltS(source(), other());
          case 0x2b:
            result = b.ltU(source(), other());
          case 0x2c:
            result = b.select(b.ltS(other(), source()), source(), other());
          case 0x2d:
            result = b.select(b.ltS(source(), other()), source(), other());
          default:
            return false;
        }
      case 1:
        return rt == 0x1f; // SYNCI
      case 0x08 || 0x09:
        result = b.add(source(), b.c32(imm));
      case 0x0a:
        result = b.ltS(source(), b.c32(imm));
      case 0x0b:
        result = b.ltU(source(), b.c32(imm));
      case 0x0c:
        result = b.and(source(), b.c32(uimm));
      case 0x0d:
        result = b.or(source(), b.c32(uimm));
      case 0x0e:
        result = b.xor(source(), b.c32(uimm));
      case 0x0f:
        result = b.c32(uimm << 16);
      case 0x11:
        switch (rs) {
          case 0 || 1:
            result = _get(AllegrexTranslator.ctxFpr + rd);
          case 4 || 5:
            _set(AllegrexTranslator.ctxFpr + rd, other());
            return true;
          case 0x10:
            return _singleFloat(rd, rt, sa, fn, at, before);
          case 0x14:
            if (fn != 0x20) return false;
            _intToFloat(rd, sa);
            return true;
          default:
            return false;
        }
      case 0x1c:
        if (fn != 2) return false;
        dest = rd;
        result = b.mul(source(), other());
      case 0x1f:
        switch (fn) {
          case 0:
            result =
                b.and(b.shrU(source(), b.c32(sa)), b.c32((1 << (rd + 1)) - 1));
          case 4:
            if (rd < sa) return false;
            final mask = b.c32(((1 << (rd - sa + 1)) - 1) << sa);
            result = b.or(b.and(other(), b.not(mask)),
                b.and(b.shl(source(), b.c32(sa)), mask));
          case 0x20:
            dest = rd;
            switch (sa) {
              case 0x10:
                result = b.sext8(other());
              case 0x18:
                result = b.sext16(other());
              default:
                return false;
            }
          default:
            return false;
        }
      case 0x20 ||
            0x21 ||
            0x23 ||
            0x24 ||
            0x25 ||
            0x28 ||
            0x29 ||
            0x2b ||
            0x31 ||
            0x39:
        _memory(word, source(), at, before);
        return true;
      case 0x2f || 0x33:
        return true; // CACHE and PREF
      case 0x32 || 0x36 || 0x3a || 0x3e:
        _vectorMemory(word, source(), at, before);
        return true;
      case 0x3f:
        if (word >>> 16 != 0xffff) return false;
        _set(AllegrexTranslator.ctxVfpuZeroLanes, b.c32(0));
        return true; // VNOP and VFPU synchronisation
      default:
        return false;
    }
    _set(AllegrexTranslator.ctxRegs + dest, result);
    return true;
  }

  IrValue _shift(IrValue value) => b.and(value, b.c32(31));

  IrValue _rotate(IrValue value, IrValue by) =>
      b.or(b.shrU(value, by), b.shl(value, _shift(b.sub(b.c32(0), by))));

  void _divide(IrValue a, IrValue divisor, {required bool signed}) {
    final zero = b.eq(divisor, b.c32(0));
    final quotient = signed ? b.divS(a, divisor) : b.divU(a, divisor);
    final remainder = signed ? b.remS(a, divisor) : b.remU(a, divisor);
    final zeroQuotient =
        signed ? b.select(b.ltS(a, b.c32(0)), b.c32(1), b.c32(-1)) : b.c32(-1);
    _set(AllegrexTranslator.ctxLo, b.select(zero, zeroQuotient, quotient));
    _set(AllegrexTranslator.ctxHi, b.select(zero, a, remainder));
  }

  IrValue _floatMagnitude(IrValue bits) => b.and(bits, b.c32(0x7fffffff));

  bool _singleFloat(int fs, int ft, int fd, int fn, int at, IrExit? before) {
    final dest = AllegrexTranslator.ctxFpr + fd;
    final a = _get(AllegrexTranslator.ctxFpr + fs);
    final magnitude = _floatMagnitude(a);
    final zero = b.c32(0), infinity = b.c32(0x7f800000);
    if (fn >= 0x30) {
      _compareFloat(a, _get(AllegrexTranslator.ctxFpr + ft), fn & 7, fd >>> 2);
      return true;
    }
    final replay = before ?? _interpret(at);
    if (fn == 0x0d) {
      // The CPU clamps large and NaN results differently from the IR.
      b.exitIf(b.eq(b.ltU(magnitude, b.c32(0x4f000000)), zero), replay);
      _set(dest, b.floatToInt(a, truncate: true));
      return true;
    }
    if (fn > 7) return false;

    // Exceptional operations use the interpreter's NaN and infinity rules.
    final finite = b.ltU(magnitude, infinity);
    final IrValue result;
    if (fn <= 3) {
      final other = _get(AllegrexTranslator.ctxFpr + ft);
      final otherMagnitude = _floatMagnitude(other);
      final otherValid = fn == 3
          ? b.and(b.ltU(otherMagnitude, infinity), b.ne(otherMagnitude, zero))
          : b.ltU(otherMagnitude, infinity);
      b.exitIf(b.eq(b.and(finite, otherValid), zero), replay);
      const ops = [IrOp.floatAdd, IrOp.floatSub, IrOp.floatMul, IrOp.floatDiv];
      result = b.floatConvert(
          b.floatBinary(ops[fn], b.floatConvert(a), b.floatConvert(other)));
    } else {
      final invalid = fn == 4
          ? b.or(
              b.eq(finite, zero), b.and(b.ltS(a, zero), b.ne(magnitude, zero)))
          : b.eq(finite, zero);
      b.exitIf(invalid, replay);
      result = switch (fn) {
        4 => b.floatConvert(b.floatSqrt(b.floatConvert(a))),
        5 => magnitude,
        6 => a,
        _ => b.xor(a, b.c32(0x80000000)),
      };
    }
    _set(dest, result);
    return true;
  }

  void _intToFloat(int fs, int fd) {
    final raw = _get(AllegrexTranslator.ctxFpr + fs);
    // Encode the biased word in the low mantissa bits of 2^52. Subtracting
    // the bias in binary64 gives the exact signed value before narrowing.
    final biased = b.zext32(b.xor(raw, b.c32(0x80000000)));
    final encoded = b.or(b.c64Parts(0, 0x43300000), biased);
    final value = b.floatBinary(
        IrOp.floatSub, encoded, b.c64Parts(0x80000000, 0x43300000));
    _set(AllegrexTranslator.ctxFpr + fd, b.floatConvert(value));
  }

  void _compareFloat(IrValue a, IrValue other, int cond, int cc) {
    final zero = b.c32(0), infinity = b.c32(0x7f800000);
    final x = _floatMagnitude(a), y = _floatMagnitude(other);
    final unordered = b.or(b.ltU(infinity, x), b.ltU(infinity, y));
    final bothZero = b.eq(b.or(x, y), zero);
    var result = cond & 1 == 0 ? zero : unordered;
    if (cond & 2 != 0) {
      final equal =
          b.and(b.eq(unordered, zero), b.or(b.eq(a, other), bothZero));
      result = b.or(result, equal);
    }
    if (cond & 4 != 0) {
      final negative = b.ltS(a, zero);
      final sameSign = b.select(negative, b.ltU(y, x), b.ltU(x, y));
      final less = b.select(b.ltS(b.xor(a, other), zero), negative, sameSign);
      result = b.or(result, b.and(less, b.eq(b.or(unordered, bothZero), zero)));
    }
    final fcc = _get(AllegrexTranslator.ctxFcc);
    _set(AllegrexTranslator.ctxFcc,
        b.or(b.and(fcc, b.c32(~(1 << cc))), b.shl(result, b.c32(cc))));
  }

  static bool _writesMemory(int word) => switch (word >>> 26) {
        0x28 || 0x29 || 0x2b || 0x39 || 0x3a || 0x3e => true,
        _ => false,
      };

  void _memory(int word, IrValue base, int at, IrExit? before) {
    final op = word >>> 26, rt = word >>> 16 & 31;
    final size = switch (op) {
      0x20 || 0x24 || 0x28 => 1,
      0x21 || 0x25 || 0x29 => 2,
      _ => 4,
    };
    final address = b.add(base, b.c32((word & 0xffff).toSigned(16)));
    final replay = before ?? _interpret(at);
    if (size > 1) {
      // The interpreter handles the unaligned and region-end cases.
      b.exitIf(b.and(address, b.c32(size - 1)), replay);
    }

    final fp = op == 0x31 || op == 0x39;
    final index =
        (fp ? AllegrexTranslator.ctxFpr : AllegrexTranslator.ctxRegs) + rt;
    if (_writesMemory(word)) {
      b.store(size, address, _get(index),
          unmapped: IrExit(AllegrexTranslator.reasonStore, replay.pc,
              spent: replay.spent, stores: replay.stores));
      if (!fp) _set(AllegrexTranslator.ctxLinked, b.c32(0));
    } else {
      _set(
          index,
          b.load(size, address,
              signed: op == 0x20 || op == 0x21, unmapped: replay));
    }
  }

  void _vectorMemory(int word, IrValue base, int at, IrExit? before) {
    final lanes = PspVfpuExec.memoryRegisters(word);
    final address = b.add(base, b.c32(PspVfpuExec.memoryOffset(word)));
    final replay = before ?? _interpret(at);
    // A naturally aligned transfer stays on one page, so a write cannot
    // exit partway through the vector after committing its first lanes.
    b.exitIf(b.and(address, b.c32(lanes.length * 4 - 1)), replay);
    final write = _writesMemory(word);
    final unmapped = write
        ? IrExit(AllegrexTranslator.reasonStore, replay.pc,
            spent: replay.spent, stores: replay.stores)
        : replay;
    for (final (i, lane) in lanes.indexed) {
      final addr = b.add(address, b.c32(i * 4));
      final index = AllegrexTranslator.ctxVfpr + lane;
      if (write) {
        b.store(4, addr, _get(index), unmapped: unmapped);
      } else {
        _set(index, b.load(4, addr, unmapped: unmapped));
      }
    }
    _set(AllegrexTranslator.ctxVfpuZeroLanes, b.c32(0));
  }
}
