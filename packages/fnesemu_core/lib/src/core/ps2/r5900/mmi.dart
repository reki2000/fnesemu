import 'dart:typed_data';

import 'r5900.dart';

/// The multimedia instructions (opcode 28).
///
/// Lanes are read straight from the register file, so the host must be
/// little endian, as `Int64List` word `n` then holds bytes `8n..8n+7`.
///
/// HI and LO are 128 bits wide: [R5900.hi] and [R5900.lo] hold words 0-1
/// and [R5900.hi1] and [R5900.lo1] words 2-3. The halfword multiplies
/// PHMADH and PHMSBH leave words 1 and 3 of HI and LO unchanged, as does
/// PMTHL; the manual does not describe them.
extension R5900Mmi on R5900 {
  static final _out = ByteData(16);

  ByteData get _regs => ByteData.sublistView(gpr);

  int _lane(int reg, int width, int index, bool signed) {
    final offset = reg * 16 + index * width;
    final v = _regs;
    return switch (width) {
      1 => signed ? v.getInt8(offset) : v.getUint8(offset),
      2 => signed
          ? v.getInt16(offset, Endian.little)
          : v.getUint16(offset, Endian.little),
      _ => signed
          ? v.getInt32(offset, Endian.little)
          : v.getUint32(offset, Endian.little),
    };
  }

  void _setOut(int width, int index, int value) {
    switch (width) {
      case 1:
        _out.setUint8(index, value & 0xff);
      case 2:
        _out.setUint16(index * 2, value & 0xffff, Endian.little);
      default:
        _out.setUint32(index * 4, value & 0xffffffff, Endian.little);
    }
  }

  void _commit(int rd) {
    gpr[rd * 2] = _out.getInt64(0, Endian.little);
    gpr[rd * 2 + 1] = _out.getInt64(8, Endian.little);
  }

  /// rd lane i = f(rs lane i, rt lane i)
  void _map(int rs, int rt, int rd, int width, bool signed,
      int Function(int, int) f) {
    for (var i = 0; i < 16 ~/ width; i++) {
      _setOut(width, i,
          f(_lane(rs, width, i, signed), _lane(rt, width, i, signed)));
    }
    _commit(rd);
  }

  /// rd lane i = f(rt lane i, amount)
  void _shift(int rt, int rd, int width, bool signed, int amount,
      int Function(int, int) f) {
    for (var i = 0; i < 16 ~/ width; i++) {
      _setOut(width, i, f(_lane(rt, width, i, signed), amount));
    }
    _commit(rd);
  }

  static int _clamp(int v, int min, int max) =>
      v < min ? min : (v > max ? max : v);

  void _set128(int rd, int low, int high) {
    gpr[rd * 2] = low;
    gpr[rd * 2 + 1] = high;
  }

  /// interleave: rd lane 2i = rt lane (base + i), rd lane 2i + 1 = rs lane (base + i)
  void _interleave(int rs, int rt, int rd, int width, int base) {
    final count = 8 ~/ width;
    for (var i = 0; i < count; i++) {
      _setOut(width, 2 * i, _lane(rt, width, base + i, false));
      _setOut(width, 2 * i + 1, _lane(rs, width, base + i, false));
    }
    _commit(rd);
  }

  /// rd takes the even lanes of rt, then the even lanes of rs
  void _pack(int rs, int rt, int rd, int width) {
    final count = 8 ~/ width;
    for (var i = 0; i < count; i++) {
      _setOut(width, i, _lane(rt, width, 2 * i, false));
      _setOut(width, count + i, _lane(rs, width, 2 * i, false));
    }
    _commit(rd);
  }

  /// rd = rt with its lanes taken in the order given by [order]
  void _reorder(int rt, int rd, int width, List<int> order) {
    for (var i = 0; i < order.length; i++) {
      _setOut(width, i, _lane(rt, width, order[i], false));
    }
    _commit(rd);
  }

  bool executeMmi(int ir, int at) {
    final rs = (ir >>> 21) & 31, rt = (ir >>> 16) & 31, rd = (ir >>> 11) & 31;
    final sa = (ir >>> 6) & 31;
    switch (ir & 63) {
      case 0x00:
        _madd(rs, rt, rd, true, false);
      case 0x01:
        _madd(rs, rt, rd, false, false);
      case 0x04: // PLZCW
        final w0 = _lane(rs, 4, 0, true), w1 = _lane(rs, 4, 1, true);
        setReg(rd, (_leadingSigns(w1) << 32) | _leadingSigns(w0));
      case 0x08:
        return _mmi0(sa, rs, rt, rd);
      case 0x09:
        return _mmi2(sa, rs, rt, rd);
      case 0x10:
        setReg(rd, hi1);
      case 0x11:
        hi1 = reg(rs);
      case 0x12:
        setReg(rd, lo1);
      case 0x13:
        lo1 = reg(rs);
      case 0x18:
        _mult1(rs, rt, rd, true);
      case 0x19:
        _mult1(rs, rt, rd, false);
      case 0x1a:
        _div1(reg(rs), reg(rt), true);
      case 0x1b:
        _div1(reg(rs), reg(rt), false);
      case 0x20:
        _madd(rs, rt, rd, true, true);
      case 0x21:
        _madd(rs, rt, rd, false, true);
      case 0x28:
        return _mmi1(sa, rs, rt, rd);
      case 0x29:
        return _mmi3(sa, rs, rt, rd);
      case 0x30:
        return _pmfhl(sa, rd);
      case 0x31:
        if (sa != 0) return false;
        // PMTHL.LW
        _setHiLo(_lane(rs, 4, 0, true), _lane(rs, 4, 1, true),
            _lane(rs, 4, 2, true), _lane(rs, 4, 3, true),
            keepOdd: true);
      case 0x34:
        _shift(rt, rd, 2, false, sa & 15, (v, n) => v << n);
      case 0x36:
        _shift(rt, rd, 2, false, sa & 15, (v, n) => v >>> n);
      case 0x37:
        _shift(rt, rd, 2, true, sa & 15, (v, n) => v >> n);
      case 0x3c:
        _shift(rt, rd, 4, false, sa, (v, n) => v << n);
      case 0x3e:
        _shift(rt, rd, 4, false, sa, (v, n) => v >>> n);
      case 0x3f:
        _shift(rt, rd, 4, true, sa, (v, n) => v >> n);
      default:
        return false;
    }
    return true;
  }

  /// number of bits after the sign bit that equal it
  int _leadingSigns(int w) {
    var v = (w < 0 ? ~w : w) & 0x7fffffff;
    var n = 0;
    for (var bit = 30; bit >= 0 && (v >> bit) & 1 == 0; bit--) {
      n++;
    }
    return n;
  }

  void _madd(int rs, int rt, int rd, bool signed, bool pipe1) {
    final a = signed ? reg(rs).toSigned(32) : reg(rs) & 0xffffffff;
    final b = signed ? reg(rt).toSigned(32) : reg(rt) & 0xffffffff;
    final h = pipe1 ? hi1 : hi, l = pipe1 ? lo1 : lo;
    final acc = (h << 32) | (l & 0xffffffff);
    final r = acc + a * b;
    final nl = r.toSigned(32), nh = (r >> 32).toSigned(32);
    if (pipe1) {
      lo1 = nl;
      hi1 = nh;
    } else {
      lo = nl;
      hi = nh;
    }
    setReg(rd, nl);
  }

  void _mult1(int rs, int rt, int rd, bool signed) {
    final a = signed ? reg(rs).toSigned(32) : reg(rs) & 0xffffffff;
    final b = signed ? reg(rt).toSigned(32) : reg(rt) & 0xffffffff;
    final p = a * b;
    lo1 = p.toSigned(32);
    hi1 = (p >> 32).toSigned(32);
    setReg(rd, lo1);
  }

  void _div1(int a, int b, bool signed) {
    if (signed) {
      final n = a.toSigned(32), d = b.toSigned(32);
      if (d == 0) {
        lo1 = n < 0 ? 1 : -1;
        hi1 = n;
      } else if (n == -0x80000000 && d == -1) {
        lo1 = n;
        hi1 = 0;
      } else {
        lo1 = n ~/ d;
        hi1 = n.remainder(d);
      }
    } else {
      final n = a & 0xffffffff, d = b & 0xffffffff;
      if (d == 0) {
        lo1 = -1;
        hi1 = n.toSigned(32);
      } else {
        lo1 = (n ~/ d).toSigned(32);
        hi1 = (n % d).toSigned(32);
      }
    }
  }

  bool _pmfhl(int variant, int rd) {
    switch (variant) {
      case 0: // LW
        _set128(rd, (hi.toSigned(32) << 32) | (lo & 0xffffffff),
            (hi1.toSigned(32) << 32) | (lo1 & 0xffffffff));
      case 1: // UW
        _set128(rd, ((hi >> 32) << 32) | ((lo >> 32) & 0xffffffff),
            ((hi1 >> 32) << 32) | ((lo1 >> 32) & 0xffffffff));
      case 2: // SLW
        int saturate(int h, int l) {
          final acc = (h << 32) | (l & 0xffffffff);
          return _clamp(acc, -0x80000000, 0x7fffffff);
        }
        _set128(rd, saturate(hi, lo), saturate(hi1, lo1));
      case 3: // LH
        _set128(
            rd,
            lo & 0xffff |
                (lo >> 32 & 0xffff) << 16 |
                (hi & 0xffff) << 32 |
                (hi >> 32 & 0xffff) << 48,
            lo1 & 0xffff |
                (lo1 >> 32 & 0xffff) << 16 |
                (hi1 & 0xffff) << 32 |
                (hi1 >> 32 & 0xffff) << 48);
      case 4: // SH
        int sat(int v) => _clamp(v.toSigned(32), -0x8000, 0x7fff) & 0xffff;
        _set128(
            rd,
            sat(lo) | sat(lo >> 32) << 16 | sat(hi) << 32 | sat(hi >> 32) << 48,
            sat(lo1) |
                sat(lo1 >> 32) << 16 |
                sat(hi1) << 32 |
                sat(hi1 >> 32) << 48);
      default:
        return false;
    }
    return true;
  }

  int _word(int v, int i) => (i == 0 ? v : v >> 32).toSigned(32);

  /// sets words 0 and 2 of LO and HI to [lo0], [hi0], [lo2] and [hi2].
  /// Words 1 and 3 become [lo1w], [hi1w], [lo3w] and [hi3w] unless
  /// [keepOdd] is set.
  void _setHiLo(int lo0, int hi0, int lo2, int hi2,
      {int lo1w = 0,
      int hi1w = 0,
      int lo3w = 0,
      int hi3w = 0,
      bool keepOdd = false}) {
    int pair(int even, int odd, int old) =>
        (keepOdd ? old >> 32 : odd) << 32 | (even & 0xffffffff);
    lo = pair(lo0, lo1w, lo);
    hi = pair(hi0, hi1w, hi);
    lo1 = pair(lo2, lo3w, lo1);
    hi1 = pair(hi2, hi3w, hi1);
  }

  /// PMULTH ([sign] 0), PMADDH (1) and PMSUBH (-1). Products 0-7 of the
  /// signed halfwords go to LO0, LO1, HI0, HI1, LO2, LO3, HI2 and HI3, and
  /// rd takes LO0, HI0, LO2 and HI2.
  void _halfMultiply(int rs, int rt, int rd, int sign) {
    final old = [
      _word(lo, 0), _word(lo, 1), _word(hi, 0), _word(hi, 1), //
      _word(lo1, 0), _word(lo1, 1), _word(hi1, 0), _word(hi1, 1),
    ];
    final r = List<int>.generate(8, (i) {
      final p = _lane(rs, 2, i, true) * _lane(rt, 2, i, true);
      return (sign == 0 ? p : old[i] + sign * p).toSigned(32);
    });
    _setHiLo(r[0], r[2], r[4], r[6],
        lo1w: r[1], hi1w: r[3], lo3w: r[5], hi3w: r[7]);
    for (var i = 0; i < 4; i++) {
      _setOut(4, i, r[2 * i]);
    }
    _commit(rd);
  }

  /// PHMADH ([sign] 1) and PHMSBH (-1): word i of rd, and LO0, HI0, LO2 and
  /// HI2 in turn, are product 2i + 1 plus or minus product 2i
  void _halfPairs(int rs, int rt, int rd, int sign) {
    int p(int i) => _lane(rs, 2, i, true) * _lane(rt, 2, i, true);
    final r = [
      for (var i = 0; i < 4; i++) (p(2 * i + 1) + sign * p(2 * i)).toSigned(32)
    ];
    _setHiLo(r[0], r[1], r[2], r[3], keepOdd: true);
    for (var i = 0; i < 4; i++) {
      _setOut(4, i, r[i]);
    }
    _commit(rd);
  }

  /// PDIVBW: the four words of rs divided by halfword 0 of rt. Quotients go
  /// to LO0-LO3 and remainders to HI0-HI3.
  void _pdivbw(int rs, int rt) {
    final d = _lane(rt, 2, 0, true);
    final q = <int>[], r = <int>[];
    for (var i = 0; i < 4; i++) {
      final n = _lane(rs, 4, i, true);
      if (d == 0) {
        q.add(n < 0 ? 1 : -1);
        r.add(n);
      } else if (n == -0x80000000 && d == -1) {
        q.add(n);
        r.add(0);
      } else {
        q.add((n ~/ d).toSigned(32));
        r.add(n.remainder(d).toSigned(32));
      }
    }
    _setHiLo(q[0], r[0], q[2], r[2],
        lo1w: q[1], hi1w: r[1], lo3w: q[3], hi3w: r[3]);
  }

  bool _mmi0(int sa, int rs, int rt, int rd) {
    switch (sa) {
      case 0x00:
        _map(rs, rt, rd, 4, false, (a, b) => a + b);
      case 0x01:
        _map(rs, rt, rd, 4, false, (a, b) => a - b);
      case 0x02:
        _map(rs, rt, rd, 4, true, (a, b) => a > b ? -1 : 0);
      case 0x03:
        _map(rs, rt, rd, 4, true, (a, b) => a > b ? a : b);
      case 0x04:
        _map(rs, rt, rd, 2, false, (a, b) => a + b);
      case 0x05:
        _map(rs, rt, rd, 2, false, (a, b) => a - b);
      case 0x06:
        _map(rs, rt, rd, 2, true, (a, b) => a > b ? -1 : 0);
      case 0x07:
        _map(rs, rt, rd, 2, true, (a, b) => a > b ? a : b);
      case 0x08:
        _map(rs, rt, rd, 1, false, (a, b) => a + b);
      case 0x09:
        _map(rs, rt, rd, 1, false, (a, b) => a - b);
      case 0x0a:
        _map(rs, rt, rd, 1, true, (a, b) => a > b ? -1 : 0);
      case 0x10:
        _map(rs, rt, rd, 4, true,
            (a, b) => _clamp(a + b, -0x80000000, 0x7fffffff));
      case 0x11:
        _map(rs, rt, rd, 4, true,
            (a, b) => _clamp(a - b, -0x80000000, 0x7fffffff));
      case 0x12:
        _interleave(rs, rt, rd, 4, 0);
      case 0x13:
        _pack(rs, rt, rd, 4);
      case 0x14:
        _map(rs, rt, rd, 2, true, (a, b) => _clamp(a + b, -0x8000, 0x7fff));
      case 0x15:
        _map(rs, rt, rd, 2, true, (a, b) => _clamp(a - b, -0x8000, 0x7fff));
      case 0x16:
        _interleave(rs, rt, rd, 2, 0);
      case 0x17:
        _pack(rs, rt, rd, 2);
      case 0x18:
        _map(rs, rt, rd, 1, true, (a, b) => _clamp(a + b, -0x80, 0x7f));
      case 0x19:
        _map(rs, rt, rd, 1, true, (a, b) => _clamp(a - b, -0x80, 0x7f));
      case 0x1a:
        _interleave(rs, rt, rd, 1, 0);
      case 0x1b:
        _pack(rs, rt, rd, 1);
      case 0x1e: // PEXT5
        for (var i = 0; i < 4; i++) {
          final v = _lane(rt, 4, i, false);
          _setOut(
              4,
              i,
              (v & 0x1f) << 3 |
                  (v >> 5 & 0x1f) << 11 |
                  (v >> 10 & 0x1f) << 19 |
                  (v >> 15 & 1) << 31);
        }
        _commit(rd);
      case 0x1f: // PPAC5
        for (var i = 0; i < 4; i++) {
          final v = _lane(rt, 4, i, false);
          _setOut(
              4,
              i,
              v >> 3 & 0x1f |
                  (v >> 11 & 0x1f) << 5 |
                  (v >> 19 & 0x1f) << 10 |
                  (v >> 31 & 1) << 15);
        }
        _commit(rd);
      default:
        return false;
    }
    return true;
  }

  bool _mmi1(int sa, int rs, int rt, int rd) {
    switch (sa) {
      case 0x01:
        _shift(rt, rd, 4, true, 0,
            (v, _) => v == -0x80000000 ? 0x7fffffff : v.abs());
      case 0x02:
        _map(rs, rt, rd, 4, false, (a, b) => a == b ? -1 : 0);
      case 0x03:
        _map(rs, rt, rd, 4, true, (a, b) => a < b ? a : b);
      case 0x04: // PADSBH
        for (var i = 0; i < 8; i++) {
          final a = _lane(rs, 2, i, false), b = _lane(rt, 2, i, false);
          _setOut(2, i, i < 4 ? a - b : a + b);
        }
        _commit(rd);
      case 0x05:
        _shift(rt, rd, 2, true, 0, (v, _) => v == -0x8000 ? 0x7fff : v.abs());
      case 0x06:
        _map(rs, rt, rd, 2, false, (a, b) => a == b ? -1 : 0);
      case 0x07:
        _map(rs, rt, rd, 2, true, (a, b) => a < b ? a : b);
      case 0x0a:
        _map(rs, rt, rd, 1, false, (a, b) => a == b ? -1 : 0);
      case 0x10:
        _map(rs, rt, rd, 4, false, (a, b) => _clamp(a + b, 0, 0xffffffff));
      case 0x11:
        _map(rs, rt, rd, 4, false, (a, b) => _clamp(a - b, 0, 0xffffffff));
      case 0x12:
        _interleave(rs, rt, rd, 4, 2);
      case 0x14:
        _map(rs, rt, rd, 2, false, (a, b) => _clamp(a + b, 0, 0xffff));
      case 0x15:
        _map(rs, rt, rd, 2, false, (a, b) => _clamp(a - b, 0, 0xffff));
      case 0x16:
        _interleave(rs, rt, rd, 2, 4);
      case 0x18:
        _map(rs, rt, rd, 1, false, (a, b) => _clamp(a + b, 0, 0xff));
      case 0x19:
        _map(rs, rt, rd, 1, false, (a, b) => _clamp(a - b, 0, 0xff));
      case 0x1a:
        _interleave(rs, rt, rd, 1, 8);
      case 0x1b: // QFSRV: rs:rt shifted right by the SA bytes
        final bytes = Uint8List(32);
        final view = ByteData.sublistView(bytes)
          ..setInt64(0, gpr[rt * 2], Endian.little)
          ..setInt64(8, gpr[rt * 2 + 1], Endian.little)
          ..setInt64(16, gpr[rs * 2], Endian.little)
          ..setInt64(24, gpr[rs * 2 + 1], Endian.little);
        final shift = this.sa & 15;
        _set128(rd, view.getInt64(shift, Endian.little),
            view.getInt64(shift + 8, Endian.little));
      default:
        return false;
    }
    return true;
  }

  bool _mmi2(int sa, int rs, int rt, int rd) {
    switch (sa) {
      case 0x00:
        _pmadd(rs, rt, rd, true, 1);
      case 0x02: // PSLLVW
        _variableShift(rs, rt, rd, (v, n) => v << n);
      case 0x03: // PSRLVW
        _variableShift(rs, rt, rd, (v, n) => (v & 0xffffffff) >>> n);
      case 0x04:
        _pmadd(rs, rt, rd, true, -1);
      case 0x08: // PMFHI
        _set128(rd, hi, hi1);
      case 0x09: // PMFLO
        _set128(rd, lo, lo1);
      case 0x0a: // PINTH
        for (var i = 0; i < 4; i++) {
          _setOut(2, 2 * i, _lane(rt, 2, i, false));
          _setOut(2, 2 * i + 1, _lane(rs, 2, 4 + i, false));
        }
        _commit(rd);
      case 0x0c:
        _pmult(rs, rt, rd, true);
      case 0x0d:
        _pdiv(rs, rt, true);
      case 0x0e: // PCPYLD
        _set128(rd, reg(rt), reg(rs));
      case 0x10: // PMADDH
        _halfMultiply(rs, rt, rd, 1);
      case 0x11: // PHMADH
        _halfPairs(rs, rt, rd, 1);
      case 0x14: // PMSUBH
        _halfMultiply(rs, rt, rd, -1);
      case 0x15: // PHMSBH
        _halfPairs(rs, rt, rd, -1);
      case 0x1c: // PMULTH
        _halfMultiply(rs, rt, rd, 0);
      case 0x1d: // PDIVBW
        _pdivbw(rs, rt);
      case 0x12:
        _set128(rd, reg(rs) & reg(rt), gpr[rs * 2 + 1] & gpr[rt * 2 + 1]);
      case 0x13:
        _set128(rd, reg(rs) ^ reg(rt), gpr[rs * 2 + 1] ^ gpr[rt * 2 + 1]);
      case 0x1a: // PEXEH
        _reorder(rt, rd, 2, const [2, 1, 0, 3, 6, 5, 4, 7]);
      case 0x1b: // PREVH
        _reorder(rt, rd, 2, const [3, 2, 1, 0, 7, 6, 5, 4]);
      case 0x1e: // PEXEW
        _reorder(rt, rd, 4, const [2, 1, 0, 3]);
      case 0x1f: // PROT3W
        _reorder(rt, rd, 4, const [1, 2, 0, 3]);
      default:
        return false;
    }
    return true;
  }

  bool _mmi3(int sa, int rs, int rt, int rd) {
    switch (sa) {
      case 0x00:
        _pmadd(rs, rt, rd, false, 1);
      case 0x03: // PSRAVW
        _variableShift(rs, rt, rd, (v, n) => v.toSigned(32) >> n);
      case 0x08: // PMTHI
        hi = reg(rs);
        hi1 = gpr[rs * 2 + 1];
      case 0x09: // PMTLO
        lo = reg(rs);
        lo1 = gpr[rs * 2 + 1];
      case 0x0a: // PINTEH
        for (var i = 0; i < 4; i++) {
          _setOut(2, 2 * i, _lane(rt, 2, 2 * i, false));
          _setOut(2, 2 * i + 1, _lane(rs, 2, 2 * i, false));
        }
        _commit(rd);
      case 0x0c:
        _pmult(rs, rt, rd, false);
      case 0x0d:
        _pdiv(rs, rt, false);
      case 0x0e: // PCPYUD
        _set128(rd, gpr[rs * 2 + 1], gpr[rt * 2 + 1]);
      case 0x12:
        _set128(rd, reg(rs) | reg(rt), gpr[rs * 2 + 1] | gpr[rt * 2 + 1]);
      case 0x13:
        _set128(rd, ~(reg(rs) | reg(rt)), ~(gpr[rs * 2 + 1] | gpr[rt * 2 + 1]));
      case 0x1a: // PEXCH
        _reorder(rt, rd, 2, const [0, 2, 1, 3, 4, 6, 5, 7]);
      case 0x1b: // PCPYH
        _reorder(rt, rd, 2, const [0, 0, 0, 0, 4, 4, 4, 4]);
      case 0x1e: // PEXCW
        _reorder(rt, rd, 4, const [0, 2, 1, 3]);
      default:
        return false;
    }
    return true;
  }

  /// rd double word i = f(rt word 2i, rs word 2i), as a sign extended word
  void _variableShift(int rs, int rt, int rd, int Function(int, int) f) {
    int one(int i) =>
        f(_lane(rt, 4, 2 * i, true), _lane(rs, 4, 2 * i, false) & 31)
            .toSigned(32);
    _set128(rd, one(0), one(1));
  }

  /// the two products of PMULTW / PMULTUW also fill HI, LO, HI1 and LO1
  void _pmult(int rs, int rt, int rd, bool signed) {
    final p0 = _product(rs, rt, 0, signed), p1 = _product(rs, rt, 1, signed);
    lo = p0.toSigned(32);
    hi = (p0 >> 32).toSigned(32);
    lo1 = p1.toSigned(32);
    hi1 = (p1 >> 32).toSigned(32);
    _set128(rd, p0, p1);
  }

  int _product(int rs, int rt, int i, bool signed) => signed
      ? _lane(rs, 4, 2 * i, true) * _lane(rt, 4, 2 * i, true)
      : _lane(rs, 4, 2 * i, false) * _lane(rt, 4, 2 * i, false);

  /// PMADDW / PMADDUW ([sign] 1) and PMSUBW ([sign] -1)
  void _pmadd(int rs, int rt, int rd, bool signed, int sign) {
    final a0 =
        ((hi << 32) | (lo & 0xffffffff)) + sign * _product(rs, rt, 0, signed);
    final a1 =
        ((hi1 << 32) | (lo1 & 0xffffffff)) + sign * _product(rs, rt, 1, signed);
    lo = a0.toSigned(32);
    hi = (a0 >> 32).toSigned(32);
    lo1 = a1.toSigned(32);
    hi1 = (a1 >> 32).toSigned(32);
    _set128(rd, a0, a1);
  }

  void _pdiv(int rs, int rt, bool signed) {
    (int, int) divide(int i) {
      if (signed) {
        final n = _lane(rs, 4, 2 * i, true), d = _lane(rt, 4, 2 * i, true);
        if (d == 0) return (n < 0 ? 1 : -1, n);
        if (n == -0x80000000 && d == -1) return (n, 0);
        return (n ~/ d, n.remainder(d));
      }
      final n = _lane(rs, 4, 2 * i, false), d = _lane(rt, 4, 2 * i, false);
      if (d == 0) return (-1, n.toSigned(32));
      return ((n ~/ d).toSigned(32), (n % d).toSigned(32));
    }

    final (q0, r0) = divide(0);
    final (q1, r1) = divide(1);
    lo = q0;
    hi = r0;
    lo1 = q1;
    hi1 = r1;
  }
}
