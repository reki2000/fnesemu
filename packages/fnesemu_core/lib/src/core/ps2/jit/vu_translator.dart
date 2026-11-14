import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../vu.dart';
import 'vu_context.dart';

/// Translates VU micro code into IR blocks, pair by pair, with the timing
/// of the interpreter ([Vu.step]).
///
/// A block starts at a pair boundary (see [Vu.atPairBoundary]) and ends
/// after the delay slot of a branch, after the pair that follows an end
/// bit, or before a pair it does not translate. A pair whose XGKICK or end
/// bit takes effect after the next pair is translated only together with
/// that pair.
///
/// The VF registers, the accumulator, the VI registers and the ready
/// cycles are kept in values while a block runs and written back at its
/// end. The cycle counter is a value too: each pair waits for the ready
/// cycles of the fields it reads and for Q, as [Vu.decodeStall] lists
/// them, and then takes one cycle. A wait is left out when the value was
/// written four or more pairs before, as it is ready by then.
///
/// Q and the flags are applied lazily. A read of Q selects the result of a
/// pending division when its cycle has come. The flag results stay in a
/// list until a flag instruction reads them or they leave the pipeline;
/// see [VuCtx] for their slots between blocks.
///
/// Floating point values are kept as register images and evaluated as in
/// the interpreter: decoded exactly to binary64, computed there and
/// truncated back ([_decode], [_encode]). MAX, MINI and CLIP compare the
/// images as integers ordered like their values.
///
/// Not translated: EATANxy, EATANxz, ESIN, EATAN and EEXP, and the upper
/// opcodes 0x30 to 0x3b.
final class VuTranslator {
  static const reasonEnd = JitReason.user;
  static const defaultMaxPairs = 64;
  static const _latency = 4;

  /// the values after which a block takes no new pair, so that two more
  /// pairs and the write back stay within the 4096 values of a block
  static const _valueLimit = 2400;

  final int pairCount;
  final int dataQuads;

  /// the guest address of micro memory, for the code guards
  final int microBase;
  final int kickHelper, topHelper, itopHelper;
  final int maxPairs;

  /// the lower and upper words of a pair
  final int Function(int word) fetch;

  VuTranslator(
      {required this.pairCount,
      required this.dataQuads,
      required this.microBase,
      required this.fetch,
      required this.kickHelper,
      required this.topHelper,
      required this.itopHelper,
      this.maxPairs = defaultMaxPairs});

  late IrBuilder b;

  /// the pair index in the block being translated
  int _p = 0;

  final _vf = List<IrValue?>.filled(128, null);
  final _vfDecoded = List<IrValue?>.filled(128, null);
  final _vfDirty = List<bool>.filled(128, false);
  final _acc = List<IrValue?>.filled(4, null);
  final _accDecoded = List<IrValue?>.filled(4, null);
  final _accDirty = List<bool>.filled(4, false);
  final _vi = List<IrValue?>.filled(16, null);
  final _viDirty = List<bool>.filled(16, false);
  final _viWord = List<IrValue?>.filled(8, null);
  final _ready = List<IrValue?>.filled(128, null);
  final _readyDirty = List<bool>.filled(128, false);

  /// the pair that wrote each ready cycle, -1 for one from before the block
  final _readyPair = Int32List(128);

  late IrValue _cycles;
  late IrValue _issued, _readyNew;

  IrValue? _i;
  bool _iDirty = false;

  // the division unit (Q) and the EFU (P)
  final _qUnit = _Unit(VuCtx.q, VuCtx.qValue, VuCtx.qBusy, VuCtx.qReady, 13);
  final _pUnit = _Unit(VuCtx.p, VuCtx.pValue, VuCtx.pBusy, VuCtx.pReady, 54);

  IrValue? _r;
  bool _rDirty = false;

  // the flags before the results in [_flags]; see [VuCtx]
  IrValue? _mac, _status, _macOr, _statusDirty, _clip;
  bool _flagsDirty = false;
  final _flags = <_Flag>[];
  bool _slotsLoaded = false;

  /// the XGKICK address of the previous pair and of this one
  IrValue? _kickPrevious, _kick;

  IrValue _c(int v) => b.c32(v);
  IrValue _c64(int v) => b.c64Parts(v, v >> 32);

  IrValue _max64(IrValue a, IrValue v) => b.select(b.ltS(a, v), v, a);

  // ---- translation ----

  (int, int) _words(int pc) => (fetch(pc * 2), fetch(pc * 2 + 1));

  IrBlock? translate(int pc) {
    b = IrBuilder(pc);
    _reset();
    var at = pc;
    while (true) {
      // the pair after an XGKICK always belongs to the block of the XGKICK
      if (_kickPrevious == null &&
          (_p >= maxPairs || b.length >= _valueLimit)) {
        break;
      }
      final (lo, hi) = _words(at);
      if (!_supported(lo, hi)) break;
      final next = (at + 1) & (pairCount - 1);
      final (nlo, nhi) = _words(next);
      final branch = _isBranch(lo, hi);
      final ending = hi & 0x40000000 != 0;
      if (branch || ending || _isKick(lo, hi)) {
        // the next pair belongs to this block
        if (_p + 1 >= maxPairs ||
            !_supported(nlo, nhi) ||
            _isBranch(nlo, nhi) ||
            nhi & 0x40000000 != 0) {
          break;
        }
        if (branch && (ending || _isKick(nlo, nhi))) break;
        // the pair after an XGKICK must not need one more pair itself
        if (!branch && !ending && _isKick(nlo, nhi)) break;
      }
      _guard(at, lo, hi);
      if (branch) {
        final term = _branch(at, lo);
        _guard(next, nlo, nhi);
        _pair(next, nlo, nhi);
        _flush();
        return b.finish(term, cost: _p);
      }
      _pair(at, lo, hi);
      if (ending) {
        _guard(next, nlo, nhi);
        _pair(next, nlo, nhi);
        _flush();
        if (_kickPrevious != null) b.ctxStore(VuCtx.kick, _kickPrevious!);
        final after = (next + 1) & (pairCount - 1);
        return b.finish(IrExitTerm(IrExit(reasonEnd, after)), cost: _p);
      }
      at = next;
    }
    if (_p == 0) return null;
    _flush();
    return b.finish(IrJump(at), cost: _p);
  }

  void _reset() {
    _p = 0;
    _vf.fillRange(0, 128, null);
    _vfDecoded.fillRange(0, 128, null);
    _vfDirty.fillRange(0, 128, false);
    _acc.fillRange(0, 4, null);
    _accDecoded.fillRange(0, 4, null);
    _accDirty.fillRange(0, 4, false);
    _vi.fillRange(0, 16, null);
    _viDirty.fillRange(0, 16, false);
    _viWord.fillRange(0, 8, null);
    _ready.fillRange(0, 128, null);
    _readyDirty.fillRange(0, 128, false);
    _readyPair.fillRange(0, 128, -1);
    _cycles = b.ctxLoad(VuCtx.cycles, type: IrType.i64);
    _i = null;
    _iDirty = false;
    _qUnit.reset();
    _pUnit.reset();
    _r = null;
    _rDirty = false;
    _mac = _status = _macOr = _statusDirty = _clip = null;
    _flagsDirty = false;
    _flags.clear();
    _slotsLoaded = false;
    _kickPrevious = _kick = null;
  }

  void _guard(int pc, int lo, int hi) {
    b.guard(microBase + pc * 8, lo);
    b.guard(microBase + pc * 8 + 4, hi);
  }

  static bool _isBranch(int lo, int hi) {
    if (hi >>> 31 != 0) return false;
    final op = lo >>> 25;
    return op >= 0x20 && op < 0x30;
  }

  static bool _isKick(int lo, int hi) =>
      hi >>> 31 == 0 && lo >>> 25 == 0x40 && lo & 0x7ff == 0x6fc;

  bool _supported(int lo, int hi) {
    final op = hi & 63;
    if (op >= 0x30 && op < 0x3c) return false;
    if (hi >>> 31 != 0) return true;
    return _lowerSupported(lo);
  }

  static bool _lowerSupported(int ir) {
    final op = ir >>> 25;
    switch (op) {
      case 0x00 || 0x01 || 0x04 || 0x05 || 0x08 || 0x09:
        return true;
      case >= 0x10 && <= 0x1c:
        return op != 0x19;
      case 0x20 || 0x21 || 0x24 || 0x25:
        return true;
      case 0x28 || 0x29 || >= 0x2c && <= 0x2f:
        return true;
      case 0x40:
        final funct = ir & 0x3f;
        if (funct < 0x3c) return true;
        final code = ((ir >> 6) & 31) << 2 | (funct & 3);
        return switch (code) {
          >= 0x30 && < 0x40 => true, // 0x0c..0x0f
          >= 0x40 && < 0x44 => true, // RNEXT, RGET, RINIT, RXOR
          const (0x19 << 2 | 0) || const (0x1e << 2 | 3) => true, // MFP, WAITP
          >= 0x70 && < 0x74 || 0x76 || >= 0x78 && < 0x7b => true, // EFU
          const (0x1a << 2 | 0) || const (0x1a << 2 | 1) => true, // XTOP
          const (0x1b << 2 | 0) => true, // XGKICK
          _ => false,
        };
    }
    return false;
  }

  /// Translates the pair at [pc], as [Vu.step] runs it.
  void _pair(int pc, int lo, int hi) {
    final iBit = hi >>> 31 != 0;
    final stall = Vu.decodeStall(hi, lo);
    var t = _cycles;
    final seen = <IrValue>{};
    for (var g = stall & Vu.stallGroups; g != 0; g >>= 9) {
      final reg = g & 31, fields = (g >> 5) & 15;
      for (var c = 0; c < 4; c++) {
        if (fields & (8 >> c) == 0) continue;
        final k = reg * 4 + c;
        if (_p - _readyPair[k] >= _latency) continue;
        final r = _readyOf(k);
        if (seen.add(r)) t = _max64(t, r);
      }
    }
    if (stall & Vu.stallQ != 0) t = _waitFor(_qUnit, t);
    if (stall & Vu.stallP != 0) t = _waitFor(_pUnit, t);
    _issued = t;
    _cycles = b.add(t, _c64(1));
    _readyNew = b.add(t, _c64(_latency));
    _kick = null;

    final upper = _upper(hi);
    if (iBit) {
      _i = _c(lo);
      _iDirty = true;
    } else {
      _lower(pc, lo);
    }
    if (upper != null) {
      final (reg, mask, lanes, decoded) = upper;
      if (reg != 0) {
        for (var c = 0; c < 4; c++) {
          if (mask & (8 >> c) == 0) continue;
          _setLane(reg, c, lanes[c]!, decoded[c]);
        }
        _setReady(reg, mask);
      }
    }
    if (_upperMac != null || _upperClip != null) {
      _flags.add(_Flag(_readyNew, _upperMac, _upperClip, _p, slot: false));
    }
    if (_kickPrevious != null) b.call(kickHelper, _kickPrevious);
    _kickPrevious = _kick;
    _p++;
  }

  // ---- registers ----

  IrValue _lane(int reg, int c) {
    final k = reg * 4 + c;
    return _vf[k] ??= b.ctxLoad(VuCtx.vf + k);
  }

  IrValue _laneDecoded(int reg, int c) {
    final k = reg * 4 + c;
    return _vfDecoded[k] ??= _decode(_lane(reg, c));
  }

  void _setLane(int reg, int c, IrValue bits, [IrValue? decoded]) {
    if (reg == 0) return;
    final k = reg * 4 + c;
    _vf[k] = bits;
    _vfDecoded[k] = decoded;
    _vfDirty[k] = true;
  }

  IrValue _accLane(int c) => _acc[c] ??= b.ctxLoad(VuCtx.acc + c);

  IrValue _accDecodedLane(int c) => _accDecoded[c] ??= _decode(_accLane(c));

  void _setAcc(int c, IrValue bits, [IrValue? decoded]) {
    _acc[c] = bits;
    _accDecoded[c] = decoded;
    _accDirty[c] = true;
  }

  IrValue _getVi(int n) {
    if (n == 0) return _c(0);
    final value = _vi[n];
    if (value != null) return value;
    final word = _viWord[n >> 1] ??= b.ctxLoad(VuCtx.vi + (n >> 1));
    return _vi[n] = n.isOdd ? b.shrU(word, _c(16)) : b.and(word, _c(0xffff));
  }

  void _setVi(int n, IrValue value) {
    if (n == 0) return;
    _vi[n] = b.and(value, _c(0xffff));
    _viDirty[n] = true;
  }

  IrValue _readyOf(int k) =>
      _ready[k] ??= b.ctxLoad(VuCtx.ready + 2 * k, type: IrType.i64);

  /// the fields [mask] of [reg] are written by this pair
  void _setReady(int reg, int mask) {
    if (reg == 0) return;
    for (var c = 0; c < 4; c++) {
      if (mask & (8 >> c) == 0) continue;
      final k = reg * 4 + c;
      _ready[k] = _readyNew;
      _readyDirty[k] = true;
      _readyPair[k] = _p;
    }
  }

  IrValue _iValue() => _i ??= b.ctxLoad(VuCtx.i);

  // ---- Q and P ----

  IrValue _busy(_Unit u) => u.busy ??= b.ctxLoad(u.busyWord);
  IrValue _readyAt(_Unit u) =>
      u.ready ??= b.ctxLoad(u.readyWord, type: IrType.i64);
  IrValue _pending(_Unit u) => u.pending ??= b.ctxLoad(u.pendingWord);
  IrValue _register(_Unit u) => u.value ??= b.ctxLoad(u.valueWord);

  /// Whether nothing is pending in [u] by now; a pending result known to
  /// be done is applied.
  bool _done(_Unit u) {
    if (u.idle) return true;
    if (_p - u.pair < u.latency) return false;
    _finishUnit(u);
    return true;
  }

  void _finishUnit(_Unit u) {
    u.value = b.select(b.ne(_busy(u), _c(0)), _pending(u), _register(u));
    u.busy = _c(0);
    u.idle = true;
    u.dirty = true;
  }

  /// the register of [u] as the pair issued at [_issued] reads it
  IrValue _now(_Unit u) {
    if (_done(u)) return _register(u);
    final done =
        b.and(b.ne(_busy(u), _c(0)), b.eq(b.ltS(_issued, _readyAt(u)), _c(0)));
    return b.select(done, _pending(u), _register(u));
  }

  /// the cycle [t] after a wait for the pending result of [u]
  IrValue _waitFor(_Unit u, IrValue t) {
    if (_done(u)) return t;
    return _max64(t, b.select(b.ne(_busy(u), _c(0)), _readyAt(u), t));
  }

  /// Starts an operation of [u] that gives [value] after [latency] cycles.
  /// A pending one is waited for, as [Vu] does.
  void _start(_Unit u, IrValue value, int latency) {
    if (!_done(u)) {
      _cycles = _waitFor(u, _cycles);
      _finishUnit(u);
    }
    u.busy = _c(1);
    u.pending = value;
    u.ready = b.add(_cycles, _c64(latency - 1));
    u.pair = _p;
    u.latency = latency;
    u.idle = false;
    u.dirty = true;
  }

  void _flushUnit(_Unit u) {
    if (!u.dirty) return;
    if (u.value != null) b.ctxStore(u.valueWord, u.value!);
    b.ctxStore(u.busyWord, _busy(u));
    if (u.pending != null) b.ctxStore(u.pendingWord, u.pending!);
    if (u.ready != null) b.ctxStore(u.readyWord, u.ready!);
  }

  // ---- floating point ----

  /// a register image as binary64 bits, exactly
  IrValue _decode(IrValue bits) {
    final exp = b.and(b.shrU(bits, _c(23)), _c(0xff));
    final mant = b.and(bits, _c(0x7fffff));
    final hi = b.or(b.and(bits, _c(0x80000000)),
        b.or(b.shl(b.add(exp, _c(896)), _c(20)), b.shrU(mant, _c(3))));
    final packed =
        b.or(b.zext32(b.shl(mant, _c(29))), b.shl(b.zext32(hi), _c(32)));
    return b.select(b.eq(exp, _c(0)), _c64(0), packed);
  }

  /// the binary64 bits of the largest magnitude, 0x7fffffff decoded
  static const _maxDecoded = 0x47ffffffe0000000;

  /// the decoded value of the last [_encode]: the result with the bits
  /// below single precision cleared, zero, or the largest magnitude
  late IrValue _encodedValue;

  /// A binary64 result truncated to a register image, as
  /// [R5900Fpu.encodeCause]: the image, and whether it underflowed or
  /// overflowed (0 or 1). The image decoded is left in [_encodedValue].
  (IrValue, IrValue, IrValue) _encode(IrValue raw) {
    final hi = b.trunc32(b.shrU(raw, _c(32)));
    final lo = b.trunc32(raw);
    final sign = b.and(hi, _c(0x80000000));
    final exp = b.sub(b.and(b.shrU(hi, _c(20)), _c(0x7ff)), _c(896));
    final zero = b.and(b.eq(b.and(hi, _c(0x7fffffff)), _c(0)), b.eq(lo, _c(0)));
    final under = b.and(b.ltS(exp, _c(1)), b.eq(zero, _c(0)));
    final over = b.eq(b.ltS(exp, _c(256)), _c(0));
    final normal = b.or(
        sign,
        b.or(b.shl(exp, _c(23)),
            b.or(b.shl(b.and(hi, _c(0xfffff)), _c(3)), b.shrU(lo, _c(29)))));
    final bits = b.select(b.or(zero, under), sign,
        b.select(over, b.or(sign, _c(0x7fffffff)), normal));
    final clamped = b.or(b.shl(b.zext32(sign), _c(32)), _c64(_maxDecoded));
    _encodedValue = b.select(b.or(zero, under), _c64(0),
        b.select(over, clamped, b.and(raw, _c64(~0x1fffffff))));
    return (bits, under, over);
  }

  IrValue _bits(IrValue raw) => _encode(raw).$1;

  /// an integer ordered as the values of register images, equal for every
  /// zero
  IrValue _key(IrValue bits) {
    final magnitude = b.and(bits, _c(0x7fffffff));
    final value =
        b.select(b.ltS(bits, _c(0)), b.sub(_c(0), magnitude), magnitude);
    return b.select(b.eq(b.and(bits, _c(0x7f800000)), _c(0)), _c(0), value);
  }

  /// the MAC flag bits of lane [c] of a result
  IrValue _macBits(int c, IrValue bits, IrValue under, IrValue over) {
    final shift = 3 - c;
    final zero = b.eq(b.and(bits, _c(0x7fffffff)), _c(0));
    final sign = b.shrU(bits, _c(31));
    return b.or(b.or(b.shl(zero, _c(shift)), b.shl(sign, _c(4 + shift))),
        b.or(b.shl(under, _c(8 + shift)), b.shl(over, _c(12 + shift))));
  }

  // ---- upper instructions ----

  /// the MAC bits and the clip judgement of the upper instruction
  IrValue? _upperMac, _upperClip;

  /// Translates the upper instruction. Returns its VF result: the
  /// register, the mask and the lanes (with their decoded values when
  /// known), or null.
  (int, int, List<IrValue?>, List<IrValue?>)? _upper(int ir) {
    _upperMac = _upperClip = null;
    final mask = (ir >> 21) & 15;
    final ft = (ir >> 16) & 31, fs = (ir >> 11) & 31, fd = (ir >> 6) & 31;
    final op = ir & 63;
    int kind, bsel;
    if (op < 0x1c) {
      kind = const [0, 1, 2, 3, 4, 5, 6][op >> 2];
      bsel = op & 3;
    } else if (op < 0x28) {
      const table = [
        (6, 4), (4, 5), (6, 5), (5, 5), //
        (0, 4), (2, 4), (0, 5), (2, 5), (1, 4), (3, 4), (1, 5), (3, 5)
      ];
      (kind, bsel) = table[op - 0x1c];
    } else if (op < 0x2e) {
      kind = const [0, 2, 6, 4, 1, 3][op - 0x28];
      bsel = 6;
    } else if (op == 0x2f) {
      kind = 5;
      bsel = 6;
    } else if (op == 0x2e) {
      return _opmsub(fs, ft, fd);
    } else {
      return _special(ir, mask, ft, fs);
    }
    return _fmac(kind, bsel, mask, fs, ft, fd, toAcc: false);
  }

  // kind: 0 ADD, 1 SUB, 2 MADD, 3 MSUB, 4 MAX, 5 MINI, 6 MUL
  (int, int, List<IrValue?>, List<IrValue?>)? _fmac(
      int kind, int bsel, int mask, int fs, int ft, int fd,
      {required bool toAcc}) {
    final scalar = switch (bsel) {
      4 => _now(_qUnit),
      5 => _iValue(),
      6 => null,
      _ => _lane(ft, bsel),
    };
    final lanes = List<IrValue?>.filled(4, null);
    final decoded = List<IrValue?>.filled(4, null);
    if (kind == 4 || kind == 5) {
      final scalarKey = scalar == null ? null : _key(scalar);
      for (var c = 0; c < 4; c++) {
        if (mask & (8 >> c) == 0) continue;
        final a = _lane(fs, c);
        final v = scalar ?? _lane(ft, c);
        final ka = _key(a), kv = scalarKey ?? _key(v);
        lanes[c] = kind == 4
            ? b.select(b.ltS(ka, kv), v, a)
            : b.select(b.ltS(kv, ka), v, a);
      }
      return (fd, mask, lanes, decoded);
    }
    final scalarValue = switch (bsel) {
      < 4 => _laneDecoded(ft, bsel),
      6 => null,
      _ => _decode(scalar!),
    };
    IrValue mac = _c(0);
    for (var c = 0; c < 4; c++) {
      if (mask & (8 >> c) == 0) continue;
      final x = _laneDecoded(fs, c);
      final y = scalarValue ?? _laneDecoded(ft, c);
      final v = switch (kind) {
        0 => b.floatBinary(IrOp.floatAdd, x, y),
        1 => b.floatBinary(IrOp.floatSub, x, y),
        2 => b.floatBinary(IrOp.floatAdd, _accDecodedLane(c),
            b.floatBinary(IrOp.floatMul, x, y)),
        3 => b.floatBinary(IrOp.floatSub, _accDecodedLane(c),
            b.floatBinary(IrOp.floatMul, x, y)),
        _ => b.floatBinary(IrOp.floatMul, x, y),
      };
      final (bits, under, over) = _encode(v);
      mac = b.or(mac, _macBits(c, bits, under, over));
      lanes[c] = bits;
      decoded[c] = _encodedValue;
    }
    _upperMac = mac;
    if (toAcc) {
      for (var c = 0; c < 4; c++) {
        if (mask & (8 >> c) != 0) _setAcc(c, lanes[c]!, decoded[c]);
      }
      return null;
    }
    return (fd, mask, lanes, decoded);
  }

  (int, int, List<IrValue?>, List<IrValue?>)? _opmsub(int fs, int ft, int fd) {
    final lanes = List<IrValue?>.filled(4, null);
    IrValue mac = _c(0);
    for (var c = 0; c < 3; c++) {
      final a = c == 2 ? 0 : c + 1, v = c == 0 ? 2 : c - 1;
      final product = b.floatBinary(
          IrOp.floatMul, _laneDecoded(fs, a), _laneDecoded(ft, v));
      final (bits, under, over) =
          _encode(b.floatBinary(IrOp.floatSub, _accDecodedLane(c), product));
      mac = b.or(mac, _macBits(c, bits, under, over));
      lanes[c] = bits;
    }
    _upperMac = mac;
    return (fd, 14, lanes, List<IrValue?>.filled(4, null));
  }

  (int, int, List<IrValue?>, List<IrValue?>)? _special(
      int ir, int mask, int ft, int fs) {
    final sub = (ir >> 6) & 31, col = ir & 3;
    if (sub < 4) return _fmac(sub, col, mask, fs, ft, 0, toAcc: true);
    if (sub == 6) return _fmac(6, col, mask, fs, ft, 0, toAcc: true);
    if (sub == 4 || sub == 5) return _convert(sub == 4, col, mask, fs, ft);
    switch ((sub << 2) | col) {
      case const (7 << 2 | 0): // MULAq
        return _fmac(6, 4, mask, fs, ft, 0, toAcc: true);
      case const (7 << 2 | 1): // ABS
        final lanes = [
          for (var c = 0; c < 4; c++)
            mask & (8 >> c) != 0 ? b.and(_lane(fs, c), _c(0x7fffffff)) : null
        ];
        return (ft, mask, lanes, List<IrValue?>.filled(4, null));
      case const (7 << 2 | 2): // MULAi
        return _fmac(6, 5, mask, fs, ft, 0, toAcc: true);
      case const (7 << 2 | 3): // CLIP
        _clipJudgement(fs, ft);
        return null;
      case const (8 << 2 | 0): // ADDAq
        return _fmac(0, 4, mask, fs, ft, 0, toAcc: true);
      case const (8 << 2 | 1): // MADDAq
        return _fmac(2, 4, mask, fs, ft, 0, toAcc: true);
      case const (8 << 2 | 2): // ADDAi
        return _fmac(0, 5, mask, fs, ft, 0, toAcc: true);
      case const (8 << 2 | 3): // MADDAi
        return _fmac(2, 5, mask, fs, ft, 0, toAcc: true);
      case const (9 << 2 | 0): // SUBAq
        return _fmac(1, 4, mask, fs, ft, 0, toAcc: true);
      case const (9 << 2 | 1): // MSUBAq
        return _fmac(3, 4, mask, fs, ft, 0, toAcc: true);
      case const (9 << 2 | 2): // SUBAi
        return _fmac(1, 5, mask, fs, ft, 0, toAcc: true);
      case const (9 << 2 | 3): // MSUBAi
        return _fmac(3, 5, mask, fs, ft, 0, toAcc: true);
      case const (10 << 2 | 0): // ADDA
        return _fmac(0, 6, mask, fs, ft, 0, toAcc: true);
      case const (10 << 2 | 1): // MADDA
        return _fmac(2, 6, mask, fs, ft, 0, toAcc: true);
      case const (10 << 2 | 2): // MULA
        return _fmac(6, 6, mask, fs, ft, 0, toAcc: true);
      case const (11 << 2 | 0): // SUBA
        return _fmac(1, 6, mask, fs, ft, 0, toAcc: true);
      case const (11 << 2 | 1): // MSUBA
        return _fmac(3, 6, mask, fs, ft, 0, toAcc: true);
      case const (11 << 2 | 2): // OPMULA
        IrValue mac = _c(0);
        for (var c = 0; c < 3; c++) {
          final a = c == 2 ? 0 : c + 1, v = c == 0 ? 2 : c - 1;
          final (bits, under, over) = _encode(b.floatBinary(
              IrOp.floatMul, _laneDecoded(fs, a), _laneDecoded(ft, v)));
          _setAcc(c, bits);
          mac = b.or(mac, _macBits(c, bits, under, over));
        }
        _upperMac = mac;
        return null;
    }
    return null; // NOP and unassigned codes
  }

  /// ITOF ([toFloat]) or FTOI with the fixed point shift of [col]
  (int, int, List<IrValue?>, List<IrValue?>) _convert(
      bool toFloat, int col, int mask, int fs, int ft) {
    final n = const [0, 4, 12, 15][col];
    final lanes = List<IrValue?>.filled(4, null);
    for (var c = 0; c < 4; c++) {
      if (mask & (8 >> c) == 0) continue;
      if (toFloat) {
        // 2^52 + 2^31 + x as binary64 bits, minus 2^52 + 2^31, is x
        final biased = b.zext32(b.xor(_lane(fs, c), _c(0x80000000)));
        var v = b.floatBinary(IrOp.floatSub,
            b.or(biased, _c64(0x4330000000000000)), _c64(0x4330000080000000));
        if (n != 0) {
          v = b.floatBinary(IrOp.floatMul, v, _c64((1023 - n) << 52));
        }
        lanes[c] = _bits(v);
      } else {
        var v = _laneDecoded(fs, c);
        if (n != 0) {
          v = b.floatBinary(IrOp.floatMul, v, _c64((1023 + n) << 52));
        }
        final hi = b.trunc32(b.shrU(v, _c(32)));
        final inRange =
            b.ltS(b.and(b.shrU(hi, _c(20)), _c(0x7ff)), _c(1023 + 31));
        final converted =
            b.floatToInt(b.select(inRange, v, _c64(0)), truncate: true);
        lanes[c] = b.select(inRange, converted,
            b.select(b.ltS(hi, _c(0)), _c(0x80000000), _c(0x7fffffff)));
      }
    }
    return (ft, mask, lanes, List<IrValue?>.filled(4, null));
  }

  void _clipJudgement(int fs, int ft) {
    final w = _lane(ft, 3);
    final kw = b.select(
        b.eq(b.and(w, _c(0x7f800000)), _c(0)), _c(0), b.and(w, _c(0x7fffffff)));
    final negative = b.sub(_c(0), kw);
    IrValue bits = _c(0);
    for (var c = 0; c < 3; c++) {
      final kv = _key(_lane(fs, c));
      bits = b.or(
          bits,
          b.or(b.shl(b.ltS(kw, kv), _c(c * 2)),
              b.shl(b.ltS(kv, negative), _c(c * 2 + 1))));
    }
    _upperClip = bits;
  }

  // ---- lower instructions ----

  IrValue _quad(IrValue base, int offset) =>
      b.and(b.add(base, _c(offset)), _c(dataQuads - 1));

  IrValue _laneAddress(IrValue quad, int c) =>
      b.add(b.shl(quad, _c(4)), _c(c * 4));

  void _loadQuad(int reg, int mask, IrValue quad) {
    if (reg == 0) return;
    _setReady(reg, mask);
    for (var c = 0; c < 4; c++) {
      if (mask & (8 >> c) != 0) {
        _setLane(reg, c, b.load(4, _laneAddress(quad, c)));
      }
    }
  }

  void _storeQuad(int reg, int mask, IrValue quad) {
    for (var c = 0; c < 4; c++) {
      if (mask & (8 >> c) != 0) {
        b.store(4, _laneAddress(quad, c), _lane(reg, c));
      }
    }
  }

  static int _maskLane(int mask) =>
      mask & 8 != 0 ? 0 : (mask & 4 != 0 ? 1 : (mask & 2 != 0 ? 2 : 3));

  int _target(int pair) => pair & (pairCount - 1);

  static int _imm12(int ir) => ((ir >> 10) & 0x800) | (ir & 0x7ff);

  /// The term of the branch at [pc], with its link write. The branch
  /// reads its registers before the delay slot.
  IrTerm _branch(int pc, int ir) {
    final op = ir >>> 25;
    final it = (ir >> 16) & 15, is_ = (ir >> 11) & 15;
    final imm11 = (ir & 0x7ff).toSigned(11);
    final target = _target(pc + 1 + imm11);
    final next = _target(pc + 2);
    final isv = _getVi(is_);
    IrTerm term;
    switch (op) {
      case 0x20 || 0x21: // B, BAL
        term = IrJump(target);
      case 0x24 || 0x25: // JR, JALR
        term = IrJumpDyn(b.and(isv, _c(pairCount - 1)));
      case _:
        final signed = b.sext16(isv);
        final cond = switch (op) {
          0x28 => b.eq(_getVi(it), isv),
          0x29 => b.ne(_getVi(it), isv),
          0x2c => b.ltS(signed, _c(0)),
          0x2d => b.ltS(_c(0), signed),
          0x2e => b.ltS(signed, _c(1)),
          _ => b.ltS(_c(-1), signed),
        };
        term = IrBranch(cond, target, next);
    }
    // the branch pair itself, with the link written by its lower word
    _pairWithLower(pc, ir, () {
      if (op == 0x21 || op == 0x25) _setVi(it, _c(pc + 2));
    });
    return term;
  }

  /// Translates the branch pair at [pc], whose lower instruction is
  /// [lower] in place of the decoding of the lower word [lo].
  void _pairWithLower(int pc, int lo, void Function() lower) {
    _lowerOverride = lower;
    _pair(pc, lo, fetch(pc * 2 + 1));
    _lowerOverride = null;
  }

  void Function()? _lowerOverride;

  void _lower(int pc, int ir) {
    final override = _lowerOverride;
    if (override != null) {
      override();
      return;
    }
    final op = ir >>> 25;
    final mask = (ir >> 21) & 15;
    final it = (ir >> 16) & 31, is_ = (ir >> 11) & 15;
    final fsReg = (ir >> 11) & 31;
    final imm11 = (ir & 0x7ff).toSigned(11);
    switch (op) {
      case 0x00: // LQ
        _loadQuad(it, mask, _quad(_getVi(fsReg & 15), imm11));
      case 0x01: // SQ
        _storeQuad(fsReg, mask, _quad(_getVi(it & 15), imm11));
      case 0x04: // ILW
        final quad = _quad(_getVi(is_), imm11);
        _setVi(it & 15, b.load(4, _laneAddress(quad, _maskLane(mask))));
      case 0x05: // ISW
        final quad = _quad(_getVi(is_), imm11);
        final value = _getVi(it & 15);
        for (var c = 0; c < 4; c++) {
          if (mask & (8 >> c) != 0) b.store(4, _laneAddress(quad, c), value);
        }
      case 0x08: // IADDIU
        _setVi(it & 15,
            b.add(_getVi(is_), _c(((mask << 11) | (ir & 0x7ff)) & 0x7fff)));
      case 0x09: // ISUBIU
        _setVi(it & 15,
            b.sub(_getVi(is_), _c(((mask << 11) | (ir & 0x7ff)) & 0x7fff)));
      case 0x10: // FCEQ
        _commitFlags();
        _setVi(1, b.eq(_clipValue(), _c(ir & 0xffffff)));
      case 0x11: // FCSET
        _commitFlags();
        _clip = _c(ir & 0xffffff);
        _flagsDirty = true;
      case 0x12: // FCAND
        _commitFlags();
        _setVi(1, b.ne(b.and(_clipValue(), _c(ir & 0xffffff)), _c(0)));
      case 0x13: // FCOR
        _commitFlags();
        _setVi(1, b.eq(b.or(_clipValue(), _c(ir & 0xffffff)), _c(0xffffff)));
      case 0x14: // FSEQ
        _commitFlags();
        _setVi(it & 15, b.eq(b.and(_statusValue(), _c(0xfff)), _c(_imm12(ir))));
      case 0x15: // FSSET
        _commitFlags();
        _status = b.or(b.and(_statusValue(), _c(0x3f)), _c(_imm12(ir) & 0xfc0));
        _macOr = _c(0);
        _statusDirty = _c(0);
        _flagsDirty = true;
      case 0x16: // FSAND
        _commitFlags();
        _setVi(it & 15, b.and(_statusValue(), _c(_imm12(ir))));
      case 0x17: // FSOR
        _commitFlags();
        _setVi(it & 15, b.or(_statusValue(), _c(_imm12(ir))));
      case 0x18: // FMEQ
        _commitFlags();
        _setVi(it & 15, b.eq(_macValue(), _getVi(is_)));
      case 0x1a: // FMAND
        _commitFlags();
        _setVi(it & 15, b.and(_macValue(), _getVi(is_)));
      case 0x1b: // FMOR
        _commitFlags();
        _setVi(it & 15, b.or(_macValue(), _getVi(is_)));
      case 0x1c: // FCGET
        _commitFlags();
        _setVi(it & 15, b.and(_clipValue(), _c(0xfff)));
      case 0x40:
        _lowerSpecial(ir, mask, it, fsReg);
    }
  }

  void _lowerSpecial(int ir, int mask, int it, int fs) {
    final funct = ir & 0x3f;
    final id = (ir >> 6) & 15;
    final isIdx = fs & 15;
    switch (funct) {
      case 0x30:
        _setVi(id, b.add(_getVi(isIdx), _getVi(it & 15)));
        return;
      case 0x31:
        _setVi(id, b.sub(_getVi(isIdx), _getVi(it & 15)));
        return;
      case 0x32:
        _setVi(it & 15, b.add(_getVi(isIdx), _c(((ir >> 6) & 31).toSigned(5))));
        return;
      case 0x34:
        _setVi(id, b.and(_getVi(isIdx), _getVi(it & 15)));
        return;
      case 0x35:
        _setVi(id, b.or(_getVi(isIdx), _getVi(it & 15)));
        return;
    }
    if (funct < 0x3c) return;
    final sub = (ir >> 6) & 31;
    final col = funct & 3;
    final fsf = (ir >> 21) & 3, ftf = (ir >> 23) & 3;
    switch ((sub << 2) | col) {
      case const (0x0c << 2 | 0): // MOVE
        if (it == 0) return;
        _setReady(it, mask);
        for (var c = 0; c < 4; c++) {
          if (mask & (8 >> c) != 0) {
            _setLane(it, c, _lane(fs, c), _vfDecoded[fs * 4 + c]);
          }
        }
      case const (0x0d << 2 | 0): // LQI
        final base = _getVi(isIdx);
        _loadQuad(it, mask, b.and(base, _c(dataQuads - 1)));
        _setVi(isIdx, b.add(base, _c(1)));
      case const (0x0e << 2 | 0): // DIV
        _divide(fs, fsf, it, ftf, root: false);
      case const (0x0f << 2 | 0): // MTIR
        _setVi(it & 15, _lane(fs, fsf));
      case const (0x0c << 2 | 1): // MR32
        if (it == 0) return;
        final source = [for (var c = 0; c < 4; c++) _lane(fs, (c + 1) % 4)];
        _setReady(it, mask);
        for (var c = 0; c < 4; c++) {
          if (mask & (8 >> c) != 0) _setLane(it, c, source[c]);
        }
      case const (0x0d << 2 | 1): // SQI
        final base = _getVi(it & 15);
        _storeQuad(fs, mask, b.and(base, _c(dataQuads - 1)));
        _setVi(it & 15, b.add(base, _c(1)));
      case const (0x0e << 2 | 1): // SQRT
        final value = _laneDecoded(it, ftf);
        final negative = b.ltS(b.trunc32(b.shrU(value, _c(32))), _c(0));
        _setDivisionStatus(b.select(negative, _c(0x10), _c(0)));
        final magnitude = b.and(value, _c64(0x7fffffffffffffff));
        _start(_qUnit, _bits(b.floatSqrt(magnitude)), 7);
      case const (0x0f << 2 | 1): // MFIR
        if (it == 0) return;
        final value = b.sext16(_getVi(isIdx));
        for (var c = 0; c < 4; c++) {
          if (mask & (8 >> c) != 0) _setLane(it, c, value);
        }
      case const (0x0d << 2 | 2): // LQD
        final base = b.sub(_getVi(isIdx), _c(1));
        _setVi(isIdx, base);
        _loadQuad(it, mask, b.and(base, _c(dataQuads - 1)));
      case const (0x0e << 2 | 2): // RSQRT
        _divide(fs, fsf, it, ftf, root: true);
      case const (0x0f << 2 | 2): // ILWR
        final quad = b.and(_getVi(isIdx), _c(dataQuads - 1));
        _setVi(it & 15, b.load(4, _laneAddress(quad, _maskLane(mask))));
      case const (0x0d << 2 | 3): // SQD
        final base = b.sub(_getVi(it & 15), _c(1));
        _setVi(it & 15, base);
        _storeQuad(fs, mask, b.and(base, _c(dataQuads - 1)));
      case const (0x0e << 2 | 3): // WAITQ
        break;
      case const (0x0f << 2 | 3): // ISWR
        final quad = b.and(_getVi(isIdx), _c(dataQuads - 1));
        final value = _getVi(it & 15);
        for (var c = 0; c < 4; c++) {
          if (mask & (8 >> c) != 0) b.store(4, _laneAddress(quad, c), value);
        }
      case const (0x10 << 2 | 0): // RNEXT
        final r = _rValue();
        final bit = b.and(b.xor(b.shrU(r, _c(4)), b.shrU(r, _c(22))), _c(1));
        _setR(b.or(b.shl(r, _c(1)), bit));
        _writeScalar(it, mask, _r!);
      case const (0x10 << 2 | 1): // RGET
        _writeScalar(it, mask, _rValue());
      case const (0x10 << 2 | 2): // RINIT
        _setR(_lane(fs, fsf));
      case const (0x10 << 2 | 3): // RXOR
        _setR(b.xor(_rValue(), _lane(fs, fsf)));
      case const (0x19 << 2 | 0): // MFP
        _writeScalar(it, mask, _now(_pUnit));
      case const (0x1e << 2 | 3): // WAITP
        break;
      case >= 0x70: // the EFU
        _efu((sub << 2) | col, fs, fsf);
      case const (0x1a << 2 | 0): // XTOP
        _setVi(it & 15, b.call(topHelper));
      case const (0x1a << 2 | 1): // XITOP
        _setVi(it & 15, b.and(b.call(itopHelper), _c(0x3ff)));
      case const (0x1b << 2 | 0): // XGKICK
        _kick = b.and(_getVi(isIdx), _c(dataQuads - 1));
    }
  }

  IrValue _rValue() => _r ??= b.ctxLoad(VuCtx.r);

  /// R set to the fraction of [value] with the exponent of 1.0
  void _setR(IrValue value) {
    _r = b.or(_c(0x3f800000), b.and(value, _c(0x7fffff)));
    _rDirty = true;
  }

  void _writeScalar(int reg, int mask, IrValue value) {
    if (reg == 0) return;
    _setReady(reg, mask);
    for (var c = 0; c < 4; c++) {
      if (mask & (8 >> c) != 0) _setLane(reg, c, value);
    }
  }

  /// the EFU operations that need only the arithmetic of the IR, with the
  /// latencies of [Vu]
  void _efu(int code, int fs, int fsf) {
    IrValue add(IrValue a, IrValue v) => b.floatBinary(IrOp.floatAdd, a, v);
    IrValue mul(IrValue a, IrValue v) => b.floatBinary(IrOp.floatMul, a, v);
    IrValue reciprocal(IrValue v) =>
        b.floatBinary(IrOp.floatDiv, _c64(0x3ff0000000000000), v);
    IrValue squares() {
      final x = _laneDecoded(fs, 0), y = _laneDecoded(fs, 1);
      final z = _laneDecoded(fs, 2);
      return add(add(mul(x, x), mul(y, y)), mul(z, z));
    }

    IrValue magnitude() =>
        b.and(_laneDecoded(fs, fsf), _c64(0x7fffffffffffffff));
    final (value, latency) = switch (code) {
      0x70 => (squares(), 11), // ESADD
      0x71 => (reciprocal(squares()), 18), // ERSADD
      0x72 => (b.floatSqrt(squares()), 18), // ELENG
      0x73 => (reciprocal(b.floatSqrt(squares())), 24), // ERLENG
      0x76 => (
          add(
              add(add(_laneDecoded(fs, 0), _laneDecoded(fs, 1)),
                  _laneDecoded(fs, 2)),
              _laneDecoded(fs, 3)),
          12
        ), // ESUM
      0x78 => (b.floatSqrt(magnitude()), 12), // ESQRT
      0x79 => (reciprocal(b.floatSqrt(magnitude())), 18), // ERSQRT
      _ => (reciprocal(_laneDecoded(fs, fsf)), 12), // ERCPR
    };
    _start(_pUnit, _bits(value), latency);
  }

  /// the division status bits I and D (0x10 and 0x20) set to [bits]
  void _setDivisionStatus(IrValue bits) {
    _status = b.or(b.and(_statusBase(), _c(~0x30)), bits);
    _flagsDirty = true;
  }

  /// DIV fs.fsf / ft.ftf, or RSQRT with the square root of the divisor
  void _divide(int fs, int fsf, int ft, int ftf, {required bool root}) {
    final aBits = _lane(fs, fsf), divisorBits = _lane(ft, ftf);
    final a = _laneDecoded(fs, fsf);
    final divisor = _laneDecoded(ft, ftf);
    final aZero = b.eq(b.and(aBits, _c(0x7f800000)), _c(0));
    final byZero = b.eq(b.and(divisorBits, _c(0x7f800000)), _c(0));
    final zeroStatus = b.select(aZero, _c(0x10), _c(0x20));
    // a zero divisor gives the largest magnitude with the sign of a for
    // RSQRT and of the quotient for DIV; a decoded zero is positive
    final aSign = b.select(aZero, _c(0), b.and(aBits, _c(0x80000000)));
    final IrValue quotient;
    if (root) {
      final negative = b.and(b.ltS(divisorBits, _c(0)), b.eq(byZero, _c(0)));
      _setDivisionStatus(
          b.select(byZero, zeroStatus, b.select(negative, _c(0x10), _c(0))));
      final magnitude = b.and(divisor, _c64(0x7fffffffffffffff));
      quotient = _bits(b.floatBinary(IrOp.floatDiv, a,
          b.floatSqrt(b.select(byZero, _c64(0x3ff0000000000000), magnitude))));
    } else {
      _setDivisionStatus(b.select(byZero, zeroStatus, _c(0)));
      quotient = _bits(b.floatBinary(IrOp.floatDiv, a,
          b.select(byZero, _c64(0x3ff0000000000000), divisor)));
    }
    _start(_qUnit, b.select(byZero, b.or(aSign, _c(0x7fffffff)), quotient),
        root ? 13 : 7);
  }

  // ---- flags ----

  IrValue _macValue() => _mac ??= b.ctxLoad(VuCtx.mac);
  IrValue _clipValue() => _clip ??= b.ctxLoad(VuCtx.clip);
  IrValue _statusBase() => _status ??= b.ctxLoad(VuCtx.status);
  IrValue _macOrValue() => _macOr ??= b.ctxLoad(VuCtx.macOr);
  IrValue _statusDirtyValue() => _statusDirty ??= b.ctxLoad(VuCtx.statusDirty);

  /// the status flag as [Vu.statusOf] derives it
  IrValue _statusValue() {
    IrValue bits(IrValue m, int shift) {
      IrValue r = _c(0);
      for (var g = 0; g < 4; g++) {
        r = b.or(
            r, b.shl(b.ne(b.and(m, _c(0xf << (g * 4))), _c(0)), _c(g + shift)));
      }
      return r;
    }

    final base = _statusBase();
    final derived = b.or(b.and(base, _c(0xff0)),
        b.or(bits(_macValue(), 0), bits(_macOrValue(), 6)));
    final value = b.select(b.ne(_statusDirtyValue(), _c(0)), derived, base);
    _status = value;
    _macOr = _c(0);
    _statusDirty = _c(0);
    _flagsDirty = true;
    return value;
  }

  void _loadSlots() {
    if (_slotsLoaded) return;
    _slotsLoaded = true;
    // oldest first, before the results of the block
    for (var k = 0; k < VuCtx.flagSlots; k++) {
      _flags.insert(
          0,
          _Flag(
              b.ctxLoad(VuCtx.flagReady + 2 * k, type: IrType.i64),
              b.ctxLoad(VuCtx.flagMac + k),
              b.ctxLoad(VuCtx.flagClip + k),
              -1 - k,
              slot: true));
    }
  }

  /// whether the flag result [f] is visible from this pair on for sure
  bool _aged(_Flag f) => _p - f.pair >= _latency;

  /// Applies the flag results visible at [_issued], in order, as the
  /// interpreter does at the start of a pair. A result applied here is
  /// marked as gone in its slot.
  void _commitFlags() {
    _loadSlots();
    for (final f in List.of(_flags)) {
      if (_aged(f)) {
        _apply(f, f.consumed ? b.ne(f.ready, _c64(VuCtx.flagNone)) : null);
        _flags.remove(f);
      } else {
        final visible = b.eq(b.ltS(_issued, f.ready), _c(0));
        _apply(f, visible);
        f.ready = b.select(visible, _c64(VuCtx.flagNone), f.ready);
        f.consumed = true;
      }
    }
  }

  /// Applies the result [f] when [when] is not 0, or always for null.
  void _apply(_Flag f, IrValue? when) {
    _flagsDirty = true;
    final mac = f.mac, clip = f.clip;
    if (mac != null) {
      var cond = when;
      if (f.slot) {
        final present = b.eq(b.ltS(mac, _c(0)), _c(0));
        cond = cond == null ? present : b.and(cond, present);
      }
      if (cond == null) {
        _mac = mac;
        _macOr = b.or(_macOrValue(), mac);
        _statusDirty = _c(1);
      } else {
        _mac = b.select(cond, mac, _macValue());
        _macOr = b.select(cond, b.or(_macOrValue(), mac), _macOrValue());
        _statusDirty = b.or(_statusDirtyValue(), cond);
      }
    }
    if (clip != null) {
      var cond = when;
      if (f.slot) {
        final present = b.eq(b.ltS(clip, _c(0)), _c(0));
        cond = cond == null ? present : b.and(cond, present);
      }
      final shifted =
          b.and(b.or(b.shl(_clipValue(), _c(6)), clip), _c(0xffffff));
      _clip = cond == null ? shifted : b.select(cond, shifted, _clipValue());
    }
  }

  /// Writes the flag state for the next block: the results of the last
  /// [VuCtx.flagSlots] pairs to their slots, the older ones applied.
  void _flushFlags() {
    final slots = List<_Flag?>.filled(VuCtx.flagSlots, null);
    if (!_slotsLoaded) {
      // the slots from before the block, oldest first, which are older
      // than every result of the block
      for (var from = VuCtx.flagSlots - 1; from >= 0; from--) {
        final f = _Flag(
            b.ctxLoad(VuCtx.flagReady + 2 * from, type: IrType.i64),
            b.ctxLoad(VuCtx.flagMac + from),
            b.ctxLoad(VuCtx.flagClip + from),
            -1 - from,
            slot: true);
        if (_aged(f)) {
          _apply(f, b.ne(f.ready, _c64(VuCtx.flagNone)));
        } else {
          slots[from + _p] = f;
        }
      }
    }
    for (final f in _flags) {
      if (_aged(f)) {
        _apply(f, f.consumed ? b.ne(f.ready, _c64(VuCtx.flagNone)) : null);
      } else {
        slots[_p - 1 - f.pair] = f;
      }
    }
    for (var k = 0; k < VuCtx.flagSlots; k++) {
      final f = slots[k];
      b.ctxStore(VuCtx.flagReady + 2 * k, f?.ready ?? _c64(VuCtx.flagNone));
      b.ctxStore(VuCtx.flagMac + k, f?.mac ?? _c(-1));
      b.ctxStore(VuCtx.flagClip + k, f?.clip ?? _c(-1));
    }
    if (_flagsDirty) {
      if (_mac != null) b.ctxStore(VuCtx.mac, _mac!);
      if (_clip != null) b.ctxStore(VuCtx.clip, _clip!);
      if (_status != null) b.ctxStore(VuCtx.status, _status!);
      if (_macOr != null) b.ctxStore(VuCtx.macOr, _macOr!);
      if (_statusDirty != null) b.ctxStore(VuCtx.statusDirty, _statusDirty!);
    }
  }

  void _flush() {
    for (var k = 4; k < 128; k++) {
      if (_vfDirty[k]) b.ctxStore(VuCtx.vf + k, _vf[k]!);
      if (_readyDirty[k]) b.ctxStore(VuCtx.ready + 2 * k, _ready[k]!);
    }
    for (var c = 0; c < 4; c++) {
      if (_accDirty[c]) b.ctxStore(VuCtx.acc + c, _acc[c]!);
    }
    for (var w = 0; w < 8; w++) {
      if (!_viDirty[2 * w] && !_viDirty[2 * w + 1]) continue;
      final low = w == 0 ? _c(0) : _getVi(2 * w);
      b.ctxStore(VuCtx.vi + w, b.or(low, b.shl(_getVi(2 * w + 1), _c(16))));
    }
    b.ctxStore(VuCtx.cycles, _cycles);
    if (_iDirty) b.ctxStore(VuCtx.i, _i!);
    if (_rDirty) b.ctxStore(VuCtx.r, _r!);
    _flushUnit(_qUnit);
    _flushUnit(_pUnit);
    _flushFlags();
  }
}

/// a flag result in the FMAC pipeline: its ready cycle, MAC bits and clip
/// judgement (null when the pair set none, or -1 in a slot)
final class _Flag {
  IrValue ready;
  final IrValue? mac, clip;

  /// the pair that set it, negative for a slot from before the block
  final int pair;
  final bool slot;

  /// whether [ready] may already be [VuCtx.flagNone]
  bool consumed;

  _Flag(this.ready, this.mac, this.clip, this.pair, {required this.slot})
      : consumed = slot;
}

/// a unit whose result comes some cycles after its operation (the
/// division unit or the EFU), with the context words of its register, its
/// pending result, whether one is pending and its cycle
final class _Unit {
  final int valueWord, pendingWord, busyWord, readyWord;

  /// the longest latency of the unit, for a result from before the block
  final int maxLatency;
  IrValue? value, pending, busy, ready;
  bool dirty = false;

  /// whether nothing is pending for sure
  bool idle = false;

  /// the pair of the pending operation and its latency, after which it is
  /// done for sure
  int pair = -1, latency = 0;

  _Unit(this.valueWord, this.pendingWord, this.busyWord, this.readyWord,
      this.maxLatency);

  void reset() {
    value = pending = busy = ready = null;
    dirty = idle = false;
    pair = -1;
    latency = maxLatency;
  }
}
