import 'dart:math';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:test/test.dart';

void main() {
  late DcBus bus;
  late Sh4 cpu;
  const code = 0x0c010000, data = 0x0c020000;
  void execute(int op) {
    bus.write16(code, op);
    cpu.pc = code;
    cpu.step();
  }

  setUp(() {
    bus = DcBus();
    cpu = Sh4(bus)..sr = 0x40000000;
  });

  test('carry and overflow arithmetic agree with unbounded integer arithmetic',
      () {
    const values = [0, 1, 0x7fffffff, 0x80000000, 0xffffffff];
    for (final op in [0x312e, 0x312f, 0x312a, 0x312b]) {
      final signed = op == 0x312f || op == 0x312b;
      final subtract = op == 0x312a || op == 0x312b;
      for (final a in values) {
        for (final b in values) {
          for (final carry in [false, true]) {
            cpu.r[1] = a;
            cpu.r[2] = b;
            cpu.t = carry;
            var left = BigInt.from(a), right = BigInt.from(b);
            if (signed) {
              left = left.toSigned(32);
              right = right.toSigned(32);
            } else if (carry) {
              right += BigInt.one;
            }
            final result = subtract ? left - right : left + right;
            final flag = signed
                ? result < BigInt.from(-0x80000000) ||
                    result > BigInt.from(0x7fffffff)
                : subtract
                    ? result.isNegative
                    : result > BigInt.from(0xffffffff);
            execute(op);
            expect(cpu.r[1], result.toUnsigned(32).toInt(),
                reason: '$op: $a, $b, T=$carry');
            expect(cpu.t, flag);
          }
        }
      }
    }
  });




  test(
      '32-bit multiply results agree with BigInt including full 64-bit products',
      () {
    final random = Random(7750);
    final values = [
      0,
      1,
      0xffff,
      0x10000,
      0x7fffffff,
      0x80000000,
      0xffffffff,
      for (var i = 0; i < 40; i++)
        random.nextInt(65536) * 65536 + random.nextInt(65536)
    ];
    for (final op in [0x0127, 0x3125, 0x312d]) {
      for (final a in values) {
        for (final b in values) {
          cpu.r[1] = a;
          cpu.r[2] = b;
          cpu.mach = 0x76543210;
          cpu.t = true;
          var left = BigInt.from(a), right = BigInt.from(b);
          if (op == 0x312d) {
            left = left.toSigned(32);
            right = right.toSigned(32);
          }
          final product = (left * right).toUnsigned(64);
          execute(op);
          expect(cpu.macl, product.toUnsigned(32).toInt(),
              reason: '$op: $a * $b');
          expect(cpu.mach, op == 0x0127 ? 0x76543210 : (product >> 32).toInt());
          expect(cpu.t, isTrue);
        }
      }
    }
  });





  test(
      'CMP/STR compares corresponding byte lanes, not arbitrary matching bytes',
      () {
    cpu.r[1] = 0x12345678;
    for (final (value, expected) in [
      (0x12abcdef, true),
      (0xab34cdef, true),
      (0xabcd56ef, true),
      (0xabcdef78, true),
      (0x78563412, false),
    ]) {
      cpu.r[2] = value;
      execute(0x212c);
      expect(cpu.t, expected);
    }
  });






}
