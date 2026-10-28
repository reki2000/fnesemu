import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

/// Each GPR is one i64 SSA value; word results are truncated and
/// sign-extended explicitly.
final class Vr4300Translator {
  static const defaultMaxInstructions = 24;
  static const ctxRegs = JitCtx.user;
  static const interpret = JitReason.user;
  static const ctxHi = ctxRegs + 64;
  static const ctxLo = ctxRegs + 66;
  static const ctxFpu = ctxRegs + 68;
  static const ctxFpuControl = ctxFpu + 64;
  final int? fpuHelper;
  final bool cop1;
  final bool nativeFpu;
  int _tag = 0;
  bool get _fpEnabled =>
      (cop1 || nativeFpu || fpuHelper != null) && (_tag & 2) != 0;
  int _fpWord(int r) => ctxFpu + r * ((_tag & 1) != 0 ? 2 : 1);
  final int maxInstructions;
  final bool inlineJumps;
  final int? Function(int) fetch;
  final void Function(int) protect;
  late IrBuilder b;
  final _lowRegs = List<IrValue?>.filled(32, null);
  final _wideRegs = List<IrValue?>.filled(32, null);
  final _dirty = <int>{};
  IrValue? _hi, _lo;
  bool _hiDirty = false, _loDirty = false;

  Vr4300Translator(
      {required this.fetch,
      required this.protect,
      this.maxInstructions = defaultMaxInstructions,
      this.fpuHelper,
      this.cop1 = false,
      this.nativeFpu = false,
      this.inlineJumps = false});

  IrValue _c(int value) => b.c32(value);
  void _resetRegisters() {
    _wideRegs.fillRange(0, _wideRegs.length, null);
    _lowRegs.fillRange(0, _lowRegs.length, null);
  }

  IrValue _c64(int value) => b.c64Parts(value, value >> 32);
  IrValue _get64(int r) => r == 0
      ? _c64(0)
      : _wideRegs[r] ??= b.ctxLoad(ctxRegs + r * 2, type: IrType.i64);
  void _put64(int r, IrValue value) {
    if (r == 0) return;
    _wideRegs[r] = value;
    _lowRegs[r] = null;
    _dirty.add(r);
  }

  IrValue _low(int r) => r == 0 ? _c(0) : _lowRegs[r] ??= b.trunc32(_get64(r));
  void _word(int r, IrValue value) {
    if (r == 0) return;
    _put64(r, b.sext32(value));
    _lowRegs[r] = value;
  }

  IrExit _snapshot(int pc, int spent,
          {int reason = interpret, bool link = false}) =>
      IrExit(reason, pc, tag: _tag, spent: spent, link: link, stores: [
        for (final r in _dirty) (ctxRegs + r * 2, _wideRegs[r]!),
        if (_hiDirty) (ctxHi, _hi!),
        if (_loDirty) (ctxLo, _lo!),
      ]);
  void _flush() {
    for (final r in _dirty) {
      b.ctxStore(ctxRegs + r * 2, _wideRegs[r]!);
    }
    if (_hiDirty) b.ctxStore(ctxHi, _hi!);
    if (_loDirty) b.ctxStore(ctxLo, _lo!);
  }

  IrValue _getHi() => _hi ??= b.ctxLoad(ctxHi, type: IrType.i64);
  IrValue _getLo() => _lo ??= b.ctxLoad(ctxLo, type: IrType.i64);
  void _putHi(IrValue value) {
    _hi = value;
    _hiDirty = true;
  }

  void _putLo(IrValue value) {
    _lo = value;
    _loDirty = true;
  }

  bool _memory(int op) => const [
        32,
        32,
        33,
        34,
        35,
        36,
        37,
        39,
        40,
        41,
        43,
        49,
        53,
        55,
        57,
        61,
        63
      ].contains(op >>> 26);

  bool _branch(int op) {
    final code = op >>> 26;
    return code >= 1 && code <= 7 ||
        code == 0 && const [8, 9].contains(op & 63) ||
        code >= 20 && code <= 23 ||
        _fpEnabled && code == 17 && ((op >>> 21) & 31) == 8;
  }

  bool _supported(int op) {
    final code = op >>> 26;
    if (code == 17) {
      if (!_fpEnabled) return false;
      final fmt = (op >>> 21) & 31, fn = op & 63;
      return const [0, 1, 2, 4, 5, 6].contains(fmt) ||
          _nativeFpuOp(fmt, fn) ||
          fpuHelper != null &&
              const [16, 17, 20, 21].contains(fmt) &&
              (fn <= 15 || const [32, 33, 36, 37].contains(fn) || fn >= 48);
    }
    if (const [49, 53, 57, 61].contains(code)) return _fpEnabled;
    if (code == 0) {
      return const [
        0,
        2,
        3,
        4,
        6,
        7,
        15,
        16,
        17,
        18,
        19,
        24,
        25,
        32,
        33,
        34,
        35,
        36,
        37,
        38,
        39,
        42,
        43,
        45,
        47,
        56,
        58,
        59,
        60,
        62,
        63
      ].contains(op & 63);
    }
    return const [
      8,
      9,
      10,
      11,
      12,
      13,
      14,
      15,
      25,
      32,
      33,
      35,
      36,
      37,
      39,
      40,
      41,
      43,
      47,
      55,
      63
    ].contains(code);
  }

  bool _trapping(int op) =>
      op >>> 26 == 8 || (op >>> 26 == 0 && const [32, 34].contains(op & 63));

  IrValue _checkedWord(IrValue a, IrValue value, IrExit exit,
      {bool subtract = false}) {
    final result = subtract ? b.sub(a, value) : b.add(a, value);
    final overflow =
        b.and(b.xor(a, result), b.xor(subtract ? a : result, value));
    b.exitIf(b.ltS(overflow, _c(0)), exit);
    return result;
  }

  bool _mayExit(int op) =>
      _memory(op) ||
      _trapping(op) ||
      op >>> 26 == 17 && _nativeFpuOp((op >>> 21) & 31, op & 63);

  // C.EQ, C.LT and C.LE for the single and double formats.
  static const _nativeCompares = [0x32, 0x3c, 0x3e];

  // ROUND.W, TRUNC.W and CVT.W; CVT.S from double and CVT.D from single.
  static const _nativeToWord = [12, 13, 36];

  bool _nativeFpuOp(int fmt, int fn) =>
      nativeFpu &&
      const [16, 17].contains(fmt) &&
      (fn <= 2 ||
          _nativeCompares.contains(fn) ||
          _nativeToWord.contains(fn) ||
          (fn == 32 && fmt == 17) ||
          (fn == 33 && fmt == 16));

  // Condition for finite operands. Zeros of either sign are equal, and
  // less-than compares the sign bits first. Equal sign bits order the
  // magnitudes unsigned: reversed for negative values.
  IrValue _fpCompare(int cond, IrValue x, IrValue y, IrType type) {
    final wide = type == IrType.i64;
    final zero = wide ? _c64(0) : _c(0);
    final magnitude = wide ? b.c64Parts(-1, 0x7fffffff) : _c(0x7fffffff);
    final xNeg = b.ltS(x, zero), yNeg = b.ltS(y, zero);
    final bothZero =
        b.and(b.eq(b.and(x, magnitude), zero), b.eq(b.and(y, magnitude), zero));
    final equal = b.or(b.eq(x, y), bothZero);
    if (cond == 2) return equal;
    final sameSign = b.select(xNeg, b.ltU(y, x), b.ltU(x, y));
    final differentSign = b.and(xNeg, b.eq(bothZero, _c(0)));
    final less = b.select(b.ne(xNeg, yNeg), differentSign, sameSign);
    return cond == 12 ? less : b.or(less, equal);
  }

  bool _nativeFloat(int op, IrExit? exit) {
    final fmt = (op >>> 21) & 31, fn = op & 63;
    if (!_nativeFpuOp(fmt, fn)) return false;
    final compare = _nativeCompares.contains(fn);
    final type = fmt == 16 ? IrType.i32 : IrType.i64;
    final fs = (op >>> 11) & 31, ft = (op >>> 16) & 31, fd = (op >>> 6) & 31;
    final a = b.ctxLoad(_fpWord(fs), type: type);
    final mask = fmt == 16 ? _c(0x7f800000) : b.c64Parts(0, 0x7ff00000);
    if (fn >= 12 && !compare) {
      // Conversions read only fs. Nonfinite operands and words out of
      // range leave for the CPU, as does CVT.W outside round-to-nearest.
      if (fn == 32 || fn == 33) {
        b.exitIf(b.eq(b.and(a, mask), mask), exit!);
        b.ctxStore(_fpWord(fd), b.floatConvert(a));
        return true;
      }
      // |value| < 2^31: the biased exponent is below 127 + 31 (1023 + 31).
      final limit = fmt == 16 ? _c(0x4f000000) : b.c64Parts(0, 0x41e00000);
      b.exitIf(b.eq(b.ltU(b.and(a, mask), limit), _c(0)), exit!);
      if (fn == 36) {
        b.exitIf(b.ne(b.and(b.ctxLoad(ctxFpuControl), _c(3)), _c(0)), exit);
      }
      b.ctxStore(_fpWord(fd), b.floatToInt(a, truncate: fn == 13));
      return true;
    }
    final value = b.ctxLoad(_fpWord(ft), type: type);
    // Preserve interpreter NaN payload behavior through the CPU path.
    b.exitIf(b.or(b.eq(b.and(a, mask), mask), b.eq(b.and(value, mask), mask)),
        exit!);
    if (compare) {
      final cond = _fpCompare(fn & 15, a, value, type);
      // Only the condition bit (FCSR bit 23) changes.
      final fcsr = b.ctxLoad(ctxFpuControl);
      b.ctxStore(ctxFpuControl,
          b.or(b.and(fcsr, _c(0xff7fffff)), b.shl(cond, _c(23))));
      return true;
    }
    b.ctxStore(
        _fpWord(fd),
        b.floatBinary(
            fn == 0
                ? IrOp.floatAdd
                : fn == 1
                    ? IrOp.floatSub
                    : IrOp.floatMul,
            a,
            value));
    return true;
  }

  IrBlock? translate(int pc, {int tag = 0}) {
    _tag = tag;
    b = IrBuilder(pc, tag: tag);
    _resetRegisters();
    _dirty.clear();
    _hi = _lo = null;
    _hiDirty = _loDirty = false;
    var spent = 0, at = pc;
    final visited = <int>{};
    IrBlock? end() => spent == 0
        ? null
        : b.finish(IrExitTerm(_snapshot(at, spent)), cost: spent);
    while (spent < maxInstructions) {
      final op = fetch(at);
      if (op == null) return end();
      visited.add(at);
      if (_branch(op)) {
        final code = op >>> 26, rt = (op >>> 16) & 31;
        if (code == 1 && !const [0, 1, 2, 3, 16, 17, 18, 19].contains(rt))
          return end();
        final slot = fetch((at + 4) & 0xffffffff);
        if (slot == null || !_supported(slot)) return end();
        final target = ((at + 4) & 0xf0000000) | ((op & 0x3ffffff) << 2);
        // Let the CPU recognize its existing idle-loop optimization.
        if (slot == 0 && (op == 0x1000ffff || code == 2 && target == at)) {
          return end();
        }
        _guard(at, op);
        _guard((at + 4) & 0xffffffff, slot);
        final beforeBranch = _mayExit(slot) ? _snapshot(at, spent) : null;
        final term = _branchTerm(op, at);
        final likely = code >= 20 && code <= 23 ||
            (code == 1 || code == 17) && (rt & 2) != 0;
        if (likely) {
          b.exitIf(
              b.eq((term as IrBranch).cond, _c(0)),
              _snapshot((at + 8) & 0xffffffff, spent + 1,
                  reason: JitReason.miss, link: true));
        }
        _execute(slot, beforeBranch);
        visited.add((at + 4) & 0xffffffff);
        if (inlineJumps &&
            code == 2 &&
            spent + 2 < maxInstructions &&
            !visited.contains(target) &&
            fetch(target) != null) {
          spent += 2;
          at = target;
          continue;
        }
        _flush();
        return b.finish(term, cost: spent + 2);
      }
      if (!_supported(op)) return end();
      _guard(at, op);
      _execute(op, _mayExit(op) ? _snapshot(at, spent) : null);
      spent++;
      at = (at + 4) & 0xffffffff;
    }
    _flush();
    return b.finish(IrJump(at, tag: _tag), cost: spent);
  }

  void _guard(int pc, int op) {
    protect(pc);
    // RAM is big endian; compiled guard loads are little endian.
    final raw = ((op & 255) << 24) |
        ((op & 0xff00) << 8) |
        ((op >>> 8) & 0xff00) |
        (op >>> 24);
    b.guard(pc, raw);
  }

  IrTerm _branchTerm(int op, int at) {
    var code = op >>> 26;
    final s = (op >>> 21) & 31, t = (op >>> 16) & 31, d = (op >>> 11) & 31;
    final next = (at + 8) & 0xffffffff;
    final target = (at + 4 + (op & 0xffff).toSigned(16) * 4) & 0xffffffff;
    if (code == 0) {
      final destination = _low(s);
      if ((op & 63) == 9) _word(d, _c(next));
      return IrJumpDyn(destination, tag: _tag);
    }
    if (code == 2 || code == 3) {
      if (code == 3) _word(31, _c(next));
      return IrJump(((at + 4) & 0xf0000000) | ((op & 0x3ffffff) << 2),
          tag: _tag);
    }
    if (code == 17) {
      final flag = b.and(b.ctxLoad(ctxFpuControl), _c(0x800000));
      return IrBranch(
          t.isOdd ? b.ne(flag, _c(0)) : b.eq(flag, _c(0)), target, next,
          tagTrue: _tag, tagFalse: _tag);
    }
    if (code >= 20 && code <= 23) code -= 16;
    final a = _get64(s), zero = _c64(0);
    final condition = switch (code) {
      1 => t.isEven ? b.ltS(a, zero) : b.eq(b.ltS(a, zero), _c(0)),
      4 => b.eq(a, _get64(t)),
      5 => b.ne(a, _get64(t)),
      6 => b.or(b.ltS(a, zero), b.eq(a, zero)),
      _ => b.eq(b.or(b.ltS(a, zero), b.eq(a, zero)), _c(0)),
    };
    if (code == 1 && t >= 16) _word(31, _c(next));
    return IrBranch(condition, target, next, tagTrue: _tag, tagFalse: _tag);
  }

  void _execute(int op, IrExit? sideExit) {
    final code = op >>> 26, s = (op >>> 21) & 31;
    final t = (op >>> 16) & 31, d = (op >>> 11) & 31;
    final n = (op >>> 6) & 31, imm = (op & 0xffff).toSigned(16);
    if (code == 0) {
      final fn = op & 63;
      if (fn == 15 || op == 0) return;
      switch (fn) {
        case 0:
          _word(d, b.shl(_low(t), _c(n)));
        case 2:
          _word(d, b.shrU(_low(t), _c(n)));
        case 3:
          _word(d, b.shrS(_low(t), _c(n)));
        case 4:
          _word(d, b.shl(_low(t), _low(s)));
        case 6:
          _word(d, b.shrU(_low(t), _low(s)));
        case 7:
          _word(d, b.shrS(_low(t), _low(s)));
        case 16:
          _put64(d, _getHi());
        case 17:
          _putHi(_get64(s));
        case 18:
          _put64(d, _getLo());
        case 19:
          _putLo(_get64(s));
        case 24 || 25:
          // The 32-bit operands are extended, so the low 64 bits of the
          // product are exact.
          final unsigned = fn == 25;
          final x = unsigned ? b.zext32(_low(s)) : b.sext32(_low(s));
          final y = unsigned ? b.zext32(_low(t)) : b.sext32(_low(t));
          final product = b.mul(x, y);
          _putLo(b.sext32(b.trunc32(product)));
          _putHi(b.sext32(b.trunc32(b.shrU(product, _c(32)))));
        case 32:
          _word(d, _checkedWord(_low(s), _low(t), sideExit!));
        case 34:
          _word(d, _checkedWord(_low(s), _low(t), sideExit!, subtract: true));
        case 33:
          _word(d, b.add(_low(s), _low(t)));
        case 35:
          _word(d, b.sub(_low(s), _low(t)));
        case 36:
          _put64(d, b.and(_get64(s), _get64(t)));
        case 37:
          _put64(d, b.or(_get64(s), _get64(t)));
        case 38:
          _put64(d, b.xor(_get64(s), _get64(t)));
        case 39:
          _put64(d, b.not(b.or(_get64(s), _get64(t))));
        case 42:
          _word(d, b.ltS(_get64(s), _get64(t)));
        case 43:
          _word(d, b.ltU(_get64(s), _get64(t)));
        case 45:
          _put64(d, b.add(_get64(s), _get64(t)));
        case 47:
          _put64(d, b.sub(_get64(s), _get64(t)));
        default:
          final shift = _c(n + (fn >= 60 ? 32 : 0));
          final value = _get64(t);
          _put64(
              d,
              fn == 56 || fn == 60
                  ? b.shl(value, shift)
                  : fn == 59 || fn == 63
                      ? b.shrS(value, shift)
                      : b.shrU(value, shift));
      }
      return;
    }
    if (code == 17) {
      if (_nativeFloat(op, sideExit)) return;
      final at = _fpWord(d);
      switch (s) {
        case 0:
          _word(t, b.ctxLoad(at));
        case 1:
          _put64(t, b.ctxLoad(at, type: IrType.i64));
        case 2:
          _word(t, d == 31 ? b.ctxLoad(ctxFpuControl) : _c(0x511));
        case 4:
          b.ctxStore(at, _low(t));
        case 5:
          b.ctxStore(at, _get64(t));
        case 6:
          if (d == 31) b.ctxStore(ctxFpuControl, _low(t));
        default:
          b.call(fpuHelper!, _c(op));
      }
      return;
    }
    switch (code) {
      case 8:
        _word(t, _checkedWord(_low(s), _c(imm), sideExit!));
      case 9:
        _word(t, b.add(_low(s), _c(imm)));
      case 10:
        _word(t, b.ltS(_get64(s), _c64(imm)));
      case 11:
        _word(t, b.ltU(_get64(s), _c64(imm)));
      case 12:
        _put64(t, b.and(_get64(s), _c64(op & 0xffff)));
      case 13:
        _put64(t, b.or(_get64(s), _c64(op & 0xffff)));
      case 14:
        _put64(t, b.xor(_get64(s), _c64(op & 0xffff)));
      case 15:
        _word(t, _c((op & 0xffff) << 16));
      case 25:
        _put64(t, b.add(_get64(s), _c64(imm)));
      case 47:
        return; // CACHE has no modeled cache effects in this core.
      default:
        final exit = sideExit!;
        final size = switch (code) {
          32 || 36 || 40 => 1,
          33 || 37 || 41 => 2,
          53 || 55 || 61 || 63 => 8,
          _ => 4,
        };
        final address = b.add(_low(s), _c(imm));
        final segment = b.and(address, _c(0xc0000000));
        b.exitIf(
            b.or(b.ne(segment, _c(0x80000000)),
                b.ne(b.and(address, _c(size - 1)), _c(0))),
            exit);
        final fpMemory = const [49, 53, 57, 61].contains(code);
        final type = fpMemory && size == 4 ? IrType.i32 : IrType.i64;
        if (const [40, 41, 43, 57, 61, 63].contains(code)) {
          final value = fpMemory
              ? b.ctxLoad(_fpWord(t), type: type)
              : size == 8
                  ? _get64(t)
                  : _low(t);
          b.store(size, address, value, endian: IrEndian.big, unmapped: exit);
        } else {
          final signed = const [32, 33, 35].contains(code);
          final value = b.load(size, address,
              type: type, signed: signed, endian: IrEndian.big, unmapped: exit);
          if (fpMemory) {
            b.ctxStore(_fpWord(t), value);
          } else {
            _put64(t, value);
          }
        }
    }
  }
}
