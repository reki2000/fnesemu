import 'dart:math' as math;
import 'dart:typed_data';

import 'r5900.dart';

/// The EE floating point unit (COP1, single precision only).
///
/// Differences from IEEE 754 that the arithmetic follows: an exponent field
/// of 255 is an ordinary number, so there are no infinities or NaNs and the
/// largest magnitude is 0x7fffffff; denormal operands read as zero and
/// denormal results flush to zero; overflow clamps to the largest magnitude;
/// and results round toward zero.
///
/// Operations are evaluated in double precision and truncated to single.
/// Sums of operands more than 29 binary orders apart and the fused
/// accumulate forms are not guaranteed to match the hardware to the last bit.
/// FCR31 flag bits follow the layout of the EE Core User's Manual: C is bit
/// 23, the cause bits I, D, O, U are bits 17..14 and the sticky bits SI, SD,
/// SO, SU are bits 6..3.
extension R5900Fpu on R5900 {
  static const _maxMagnitude = 0x7fffffff;
  static const _flagI = 1 << 17, _flagD = 1 << 16;
  static const flagOverflow = 1 << 15, flagUnderflow = 1 << 14;
  static const _stickyI = 1 << 6, _stickyD = 1 << 5;
  static const _stickyO = 1 << 4, _stickyU = 1 << 3;
  static const _causeMask = _flagI | _flagD | flagOverflow | flagUnderflow;
  static const conditionBit = 1 << 23;

  static final _bits = ByteData(8);

  /// the value of a single precision register image
  static double decode(int bits) {
    final exp = (bits >>> 23) & 0xff;
    if (exp == 0) return 0.0;
    _bits.setInt64(
        0,
        ((bits & 0x80000000) << 32) |
            ((exp - 127 + 1023) << 52) |
            ((bits & 0x7fffff) << 29));
    return _bits.getFloat64(0);
  }

  /// Truncates [value] to a register image; [flags] receives the cause bits.
  static int encode(double value, List<int> flags) {
    if (value == 0.0) return value.isNegative ? 0x80000000 : 0;
    _bits.setFloat64(0, value);
    final raw = _bits.getInt64(0);
    final sign = raw < 0 ? 0x80000000 : 0;
    final exp = ((raw >>> 52) & 0x7ff) - 1023 + 127;
    if (exp <= 0) {
      flags[0] |= flagUnderflow;
      return sign;
    }
    if (exp >= 256) {
      flags[0] |= flagOverflow;
      return sign | _maxMagnitude;
    }
    return sign | (exp << 23) | ((raw >>> 29) & 0x7fffff);
  }

  /// the sign bit of a quotient of [a] and [b] for a division by zero
  static int encodeSign(double a, double b) =>
      a.isNegative != b.isNegative ? 0x80000000 : 0;

  static final _flags = <int>[0];

  int _fp(double value) {
    _flags[0] = 0;
    final r = encode(value, _flags);
    _raise(_flags[0]);
    return r;
  }

  void _raise(int cause) {
    if (cause == 0) return;
    var v = fcr31 | cause;
    if (cause & _flagI != 0) v |= _stickyI;
    if (cause & _flagD != 0) v |= _stickyD;
    if (cause & flagOverflow != 0) v |= _stickyO;
    if (cause & flagUnderflow != 0) v |= _stickyU;
    fcr31 = v;
  }

  /// Executes a COP1 instruction other than BC1. Returns false when the
  /// instruction is not implemented.
  bool executeCop1(int ir) {
    final fmt = (ir >>> 21) & 31, rt = (ir >>> 16) & 31;
    final fs = (ir >>> 11) & 31, ft = rt, fd = (ir >>> 6) & 31;
    switch (fmt) {
      case 0: // MFC1
        setReg(rt, fpr[fs].toSigned(32));
      case 2: // CFC1
        setReg(rt, fs == 31 ? fcr31 : (fs == 0 ? 0x2e00 : 0));
      case 4: // MTC1
        fpr[fs] = reg(rt);
      case 6: // CTC1
        if (fs == 31) fcr31 = reg(rt) & 0x0183ffff;
      case 16:
        return _single(ir & 63, fs, ft, fd);
      case 20: // W format
        if (ir & 63 != 0x20) return false;
        fpr[fd] = _fp(fpr[fs].toSigned(32).toDouble());
      default:
        return false;
    }
    return true;
  }

  /// Clears the cause bits before an arithmetic operation.
  void _begin() => fcr31 &= ~_causeMask;

  /// divide-style result: x / y with the EE's zero handling
  int _divide(double x, double y, int sign) {
    if (y == 0.0) {
      if (x == 0.0) {
        _raise(_flagI);
      } else {
        _raise(_flagD);
      }
      return sign | _maxMagnitude;
    }
    return _fp(x / y);
  }

  bool _single(int fn, int fs, int ft, int fd) {
    final a = decode(fpr[fs]), b = decode(fpr[ft]);
    switch (fn) {
      case 0x00:
        _begin();
        fpr[fd] = _fp(a + b);
      case 0x01:
        _begin();
        fpr[fd] = _fp(a - b);
      case 0x02:
        _begin();
        fpr[fd] = _fp(a * b);
      case 0x03:
        _begin();
        fpr[fd] = _divide(a, b, (fpr[fs] ^ fpr[ft]) & 0x80000000);
      case 0x04: // SQRT
        _begin();
        if (fpr[ft] & 0x80000000 != 0 && b != 0.0) _raise(_flagI);
        fpr[fd] = _fp(math.sqrt(b.abs()));
      case 0x05:
        _begin();
        fpr[fd] = fpr[fs] & 0x7fffffff;
      case 0x06:
        fpr[fd] = fpr[fs];
      case 0x07:
        _begin();
        fpr[fd] = fpr[fs] ^ 0x80000000;
      case 0x16: // RSQRT
        _begin();
        if (fpr[ft] & 0x80000000 != 0 && b != 0.0) _raise(_flagI);
        final root = math.sqrt(b.abs());
        fpr[fd] = _divide(a, root, fpr[fs] & 0x80000000);
      case 0x18:
        _begin();
        facc = _fp(a + b);
      case 0x19:
        _begin();
        facc = _fp(a - b);
      case 0x1a:
        _begin();
        facc = _fp(a * b);
      case 0x1c: // MADD
        _begin();
        fpr[fd] = _fp(decode(facc) + a * b);
      case 0x1d: // MSUB
        _begin();
        fpr[fd] = _fp(decode(facc) - a * b);
      case 0x1e: // MADDA
        _begin();
        facc = _fp(decode(facc) + a * b);
      case 0x1f: // MSUBA
        _begin();
        facc = _fp(decode(facc) - a * b);
      case 0x24: // CVT.W.S
        final t = a.truncateToDouble();
        fpr[fd] = t >= 2147483648.0
            ? 0x7fffffff
            : (t <= -2147483648.0 ? 0x80000000 : t.toInt());
      case 0x28:
        fpr[fd] = a >= b ? fpr[fs] : fpr[ft];
      case 0x29:
        fpr[fd] = a <= b ? fpr[fs] : fpr[ft];
      case 0x30: // C.F
        fcr31 &= ~conditionBit;
      case 0x32: // C.EQ
        _setCondition(a == b);
      case 0x34: // C.LT
        _setCondition(a < b);
      case 0x36: // C.LE
        _setCondition(a <= b);
      default:
        return false;
    }
    return true;
  }

  void _setCondition(bool c) =>
      fcr31 = c ? fcr31 | conditionBit : fcr31 & ~conditionBit;
}
