import 'dart:math' as math;
import 'dart:typed_data';

import 'r5900/fpu.dart';

/// A vector unit (VU0 or VU1): 32 four-lane float registers, 16 integer
/// registers, micro memory of 64-bit instruction pairs and data memory of
/// quadwords.
///
/// A micro program runs to its end when it is started. Every pair takes one
/// cycle. A pair that reads a field of a VF register written by an FMAC or a
/// load within the last four cycles stalls until the value is ready, as the
/// hardware interlocks it. The check is done per field (x, y, z, w), so a
/// write to one field does not stall a read of another. DIV and SQRT update Q seven cycles after they
/// issue and RSQRT thirteen; Q is not interlocked, so the pairs before that
/// read the old value. The elementary function unit (EFU) updates P in the
/// same way, after the latency of each function. WAITQ and WAITP, and a new
/// operation of the same unit, wait for the pending result.
/// The MAC, status and clip flags that an FMAC operation or CLIP sets come
/// out of the pipeline with its result, so the flag instructions of a pair
/// see them four cycles after the operation issues. MAX, MINI, ABS, FTOI and
/// ITOF leave the flags alone. Upper instructions read their operands before
/// the lower instruction of the same pair writes. Macro mode applies every
/// result at once.
///
/// The encoding of the lower special instructions is written from memory of
/// the manuals and is not yet checked against hardware. The EFU computes in double precision and
/// rounds to the VU format, so its last bit may differ from the hardware
/// approximations. Not implemented: the T and D debug bits.
class Vu {
  final int index;
  final int microWords; // 32-bit words of micro memory
  final int dataQuads;

  final Uint32List micro;
  final Uint32List data;
  final Uint32List vf = Uint32List(128);
  final Uint16List vi = Uint16List(16);
  final Uint32List acc = Uint32List(4);

  int i = 0, q = 0x3f800000, r = 0x3f800000, p = 0;
  int mac = 0, status = 0, clip = 0;
  int pc = 0;
  int cmsar0 = 0;
  bool running = false;
  int cycles = 0;

  /// VU1 only: the value of XTOP and XITOP
  int Function() top = _zero, itop = _zero;

  /// VU1 only: called with the data memory address of an XGKICK
  void Function(int quadAddress)? onXgkick;

  /// set when a program finishes
  void Function()? onEnd;

  /// VU0 only: called when the CPU writes the address of a VU1 program
  void Function(int address)? onCmsar1;

  int _pending = -1;
  bool _ending = false;

  /// true while a micro program runs, so that Q and VF results are delayed
  bool _micro = false;

  // the division unit: the value Q takes at cycle [_qReady]
  bool _qBusy = false;
  int _qValue = 0, _qReady = 0;

  // the EFU: the value P takes at cycle [_pReady]
  bool _pBusy = false;
  int _pValue = 0, _pReady = 0;

  /// the cycle at which each field of a VF register holds its newest value,
  /// indexed by register * 4 + field
  final _vfReady = Int64List(128);

  static const _fmacLatency = 4;

  // The flag results in the FMAC pipeline, in issue order: the cycle at which
  // each one becomes visible, the MAC flag bits (or -1) and the clip
  // judgement bits (or -1).
  static const _flagSlots = 16;
  final _flagReady = Int64List(_flagSlots);
  final _flagMac = Int32List(_flagSlots);
  final _flagClip = Int32List(_flagSlots);
  int _flagHead = 0, _flagCount = 0;

  Vu(this.index)
      : microWords = index == 0 ? 1024 : 4096,
        dataQuads = index == 0 ? 256 : 1024,
        micro = Uint32List(index == 0 ? 1024 : 4096),
        data = Uint32List((index == 0 ? 256 : 1024) * 4) {
    reset();
  }

  static int _zero() => 0;

  void reset() {
    vf.fillRange(0, 128, 0);
    vf[3] = 0x3f800000; // VF0 = (0, 0, 0, 1)
    vi.fillRange(0, 16, 0);
    acc.fillRange(0, 4, 0);
    mac = status = clip = 0;
    i = 0;
    q = r = 0x3f800000;
    pc = 0;
    running = false;
    _pending = -1;
    _ending = false;
    p = 0;
    _qBusy = _pBusy = false;
    _vfReady.fillRange(0, 128, 0);
    _flagCount = 0;
  }

  /// starts the program at pair [address] and runs it to its end
  void start(int address, {int maxPairs = 1 << 20}) {
    pc = address & (microWords ~/ 2 - 1);
    running = true;
    _pending = -1;
    _ending = false;
    _micro = true;
    var n = 0;
    while (running && n++ < maxPairs) {
      step();
    }
    if (running) running = false;
    _micro = false;
    _commitFlags(null);
    _finishDivision();
    _finishEfu();
    onEnd?.call();
  }

  // ---- macro mode (VU0 instructions issued by the CPU through COP2) ----

  /// Executes the instruction word of a COP2 macro instruction.
  void macro(int ir) {
    final funct = ir & 0x3f;
    if (funct == 0x38) {
      start((ir >> 6) & 0x7fff); // VCALLMS
      return;
    }
    if (funct == 0x39) {
      start(cmsar0); // VCALLMSR
      return;
    }
    // VIADD, VISUB, VIADDI, VIAND, VIOR and the lower special2 codes
    if ((funct >= 0x30 && funct < 0x36) ||
        (funct >= 0x3c && ((ir >> 6) & 31) >= 0x0c)) {
      _lowerSpecial(ir, (ir >> 21) & 15, (ir >> 16) & 31, (ir >> 11) & 31);
      vi[0] = 0;
      return;
    }
    if (_upper(ir)) _setVf(_upperReg, _upperMask, _result);
    if (_flagsPending) _applyFlags(_upperMac, -1);
    if (_clipPending >= 0) _applyFlags(-1, _clipPending);
    _flagsPending = false;
    _clipPending = -1;
  }

  int readControl(int n) => switch (n) {
        < 16 => vi[n],
        16 => status,
        17 => mac,
        18 => clip,
        20 => r,
        21 => i,
        22 => q,
        27 => cmsar0,
        _ => 0,
      };

  void writeControl(int n, int value) {
    switch (n) {
      case < 16:
        if (n != 0) vi[n] = value;
      case 16:
        status = value & 0xfff;
      case 17:
        mac = value & 0xffff;
      case 18:
        clip = value & 0xffffff;
      case 20:
        r = value;
      case 21:
        i = value;
      case 22:
        q = value;
        _qBusy = false;
      case 27:
        cmsar0 = value & 0xffff;
      case 28:
        if (value & 2 != 0) reset();
      case 31:
        onCmsar1?.call(value & 0xffff);
    }
  }

  // ---- helpers ----

  static final _flags = <int>[0];

  double _d(int bits) => R5900Fpu.decode(bits);

  int _enc(double value) {
    _flags[0] = 0;
    final bits = R5900Fpu.encode(value, _flags);
    _lastFlags = _flags[0];
    return bits;
  }

  int _lastFlags = 0;

  int _lane(int reg, int c) => vf[reg * 4 + c];

  void _setVf(int reg, int mask, List<int> value) {
    if (reg == 0) return;
    for (var c = 0; c < 4; c++) {
      if (mask & (8 >> c) != 0) vf[reg * 4 + c] = value[c];
    }
  }

  final _result = List<int>.filled(4, 0);

  // ---- execution of one pair ----

  void step() {
    final lowWord = micro[pc * 2], highWord = micro[pc * 2 + 1];
    final delayTarget = _pending;
    _pending = -1;
    final wasEnding = _ending;
    final iBit = highWord >>> 31 != 0;
    _stall(highWord, iBit ? 0 : lowWord);
    if (_qBusy && cycles >= _qReady) _finishDivision();
    if (_pBusy && cycles >= _pReady) _finishEfu();
    if (_flagCount > 0) _commitFlags(cycles);
    final issued = cycles++;

    if (highWord & 0x40000000 != 0) _ending = true;

    // the upper instruction reads before the lower one writes
    final hasWrite = _upper(highWord);
    final savedResult = hasWrite ? List<int>.of(_result) : const <int>[];
    final upperReg = _upperReg, upperMask = _upperMask;
    final upperMac = _flagsPending ? _upperMac : -1;
    final upperClip = _clipPending;
    _flagsPending = false;
    _clipPending = -1;
    if (iBit) {
      i = lowWord;
    } else {
      _lower(lowWord);
    }
    if (hasWrite) {
      _setVf(upperReg, upperMask, savedResult);
      if (upperReg != 0) _setReady(upperReg, upperMask, issued + _fmacLatency);
    }
    if (upperMac >= 0 || upperClip >= 0) {
      _queueFlags(issued + _fmacLatency, upperMac, upperClip);
    }
    vi[0] = 0;

    if (delayTarget >= 0) {
      pc = delayTarget & (microWords ~/ 2 - 1);
    } else {
      pc = (pc + 1) & (microWords ~/ 2 - 1);
    }
    if (wasEnding) running = false;
  }

  void _setReady(int reg, int fields, int cycle) {
    for (var c = 0; c < 4; c++) {
      if (fields & (8 >> c) != 0) _vfReady[reg * 4 + c] = cycle;
    }
  }

  /// the cycle at which the [fields] of [reg] are ready, at least [t]
  int _readyAt(int reg, int fields, int t) {
    if (reg == 0) return t;
    for (var c = 0; c < 4; c++) {
      if (fields & (8 >> c) != 0) {
        final r = _vfReady[reg * 4 + c];
        if (r > t) t = r;
      }
    }
    return t;
  }

  /// Waits for the VF fields that the pair reads, and for Q before a WAITQ
  /// or P before a WAITP.
  void _stall(int upper, int lower) {
    var t = cycles;
    final (fsFields, ftFields) = _upperReads(upper);
    if (fsFields != 0) t = _readyAt((upper >> 11) & 31, fsFields, t);
    if (ftFields != 0) t = _readyAt((upper >> 16) & 31, ftFields, t);
    final op = lower >>> 25;
    final mask = (lower >> 21) & 15;
    final fs = (lower >> 11) & 31, ft = (lower >> 16) & 31;
    if (op == 0x01) {
      t = _readyAt(fs, mask, t); // SQ
    } else if (op == 0x40 && lower & 0x3c == 0x3c) {
      final fsf = 8 >> ((lower >> 21) & 3), ftf = 8 >> ((lower >> 23) & 3);
      final code = ((lower >> 6) & 31) << 2 | (lower & 3);
      switch (code) {
        // MOVE, SQI, SQD
        case const (0x0c << 2 | 0) ||
              const (0x0d << 2 | 1) ||
              const (0x0d << 2 | 3):
          t = _readyAt(fs, mask, t);
        // MR32 reads the field after each written one
        case const (0x0c << 2 | 1):
          t = _readyAt(fs, (mask >> 1 | mask << 3) & 15, t);
        // MTIR, RINIT, RXOR
        case const (0x0f << 2 | 0) ||
              const (0x10 << 2 | 2) ||
              const (0x10 << 2 | 3):
          t = _readyAt(fs, fsf, t);
        // DIV, RSQRT
        case const (0x0e << 2 | 0) || const (0x0e << 2 | 2):
          t = _readyAt(ft, ftf, _readyAt(fs, fsf, t));
        // SQRT
        case const (0x0e << 2 | 1):
          t = _readyAt(ft, ftf, t);
        // WAITQ
        case const (0x0e << 2 | 3):
          if (_qBusy && _qReady > t) t = _qReady;
        // WAITP
        case const (0x1e << 2 | 3):
          if (_pBusy && _pReady > t) t = _pReady;
        // ESADD, ERSADD, ELENG, ERLENG, EATANxy, EATANxz
        case >= 0x70 && < 0x76:
          t = _readyAt(fs, 14, t);
        // ESUM
        case const (0x1d << 2 | 2):
          t = _readyAt(fs, 15, t);
        // the EFU operations of one field
        case >= 0x78:
          t = _readyAt(fs, fsf, t);
      }
    }
    cycles = t;
  }

  /// the fields of fs and ft that the upper instruction [ir] reads
  static (int, int) _upperReads(int ir) {
    final op = ir & 63;
    final mask = (ir >> 21) & 15;
    if (op < 0x1c) return (mask, 8 >> (op & 3)); // broadcast
    if (op < 0x28) return (mask, 0); // Q or I
    if (op == 0x2e) return (14, 14); // OPMSUB
    if (op < 0x30) return (mask, mask);
    if (op < 0x3c) return (0, 0);
    final sub = (ir >> 6) & 31, col = op & 3;
    switch (sub) {
      case < 4 || 6: // the accumulator forms with a broadcast lane
        return (mask, 8 >> col);
      case 4 || 5 || 8 || 9: // ITOF, FTOI, and the Q and I forms
        return (mask, 0);
      case 7:
        return col == 3 ? (14, 1) : (mask, 0); // CLIP reads ft.w
      case 10:
        return (mask, col == 3 ? 0 : mask);
      case 11:
        return switch (col) { 2 => (14, 14), 3 => (0, 0), _ => (mask, mask) };
    }
    return (0, 0);
  }

  /// the fields [mask] of a VF register written by a lower instruction
  void _loweredVf(int reg, int mask) {
    // VF0 is constant; the lower NOP is a MOVE to it
    if (reg != 0) _setReady(reg, mask, cycles - 1 + _fmacLatency);
  }

  void _finishDivision() {
    if (!_qBusy) return;
    q = _qValue;
    _qBusy = false;
  }

  void _finishEfu() {
    if (!_pBusy) return;
    p = _pValue;
    _pBusy = false;
  }

  /// starts an EFU operation that sets P to [value] after [latency] cycles
  void _setP(double value, int latency) {
    final bits = _enc(value);
    if (!_micro) {
      p = bits;
      return;
    }
    if (_pBusy) {
      if (_pReady > cycles) cycles = _pReady;
      _finishEfu();
    }
    _pBusy = true;
    _pValue = bits;
    _pReady = cycles - 1 + latency;
  }

  /// the elementary function unit: [code] is the sub-opcode and column
  void _efu(int code, int fs, int fsf) {
    final x = _d(_lane(fs, 0)), y = _d(_lane(fs, 1)), z = _d(_lane(fs, 2));
    final s = _d(_lane(fs, fsf));
    final squares = x * x + y * y + z * z;
    switch (code) {
      case const (0x1c << 2 | 0): // ESADD
        _setP(squares, 11);
      case const (0x1c << 2 | 1): // ERSADD
        _setP(1 / squares, 18);
      case const (0x1c << 2 | 2): // ELENG
        _setP(math.sqrt(squares), 18);
      case const (0x1c << 2 | 3): // ERLENG
        _setP(1 / math.sqrt(squares), 24);
      case const (0x1d << 2 | 0): // EATANxy
        _setP(math.atan(y / x), 54);
      case const (0x1d << 2 | 1): // EATANxz
        _setP(math.atan(z / x), 54);
      case const (0x1d << 2 | 2): // ESUM
        _setP(x + y + z + _d(_lane(fs, 3)), 12);
      case const (0x1e << 2 | 0): // ESQRT
        _setP(math.sqrt(s.abs()), 12);
      case const (0x1e << 2 | 1): // ERSQRT
        _setP(1 / math.sqrt(s.abs()), 18);
      case const (0x1e << 2 | 2): // ERCPR
        _setP(1 / s, 12);
      case const (0x1f << 2 | 0): // ESIN
        _setP(math.sin(s), 29);
      case const (0x1f << 2 | 1): // EATAN
        _setP(math.atan(s), 54);
      case const (0x1f << 2 | 2): // EEXP
        _setP(math.exp(-s), 44);
    }
  }

  /// starts a division that sets Q to [value] after [latency] cycles
  void _setQ(int value, int latency) {
    if (!_micro) {
      q = value;
      return;
    }
    if (_qBusy) {
      // a new division waits for the pending one
      if (_qReady > cycles) cycles = _qReady;
      _finishDivision();
    }
    _qBusy = true;
    _qValue = value;
    _qReady = cycles - 1 + latency;
  }

  int _upperReg = 0, _upperMask = 0;
  bool _flagsPending = false;
  int _upperMac = 0;

  /// the clip judgement bits of a CLIP in the upper instruction, or -1
  int _clipPending = -1;

  void _queueFlags(int ready, int macBits, int clipBits) {
    if (_flagCount == _flagSlots) _commitFlags(null);
    final k = (_flagHead + _flagCount) % _flagSlots;
    _flagReady[k] = ready;
    _flagMac[k] = macBits;
    _flagClip[k] = clipBits;
    _flagCount++;
  }

  /// applies the queued flag results that are visible at cycle [now], or all
  /// of them when [now] is null
  void _commitFlags(int? now) {
    while (_flagCount > 0) {
      final k = _flagHead;
      if (now != null && _flagReady[k] > now) return;
      _applyFlags(_flagMac[k], _flagClip[k]);
      _flagHead = (k + 1) % _flagSlots;
      _flagCount--;
    }
  }

  /// sets the MAC flag and the status bits it derives, and shifts the clip
  /// judgement into the clip flag; -1 leaves a flag alone
  void _applyFlags(int macBits, int clipBits) {
    if (macBits >= 0) {
      mac = macBits;
      var st = status & 0xff0;
      if (macBits & 0x000f != 0) st |= 1 | 0x40; // Z
      if (macBits & 0x00f0 != 0) st |= 2 | 0x80; // S
      if (macBits & 0x0f00 != 0) st |= 4 | 0x100; // U
      if (macBits & 0xf000 != 0) st |= 8 | 0x200; // O
      status = st;
    }
    if (clipBits >= 0) clip = ((clip << 6) | clipBits) & 0xffffff;
  }

  /// Executes the upper instruction. The VF result, when there is one, is
  /// left in [_result] for destination [_upperReg] under mask [_upperMask]
  /// and the method returns true.
  bool _upper(int ir) {
    final mask = (ir >> 21) & 15;
    final ft = (ir >> 16) & 31, fs = (ir >> 11) & 31, fd = (ir >> 6) & 31;
    final op = ir & 63;
    _upperReg = fd;
    _upperMask = mask;
    int bsel; // 0..3 broadcast lane, 4 = Q, 5 = I, 6 = full vector
    int kind;
    var toAcc = false;
    if (op < 0x1c) {
      kind = const [0, 1, 2, 3, 4, 5, 6][op >> 2];
      bsel = op & 3;
    } else if (op < 0x28) {
      const table = [
        // kind, bsel for 0x1c..0x27
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
      _opmsub(fs, ft, fd);
      return true;
    } else {
      return _special(ir, mask, ft, fs, fd);
    }
    _fmac(kind, bsel, mask, fs, ft, toAcc: toAcc);
    return !toAcc;
  }

  // kind: 0 ADD, 1 SUB, 2 MADD, 3 MSUB, 4 MAX, 5 MINI, 6 MUL
  void _fmac(int kind, int bsel, int mask, int fs, int ft,
      {required bool toAcc}) {
    var macBits = 0;
    for (var c = 0; c < 4; c++) {
      final enabled = mask & (8 >> c) != 0;
      final a = _lane(fs, c);
      final bBits = switch (bsel) {
        4 => q,
        5 => i,
        6 => _lane(ft, c),
        _ => _lane(ft, bsel),
      };
      int out;
      switch (kind) {
        case 4:
          out = _d(a) >= _d(bBits) ? a : bBits;
        case 5:
          out = _d(a) <= _d(bBits) ? a : bBits;
        default:
          final x = _d(a), y = _d(bBits);
          final accValue = _d(acc[c]);
          final v = switch (kind) {
            0 => x + y,
            1 => x - y,
            2 => accValue + x * y,
            3 => accValue - x * y,
            _ => x * y,
          };
          out = _enc(v);
          if (enabled) macBits |= _macBits(c, out, _lastFlags);
      }
      _result[c] = out;
    }
    if (kind == 4 || kind == 5) return; // MAX and MINI set no flags
    _finish(macBits, mask, toAcc);
  }

  void _finish(int macBits, int mask, bool toAcc) {
    _upperMac = macBits;
    _flagsPending = true;
    if (toAcc) {
      for (var c = 0; c < 4; c++) {
        if (mask & (8 >> c) != 0) acc[c] = _result[c];
      }
    }
  }

  /// MAC flag bits of lane [c]: overflow 15..12, underflow 11..8, sign
  /// 7..4, zero 3..0, with x in the highest bit of each group
  int _macBits(int c, int bits, int flags) {
    var m = 0;
    final shift = 3 - c;
    if (bits & 0x7fffffff == 0) m |= 1 << shift;
    if (bits & 0x80000000 != 0) m |= 1 << (4 + shift);
    if (flags & R5900Fpu.flagUnderflow != 0) m |= 1 << (8 + shift);
    if (flags & R5900Fpu.flagOverflow != 0) m |= 1 << (12 + shift);
    return m;
  }

  void _opmsub(int fs, int ft, int fd) {
    // fd.x = ACC.x - fs.y * ft.z, fd.y = ACC.y - fs.z * ft.x,
    // fd.z = ACC.z - fs.x * ft.y; w is untouched
    final pairs = [(1, 2), (2, 0), (0, 1)];
    var macBits = 0;
    for (var c = 0; c < 3; c++) {
      final (a, b) = pairs[c];
      _result[c] = _enc(_d(acc[c]) - _d(_lane(fs, a)) * _d(_lane(ft, b)));
      macBits |= _macBits(c, _result[c], _lastFlags);
    }
    _upperMask = 14;
    _result[3] = vf[fd * 4 + 3];
    _finish(macBits, 14, false);
  }

  bool _special(int ir, int mask, int ft, int fs, int fd) {
    final sub = (ir >> 6) & 31, col = ir & 3;
    if (sub < 4) {
      // ADDA, SUBA, MADDA, MSUBA with a broadcast lane
      _fmac(sub, col, mask, fs, ft, toAcc: true);
      return false;
    }
    if (sub == 6) {
      _fmac(6, col, mask, fs, ft, toAcc: true);
      return false;
    }
    if (sub == 4 || sub == 5) {
      _upperReg = ft; // the destination of ITOF and FTOI is ft
      const shifts = [0, 4, 12, 15];
      final n = shifts[col];
      for (var c = 0; c < 4; c++) {
        if (sub == 4) {
          _result[c] = _enc(_lane(fs, c).toSigned(32) / (1 << n));
        } else {
          final v = (_d(_lane(fs, c)) * (1 << n)).truncateToDouble();
          _result[c] = v >= 2147483648.0
              ? 0x7fffffff
              : (v <= -2147483648.0 ? 0x80000000 : v.toInt() & 0xffffffff);
        }
      }
      _upperMask = mask;
      return true;
    }
    switch ((sub << 2) | col) {
      case const (7 << 2 | 0): // MULAq
        _fmac(6, 4, mask, fs, ft, toAcc: true);
      case const (7 << 2 | 1): // ABS
        _upperReg = ft;
        for (var c = 0; c < 4; c++) {
          _result[c] = _lane(fs, c) & 0x7fffffff;
        }
        return true;
      case const (7 << 2 | 2): // MULAi
        _fmac(6, 5, mask, fs, ft, toAcc: true);
      case const (7 << 2 | 3): // CLIP
        _clip(fs, ft);
      case const (8 << 2 | 0): // ADDAq
        _fmac(0, 4, mask, fs, ft, toAcc: true);
      case const (8 << 2 | 1): // MADDAq
        _fmac(2, 4, mask, fs, ft, toAcc: true);
      case const (8 << 2 | 2): // ADDAi
        _fmac(0, 5, mask, fs, ft, toAcc: true);
      case const (8 << 2 | 3): // MADDAi
        _fmac(2, 5, mask, fs, ft, toAcc: true);
      case const (9 << 2 | 0): // SUBAq
        _fmac(1, 4, mask, fs, ft, toAcc: true);
      case const (9 << 2 | 1): // MSUBAq
        _fmac(3, 4, mask, fs, ft, toAcc: true);
      case const (9 << 2 | 2): // SUBAi
        _fmac(1, 5, mask, fs, ft, toAcc: true);
      case const (9 << 2 | 3): // MSUBAi
        _fmac(3, 5, mask, fs, ft, toAcc: true);
      case const (10 << 2 | 0): // ADDA
        _fmac(0, 6, mask, fs, ft, toAcc: true);
      case const (10 << 2 | 1): // MADDA
        _fmac(2, 6, mask, fs, ft, toAcc: true);
      case const (10 << 2 | 2): // MULA
        _fmac(6, 6, mask, fs, ft, toAcc: true);
      case const (11 << 2 | 0): // SUBA
        _fmac(1, 6, mask, fs, ft, toAcc: true);
      case const (11 << 2 | 1): // MSUBA
        _fmac(3, 6, mask, fs, ft, toAcc: true);
      case const (11 << 2 | 2): // OPMULA
        _opmula(fs, ft);
      default:
        break; // NOP and unassigned codes
    }
    return false;
  }

  void _opmula(int fs, int ft) {
    final pairs = [(1, 2), (2, 0), (0, 1)];
    var macBits = 0;
    for (var c = 0; c < 3; c++) {
      final (a, b) = pairs[c];
      acc[c] = _enc(_d(_lane(fs, a)) * _d(_lane(ft, b)));
      macBits |= _macBits(c, acc[c], _lastFlags);
    }
    _finish(macBits, 14, false);
  }

  void _clip(int fs, int ft) {
    final w = _d(_lane(ft, 3)).abs();
    var bits = 0;
    for (var c = 0; c < 3; c++) {
      final v = _d(_lane(fs, c));
      if (v > w) bits |= 1 << (c * 2);
      if (v < -w) bits |= 2 << (c * 2);
    }
    _clipPending = bits;
  }

  // ---- lower instructions ----

  int _qAddress(int base, int offset) => (base + offset) & (dataQuads - 1);

  void _loadQuad(int reg, int mask, int addr) {
    if (reg == 0) return;
    _loweredVf(reg, mask);
    for (var c = 0; c < 4; c++) {
      if (mask & (8 >> c) != 0) vf[reg * 4 + c] = data[addr * 4 + c];
    }
  }

  void _storeQuad(int reg, int mask, int addr) {
    for (var c = 0; c < 4; c++) {
      if (mask & (8 >> c) != 0) data[addr * 4 + c] = vf[reg * 4 + c];
    }
  }

  /// the lane selected by a destination mask (x has priority)
  static int _maskLane(int mask) =>
      mask & 8 != 0 ? 0 : (mask & 4 != 0 ? 1 : (mask & 2 != 0 ? 2 : 3));

  void _lower(int ir) {
    final op = ir >>> 25;
    final mask = (ir >> 21) & 15;
    final it = (ir >> 16) & 31, is_ = (ir >> 11) & 15;
    final fsReg = (ir >> 11) & 31;
    final imm11 = (ir & 0x7ff).toSigned(11);
    final isv = vi[is_];
    switch (op) {
      case 0x00: // LQ
        _loadQuad(it, mask, _qAddress(vi[fsReg & 15], imm11));
      case 0x01: // SQ
        _storeQuad(fsReg, mask, _qAddress(vi[it & 15], imm11));
      case 0x04: // ILW
        vi[it & 15] =
            data[_qAddress(isv, imm11) * 4 + _maskLane(mask)] & 0xffff;
      case 0x05: // ISW
        final base = _qAddress(isv, imm11) * 4;
        for (var c = 0; c < 4; c++) {
          if (mask & (8 >> c) != 0) data[base + c] = vi[it & 15];
        }
      case 0x08: // IADDIU
        vi[it & 15] = isv + (((mask << 11) | (ir & 0x7ff)) & 0x7fff);
      case 0x09: // ISUBIU
        vi[it & 15] = isv - (((mask << 11) | (ir & 0x7ff)) & 0x7fff);
      case 0x10: // FCEQ
        vi[1] = (clip & 0xffffff) == (ir & 0xffffff) ? 1 : 0;
      case 0x11: // FCSET
        clip = ir & 0xffffff;
      case 0x12: // FCAND
        vi[1] = clip & ir & 0xffffff != 0 ? 1 : 0;
      case 0x13: // FCOR
        vi[1] = ((clip | ir) & 0xffffff) == 0xffffff ? 1 : 0;
      case 0x14: // FSEQ
        vi[it & 15] = (status & 0xfff) == _imm12(ir) ? 1 : 0;
      case 0x15: // FSSET
        status = (status & 0x3f) | (_imm12(ir) & 0xfc0);
      case 0x16: // FSAND
        vi[it & 15] = status & _imm12(ir);
      case 0x17: // FSOR
        vi[it & 15] = status | _imm12(ir);
      case 0x18: // FMEQ
        vi[it & 15] = mac == vi[is_] ? 1 : 0;
      case 0x1a: // FMAND
        vi[it & 15] = mac & vi[is_];
      case 0x1b: // FMOR
        vi[it & 15] = mac | vi[is_];
      case 0x1c: // FCGET
        vi[it & 15] = clip & 0xfff;
      case 0x20: // B
        _pending = _target(pc + 1 + imm11);
      case 0x21: // BAL
        vi[it & 15] = pc + 2;
        _pending = _target(pc + 1 + imm11);
      case 0x24: // JR
        _pending = _target(isv);
      case 0x25: // JALR
        vi[it & 15] = pc + 2;
        _pending = _target(isv);
      case 0x28:
        if (vi[it & 15] == isv) _pending = _target(pc + 1 + imm11);
      case 0x29:
        if (vi[it & 15] != isv) _pending = _target(pc + 1 + imm11);
      case 0x2c:
        if (isv.toSigned(16) < 0) _pending = _target(pc + 1 + imm11);
      case 0x2d:
        if (isv.toSigned(16) > 0) _pending = _target(pc + 1 + imm11);
      case 0x2e:
        if (isv.toSigned(16) <= 0) _pending = _target(pc + 1 + imm11);
      case 0x2f:
        if (isv.toSigned(16) >= 0) _pending = _target(pc + 1 + imm11);
      case 0x40:
        _lowerSpecial(ir, mask, it, fsReg);
    }
  }

  int _target(int pair) => pair & (microWords ~/ 2 - 1);

  int _imm12(int ir) => ((ir >> 10) & 0x800) | (ir & 0x7ff);

  void _lowerSpecial(int ir, int mask, int it, int fs) {
    final funct = ir & 0x3f;
    final id = (ir >> 6) & 15;
    final isIdx = fs & 15;
    switch (funct) {
      case 0x30:
        vi[id] = vi[isIdx] + vi[it & 15];
        return;
      case 0x31:
        vi[id] = vi[isIdx] - vi[it & 15];
        return;
      case 0x32:
        vi[it & 15] = vi[isIdx] + ((ir >> 6) & 31).toSigned(5);
        return;
      case 0x34:
        vi[id] = vi[isIdx] & vi[it & 15];
        return;
      case 0x35:
        vi[id] = vi[isIdx] | vi[it & 15];
        return;
    }
    if (funct < 0x3c) return;
    final sub = (ir >> 6) & 31;
    final col = funct & 3;
    final fsf = (ir >> 21) & 3, ftf = (ir >> 23) & 3;
    switch ((sub << 2) | col) {
      case const (0x0c << 2 | 0): // MOVE
        _loweredVf(it, mask);
        for (var c = 0; c < 4; c++) {
          if (mask & (8 >> c) != 0 && it != 0) vf[it * 4 + c] = vf[fs * 4 + c];
        }
      case const (0x0d << 2 | 0): // LQI
        _loadQuad(it, mask, vi[isIdx] & (dataQuads - 1));
        vi[isIdx] = vi[isIdx] + 1;
      case const (0x0e << 2 | 0): // DIV
        _div(_d(_lane(fs, fsf)), _d(_lane(it, ftf)));
      case const (0x0f << 2 | 0): // MTIR
        vi[it & 15] = _lane(fs, fsf) & 0xffff;
      case const (0x0c << 2 | 1): // MR32
        _loweredVf(it, mask);
        for (var c = 0; c < 4; c++) {
          if (mask & (8 >> c) != 0 && it != 0) {
            vf[it * 4 + c] = vf[fs * 4 + (c + 1) % 4];
          }
        }
      case const (0x0d << 2 | 1): // SQI
        _storeQuad(fs, mask, vi[it & 15] & (dataQuads - 1));
        vi[it & 15] = vi[it & 15] + 1;
      case const (0x0e << 2 | 1): // SQRT
        _sqrt(_d(_lane(it, ftf)));
      case const (0x0f << 2 | 1): // MFIR
        if (it != 0) {
          for (var c = 0; c < 4; c++) {
            if (mask & (8 >> c) != 0) {
              vf[it * 4 + c] = vi[isIdx].toSigned(16) & 0xffffffff;
            }
          }
        }
      case const (0x0d << 2 | 2): // LQD
        vi[isIdx] = vi[isIdx] - 1;
        _loadQuad(it, mask, vi[isIdx] & (dataQuads - 1));
      case const (0x0e << 2 | 2): // RSQRT
        _rsqrt(_d(_lane(fs, fsf)), _d(_lane(it, ftf)));
      case const (0x0f << 2 | 2): // ILWR
        vi[it & 15] =
            data[(vi[isIdx] & (dataQuads - 1)) * 4 + _maskLane(mask)] & 0xffff;
      case const (0x0d << 2 | 3): // SQD
        vi[it & 15] = vi[it & 15] - 1;
        _storeQuad(fs, mask, vi[it & 15] & (dataQuads - 1));
      case const (0x0e << 2 | 3): // WAITQ
        break; // [_stall] waited for Q
      case const (0x0f << 2 | 3): // ISWR
        final base = (vi[isIdx] & (dataQuads - 1)) * 4;
        for (var c = 0; c < 4; c++) {
          if (mask & (8 >> c) != 0) data[base + c] = vi[it & 15];
        }
      case const (0x10 << 2 | 0): // RNEXT
        _nextR();
        _writeScalarVf(it, mask, r);
      case const (0x10 << 2 | 1): // RGET
        _writeScalarVf(it, mask, r);
      case const (0x10 << 2 | 2): // RINIT
        r = 0x3f800000 | (_lane(fs, fsf) & 0x7fffff);
      case const (0x10 << 2 | 3): // RXOR
        r = 0x3f800000 | ((r ^ _lane(fs, fsf)) & 0x7fffff);
      case const (0x19 << 2 | 0): // MFP
        _writeScalarVf(it, mask, p);
      case const (0x1e << 2 | 3): // WAITP
        break; // [_stall] waited for P
      case >= 0x70: // sub-opcode 0x1c and above
        _efu((sub << 2) | col, fs, fsf);
      case const (0x1a << 2 | 0): // XTOP
        vi[it & 15] = top();
      case const (0x1a << 2 | 1): // XITOP
        vi[it & 15] = itop() & 0x3ff;
      case const (0x1b << 2 | 0): // XGKICK
        onXgkick?.call(vi[isIdx] & (dataQuads - 1));
    }
  }

  void _writeScalarVf(int reg, int mask, int value) {
    if (reg == 0) return;
    _loweredVf(reg, mask);
    for (var c = 0; c < 4; c++) {
      if (mask & (8 >> c) != 0) vf[reg * 4 + c] = value;
    }
  }

  void _nextR() {
    final bit = ((r >> 4) ^ (r >> 22)) & 1;
    r = 0x3f800000 | (((r << 1) | bit) & 0x7fffff);
  }

  // status bits: I = 0x10, D = 0x20
  void _div(double a, double b) {
    status &= ~0x30;
    if (b == 0.0) {
      status |= a == 0.0 ? 0x10 : 0x20;
      _setQ(R5900Fpu.encodeSign(a, b) | 0x7fffffff, 7);
      return;
    }
    _setQ(_enc(a / b), 7);
  }

  void _sqrt(double b) {
    status &= ~0x30;
    if (b < 0) status |= 0x10;
    _setQ(_enc(math.sqrt(b.abs())), 7);
  }

  void _rsqrt(double a, double b) {
    status &= ~0x30;
    if (b < 0) status |= 0x10;
    final root = math.sqrt(b.abs());
    if (root == 0.0) {
      status |= a == 0.0 ? 0x10 : 0x20;
      _setQ((a.isNegative ? 0x80000000 : 0) | 0x7fffffff, 13);
      return;
    }
    _setQ(_enc(a / root), 13);
  }
}
