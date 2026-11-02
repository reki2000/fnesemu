import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

/// Translates R5900 integer code into IR blocks.
///
/// A general register is 128 bits wide and takes four context words: the
/// low 64 bits at [ctxRegs] + 4n and the high 64 bits after them. Each low
/// half is one i64 SSA value; word results are truncated and sign extended
/// explicitly. Only LQ and SQ touch the high halves.
///
/// The translated subset is the integer ALU, the shifts, the branches and
/// jumps, MOVZ/MOVN, the aligned loads and stores up to 128 bits, integer
/// DIV/DIVU and the MMI DIV1/DIVU1, and COP1: the register moves, LWC1 and
/// SWC1, the single precision arithmetic, the compares and CVT.W.S. HI/LO
/// and HI1/LO1 live in four extra 64-bit context slots synchronized by
/// Ps2Jit at compiled/interpreter boundaries, and the division forms
/// preserve the zero-divisor and overflow semantics. The COP1 register
/// images follow the HI/LO slots in the context; the accumulator and
/// FCR31 take one word each after them, and the adapter copies those two
/// in and out around a run because the interpreter keeps them in plain
/// fields. EE floating point semantics are rebuilt with integer
/// operations around the binary64 IR operations: decode and encode are
/// exact bit constructions (see [_fdecode] and [_fencode]), so compiled
/// results match the interpreter bit for bit. COP0 and COP2, BC1,
/// CVT.S.W (the IR has no integer to float conversion), the other
/// multimedia instructions, the unaligned accesses and the exceptions
/// are left to the interpreter: a block ends before them, and a load or
/// store, a trapping add or a misaligned address exits before its
/// effects.
final class R5900Translator {
  static const defaultMaxInstructions = 32;
  static const ctxRegs = JitCtx.user;
  static const ctxHi = ctxRegs + 32 * 4;
  static const ctxLo = ctxHi + 2;
  static const ctxHi1 = ctxLo + 2;
  static const ctxLo1 = ctxHi1 + 2;
  static const ctxFpr = ctxLo1 + 2;
  static const ctxFacc = ctxFpr + 32;
  static const ctxFcr31 = ctxFacc + 1;
  static const ctxWords = ctxFcr31 + 1;
  static const interpret = JitReason.user;

  /// FCR31 cause bits I, D, O, U (bits 17..14), as the interpreter's FPU
  /// extension lays them out.
  static const _flagI = 1 << 17, _flagD = 1 << 16;
  static const _flagO = 1 << 15, _flagU = 1 << 14;
  static const _causeMask = _flagI | _flagD | _flagO | _flagU;
  static const _conditionBit = 1 << 23;

  final int maxInstructions;
  final int? Function(int) fetch;
  final void Function(int) protect;
  late IrBuilder b;
  final _lowRegs = List<IrValue?>.filled(32, null);
  final _wideRegs = List<IrValue?>.filled(32, null);
  final _dirty = <int>{};
  final _fregs = List<IrValue?>.filled(32, null);
  final _fdirty = <int>{};
  IrValue? _facc;
  bool _faccDirty = false;
  IrValue? _fcr;
  bool _fcrDirty = false;
  final _specialRegs = <int, IrValue>{};
  final _specialDirty = <int>{};

  R5900Translator(
      {required this.fetch,
      required this.protect,
      this.maxInstructions = defaultMaxInstructions});

  static int _ctxLow(int r) => ctxRegs + r * 4;
  static int _ctxHigh(int r) => ctxRegs + r * 4 + 2;

  IrValue _c(int value) => b.c32(value);
  IrValue _c64(int value) => b.c64Parts(value, value >> 32);
  IrValue _specialReg(int word) =>
      _specialRegs[word] ??= b.ctxLoad(word, type: IrType.i64);
  void _setSpecial(int word, IrValue value) {
    _specialRegs[word] = value;
    _specialDirty.add(word);
  }

  void _divide(int s, int t, {bool signed = true, bool pipe1 = false}) {
    final x = _low(s), y = _low(t), zero = _c(0);
    final byZero = b.eq(y, zero);
    final quotient = signed ? b.divS(x, y) : b.divU(x, y);
    final remainder = signed ? b.remS(x, y) : b.remU(x, y);
    final zeroQuotient = signed
        ? b.select(b.ltS(x, zero), _c(1), _c(-1))
        : _c(-1);
    _setSpecial(pipe1 ? ctxLo1 : ctxLo,
        b.sext32(b.select(byZero, zeroQuotient, quotient)));
    _setSpecial(pipe1 ? ctxHi1 : ctxHi,
        b.sext32(b.select(byZero, x, remainder)));
  }

  IrValue _get64(int r) => r == 0
      ? _c64(0)
      : _wideRegs[r] ??= b.ctxLoad(_ctxLow(r), type: IrType.i64);

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

  IrExit _snapshot(int pc, int spent, {int reason = interpret, bool link = false}) {
    _fcrMaterialize();
    return IrExit(reason, pc, spent: spent, link: link, stores: [
      for (final r in _dirty) (_ctxLow(r), _wideRegs[r]!),
      for (final r in _fdirty) (ctxFpr + r, _fregs[r]!),
      if (_faccDirty) (ctxFacc, _facc!),
      if (_fcrDirty) (ctxFcr31, _fcr!),
      for (final word in _specialDirty) (word, _specialRegs[word]!),
    ]);
  }

  void _flush() {
    _fcrMaterialize();
    for (final r in _dirty) {
      b.ctxStore(_ctxLow(r), _wideRegs[r]!);
    }
    for (final r in _fdirty) {
      b.ctxStore(ctxFpr + r, _fregs[r]!);
    }
    if (_faccDirty) b.ctxStore(ctxFacc, _facc!);
    if (_fcrDirty) b.ctxStore(ctxFcr31, _fcr!);
    for (final word in _specialDirty) {
      b.ctxStore(word, _specialRegs[word]!);
    }
  }

  static const _loads = [30, 32, 33, 35, 36, 37, 39, 49, 55];
  static const _stores = [31, 40, 41, 43, 57, 63];

  static bool _memory(int op) {
    final code = op >>> 26;
    return _loads.contains(code) || _stores.contains(code);
  }

  static bool _branch(int op) {
    final code = op >>> 26;
    if (code == 1) {
      return const [0, 1, 2, 3, 16, 17, 18, 19].contains((op >>> 16) & 31);
    }
    return code >= 2 && code <= 7 ||
        code == 0 && const [8, 9].contains(op & 63) ||
        code >= 20 && code <= 23;
  }

  static const _special = [
    0, 2, 3, 4, 6, 7, 10, 11, 15, 16, 17, 18, 19, 20, 22, 23,
    26, 27, 32, 33, 34, 35, 36, 37, 38, //
    39, 42, 43, 45, 47, 56, 58, 59, 60, 62, 63,
  ];
  static const _immediate = [8, 9, 10, 11, 12, 13, 14, 15, 25, 47, 51];

  /// Whether COP1 was usable for the block being translated (the tag's
  /// low bit, set by the adapter from Status.CU1).
  bool _cop1Usable = false;

  bool _supported(int op) {
    final code = op >>> 26;
    if (code == 0) return _special.contains(op & 63);
    if (code == 17) return _cop1Usable && _cop1Supported(op);
    if (code == 49 || code == 57) return _cop1Usable;
    if (code == 28) {
      return const [0x10, 0x11, 0x12, 0x13, 0x1a, 0x1b]
          .contains(op & 63);
    }
    return _immediate.contains(code) || _memory(op);
  }

  /// COP1 forms the translator covers: the register moves, and of the
  /// single precision functions everything the interpreter implements
  /// except CVT.S.W, which needs an integer to float conversion the IR
  /// does not have. BC1 (format 8..11) ends the block.
  static bool _cop1Supported(int op) {
    final fmt = (op >>> 21) & 31;
    if (fmt == 0 || fmt == 2 || fmt == 4 || fmt == 6) return true;
    if (fmt != 16) return false;
    return const [
      0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x16, //
      0x18, 0x19, 0x1a, 0x1c, 0x1d, 0x1e, 0x1f, 0x24, 0x28, 0x29, //
      0x30, 0x32, 0x34, 0x36,
    ].contains(op & 63);
  }

  static bool _trapping(int op) =>
      op >>> 26 == 8 || (op >>> 26 == 0 && const [32, 34].contains(op & 63));

  static bool _mayExit(int op) => _memory(op) || _trapping(op);

  IrValue _checkedWord(IrValue a, IrValue value, IrExit exit,
      {bool subtract = false}) {
    final result = subtract ? b.sub(a, value) : b.add(a, value);
    final overflow =
        b.and(b.xor(a, result), b.xor(subtract ? a : result, value));
    b.exitIf(b.ltS(overflow, _c(0)), exit);
    return result;
  }

  IrBlock? translate(int pc, {int tag = 0}) {
    _cop1Usable = tag & 1 != 0;
    b = IrBuilder(pc, tag: tag);
    _wideRegs.fillRange(0, 32, null);
    _lowRegs.fillRange(0, 32, null);
    _dirty.clear();
    _fregs.fillRange(0, 32, null);
    _fdirty.clear();
    _facc = null;
    _faccDirty = false;
    _fcr = null;
    _fcrDirty = false;
    _fcrBase = null;
    _lastCause = null;
    _stickyAcc = null;
    _specialRegs.clear();
    _specialDirty.clear();
    var spent = 0, at = pc;
    IrBlock? end() => spent == 0
        ? null
        : b.finish(IrExitTerm(_snapshot(at, spent)), cost: spent);
    while (spent < maxInstructions) {
      final op = fetch(at);
      if (op == null) return end();
      if (_branch(op)) {
        final slot = fetch((at + 4) & 0xffffffff);
        if (slot == null || !_supported(slot) || _branch(slot)) return end();
        b.guard(at, op);
        protect(at);
        b.guard((at + 4) & 0xffffffff, slot);
        protect((at + 4) & 0xffffffff);
        final beforeBranch = _mayExit(slot) ? _snapshot(at, spent) : null;
        final term = _branchTerm(op, at);
        final code = op >>> 26;
        final likely =
            code >= 20 && code <= 23 || code == 1 && ((op >>> 16) & 2) != 0;
        if (likely) {
          b.exitIf(
              b.eq((term as IrBranch).cond, _c(0)),
              _snapshot((at + 8) & 0xffffffff, spent + 1,
                  reason: JitReason.miss, link: true));
        }
        _execute(slot, beforeBranch);
        _flush();
        return b.finish(term, cost: spent + 2);
      }
      if (!_supported(op)) return end();
      b.guard(at, op);
      protect(at);
      _execute(op, _mayExit(op) ? _snapshot(at, spent) : null);
      spent++;
      at = (at + 4) & 0xffffffff;
    }
    _flush();
    return b.finish(IrJump(at), cost: spent);
  }

  IrTerm _branchTerm(int op, int at) {
    var code = op >>> 26;
    final s = (op >>> 21) & 31, t = (op >>> 16) & 31, d = (op >>> 11) & 31;
    final next = (at + 8) & 0xffffffff;
    final target = (at + 4 + (op & 0xffff).toSigned(16) * 4) & 0xffffffff;
    if (code == 0) {
      final destination = _low(s);
      if ((op & 63) == 9) _word(d, _c(next));
      return IrJumpDyn(destination);
    }
    if (code == 2 || code == 3) {
      if (code == 3) _word(31, _c(next));
      return IrJump((at & 0xf0000000) | ((op & 0x3ffffff) << 2));
    }
    if (code >= 20 && code <= 23) code -= 16;
    final a = _get64(s), zero = _c64(0);
    final condition = switch (code) {
      1 => t.isEven ? b.ltS(a, zero) : b.ltS(_c64(-1), a),
      4 => b.eq(a, _get64(t)),
      5 => b.ne(a, _get64(t)),
      6 => b.ltS(a, _c64(1)),
      _ => b.ltS(zero, a),
    };
    if (code == 1 && t >= 16) _word(31, _c(next));
    return IrBranch(condition, target, next);
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
          _word(d, b.shl(_low(t), b.and(_low(s), _c(31))));
        case 6:
          _word(d, b.shrU(_low(t), b.and(_low(s), _c(31))));
        case 7:
          _word(d, b.shrS(_low(t), b.and(_low(s), _c(31))));
        case 10 || 11: // MOVZ, MOVN
          final zero = b.eq(_get64(t), _c64(0));
          _put64(
              d,
              fn == 10
                  ? b.select(zero, _get64(s), _get64(d))
                  : b.select(zero, _get64(d), _get64(s)));
        case 16: // MFHI
          _put64(d, _specialReg(ctxHi));
        case 17: // MTHI
          _setSpecial(ctxHi, _get64(s));
        case 18: // MFLO
          _put64(d, _specialReg(ctxLo));
        case 19: // MTLO
          _setSpecial(ctxLo, _get64(s));
        case 26 || 27: // DIV, DIVU
          _divide(s, t, signed: fn == 26);
        case 20 || 22 || 23: // DSLLV, DSRLV, DSRAV
          final shift = b.and(_low(s), _c(63));
          final value = _get64(t);
          _put64(
              d,
              fn == 20
                  ? b.shl(value, shift)
                  : fn == 22
                      ? b.shrU(value, shift)
                      : b.shrS(value, shift));
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
    switch (code) {
      case 28: // MMI HI1/LO1 transfers and second integer divider
        switch (op & 63) {
          case 0x10:
            _put64(d, _specialReg(ctxHi1));
          case 0x11:
            _setSpecial(ctxHi1, _get64(s));
          case 0x12:
            _put64(d, _specialReg(ctxLo1));
          case 0x13:
            _setSpecial(ctxLo1, _get64(s));
          case 0x1a || 0x1b:
            _divide(s, t, signed: (op & 63) == 0x1a, pipe1: true);
        }
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
      case 47 || 51:
        return; // CACHE and PREF have no modeled effect
      case 30 || 31:
        _quad(code == 31, s, t, imm, sideExit!);
      case 17:
        _cop1(op);
      case 49 || 57:
        _accessF(code == 57, s, t, imm, sideExit!);
      default:
        _access(code, s, t, imm, sideExit!);
    }
  }

  /// Exits unless [address] is aligned to [size] and in a segment that the
  /// adapter maps to main memory: user addresses below 0x40000000 (which
  /// the adapter requires to be mapped one to one) and the unmapped kernel
  /// segments. Pages outside main memory exit at the access.
  void _checkAddress(IrValue address, int size, IrExit exit) {
    final segment = b.shrU(address, _c(29));
    final allowed = b.and(b.shrU(_c(0x33), segment), _c(1));
    var bad = b.eq(allowed, _c(0));
    if (size > 1) bad = b.or(bad, b.ne(b.and(address, _c(size - 1)), _c(0)));
    b.exitIf(bad, exit);
  }

  void _access(int code, int s, int t, int imm, IrExit exit) {
    final size = switch (code) {
      32 || 36 || 40 => 1,
      33 || 37 || 41 => 2,
      55 || 63 => 8,
      _ => 4,
    };
    final address = b.add(_low(s), _c(imm));
    _checkAddress(address, size, exit);
    if (_stores.contains(code)) {
      b.store(size, address, size == 8 ? _get64(t) : _low(t), unmapped: exit);
      return;
    }
    final signed = const [32, 33, 35].contains(code);
    _put64(
        t,
        b.load(size, address,
            type: IrType.i64, signed: signed, unmapped: exit));
  }

  /// LQ and SQ ignore the low four address bits
  void _quad(bool store, int s, int t, int imm, IrExit exit) {
    final address = b.and(b.add(_low(s), _c(imm)), _c(~15));
    _checkAddress(address, 1, exit);
    final high = b.add(address, _c(8));
    if (store) {
      b.store(8, address, _get64(t), unmapped: exit);
      b.store(
          8, high, t == 0 ? _c64(0) : b.ctxLoad(_ctxHigh(t), type: IrType.i64),
          unmapped: exit);
      return;
    }
    final lowValue = b.load(8, address, type: IrType.i64, unmapped: exit);
    final highValue = b.load(8, high, type: IrType.i64, unmapped: exit);
    if (t == 0) return;
    _put64(t, lowValue);
    b.ctxStore(_ctxHigh(t), highValue);
  }

  /// LWC1 and SWC1: [t] names a COP1 register instead of a general one.
  void _accessF(bool store, int s, int t, int imm, IrExit exit) {
    final address = b.add(_low(s), _c(imm));
    _checkAddress(address, 4, exit);
    if (store) {
      b.store(4, address, _fget(t), unmapped: exit);
      return;
    }
    _fput(t, b.load(4, address, unmapped: exit));
  }

  IrValue _fget(int r) => _fregs[r] ??= b.ctxLoad(ctxFpr + r);

  void _fput(int r, IrValue value) {
    _fregs[r] = value;
    _fdirty.add(r);
  }

  IrValue _faccGet() => _facc ??= b.ctxLoad(ctxFacc);

  void _faccPut(IrValue value) {
    _facc = value;
    _faccDirty = true;
  }

  /// FCR31 with any pending arithmetic flags folded in (see [_fcrRaise]).
  IrValue _fcrGet() {
    _fcrMaterialize();
    return _fcr ??= b.ctxLoad(ctxFcr31);
  }

  IrValue? _fcrBase;
  IrValue? _lastCause;
  IrValue? _stickyAcc;

  /// The interpreter's _begin: an arithmetic operation clears the cause
  /// bits of FCR31 before it runs. Under the pending scheme below that
  /// clearing is implicit in the fold, so this only opens a sequence.
  void _fcrBegin() {
    _fcrBase ??= _fcr ??= b.ctxLoad(ctxFcr31);
  }

  /// Records an arithmetic operation's flags instead of updating FCR31
  /// in place. A run of arithmetic operations shows only the last one's
  /// cause bits (each operation's _begin clears the previous ones) plus
  /// every operation's sticky mirrors, which nothing clears, so the run
  /// folds into one update when the flags are next observed: at a
  /// compare, a CFC1, a store out of the block, or any other [_fcrGet].
  void _fcrRaise(IrValue cause) {
    _fcrBegin();
    _lastCause = cause;
    final sticky = b.and(b.shrU(cause, _c(11)), _c(0x78));
    _stickyAcc = _stickyAcc == null ? sticky : b.or(_stickyAcc!, sticky);
  }

  void _fcrMaterialize() {
    final base = _fcrBase;
    if (base == null) return;
    _fcr = b.or(b.and(base, _c(~_causeMask)),
        b.or(_lastCause ?? _c(0), _stickyAcc ?? _c(0)));
    _fcrDirty = true;
    _fcrBase = null;
    _lastCause = null;
    _stickyAcc = null;
  }

  void _fcrSetCondition(IrValue cond) {
    _fcr = b.or(b.and(_fcrGet(), _c(~_conditionBit)), b.shl(cond, _c(23)));
    _fcrDirty = true;
  }

  /// The exact double value of a register image, as binary64 bits. A
  /// normal image (2^23 + fraction) * 2^(exp - 150) is the binary64 with
  /// exponent field exp + 896 and the fraction shifted up by 29 places,
  /// so it is built with integer operations alone; an exponent field of
  /// zero (a denormal image) reads as +0.0, whatever its sign.
  IrValue _fdecode(IrValue bits) {
    final exp = b.and(b.shrU(bits, _c(23)), _c(0xff));
    final mant = b.and(bits, _c(0x7fffff));
    final hi = b.or(
        b.shl(b.shrU(bits, _c(31)), _c(31)),
        b.or(b.shl(b.add(exp, _c(896)), _c(20)), b.shrU(mant, _c(3))));
    final packed =
        b.or(b.zext32(b.shl(mant, _c(29))), b.shl(b.zext32(hi), _c(32)));
    return b.select(b.eq(exp, _c(0)), _c64(0), packed);
  }

  /// Truncates a binary64 result to a register image, as the interpreter's
  /// encode: returns the image and the cause bits (underflow or overflow)
  /// it raises. An exact zero keeps its sign and raises nothing, and a
  /// nonzero result too small for a normal image flushes to zero.
  (IrValue, IrValue) _fencode(IrValue raw) {
    final hi = b.trunc32(b.shrU(raw, _c(32)));
    final lo = b.trunc32(raw);
    final sign = b.and(hi, _c(0x80000000));
    final eeExp = b.sub(b.and(b.shrU(hi, _c(20)), _c(0x7ff)), _c(896));
    final isZero = b.and(b.eq(b.and(hi, _c(0x7fffffff)), _c(0)), b.eq(lo, _c(0)));
    final under = b.and(b.ltS(eeExp, _c(1)), b.eq(isZero, _c(0)));
    final over = b.eq(b.ltS(eeExp, _c(256)), _c(0));
    final normal = b.or(
        sign,
        b.or(b.shl(eeExp, _c(23)),
            b.or(b.shl(b.and(hi, _c(0xfffff)), _c(3)), b.shrU(lo, _c(29)))));
    final bits = b.select(isZero, sign,
        b.select(under, sign, b.select(over, b.or(sign, _c(0x7fffffff)), normal)));
    final cause = b.select(isZero, _c(0),
        b.select(under, _c(_flagU), b.select(over, _c(_flagO), _c(0))));
    return (bits, cause);
  }

  /// Division with the EE zero handling, as the interpreter's _divide: a
  /// zero divisor gives the clamped magnitude with [sign] and raises D,
  /// or I when the dividend is zero too. A divisor is zero when its
  /// exponent field is zero, which is when decode reads it as zero; for
  /// RSQRT the divisor is a square root, whose zero is the same condition
  /// on the original operand, so [yRaw] is that operand's image.
  (IrValue, IrValue) _fdivide(
      IrValue x, IrValue y, IrValue xRaw, IrValue yRaw, IrValue sign) {
    final isY0 = b.eq(b.and(yRaw, _c(0x7f800000)), _c(0));
    final isX0 = b.eq(b.and(xRaw, _c(0x7f800000)), _c(0));
    final (bits, cause) = _fencode(b.floatBinary(IrOp.floatDiv, x, y));
    return (
      b.select(isY0, b.or(sign, _c(0x7fffffff)), bits),
      b.select(isY0, b.select(isX0, _c(_flagI), _c(_flagD)), cause),
    );
  }

  /// The invalid cause a square root raises for a negative nonzero image.
  IrValue _negativeCause(IrValue raw) => b.select(
      b.and(b.shrU(raw, _c(31)), b.ne(b.and(raw, _c(0x7f800000)), _c(0))),
      _c(_flagI),
      _c(0));

  IrValue _fabs(IrValue raw) =>
      b.and(raw, b.c64Parts(0xffffffff, 0x7fffffff));

  /// Encodes [value] into register [fd] and raises the flags of the
  /// encoding and of [extraCause].
  void _fd(int fd, IrValue value, [IrValue? extraCause]) {
    final (bits, cause) = _fencode(value);
    _fcrRaise(extraCause == null ? cause : b.or(cause, extraCause));
    _fput(fd, bits);
  }

  /// Encodes [value] into the accumulator and raises its flags.
  void _faccStore(IrValue value) {
    final (bits, cause) = _fencode(value);
    _fcrRaise(cause);
    _faccPut(bits);
  }

  /// An integer key that orders register images as their values order
  /// under an unsigned comparison: images decode reads as zero collapse
  /// to zero first, then the sign magnitude form maps to an unsigned
  /// order by flipping every bit of a negative image and only the sign
  /// bit of the rest.
  IrValue _forderKey(IrValue bits) {
    final norm = b.select(b.eq(b.and(bits, _c(0x7f800000)), _c(0)), _c(0), bits);
    return b.select(
        b.shrU(norm, _c(31)), b.not(norm), b.or(norm, _c(0x80000000)));
  }

  void _cop1(int op) {
    final fmt = (op >>> 21) & 31, rt = (op >>> 16) & 31;
    final fs = (op >>> 11) & 31, fd = (op >>> 6) & 31;
    switch (fmt) {
      case 0: // MFC1
        _word(rt, _fget(fs));
      case 2: // CFC1
        _word(rt, fs == 31 ? _fcrGet() : _c(fs == 0 ? 0x2e00 : 0));
      case 4: // MTC1
        _fput(fs, _low(rt));
      case 6: // CTC1 replaces FCR31 wholesale, pending flags included
        if (fs == 31) {
          _fcrBase = null;
          _lastCause = null;
          _stickyAcc = null;
          _fcr = b.and(_low(rt), _c(0x0183ffff));
          _fcrDirty = true;
        }
      default:
        _cop1Single(op & 63, fs, rt, fd);
    }
  }

  void _cop1Single(int fn, int fs, int ft, int fd) {
    final fsRaw = _fget(fs), ftRaw = _fget(ft);
    IrValue a() => _fdecode(fsRaw);
    IrValue c() => _fdecode(ftRaw);
    switch (fn) {
      case 0x00:
        _fcrBegin();
        _fd(fd, b.floatBinary(IrOp.floatAdd, a(), c()));
      case 0x01:
        _fcrBegin();
        _fd(fd, b.floatBinary(IrOp.floatSub, a(), c()));
      case 0x02:
        _fcrBegin();
        _fd(fd, b.floatBinary(IrOp.floatMul, a(), c()));
      case 0x03:
        _fcrBegin();
        final (bits, cause) = _fdivide(
            a(), c(), fsRaw, ftRaw, b.and(b.xor(fsRaw, ftRaw), _c(0x80000000)));
        _fcrRaise(cause);
        _fput(fd, bits);
      case 0x04: // SQRT
        _fcrBegin();
        _fd(fd, b.floatSqrt(_fabs(c())), _negativeCause(ftRaw));
      case 0x05: // ABS
        _fcrBegin();
        _fput(fd, b.and(fsRaw, _c(0x7fffffff)));
      case 0x06: // MOV
        _fput(fd, fsRaw);
      case 0x07: // NEG
        _fcrBegin();
        _fput(fd, b.xor(fsRaw, _c(0x80000000)));
      case 0x16: // RSQRT
        _fcrBegin();
        final (bits, cause) = _fdivide(a(), b.floatSqrt(_fabs(c())), fsRaw,
            ftRaw, b.and(fsRaw, _c(0x80000000)));
        _fcrRaise(b.or(cause, _negativeCause(ftRaw)));
        _fput(fd, bits);
      case 0x18:
        _fcrBegin();
        _faccStore(b.floatBinary(IrOp.floatAdd, a(), c()));
      case 0x19:
        _fcrBegin();
        _faccStore(b.floatBinary(IrOp.floatSub, a(), c()));
      case 0x1a:
        _fcrBegin();
        _faccStore(b.floatBinary(IrOp.floatMul, a(), c()));
      case 0x1c: // MADD
        _fcrBegin();
        _fd(
            fd,
            b.floatBinary(IrOp.floatAdd, _fdecode(_faccGet()),
                b.floatBinary(IrOp.floatMul, a(), c())));
      case 0x1d: // MSUB
        _fcrBegin();
        _fd(
            fd,
            b.floatBinary(IrOp.floatSub, _fdecode(_faccGet()),
                b.floatBinary(IrOp.floatMul, a(), c())));
      case 0x1e: // MADDA
        _fcrBegin();
        _faccStore(b.floatBinary(IrOp.floatAdd, _fdecode(_faccGet()),
            b.floatBinary(IrOp.floatMul, a(), c())));
      case 0x1f: // MSUBA
        _fcrBegin();
        _faccStore(b.floatBinary(IrOp.floatSub, _fdecode(_faccGet()),
            b.floatBinary(IrOp.floatMul, a(), c())));
      case 0x24: // CVT.W.S
        final exp = b.and(b.shrU(fsRaw, _c(23)), _c(0xff));
        final clamped = b.select(
            b.shrU(fsRaw, _c(31)), _c(0x80000000), _c(0x7fffffff));
        _fput(
            fd,
            b.select(b.eq(b.ltS(exp, _c(158)), _c(0)), clamped,
                b.floatToInt(_fdecode(fsRaw), truncate: true)));
      case 0x28: // MAX: fs when fs >= ft
        _fput(
            fd,
            b.select(b.eq(b.ltU(_forderKey(fsRaw), _forderKey(ftRaw)), _c(0)),
                fsRaw, ftRaw));
      case 0x29: // MIN: fs when fs <= ft
        _fput(
            fd,
            b.select(b.eq(b.ltU(_forderKey(ftRaw), _forderKey(fsRaw)), _c(0)),
                fsRaw, ftRaw));
      case 0x30: // C.F
        _fcrSetCondition(_c(0));
      case 0x32: // C.EQ
        _fcrSetCondition(b.eq(_forderKey(fsRaw), _forderKey(ftRaw)));
      case 0x34: // C.LT
        _fcrSetCondition(b.ltU(_forderKey(fsRaw), _forderKey(ftRaw)));
      case 0x36: // C.LE
        _fcrSetCondition(
            b.eq(b.ltU(_forderKey(ftRaw), _forderKey(fsRaw)), _c(0)));
    }
  }
}
