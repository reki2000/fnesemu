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

  test('NEGC handles incoming borrow, zero and aliased source/destination', () {
    for (final value in [0, 1, 0x80000000, 0xffffffff]) {
      for (final carry in [false, true]) {
        cpu.r[1] = value;
        cpu.t = carry;
        final expected =
            -BigInt.from(value) - (carry ? BigInt.one : BigInt.zero);
        execute(0x611a);
        expect(cpu.r[1], expected.toUnsigned(32).toInt());
        expect(cpu.t, expected.isNegative);
      }
    }
  });

  for (final (op, value, flag, result, nextFlag) in [
    (0x4100, 0x80000001, false, 2, true),
    (0x4120, 0x40000000, true, 0x80000000, false),
    (0x4101, 0x80000001, false, 0x40000000, true),
    (0x4121, 0x80000001, false, 0xc0000000, true),
    (0x4104, 0x80000000, false, 1, true),
    (0x4105, 1, false, 0x80000000, true),
    (0x4124, 0x80000000, false, 0, true),
    (0x4124, 0, true, 1, false),
    (0x4125, 1, false, 0, true),
    (0x4125, 0, true, 0x80000000, false),
    (0x4108, 0xffffffff, true, 0xfffffffc, true),
    (0x4118, 0x12345678, false, 0x34567800, false),
    (0x4128, 0x12345678, true, 0x56780000, true),
    (0x4109, 0xffffffff, true, 0x3fffffff, true),
    (0x4119, 0x12345678, false, 0x00123456, false),
    (0x4129, 0x12345678, true, 0x00001234, true),
  ]) {
    test('shift/rotate ${op.toRadixString(16)} value=$value T=$flag', () {
      cpu.r[1] = value;
      cpu.t = flag;
      execute(op);
      expect(cpu.r[1], result);
      expect(cpu.t, nextFlag);
    });
  }

  test('dynamic shifts use signed direction and a right shift range of 1..32',
      () {
    for (final op in [0x412c, 0x412d]) {
      for (final value in [0, 1, 0x7fffffff, 0x80000001, 0xffffffff]) {
        for (final count in [
          0,
          1,
          31,
          32,
          63,
          -1,
          -31,
          -32,
          -33,
          -0x80000000
        ]) {
          cpu.r[1] = value;
          cpu.r[2] = count;
          cpu.t = true;
          var expected = BigInt.from(value);
          if (count >= 0) {
            expected <<= count % 32;
          } else {
            if (op == 0x412c) expected = expected.toSigned(32);
            expected >>= ((-count - 1) % 32) + 1;
          }
          execute(op);
          expect(cpu.r[1], expected.toUnsigned(32).toInt(),
              reason: '$op: value=$value, count=$count');
          expect(cpu.t, isTrue);
        }
      }
    }
    cpu.r[1] = 0x80000001;
    execute(0x411d); // Source and destination alias.
    expect(cpu.r[1], 1);
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

  test('word multiply uses only low words and preserves MACH and T', () {
    cpu.r[1] = 0x1234fffe;
    cpu.r[2] = 0x5678ffff;
    cpu.mach = 42;
    cpu.t = true;
    execute(0x212f);
    expect(cpu.macl, 2);
    execute(0x212e);
    expect(cpu.macl, 0xfffd0002);
    expect(cpu.mach, 42);
    expect(cpu.t, isTrue);
    execute(0x0028);
    expect(cpu.mach, 0);
    expect(cpu.macl, 0);
  });

  for (final (load, store, push, pop, name) in [
    (0x480a, 0x090a, 0x4f02, 0x4f06, 'MACH'),
    (0x481a, 0x091a, 0x4f12, 0x4f16, 'MACL'),
    (0x482a, 0x092a, 0x4f22, 0x4f26, 'PR'),
  ]) {
    test('$name register transfers and stack save/restore round trip', () {
      cpu.r[8] = 0x89abcdef;
      cpu.r[15] = data + 4;
      execute(load);
      execute(push);
      expect(bus.read32(data), 0x89abcdef);
      expect(cpu.r[15], data);
      bus.write32(data, 0x12345678);
      execute(pop);
      execute(store);
      expect(cpu.r[9], 0x12345678);
      expect(cpu.r[15], data + 4);
    });
  }

  test('failed system-register transfers preserve pointers and register values',
      () {
    cpu.mach = 42;
    cpu.r[15] = 0x005f8010;
    expect(() => execute(0x4f06), throwsA(isA<DcUnsupported>()));
    expect(cpu.r[15], 0x005f8010);
    expect(cpu.mach, 42);
    expect(() => execute(0x4f02), throwsA(isA<DcUnsupported>()));
    expect(cpu.r[15], 0x005f8010);
    expect(cpu.mach, 42);
  });

  test('SWAP and XTRCT preserve T, including aliased operands', () {
    cpu.r[2] = 0x12345678;
    cpu.t = true;
    execute(0x6128);
    expect(cpu.r[1], 0x12347856);
    execute(0x6129);
    expect(cpu.r[1], 0x56781234);
    cpu.r[1] = 0xaabbccdd;
    execute(0x212d);
    expect(cpu.r[1], 0x5678aabb);
    execute(0x222d);
    expect(cpu.r[2], 0x56781234);
    expect(cpu.t, isTrue);
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

  test('CMP/PZ and CMP/PL use signed values and differ at zero', () {
    for (final (value, nonnegative, positive) in [
      (0, true, false),
      (1, true, true),
      (0x7fffffff, true, true),
      (0x80000000, false, false),
      (0xffffffff, false, false),
    ]) {
      cpu.r[1] = value;
      execute(0x4111);
      expect(cpu.t, nonnegative);
      execute(0x4115);
      expect(cpu.t, positive);
    }
  });

  test('DIV0S/DIV0U and S-bit operations change only their documented flags',
      () {
    for (final a in [0, 0x80000000]) {
      for (final b in [0, 0x80000000]) {
        cpu.r[1] = a;
        cpu.r[2] = b;
        cpu.sr = 0x400080f2;
        execute(0x2127);
        expect(
            cpu.sr,
            0x400080f2 |
                (a == 0 ? 0 : 0x100) |
                (b == 0 ? 0 : 0x200) |
                (a == b ? 0 : 1));
        execute(0x0019);
        expect(cpu.sr, 0x400080f2);
      }
    }
    execute(0x0048);
    expect(cpu.sr, 0x400080f0);
    execute(0x0058);
    expect(cpu.sr, 0x400080f2);
  });

  for (final (store, load, size, expected) in [
    (0x0124, 0x032c, 1, 0xffffff80),
    (0x0125, 0x032d, 2, 0xffff8080),
    (0x0126, 0x032e, 4, 0x12348080),
  ]) {
    test('indexed $size-byte MOV adds R0 and preserves its source', () {
      cpu.r[0] = 4;
      cpu.r[1] = data;
      cpu.r[2] = 0x12348080;
      execute(store);
      cpu.r[2] = data;
      execute(load);
      expect(cpu.r[3], expected);
      expect(cpu.r[0], 4);
    });
  }

  test('displacement and GBR transfers scale offsets by operand width', () {
    cpu.r[1] = data;
    cpu.r[0] = 0x12348080;
    execute(0x801f);
    execute(0x841f);
    expect(cpu.r[0], 0xffffff80);
    cpu.r[0] = 0x12348080;
    execute(0x811f);
    execute(0x851f);
    expect(cpu.r[0], 0xffff8080);
    cpu.gbr = data;
    for (final (store, load, expected) in [
      (0xc0ff, 0xc4ff, 0xffffff80),
      (0xc1ff, 0xc5ff, 0xffff8080),
      (0xc2ff, 0xc6ff, 0x12348080),
    ]) {
      cpu.r[0] = 0x12348080;
      execute(store);
      execute(load);
      expect(cpu.r[0], expected);
    }
  });

  test('GBR byte logic and TAS update only the addressed byte', () {
    cpu.gbr = data;
    cpu.r[0] = 1;
    bus.write32(data, 0x1234a578);
    execute(0xcd0f); // AND.B.
    expect(bus.read32(data), 0x12340578);
    execute(0xcef0); // XOR.B.
    expect(bus.read32(data), 0x1234f578);
    execute(0xcf0a); // OR.B.
    expect(bus.read32(data), 0x1234ff78);
    execute(0xcc00);
    expect(cpu.t, isTrue);
    execute(0xcc01);
    expect(cpu.t, isFalse);
    cpu.r[1] = data + 2;
    bus.write8(data + 2, 0);
    execute(0x411b);
    expect(cpu.t, isTrue);
    expect(bus.read8(data + 2), 0x80);
    execute(0x411b);
    expect(cpu.t, isFalse);
    expect(bus.read8(data), 0x78);
    expect(bus.read8(data + 3), 0x12);
  });

  test('read-modify-write failure preserves T and ROM contents', () {
    cpu.r[1] = 0;
    cpu.t = true;
    expect(() => execute(0x411b), throwsA(isA<DcUnsupported>()));
    expect(cpu.t, isTrue);
    expect(bus.bios[0], 0);
  });
}
