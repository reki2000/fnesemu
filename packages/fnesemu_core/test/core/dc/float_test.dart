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




  }


}
