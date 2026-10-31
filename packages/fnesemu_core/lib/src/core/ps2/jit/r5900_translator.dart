import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

/// Translates R5900 integer code into IR blocks.
///
/// A general register is 128 bits wide and takes four context words: the
/// low 64 bits at [ctxRegs] + 4n and the high 64 bits after them. Each low
/// half is one i64 SSA value; word results are truncated and sign extended
/// explicitly. Only LQ and SQ touch the high halves.
///
/// The translated subset is the integer ALU, the shifts, the branches and
/// jumps, MOVZ/MOVN and the aligned loads and stores up to 128 bits. HI and
/// LO, the coprocessors, the multimedia instructions, the unaligned
/// accesses and the exceptions are left to the interpreter: a block ends
/// before them, and a load or store, a trapping add or a misaligned address
/// exits before its effects.
final class R5900Translator {
  static const defaultMaxInstructions = 32;
  static const ctxRegs = JitCtx.user;
  static const ctxWords = ctxRegs + 32 * 4;
  static const interpret = JitReason.user;

  final int maxInstructions;
  final int? Function(int) fetch;
  final void Function(int) protect;
  late IrBuilder b;
  final _lowRegs = List<IrValue?>.filled(32, null);
  final _wideRegs = List<IrValue?>.filled(32, null);
  final _dirty = <int>{};

  R5900Translator(
      {required this.fetch,
      required this.protect,
      this.maxInstructions = defaultMaxInstructions});

  static int _ctxLow(int r) => ctxRegs + r * 4;
  static int _ctxHigh(int r) => ctxRegs + r * 4 + 2;

  IrValue _c(int value) => b.c32(value);
  IrValue _c64(int value) => b.c64Parts(value, value >> 32);

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

  IrExit _snapshot(int pc, int spent,
          {int reason = interpret, bool link = false}) =>
      IrExit(reason, pc, spent: spent, link: link, stores: [
        for (final r in _dirty) (_ctxLow(r), _wideRegs[r]!),
      ]);

  void _flush() {
    for (final r in _dirty) {
      b.ctxStore(_ctxLow(r), _wideRegs[r]!);
    }
  }

  static const _loads = [30, 32, 33, 35, 36, 37, 39, 55];
  static const _stores = [31, 40, 41, 43, 63];

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
    0, 2, 3, 4, 6, 7, 10, 11, 15, 20, 22, 23, 32, 33, 34, 35, 36, 37, 38, //
    39, 42, 43, 45, 47, 56, 58, 59, 60, 62, 63,
  ];
  static const _immediate = [8, 9, 10, 11, 12, 13, 14, 15, 25, 47, 51];

  static bool _supported(int op) {
    final code = op >>> 26;
    if (code == 0) return _special.contains(op & 63);
    return _immediate.contains(code) || _memory(op);
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
    b = IrBuilder(pc, tag: tag);
    _wideRegs.fillRange(0, 32, null);
    _lowRegs.fillRange(0, 32, null);
    _dirty.clear();
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
      1 => t.isEven ? b.ltS(a, zero) : b.eq(b.ltS(a, zero), _c(0)),
      4 => b.eq(a, _get64(t)),
      5 => b.ne(a, _get64(t)),
      6 => b.or(b.ltS(a, zero), b.eq(a, zero)),
      _ => b.eq(b.or(b.ltS(a, zero), b.eq(a, zero)), _c(0)),
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
}
