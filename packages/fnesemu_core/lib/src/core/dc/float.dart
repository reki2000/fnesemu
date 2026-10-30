/// The five IEEE exception bits use the order of FPSCR's flag field.
class DcFloatResult {
  const DcFloatResult(this.bits, this.flags, {this.normal = false});
  final BigInt bits;
  final int flags;
  final bool normal;
}

class _FloatValue {
  const _FloatValue(
      this.bits, this.sign, this.kind, this.significand, this.exponent);
  final BigInt bits, significand;
  final bool sign;
  // Zero, finite normal, denormal, infinity, quiet NaN, signaling NaN.
  final int kind, exponent;
}

/// Exact binary arithmetic using rational significands, independent of host FP.
/// SH-4 reverses the modern IEEE convention for the signaling-NaN fraction bit.
class DcFloat {
  const DcFloat(this.fractionBits, this.exponentBits);
  static const single = DcFloat(23, 8), doublePrecision = DcFloat(52, 11);
  static const inexact = 1, underflow = 2, overflow = 4, zeroDivide = 8;
  static const invalid = 16, error = 32;

  final int fractionBits, exponentBits;
  int get bias => (1 << (exponentBits - 1)) - 1;
  int get minExponent => 1 - bias;
  int get maxExponent => bias;
  BigInt get hidden => BigInt.one << fractionBits;
  BigInt get fractionMask => hidden - BigInt.one;
  BigInt get signMask => BigInt.one << (fractionBits + exponentBits);
  BigInt get infinity => BigInt.from((1 << exponentBits) - 1) << fractionBits;
  BigInt get quietNaN => infinity | ((hidden >> 1) - BigInt.one);
  BigInt signedZero(bool negative) => negative ? signMask : BigInt.zero;
  BigInt signedInfinity(bool negative) => infinity | signedZero(negative);

  _FloatValue _decode(BigInt bits, bool flush) {
    final sign = (bits & signMask) != BigInt.zero;
    final field =
        ((bits >> fractionBits) & BigInt.from((1 << exponentBits) - 1)).toInt();
    final fraction = bits & fractionMask;
    if (field == (1 << exponentBits) - 1) {
      final kind = fraction == BigInt.zero
          ? 3
          : ((fraction & (hidden >> 1)) == BigInt.zero ? 4 : 5);
      return _FloatValue(bits, sign, kind, fraction, 0);
    }
    if (field == 0) {
      final zero = fraction == BigInt.zero || flush;
      return _FloatValue(zero ? signedZero(sign) : bits, sign, zero ? 0 : 2,
          zero ? BigInt.zero : fraction, minExponent - fractionBits);
    }
    return _FloatValue(
        bits, sign, 1, hidden | fraction, field - bias - fractionBits);
  }

  DcFloatResult? _special(List<_FloatValue> values,
      {bool denormalError = true}) {
    if (values.any((v) => v.kind == 5)) return DcFloatResult(quietNaN, invalid);
    if (values.any((v) => v.kind == 4)) return DcFloatResult(quietNaN, 0);
    if (denormalError && values.any((v) => v.kind == 2)) {
      return DcFloatResult(BigInt.zero, error);
    }
    return null;
  }

  DcFloatResult binary(
      String operation, BigInt left, BigInt right, int control) {
    final flush = control & 0x40000 != 0;
    final a = _decode(left, flush), b = _decode(right, flush);
    final special = _special([a, b]);
    if (special != null) return special;
    final sign = a.sign != b.sign;
    if (operation == 'add' || operation == 'sub') {
      final bSign = b.sign != (operation == 'sub');
      if (a.kind == 3 || b.kind == 3) {
        if (a.kind == 3 && b.kind == 3 && a.sign != bSign) {
          return DcFloatResult(quietNaN, invalid);
        }
        return DcFloatResult(signedInfinity(a.kind == 3 ? a.sign : bSign), 0);
      }
      if (a.kind == 0 && b.kind == 0) {
        return DcFloatResult(signedZero(a.sign && bSign), 0);
      }
      final exponent = a.exponent < b.exponent ? a.exponent : b.exponent;
      final x = a.significand << (a.exponent - exponent);
      final y = b.significand << (b.exponent - exponent);
      final sum = (a.sign ? -x : x) + (bSign ? -y : y);
      return _round(sum.isNegative, sum.abs(), BigInt.one, exponent, control,
          normal: a.kind == 1 && b.kind == 1);
    }
    if (operation == 'mul') {
      if ((a.kind == 0 && b.kind == 3) || (a.kind == 3 && b.kind == 0)) {
        return DcFloatResult(quietNaN, invalid);
      }
      if (a.kind == 3 || b.kind == 3) {
        return DcFloatResult(signedInfinity(sign), 0);
      }
      if (a.kind == 0 || b.kind == 0) return DcFloatResult(signedZero(sign), 0);
      return _round(sign, a.significand * b.significand, BigInt.one,
          a.exponent + b.exponent, control);
    }
    if (operation != 'div') throw ArgumentError.value(operation);
    if ((a.kind == 0 && b.kind == 0) || (a.kind == 3 && b.kind == 3)) {
      return DcFloatResult(quietNaN, invalid);
    }
    if (a.kind == 3) return DcFloatResult(signedInfinity(sign), 0);
    if (b.kind == 3 || a.kind == 0) return DcFloatResult(signedZero(sign), 0);
    if (b.kind == 0) return DcFloatResult(signedInfinity(sign), zeroDivide);
    return _round(
        sign, a.significand, b.significand, a.exponent - b.exponent, control);
  }

  DcFloatResult _round(bool sign, BigInt numerator, BigInt denominator,
      int exponent, int control,
      {bool normal = true}) {
    if (numerator == BigInt.zero) {
      return DcFloatResult(signedZero(sign), 0, normal: normal);
    }
    var power = numerator.bitLength - denominator.bitLength;
    if (power >= 0
        ? numerator < denominator << power
        : numerator << -power < denominator) {
      power--;
    }
    power += exponent;
    var quantum = (power < minExponent ? minExponent : power) - fractionBits;
    final shift = exponent - quantum;
    final n = shift >= 0 ? numerator << shift : numerator;
    final d = shift >= 0 ? denominator : denominator << -shift;
    var mantissa = n ~/ d;
    final remainder = n % d;
    var flags = remainder == BigInt.zero ? 0 : inexact;
    if (control & 3 == 0 &&
        (remainder * BigInt.two > d ||
            (remainder * BigInt.two == d && mantissa.isOdd))) {
      mantissa += BigInt.one;
    }
    if (mantissa >= hidden << 1) {
      mantissa >>= 1;
      quantum++;
    }
    if (quantum + fractionBits > maxExponent) {
      return DcFloatResult(
          (control & 1 == 0 ? infinity : infinity - BigInt.one) |
              signedZero(sign),
          overflow | inexact,
          normal: normal);
    }
    if (mantissa < hidden) {
      if (control & 0x40000 != 0 && mantissa != BigInt.zero) {
        mantissa = BigInt.zero;
        flags |= inexact;
      }
      if (flags & inexact != 0) flags |= underflow;
      return DcFloatResult(mantissa | signedZero(sign), flags, normal: normal);
    }
    final field = quantum + fractionBits + bias;
    return DcFloatResult(
        (BigInt.from(field) << fractionBits) |
            (mantissa & fractionMask) |
            signedZero(sign),
        flags,
        normal: normal);
  }

  DcFloatResult fromInteger(int value, int control) =>
      _round(value < 0, BigInt.from(value).abs(), BigInt.one, 0, control);

  DcFloatResult convert(DcFloat source, BigInt bits, int control) {
    final v = source._decode(bits, control & 0x40000 != 0);
    if (v.kind >= 4) return DcFloatResult(quietNaN, v.kind == 5 ? invalid : 0);
    if (v.kind == 2) return DcFloatResult(BigInt.zero, error);
    if (v.kind == 3) return DcFloatResult(signedInfinity(v.sign), 0);
    return _round(v.sign, v.significand, BigInt.one, v.exponent, control);
  }

  DcFloatResult toInteger(BigInt bits, int control) {
    final v = _decode(bits, control & 0x40000 != 0);
    if (v.kind >= 3) {
      return DcFloatResult(
          BigInt.from(v.kind >= 4 || v.sign ? 0x80000000 : 0x7fffffff),
          invalid);
    }
    final magnitude = v.exponent >= 0
        ? v.significand << v.exponent
        : v.significand >> -v.exponent;
    final integer = v.sign ? -magnitude : magnitude;
    if (integer < BigInt.from(-0x80000000) ||
        integer > BigInt.from(0x7fffffff)) {
      return DcFloatResult(
          BigInt.from(v.sign ? 0x80000000 : 0x7fffffff), invalid);
    }
    return DcFloatResult(integer.toUnsigned(32), 0);
  }

  DcFloatResult compare(BigInt left, BigInt right, int control,
      {required bool greater}) {
    final a = _decode(left, control & 0x40000 != 0),
        b = _decode(right, control & 0x40000 != 0);
    if (a.kind >= 4 || b.kind >= 4) {
      return DcFloatResult(
          BigInt.zero, greater || a.kind == 5 || b.kind == 5 ? invalid : 0);
    }
    final az = a.kind == 0, bz = b.kind == 0;
    final equal = (az && bz) || a.bits == b.bits;
    var order = 0;
    if (!equal) {
      if (a.sign != b.sign) {
        order = a.sign ? -1 : 1;
      } else {
        order = (a.bits & ~signMask).compareTo(b.bits & ~signMask);
        if (a.sign) order = -order;
      }
    }
    return DcFloatResult(BigInt.from((greater ? order > 0 : equal) ? 1 : 0), 0);
  }

  DcFloatResult squareRoot(BigInt bits, int control) {
    final v = _decode(bits, control & 0x40000 != 0);
    if (v.kind >= 4) return DcFloatResult(quietNaN, v.kind == 5 ? invalid : 0);
    if (v.kind == 0) return DcFloatResult(v.bits, 0);
    if (v.sign) return DcFloatResult(quietNaN, invalid);
    if (v.kind == 2) return DcFloatResult(BigInt.zero, error);
    if (v.kind == 3) return DcFloatResult(v.bits, 0);
    final log = v.significand.bitLength - 1 + v.exponent;
    final rootPower = (log - (log & 1)) ~/ 2;
    final quantum = rootPower - fractionBits;
    final shift = v.exponent - 2 * quantum;
    final n = shift >= 0 ? v.significand << shift : v.significand;
    final d = shift >= 0 ? BigInt.one : BigInt.one << -shift;
    final integer = n ~/ d;
    var root = BigInt.one << ((integer.bitLength + 1) ~/ 2);
    while (true) {
      final next = (root + integer ~/ root) >> 1;
      if (next >= root) break;
      root = next;
    }
    final exact = root * root * d == n;
    final midpoint = (root * BigInt.two + BigInt.one).pow(2) * d;
    if (control & 3 == 0 &&
        (n * BigInt.from(4) > midpoint ||
            (n * BigInt.from(4) == midpoint && root.isOdd))) {
      root += BigInt.one;
    }
    final rounded = _round(false, root, BigInt.one, quantum, control);
    return DcFloatResult(rounded.bits, exact ? 0 : inexact, normal: true);
  }

  DcFloatResult multiplyAdd(
      BigInt left, BigInt right, BigInt addend, int control) {
    final flush = control & 0x40000 != 0;
    final a = _decode(left, flush),
        b = _decode(right, flush),
        c = _decode(addend, flush);
    if (a.kind == 5 || b.kind == 5 || c.kind == 5) {
      return DcFloatResult(quietNaN, invalid);
    }
    final special = _special([a, b]);
    if (special != null) return special;
    if ((a.kind == 0 && b.kind == 3) || (a.kind == 3 && b.kind == 0)) {
      return DcFloatResult(quietNaN, invalid);
    }
    final productSign = a.sign != b.sign;
    final addendSpecial = _special([c]);
    if (addendSpecial != null) return addendSpecial;
    if (a.kind == 3 || b.kind == 3) {
      return c.kind == 3 && c.sign != productSign
          ? DcFloatResult(quietNaN, invalid)
          : DcFloatResult(signedInfinity(productSign), 0);
    }
    if (c.kind == 3) return DcFloatResult(c.bits, 0);
    if (a.kind == 0 || b.kind == 0) {
      return DcFloatResult(
          c.kind == 0 ? signedZero(productSign != c.sign) : c.bits, 0);
    }
    final productExponent = a.exponent + b.exponent;
    final exponent =
        productExponent < c.exponent ? productExponent : c.exponent;
    final product =
        (a.significand * b.significand) << (productExponent - exponent);
    final addition = c.significand << (c.exponent - exponent);
    final sum =
        (productSign ? -product : product) + (c.sign ? -addition : addition);
    if (sum == BigInt.zero) {
      return DcFloatResult(signedZero(productSign && c.sign), 0,
          normal: a.kind == 1 && b.kind == 1);
    }
    return _round(sum.isNegative, sum.abs(), BigInt.one, exponent, control);
  }

  /// An exact dot product within the published approximation error bound.
  /// This does not reproduce the SH7091's intermediate truncation bits.
  DcFloatResult innerProduct(
      List<BigInt> left, List<BigInt> right, int control) {
    final a = left.map((v) => _decode(v, control & 0x40000 != 0)).toList();
    final b = right.map((v) => _decode(v, control & 0x40000 != 0)).toList();
    if ([...a, ...b].any((v) => v.kind == 5)) {
      return DcFloatResult(quietNaN, invalid);
    }
    for (var i = 0; i < 4; i++) {
      if ((a[i].kind == 0 && b[i].kind == 3) ||
          (a[i].kind == 3 && b[i].kind == 0)) {
        return DcFloatResult(quietNaN, invalid);
      }
    }
    if ([...a, ...b].any((v) => v.kind == 4)) return DcFloatResult(quietNaN, 0);
    bool? infinitySign;
    for (var i = 0; i < 4; i++) {
      if (a[i].kind == 3 || b[i].kind == 3) {
        final sign = a[i].sign != b[i].sign;
        if (infinitySign != null && infinitySign != sign) {
          return DcFloatResult(quietNaN, invalid);
        }
        infinitySign = sign;
      }
    }
    if (infinitySign != null) {
      return DcFloatResult(signedInfinity(infinitySign), 0);
    }
    var exponent = a[0].exponent + b[0].exponent;
    for (var i = 1; i < 4; i++) {
      final term = a[i].exponent + b[i].exponent;
      if (term < exponent) exponent = term;
    }
    var sum = BigInt.zero;
    var allNegativeZero = true;
    for (var i = 0; i < 4; i++) {
      final sign = a[i].sign != b[i].sign;
      final product = (a[i].significand * b[i].significand) <<
          (a[i].exponent + b[i].exponent - exponent);
      sum += sign ? -product : product;
      allNegativeZero &= sign && product == BigInt.zero;
    }
    final result = _round(
        sum.isNegative || (sum == BigInt.zero && allNegativeZero),
        sum.abs(),
        BigInt.one,
        exponent,
        control);
    return DcFloatResult(result.bits, result.flags | inexact, normal: true);
  }

  DcFloatResult reciprocalRoot(BigInt bits, int control) {
    final v = _decode(bits, control & 0x40000 != 0);
    if (v.kind >= 4) return DcFloatResult(quietNaN, v.kind == 5 ? invalid : 0);
    if (v.kind == 0) return DcFloatResult(signedInfinity(v.sign), zeroDivide);
    if (v.sign) return DcFloatResult(quietNaN, invalid);
    if (v.kind == 2) return DcFloatResult(BigInt.zero, error);
    if (v.kind == 3) return DcFloatResult(BigInt.zero, 0);
    final root = squareRoot(bits, control & ~3);
    final one = BigInt.from(bias) << fractionBits;
    final result = binary('div', one, root.bits, control & ~3);
    return DcFloatResult(result.bits, inexact, normal: true);
  }
}
