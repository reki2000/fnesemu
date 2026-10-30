part of 'sh4.dart';

extension _Sh4Fpu on Sh4 {
  static final _single = Float32List(1);
  static final _singleBits = Uint32List.view(_single.buffer);

  static double _toSingle(int bits) {
    _singleBits[0] = bits;
    return _single[0];
  }

  static bool _normalSingle(int bits) {
    final field = (bits >> 23) & 255;
    return field != 0 && field != 255;
  }

  /// Rounds `value + error`, an exactly known result, to single precision
  /// with the FPSCR rounding mode. Nearest rounding of a double is exact
  /// for one add, sub, mul or div of singles; round-to-zero steps one unit back
  /// when that overshoots the magnitude. Returns -1 when the result is not
  /// normal or nearest rounding would round twice.
  int _roundSingle(double value, double error, bool overshoot) {
    _single[0] = value;
    var bits = _singleBits[0];
    if (!_normalSingle(bits)) return -1;
    final rounded = _single[0];
    final inexact = error != 0 || overshoot || rounded != value;
    if (fpscr & 1 != 0) {
      final beyond = overshoot ||
          (value > 0
              ? rounded > value || (rounded == value && error < 0)
              : rounded < value || (rounded == value && error > 0));
      if (beyond) {
        bits--;
        if (!_normalSingle(bits)) return -1;
      }
    } else if (error != 0) {
      return -1;
    }
    _setFloatFlags(inexact ? DcFloat.inexact : 0);
    return bits;
  }

  void _setFloatFlags(int flags) {
    _fpscr = ((fpscr & ~0x3f000) | (flags << 12) | (flags << 2)) & 0x003fffff;
  }

  /// FIPR/FTRV row: the exact sum of four single products, rounded once.
  /// Sums in a 64-bit integer when the product exponents are close; returns -1
  /// for special operands, a wide exponent spread or a non-normal result.
  int _fastInnerProduct(int base, List<int> right, int start, int stride) {
    var minimum = 1 << 30, maximum = -(1 << 30);
    var allNegativeZero = true, nonzero = false;
    for (var i = 0; i < 4; i++) {
      final a = fr[base + i], b = right[start + i * stride];
      final fa = (a >> 23) & 255, fb = (b >> 23) & 255;
      if (fa == 255 || fb == 255) return -1;
      final zero =
          (fa == 0 && a & 0x7fffff == 0) || (fb == 0 && b & 0x7fffff == 0);
      if (!zero && (fa == 0 || fb == 0)) return -1;
      allNegativeZero &= (a ^ b) & 0x80000000 != 0 && zero;
      if (zero) continue;
      nonzero = true;
      final exponent = fa + fb;
      if (exponent < minimum) minimum = exponent;
      if (exponent > maximum) maximum = exponent;
    }
    if (!nonzero) return allNegativeZero ? 0x80000000 : 0;
    // 48-bit products, a 12-bit alignment and two carry bits fit in 62 bits.
    if (maximum - minimum > 12) return -1;
    var sum = 0;
    for (var i = 0; i < 4; i++) {
      final a = fr[base + i], b = right[start + i * stride];
      final fa = (a >> 23) & 255, fb = (b >> 23) & 255;
      if (fa == 0 || fb == 0) continue;
      final product = ((a & 0x7fffff) | 0x800000) * ((b & 0x7fffff) | 0x800000);
      final term = product << (fa + fb - minimum);
      sum += (a ^ b) & 0x80000000 != 0 ? -term : term;
    }
    if (sum == 0) return 0;
    final negative = sum < 0, magnitude = negative ? -sum : sum;
    // value = magnitude * 2^(minimum - 254 - 46).
    final length = magnitude.bitLength;
    var field = length - 1 + minimum - 300 + 127;
    if (field < 1 || field > 254) return -1;
    final shift = length - 24;
    var mantissa = shift > 0 ? magnitude >> shift : magnitude << -shift;
    if (shift > 0 && fpscr & 1 == 0) {
      final remainder = magnitude & ((1 << shift) - 1), half = 1 << (shift - 1);
      if (remainder > half || (remainder == half && mantissa.isOdd)) {
        mantissa++;
        if (mantissa == 0x1000000) {
          mantissa >>= 1;
          if (++field > 254) return -1;
        }
      }
    }
    return (negative ? 0x80000000 : 0) | (field << 23) | (mantissa & 0x7fffff);
  }

  /// Fast single-precision arithmetic for normal operands while no FPU
  /// exception is enabled. Returns false when the exact path must decide.
  bool _fastSingle(int low, int n, int m) {
    if (fpscr & 0x80f82 != 0) return false;
    final a = fr[n], b = fr[m];
    if (!_normalSingle(a) || !_normalSingle(b)) return false;
    final x = _toSingle(a), y = _toSingle(b);
    int bits;
    switch (low) {
      case 0:
      case 1:
        final z = low == 0 ? y : -y;
        final sum = x + z, virtual = sum - x;
        bits = _roundSingle(sum, (x - (sum - virtual)) + (z - virtual), false);
      case 2:
        bits = _roundSingle(x * y, 0, false);
      case 3:
        // The float32 rounding of the double quotient is correctly rounded;
        // the exact product of the result and the divisor tells the side.
        _single[0] = x / y;
        bits = _singleBits[0];
        if (!_normalSingle(bits)) return false;
        final product = _single[0] * y;
        if (fpscr & 1 != 0 && product.abs() > x.abs()) {
          bits--;
          if (!_normalSingle(bits)) return false;
        }
        _setFloatFlags(product != x ? DcFloat.inexact : 0);
      default:
        // FMAC: FR0 * FRm + FRn with one rounding.
        final f0 = fr[0];
        if (!_normalSingle(f0)) return false;
        final p = _toSingle(f0) * y;
        final sum = p + x, virtual = sum - p;
        bits = _roundSingle(sum, (p - (sum - virtual)) + (x - virtual), false);
    }
    if (bits < 0) return false;
    fr[n] = bits;
    return true;
  }

  DcFloat get _floatFormat =>
      fpscr.bit19 ? DcFloat.doublePrecision : DcFloat.single;

  void _doubleRegister(int register) {
    if (register.isOdd) _illegal();
  }

  BigInt _floatingBits(int register, {bool? wide}) {
    if (!(wide ?? fpscr.bit19)) return BigInt.from(fr[register]);
    _doubleRegister(register);
    return (BigInt.from(fr[register]) << 32) | BigInt.from(fr[register + 1]);
  }

  void _setFloatingBits(int register, BigInt bits, {bool? wide}) {
    if (!(wide ?? fpscr.bit19)) {
      fr[register] = bits.toUnsigned(32).toInt();
    } else {
      _doubleRegister(register);
      fr[register] = (bits >> 32).toUnsigned(32).toInt();
      fr[register + 1] = bits.toUnsigned(32).toInt();
    }
  }

  BigInt _finishFloat(DcFloatResult result, {int possible = 7}) {
    final enables = (fpscr >> 7) & 31;
    // Exception status cannot change FR or select another register bank.
    _fpscr = ((fpscr & ~0x3f000) |
            (result.flags << 12) |
            ((result.flags & 31) << 2)) &
        0x003fffff;
    if (result.flags & DcFloat.error != 0 ||
        result.flags & enables != 0 ||
        (result.normal && enables & possible != 0)) {
      throw const DcCpuException(0x120);
    }
    return result.bits;
  }

  bool _fpuOp(int op, int n, int m) {
    final code = op & 0xf0ff;
    final system = switch (code) {
      0x005a ||
      0x006a ||
      0x405a ||
      0x406a ||
      0x4056 ||
      0x4066 ||
      0x4052 ||
      0x4062 =>
        true,
      _ => false,
    };
    if (!system && op >> 12 != 15) return false;
    if (sr.bit15) throw DcCpuException(inDelaySlot ? 0x820 : 0x800);
    if (system) {
      final status = op & 0xf0 == 0x60;
      final load = op >> 12 == 4 && (op & 15 == 10 || op & 15 == 6);
      final memory = op & 15 == 2 || op & 15 == 6;
      if (load) {
        final value = memory ? _read(r[n], 4) : r[n];
        if (memory) r[n] = (r[n] + 4).mask32;
        if (status) {
          fpscr = value;
        } else {
          fpul = value;
        }
      } else {
        final value = status ? fpscr : fpul;
        if (memory) {
          final address = (r[n] - 4).mask32;
          _write(address, 4, value);
          r[n] = address;
        } else {
          r[n] = value;
        }
      }
      return true;
    }
    final low = op & 15;
    if (low >= 6 && low <= 12) {
      _floatingMove(op, n, m);
      return true;
    }
    if (op == 0xfbfd || op == 0xf3fd) {
      if (fpscr.bit19) _illegal();
      fpscr ^= op == 0xfbfd ? 0x200000 : 0x100000;
      return true;
    }
    if (code == 0xf00d || code == 0xf01d) {
      if (code == 0xf00d) {
        fr[n] = fpul;
      } else {
        fpul = fr[n];
      }
      return true;
    }
    if (code == 0xf08d || code == 0xf09d) {
      if (fpscr.bit19) _illegal();
      fr[n] = code == 0xf08d ? 0 : 0x3f800000;
      return true;
    }
    if (code == 0xf04d || code == 0xf05d) {
      if (fpscr.bit19) _doubleRegister(n);
      fr[n] = code == 0xf04d ? fr[n] ^ 0x80000000 : fr[n] & 0x7fffffff;
      return true;
    }
    if (fpscr & 3 > 1 || (fpscr.bit19 && fpscr.bit20)) {
      throw const DcUnsupported('reserved FPSCR arithmetic mode');
    }
    final format = _floatFormat;
    if (code == 0xf0ed || op & 0xf3ff == 0xf1fd) {
      if (fpscr.bit19) _illegal();
      final destination = (op >> 10 & 3) * 4;
      if (fpscr & 0xf80 == 0) {
        if (code == 0xf0ed) {
          final bits = _fastInnerProduct(destination, fr, (op >> 8 & 3) * 4, 1);
          if (bits >= 0) {
            _setFloatFlags(DcFloat.inexact);
            fr[destination + 3] = bits;
            return true;
          }
        } else {
          final r0 = _fastInnerProduct(destination, xf, 0, 4),
              r1 = _fastInnerProduct(destination, xf, 1, 4),
              r2 = _fastInnerProduct(destination, xf, 2, 4),
              r3 = _fastInnerProduct(destination, xf, 3, 4);
          if (r0 >= 0 && r1 >= 0 && r2 >= 0 && r3 >= 0) {
            _setFloatFlags(DcFloat.inexact);
            fr[destination] = r0;
            fr[destination + 1] = r1;
            fr[destination + 2] = r2;
            fr[destination + 3] = r3;
            return true;
          }
        }
      }
      final vector = [
        for (var i = 0; i < 4; i++) BigInt.from(fr[destination + i])
      ];
      if (code == 0xf0ed) {
        final source = (op >> 8 & 3) * 4;
        final result = DcFloat.single.innerProduct(vector,
            [for (var i = 0; i < 4; i++) BigInt.from(fr[source + i])], fpscr);
        fr[destination + 3] = _finishFloat(result).toInt();
      } else {
        final results = [
          for (var row = 0; row < 4; row++)
            DcFloat.single.innerProduct(
                vector,
                [
                  for (var column = 0; column < 4; column++)
                    BigInt.from(xf[row + 4 * column])
                ],
                fpscr)
        ];
        final flags = results.fold(0, (flags, result) => flags | result.flags);
        _finishFloat(DcFloatResult(BigInt.zero, flags, normal: true),
            possible: 23);
        for (var i = 0; i < 4; i++) {
          fr[destination + i] = results[i].bits.toInt();
        }
      }
      return true;
    }
    if (op & 0xf1ff == 0xf0fd) {
      if (fpscr.bit19) _illegal();
      final phase = fpul & 0xffff;
      final angle = phase * math.pi / 32768;
      final scratch = ByteData(4);
      // Quadrant endpoints avoid host transcendental residuals around zero.
      final sine = phase % 0x4000 == 0
          ? [0.0, 1.0, 0.0, -1.0][phase ~/ 0x4000]
          : math.sin(angle);
      final cosine = phase % 0x4000 == 0
          ? [1.0, 0.0, -1.0, 0.0][phase ~/ 0x4000]
          : math.cos(angle);
      _finishFloat(DcFloatResult(BigInt.zero, DcFloat.inexact, normal: true),
          possible: 1);
      scratch.setFloat32(0, sine);
      fr[n] = scratch.getUint32(0);
      scratch.setFloat32(0, cosine);
      fr[n + 1] = scratch.getUint32(0);
      return true;
    }
    if (low <= 3 && _fastSingle(low, n, m)) return true;
    if ((low == 4 || low == 5) && fpscr & 0x80000 == 0) {
      final a = fr[n], b = fr[m];
      if ((_normalSingle(a) || a & 0x7fffffff == 0) &&
          (_normalSingle(b) || b & 0x7fffffff == 0)) {
        final x = _toSingle(a), y = _toSingle(b);
        t = low == 4 ? x == y : x > y;
        _setFloatFlags(0);
        return true;
      }
    }
    if (low <= 5) {
      final a = _floatingBits(n), b = _floatingBits(m);
      if (low == 4 || low == 5) {
        t = _finishFloat(format.compare(a, b, fpscr, greater: low == 5),
                possible: 0) !=
            BigInt.zero;
      } else {
        final operation = ['add', 'sub', 'mul', 'div'][low];
        _setFloatingBits(
            n, _finishFloat(format.binary(operation, a, b, fpscr)));
      }
      return true;
    }
    if (low == 14) {
      if (fpscr.bit19) _illegal();
      if (_fastSingle(14, n, m)) return true;
      final result = DcFloat.single.multiplyAdd(
          BigInt.from(fr[0]), BigInt.from(fr[m]), BigInt.from(fr[n]), fpscr);
      _setFloatingBits(n, _finishFloat(result));
      return true;
    }
    switch (code) {
      case 0xf02d: // FLOAT.
        if (!fpscr.bit19 && fpscr & 0xf82 == 0) {
          final value = fpul.rel32;
          final bits =
              value == 0 ? 0 : _roundSingle(value.toDouble(), 0, false);
          if (bits >= 0) {
            if (value == 0) _setFloatFlags(0);
            fr[n] = bits;
            return true;
          }
        }
        if (fpscr.bit19) _doubleRegister(n);
        _setFloatingBits(
            n,
            _finishFloat(format.fromInteger(fpul.rel32, fpscr),
                possible: fpscr.bit19 ? 0 : 1));
      case 0xf03d: // FTRC.
        if (!fpscr.bit19) {
          final bits = fr[n], field = (bits >> 23) & 255;
          if (field < 158) {
            // Below 2^31 in magnitude, including zero and denormals.
            fpul = (field == 0 ? 0 : _toSingle(bits).toInt()) & 0xffffffff;
            _setFloatFlags(0);
            return true;
          }
        }
        fpul =
            _finishFloat(format.toInteger(_floatingBits(n), fpscr), possible: 0)
                .toInt();
      case 0xf06d: // FSQRT.
        _setFloatingBits(
            n,
            _finishFloat(format.squareRoot(_floatingBits(n), fpscr),
                possible: 1));
      case 0xf07d: // SH7091 reciprocal square-root approximation.
        if (fpscr.bit19) _illegal();
        fr[n] = _finishFloat(
                DcFloat.single.reciprocalRoot(BigInt.from(fr[n]), fpscr),
                possible: 1)
            .toInt();
      case 0xf0ad: // FCNVSD.
        if (!fpscr.bit19) _illegal();
        _doubleRegister(n);
        _setFloatingBits(
            n,
            _finishFloat(
                DcFloat.doublePrecision
                    .convert(DcFloat.single, BigInt.from(fpul), fpscr),
                possible: 0));
      case 0xf0bd: // FCNVDS.
        if (!fpscr.bit19) _illegal();
        fpul = _finishFloat(DcFloat.single
                .convert(DcFloat.doublePrecision, _floatingBits(n), fpscr))
            .toInt();
      default:
        throw DcUnsupported('FPU instruction ${op.x4} at ${pc.x8}');
    }
    return true;
  }

  void _floatingMove(int op, int n, int m) {
    final size = fpscr.bit20 ? 8 : 4;
    final low = op & 15;
    if (low == 12) {
      if (size == 4) {
        fr[n] = fr[m];
      } else {
        final source = m.isOdd ? xf : fr, destination = n.isOdd ? xf : fr;
        final first = source[m & ~1], second = source[(m & ~1) + 1];
        destination[n & ~1] = first;
        destination[(n & ~1) + 1] = second;
      }
      return;
    }
    final load = low == 6 || low == 8 || low == 9;
    final register = load ? n : m;
    final registers = size == 8 && register.isOdd ? xf : fr;
    final index = size == 8 ? register & ~1 : register;
    final address = (load
            ? (low == 6 ? r[0] + r[m] : r[m])
            : (low == 7 ? r[0] + r[n] : r[n] - (low == 11 ? size : 0)))
        .mask32;
    _checkAccess(address, size, !load);
    if (load) {
      if (size == 4) {
        registers[index] = _read(address, 4);
      } else {
        final (first, second) =
            bus.cpuReadPair(address, privileged: privileged);
        // SH-4 quadword transfers do not swap the two words in little-endian mode.
        registers[index] = first;
        registers[index + 1] = second;
      }
      if (low == 9) r[m] = (address + size).mask32;
    } else {
      if (size == 4) {
        _write(address, 4, registers[index]);
      } else {
        bus.cpuWritePair(address, registers[index], registers[index + 1],
            privileged: privileged);
      }
      if (low == 11) r[n] = address;
    }
  }
}
