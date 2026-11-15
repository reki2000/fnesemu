import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

/// Translates the COP2 macro instructions of VU0 for the EE recompiler
/// with the vector operations of the IR. Macro mode has no pipeline: the
/// results, the flags and Q take effect at once, as [Vu.macro] applies
/// them, and no micro program is running between two EE instructions.
///
/// In the context, the VF registers and the accumulator (register 32) take
/// four words each from [vf], VI0 to VI15 a halfword each from [vi], and
/// I, Q, R, the status, MAC and clip flags one word each from [scalars], in
/// the order of the scalars of [Vu].
final class Vu0Macro {
  final int vf, vi, scalars;

  Vu0Macro({required this.vf, required this.vi, required this.scalars});

  static const _acc = 32;
  static const _i = 0, _q = 1, _r = 2, _status = 3, _mac = 4, _clip = 5;

  late IrBuilder b;
  final _regs = List<IrValue?>.filled(33, null);
  final _dirty = <int>{};
  final _scalar = List<IrValue?>.filled(6, null);
  final _scalarDirty = <int>{};
  final _viWords = List<IrValue?>.filled(8, null);
  final _viDirty = <int>{};

  /// the MAC flags of the FMAC operations since the status was last
  /// updated, ORed, or null
  IrValue? _macOr;

  void reset(IrBuilder builder) {
    b = builder;
    _regs.fillRange(0, 33, null);
    _dirty.clear();
    _scalar.fillRange(0, 6, null);
    _scalarDirty.clear();
    _viWords.fillRange(0, 8, null);
    _viDirty.clear();
    _macOr = null;
  }

  IrValue _c(int value) => b.c32(value);

  // ---- registers ----

  IrValue vfGet(int r) => _regs[r] ??= b.ctxLoad(vf + 4 * r, type: IrType.v128);

  /// Writes the fields [mask] (x at 8) of [value] to VF [r] or the
  /// accumulator.
  void vfSet(int r, int mask, IrValue value) {
    if (r == 0 || mask == 0) return;
    var blend = 0;
    for (var c = 0; c < 4; c++) {
      if (mask & (8 >> c) != 0) blend |= 1 << c;
    }
    _regs[r] = blend == 15 ? value : b.vBlend(vfGet(r), value, blend);
    _dirty.add(r);
  }

  IrValue _scalarGet(int k) => _scalar[k] ??= b.ctxLoad(scalars + k);

  void _scalarSet(int k, IrValue value) {
    _scalar[k] = value;
    _scalarDirty.add(k);
  }

  IrValue _viWord(int n) => _viWords[n >> 1] ??= b.ctxLoad(vi + (n >> 1));

  IrValue viGet(int n) {
    if (n == 0) return _c(0);
    final word = _viWord(n);
    return n.isOdd ? b.shrU(word, _c(16)) : b.and(word, _c(0xffff));
  }

  void viSet(int n, IrValue value) {
    if (n == 0) return;
    final word = _viWord(n), low = b.and(value, _c(0xffff));
    _viWords[n >> 1] = n.isOdd
        ? b.or(b.and(word, _c(0xffff)), b.shl(low, _c(16)))
        : b.or(b.and(word, _c(0xffff0000)), low);
    _viDirty.add(n >> 1);
  }

  /// the bits [shift] to [shift] + 3 for the zero, sign, underflow and
  /// overflow fields of the MAC flags [mac] that have a bit set
  IrValue _flagBits(IrValue mac, int shift) {
    IrValue bits = _c(0);
    for (var k = 0; k < 4; k++) {
      final set = b.ne(b.and(mac, _c(0xf << 4 * k)), _c(0));
      bits = b.or(bits, b.shl(set, _c(k + shift)));
    }
    return bits;
  }

  /// Applies the MAC flags of the FMAC operations so far to the status:
  /// the current flags of the last one, and the sticky flags of all.
  void _settleStatus() {
    final macOr = _macOr;
    if (macOr == null) return;
    _macOr = null;
    final kept = b.and(_scalarGet(_status), _c(0xff0));
    _scalarSet(_status,
        b.or(b.or(kept, _flagBits(_scalarGet(_mac), 0)), _flagBits(macOr, 6)));
  }

  /// the context stores of the changed registers, for an exit
  List<(int, IrValue)> stores() {
    _settleStatus();
    return [
      for (final r in _dirty) (vf + 4 * r, _regs[r]!),
      for (final k in _scalarDirty) (scalars + k, _scalar[k]!),
      for (final w in _viDirty) (vi + w, _viWords[w]!),
    ];
  }

  void flush() {
    for (final (word, value) in stores()) {
      b.ctxStore(word, value);
    }
  }

  // ---- control registers ----

  /// Whether CFC2 or CTC2 of the control register [n] is translated:
  /// CMSAR0, FBRST and CMSAR1 reach state outside the context.
  static bool control(int n, {required bool write}) =>
      n != 27 && !(write && (n == 28 || n == 31));

  /// CFC2: the control register [n], as [Vu.readControl] reads it
  IrValue readControl(int n) {
    switch (n) {
      case < 16:
        return viGet(n);
      case 16:
        _settleStatus();
        return _scalarGet(_status);
      case 17:
        return _scalarGet(_mac);
      case 18:
        return _scalarGet(_clip);
      case 20:
        return _scalarGet(_r);
      case 21:
        return _scalarGet(_i);
      case 22:
        return _scalarGet(_q);
    }
    return _c(0);
  }

  /// CTC2: [value] to the control register [n], as [Vu.writeControl]
  /// writes it
  void writeControl(int n, IrValue value) {
    switch (n) {
      case < 16:
        viSet(n, value);
      case 16:
        _macOr = null;
        _scalarSet(_status, b.and(value, _c(0xfff)));
      case 17:
        _settleStatus();
        _scalarSet(_mac, b.and(value, _c(0xffff)));
      case 18:
        _scalarSet(_clip, b.and(value, _c(0xffffff)));
      case 20:
        _scalarSet(_r, value);
      case 21:
        _scalarSet(_i, value);
      case 22:
        _scalarSet(_q, value);
    }
  }

  // ---- macro instructions ----

  /// Whether the COP2 instruction [ir] with the CO bit set is translated.
  static bool supports(int ir) {
    final op = ir & 63;
    if (op < 0x30) return true;
    if (op < 0x36) return op != 0x33;
    if (op < 0x3c) return false;
    final code = ((ir >> 6) & 31) << 2 | (ir & 3);
    if (code < 0x30) return true;
    return const [0x30, 0x31, 0x3b, 0x3c, 0x3d].contains(code);
  }

  /// Translates the COP2 instruction [ir] that [supports] accepts.
  void emit(int ir) {
    final mask = (ir >> 21) & 15;
    final ft = (ir >> 16) & 31, fs = (ir >> 11) & 31, fd = (ir >> 6) & 31;
    final op = ir & 63;
    if (op < 0x1c) {
      _fmac(const [0, 1, 2, 3, 4, 5, 6][op >> 2], op & 3, mask, fs, ft, fd);
    } else if (op < 0x28) {
      const table = [
        (6, 4), (4, 5), (6, 5), (5, 5), //
        (0, 4), (2, 4), (0, 5), (2, 5), (1, 4), (3, 4), (1, 5), (3, 5)
      ];
      final (kind, bsel) = table[op - 0x1c];
      _fmac(kind, bsel, mask, fs, ft, fd);
    } else if (op < 0x2e) {
      _fmac(const [0, 2, 6, 4, 1, 3][op - 0x28], 6, mask, fs, ft, fd);
    } else if (op == 0x2f) {
      _fmac(5, 6, mask, fs, ft, fd);
    } else if (op == 0x2e) {
      // OPMSUB
      _result(
          b.vuArithmetic(IrOp.vuMsub, vfGet(fs), vfGet(ft),
              c: vfGet(_acc), aLanes: _outerA, bLanes: _outerB),
          14,
          fd);
    } else if (op < 0x36) {
      _integer(ir, ft, fs);
    } else {
      _special(ir, mask, ft, fs);
    }
  }

  // the lanes y, z, x and z, x, y of the outer product
  static const _outerA = 0xc9, _outerB = 0xd2;

  /// the MAC flags of an FMAC [result] for the fields [mask], to MAC and,
  /// lazily, to the status
  void _flags(IrValue result, int mask) {
    var flagMask = 0;
    for (var c = 0; c < 4; c++) {
      if (mask & (8 >> c) != 0) flagMask |= 0x1111 << (3 - c);
    }
    final mac = b.and(b.vuMac(result), _c(flagMask));
    _scalarSet(_mac, mac);
    _macOr = _macOr == null ? mac : b.or(_macOr!, mac);
  }

  void _result(IrValue result, int mask, int fd) {
    _flags(result, mask);
    vfSet(fd, mask, result);
  }

  /// kind: 0 ADD, 1 SUB, 2 MADD, 3 MSUB, 4 MAX, 5 MINI, 6 MUL; bsel: a
  /// broadcast field, 4 Q, 5 I or 6 the full vector of [ft]. The result
  /// goes to [fd], or to the accumulator when [fd] is [_acc].
  void _fmac(int kind, int bsel, int mask, int fs, int ft, int fd) {
    final scalar = switch (bsel) {
      4 => _scalarGet(_q),
      5 => _scalarGet(_i),
      _ => null,
    };
    final a = vfGet(fs);
    if (kind == 4 || kind == 5) {
      final v = switch (bsel) {
        < 4 => b.vShuffle(vfGet(ft), bsel * 0x55),
        6 => vfGet(ft),
        _ => b.vSplat(scalar!),
      };
      vfSet(fd, mask, kind == 4 ? b.vuMax(a, v) : b.vuMin(a, v));
      return;
    }
    final (y, lanes) = switch (bsel) {
      < 4 => (vfGet(ft), bsel * 0x55),
      6 => (vfGet(ft), 0xe4),
      _ => (b.vSplat(scalar!), 0xe4),
    };
    final op = const [
      IrOp.vuAdd,
      IrOp.vuSub,
      IrOp.vuMadd,
      IrOp.vuMsub,
      IrOp.vuMul,
      IrOp.vuMul,
      IrOp.vuMul
    ][kind];
    _result(
        b.vuArithmetic(op, a, y,
            c: kind == 2 || kind == 3 ? vfGet(_acc) : null, bLanes: lanes),
        mask,
        fd);
  }

  /// VIADD, VISUB, VIADDI, VIAND and VIOR
  void _integer(int ir, int it, int fs) {
    final id = (ir >> 6) & 15, s = viGet(fs & 15);
    switch (ir & 63) {
      case 0x30:
        viSet(id, b.add(s, viGet(it & 15)));
      case 0x31:
        viSet(id, b.sub(s, viGet(it & 15)));
      case 0x32:
        viSet(it & 15, b.add(s, _c(((ir >> 6) & 31).toSigned(5))));
      case 0x34:
        viSet(id, b.and(s, viGet(it & 15)));
      case 0x35:
        viSet(id, b.or(s, viGet(it & 15)));
    }
  }

  /// the instructions of the special codes 0x3c to 0x3f
  void _special(int ir, int mask, int ft, int fs) {
    final sub = (ir >> 6) & 31, col = ir & 3;
    if (sub < 4) return _fmac(sub, col, mask, fs, ft, _acc);
    if (sub == 6) return _fmac(6, col, mask, fs, ft, _acc);
    if (sub == 4 || sub == 5) {
      final n = const [0, 4, 12, 15][col];
      final a = vfGet(fs);
      vfSet(ft, mask, sub == 4 ? b.vuItof(a, n) : b.vuFtoi(a, n));
      return;
    }
    switch ((sub << 2) | col) {
      case const (7 << 2 | 0): // MULAq
        _fmac(6, 4, mask, fs, ft, _acc);
      case const (7 << 2 | 1): // ABS
        var v = vfGet(fs);
        for (var c = 0; c < 4; c++) {
          if (mask & (8 >> c) == 0) continue;
          v = b.vInsert(v, b.and(b.vExtract(v, c), _c(0x7fffffff)), c);
        }
        vfSet(ft, mask, v);
      case const (7 << 2 | 2): // MULAi
        _fmac(6, 5, mask, fs, ft, _acc);
      case const (7 << 2 | 3): // CLIP
        final clip = _scalarGet(_clip);
        _scalarSet(
            _clip,
            b.and(b.or(b.shl(clip, _c(6)), b.vuClip(vfGet(fs), vfGet(ft))),
                _c(0xffffff)));
      case const (8 << 2 | 0): // ADDAq
        _fmac(0, 4, mask, fs, ft, _acc);
      case const (8 << 2 | 1): // MADDAq
        _fmac(2, 4, mask, fs, ft, _acc);
      case const (8 << 2 | 2): // ADDAi
        _fmac(0, 5, mask, fs, ft, _acc);
      case const (8 << 2 | 3): // MADDAi
        _fmac(2, 5, mask, fs, ft, _acc);
      case const (9 << 2 | 0): // SUBAq
        _fmac(1, 4, mask, fs, ft, _acc);
      case const (9 << 2 | 1): // MSUBAq
        _fmac(3, 4, mask, fs, ft, _acc);
      case const (9 << 2 | 2): // SUBAi
        _fmac(1, 5, mask, fs, ft, _acc);
      case const (9 << 2 | 3): // MSUBAi
        _fmac(3, 5, mask, fs, ft, _acc);
      case const (10 << 2 | 0): // ADDA
        _fmac(0, 6, mask, fs, ft, _acc);
      case const (10 << 2 | 1): // MADDA
        _fmac(2, 6, mask, fs, ft, _acc);
      case const (10 << 2 | 2): // MULA
        _fmac(6, 6, mask, fs, ft, _acc);
      case const (11 << 2 | 0): // SUBA
        _fmac(1, 6, mask, fs, ft, _acc);
      case const (11 << 2 | 1): // MSUBA
        _fmac(3, 6, mask, fs, ft, _acc);
      case const (11 << 2 | 2): // OPMULA
        _result(
            b.vuArithmetic(IrOp.vuMul, vfGet(fs), vfGet(ft),
                aLanes: _outerA, bLanes: _outerB),
            14,
            _acc);
      case const (12 << 2 | 0): // MOVE
        vfSet(ft, mask, vfGet(fs));
      case const (12 << 2 | 1): // MR32
        vfSet(ft, mask, b.vShuffle(vfGet(fs), 0x39));
      case const (15 << 2 | 0): // MTIR
        viSet(ft & 15, b.vExtract(vfGet(fs), (ir >> 21) & 3));
      case const (15 << 2 | 1): // MFIR
        final value = b.sext16(viGet(fs & 15));
        vfSet(ft, mask, b.vSplat(value));
    }
    // NOP, WAITQ and the unassigned upper codes do nothing
  }
}
