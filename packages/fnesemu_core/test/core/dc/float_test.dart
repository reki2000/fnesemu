import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/float.dart';
import 'package:test/test.dart';

BigInt _bits(double value, bool wide) {
  final data = ByteData(8);
  if (!wide) {
    data.setFloat32(0, value);
    return BigInt.from(data.getUint32(0));
  }
  data.setFloat64(0, value);
  return (BigInt.from(data.getUint32(0)) << 32) |
      BigInt.from(data.getUint32(4));
}

double _value(BigInt bits, bool wide) {
  final data = ByteData(8);
  if (!wide) {
    data.setUint32(0, bits.toInt());
    return data.getFloat32(0);
  }
  data.setUint32(0, (bits >> 32).toInt());
  data.setUint32(4, bits.toUnsigned(32).toInt());
  return data.getFloat64(0);
}

void main() {
  for (final wide in [false, true]) {
    final format = wide ? DcFloat.doublePrecision : DcFloat.single;
    test(
        'binary $wide RN arithmetic matches host IEEE arithmetic on finite inputs',
        () {
      final random = math.Random(wide ? 64 : 32);
      for (var i = 0; i < 400; i++) {
        final a = _bits(
            (random.nextDouble() - 0.5) * math.pow(2, random.nextInt(120) - 60),
            wide);
        final b = _bits(
            (random.nextDouble() - 0.5) * math.pow(2, random.nextInt(120) - 60),
            wide);
        final x = _value(a, wide), y = _value(b, wide);
        for (final (op, expected) in [
          ('add', x + y),
          ('sub', x - y),
          ('mul', x * y),
          ('div', x / y),
        ]) {
          final result = format.binary(op, a, b, 0);
          expect(result.bits, _bits(expected, wide), reason: '$op: $x,$y');
        }
        final positive = a & ~format.signMask;
        expect(format.squareRoot(positive, 0).bits,
            _bits(math.sqrt(_value(positive, wide)), wide));
      }
    });

    test('binary $wide RN tie-even and RZ differ at exact halfway boundaries',
        () {
      final one = _bits(1, wide);
      final epsilon = _bits(math.pow(2, -(wide ? 53 : 24)).toDouble(), wide);
      expect(format.binary('add', one, epsilon, 0).bits, one);
      final three = _bits(3 * math.pow(2, -(wide ? 53 : 24)).toDouble(), wide);
      final rn = format.binary('add', one, three, 0);
      final rz = format.binary('add', one, three, 1);
      expect(rn.bits, one + BigInt.two);
      expect(rz.bits, one + BigInt.one);
      expect(rn.flags, DcFloat.inexact);
      expect(rz.flags, DcFloat.inexact);
    });

    test('binary $wide NaN convention and special arithmetic are SH-4 specific',
        () {
      final one = _bits(1, wide), zero = BigInt.zero;
      final quiet = format.infinity | BigInt.one;
      final signaling = format.infinity | (format.hidden >> 1);
      expect(format.binary('add', quiet, one, 0).bits, format.quietNaN);
      expect(format.binary('add', quiet, one, 0).flags, 0);
      expect(format.binary('add', signaling, one, 0).flags, DcFloat.invalid);
      expect(format.binary('mul', zero, format.infinity, 0).flags,
          DcFloat.invalid);
      expect(format.binary('div', zero, zero, 0).flags, DcFloat.invalid);
      expect(format.binary('div', one, zero, 0).flags, DcFloat.zeroDivide);
      expect(
          format
              .binary('add', format.infinity, format.signedInfinity(true), 0)
              .flags,
          DcFloat.invalid);
      expect(
          format.binary('mul', format.signMask, one, 0).bits, format.signMask);
      expect(format.binary('add', format.signMask, format.signMask, 0).bits,
          format.signMask);
      expect(format.binary('add', format.signMask, zero, 0).bits, zero);
    });

    test(
        'binary $wide underflow distinguishes exact subnormals, flush and FPU error',
        () {
      final minimum = BigInt.one << format.fractionBits;
      final half = _bits(0.5, wide);
      final exact = format.binary('mul', minimum, half, 0);
      expect(exact.bits, minimum >> 1);
      expect(exact.flags, 0);
      final flush = format.binary('mul', minimum, half, 0x40000);
      expect(flush.bits, BigInt.zero);
      expect(flush.flags, DcFloat.inexact | DcFloat.underflow);
      expect(format.binary('add', BigInt.one, _bits(1, wide), 0).flags,
          DcFloat.error);
      expect(format.binary('add', BigInt.one, _bits(1, wide), 0x40000).bits,
          _bits(1, wide));
    });

    test('binary $wide overflow follows sign and rounding mode', () {
      final maximum = format.infinity - BigInt.one;
      final rn = format.binary('mul', maximum, _bits(2, wide), 0);
      final rz =
          format.binary('mul', maximum | format.signMask, _bits(2, wide), 1);
      expect(rn.bits, format.infinity);
      expect(rz.bits, maximum | format.signMask);
      expect(rn.flags, DcFloat.overflow | DcFloat.inexact);
      expect(rz.flags, DcFloat.overflow | DcFloat.inexact);
    });

    test('binary $wide comparisons handle signed zero, denormals and NaNs', () {
      expect(
          format.compare(BigInt.zero, format.signMask, 0, greater: false).bits,
          BigInt.one);
      expect(
          format.compare(format.signMask, BigInt.zero, 0, greater: true).bits,
          BigInt.zero);
      expect(format.compare(BigInt.one, BigInt.zero, 0, greater: true).bits,
          BigInt.one);
      expect(
          format.compare(format.quietNaN, BigInt.zero, 0, greater: false).flags,
          0);
      expect(
          format.compare(format.quietNaN, BigInt.zero, 0, greater: true).flags,
          DcFloat.invalid);
    });

    test('binary $wide integer conversions truncate without inexact exceptions',
        () {
      for (final value in [-2147483648, -1234567, 0, 1, 1234567, 2147483647]) {
        final result = format.fromInteger(value, 0);
        expect(result.bits, _bits(value.toDouble(), wide));
      }
      expect(format.toInteger(_bits(-3.75, wide), 0).bits,
          BigInt.from(0xfffffffd));
      expect(format.toInteger(_bits(-3.75, wide), 0).flags, 0);
      expect(format.toInteger(_bits(2147483648, wide), 0).bits,
          BigInt.from(0x7fffffff));
      expect(
          format.toInteger(_bits(2147483648, wide), 0).flags, DcFloat.invalid);
      expect(
          format.toInteger(format.quietNaN, 0).bits, BigInt.from(0x80000000));
    });
  }

  test(
      'format conversions preserve exactly representable numbers and round narrowing',
      () {
    final single = DcFloat.single, wide = DcFloat.doublePrecision;
    for (final value in [-100000.0, -0.0, 0.0, 0.1, 1.0, 123456.5]) {
      final f32 = _bits(value, false);
      expect(
          wide.convert(single, f32, 0).bits, _bits(_value(f32, false), true));
      expect(single.convert(wide, _bits(value, true), 0).bits, f32);
    }
  });

  test('FMAC uses an exact product with one final rounding', () {
    final result = DcFloat.single.multiplyAdd(BigInt.from(0x3f800001),
        BigInt.from(0x3f7ffffe), BigInt.from(0xbf800000), 0);
    // (1 + 2^-23) * (1 - 2^-23) - 1 = -2^-46.
    expect(result.bits, _bits(-math.pow(2, -46).toDouble(), false));
    expect(result.flags, 0);
    expect(
        DcFloat.single
            .multiplyAdd(BigInt.zero, BigInt.from(0x7f800000),
                BigInt.from(0x7fbfffff), 0)
            .flags,
        DcFloat.invalid);
    expect(
        DcFloat.single
            .multiplyAdd(BigInt.zero, BigInt.from(0x3f800000),
                BigInt.from(0x80000000), 0)
            .bits,
        BigInt.from(0x80000000));
  });
}
