import 'dart:math';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/mmu.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:test/test.dart';

const _code = 0x0c010000, _left = 0x0c020000, _right = 0x0c030000;

class _RecordingBus extends DcBus {
  final reads = <int>[];
  @override
  int read16(int address, {DcTranslation? mapping, bool peek = false}) {
    if (address != _code) reads.add(address);
    return super.read16(address, mapping: mapping, peek: peek);
  }

  @override
  int read32(int address, {DcTranslation? mapping, bool peek = false}) {
    reads.add(address);
    return super.read32(address, mapping: mapping, peek: peek);
  }
}

void main() {
  late _RecordingBus bus;
  late Sh4 cpu;
  void execute(int op) {
    bus.write16(_code, op);
    cpu.pc = _code;
    cpu.step();
  }

  BigInt accumulator() => (BigInt.from(cpu.mach) << 32) | BigInt.from(cpu.macl);

  setUp(() {
    bus = _RecordingBus();
    cpu = Sh4(bus)..sr = 0x40000000;
    cpu.vbr = 0x8c040000;
  });

  test('DIV1 agrees with a 33-bit mathematical model for all M/Q/T states', () {
    final random = Random(775019);
    final values = [
      0,
      1,
      0x7fffffff,
      0x80000000,
      0xffffffff,
      for (var i = 0; i < 12; i++)
        random.nextInt(65536) * 65536 + random.nextInt(65536)
    ];
    for (var flags = 0; flags < 8; flags++) {
      final q = (flags >> 2) & 1, m = (flags >> 1) & 1, t = flags & 1;
      for (final dividend in values) {
        for (final divisor in values) {
          cpu.r[1] = dividend;
          cpu.r[2] = divisor;
          cpu.sr = 0x400080f2 | (q << 8) | (m << 9) | t;
          // A non-restoring step operates on a mathematical 33-bit remainder.
          final wide = BigInt.from(dividend) * BigInt.two +
              BigInt.from(t) +
              BigInt.from(q == m ? -divisor : divisor);
          final high = (wide.toUnsigned(33) >> 32).toInt();
          execute(0x3124);
          expect(cpu.r[1], wide.toUnsigned(32).toInt());
          expect(cpu.r[2], divisor);
          expect(cpu.sr, 0x400080f2 | ((high ^ m) << 8) | (m << 9) | (1 - high),
              reason: 'dividend=$dividend divisor=$divisor flags=$flags');
        }
      }
    }
  });

  test('DIV1 captures an aliased divisor before shifting its destination', () {
    cpu.r[1] = 0x87654321;
    cpu.sr = 0x40000001;
    final wide = BigInt.from(0x87654321) + BigInt.one;
    execute(0x3114);
    expect(cpu.r[1], wide.toUnsigned(32).toInt());
    expect(cpu.sr & 0x301, 1);
  });

  test('a full unsigned divide sequence computes 64-by-32-bit quotients', () {
    final random = Random(320064);
    for (var i = 0; i < 160; i++) {
      final divisor = i == 0
          ? 1
          : random.nextInt(0xffff) * 65536 + random.nextInt(65535) + 1;
      final high = random.nextInt(divisor);
      final low = random.nextInt(65536) * 65536 + random.nextInt(65536);
      final dividend = (BigInt.from(high) << 32) + BigInt.from(low);
      cpu.r[0] = divisor;
      cpu.r[1] = high;
      cpu.r[2] = low;
      execute(0x0019); // DIV0U.
      for (var bit = 0; bit < 32; bit++) {
        execute(0x4224); // ROTCL R2 supplies the next dividend bit.
        execute(0x3104); // DIV1 R0,R1.
      }
      execute(0x4224); // Insert the final quotient bit.
      expect(cpu.r[2], (dividend ~/ BigInt.from(divisor)).toInt());
      expect(cpu.r[0], divisor);
    }
  });

  for (final size in [2, 4]) {
    final op = size == 4 ? 0x089f : 0x489f;
    test('MAC.$size wraps 64-bit signed products and sums like BigInt', () {
      final random = Random(6400 + size);
      final values = size == 4
          ? [0, 1, 0xffffffff, 0x7fffffff, 0x80000000]
          : [0, 1, 0xffff, 0x7fff, 0x8000];
      for (var sample = 0; sample < 400; sample++) {
        final a = sample < 25
            ? values[sample ~/ 5]
            : random.nextInt(65536) * (size == 4 ? 65536 : 0) +
                random.nextInt(65536);
        final b = sample < 25
            ? values[sample % 5]
            : random.nextInt(65536) * (size == 4 ? 65536 : 0) +
                random.nextInt(65536);
        cpu.r[8] = _left;
        cpu.r[9] = _right;
        cpu.mach = random.nextInt(65536) * 65536 + random.nextInt(65536);
        cpu.macl = random.nextInt(65536) * 65536 + random.nextInt(65536);
        cpu.sr = 0x400083f1;
        if (size == 4) {
          bus.write32(_left, a);
          bus.write32(_right, b);
        } else {
          bus.write16(_left, a);
          bus.write16(_right, b);
        }
        final expected = accumulator() +
            BigInt.from(a).toSigned(size * 8) *
                BigInt.from(b).toSigned(size * 8);
        execute(op);
        expect(accumulator(), expected.toUnsigned(64), reason: '$a * $b');
        expect(cpu.r[8], _left + size);
        expect(cpu.r[9], _right + size);
        expect(cpu.sr, 0x400083f1);
      }
    });

    test('MAC.$size handles accumulator carry and 64-bit wraparound', () {
      cpu.r[8] = _left;
      cpu.r[9] = _right;
      bus.write32(_left, 1);
      bus.write32(_right, 1);
      cpu.mach = cpu.macl = 0xffffffff;
      execute(op);
      expect(accumulator(), BigInt.zero);
    });

    test('MAC.$size reads Rn before Rm and advances an aliased pointer twice',
        () {
      cpu.r[8] = _left;
      bus.write32(_left, size == 4 ? 3 : 0xfffe);
      bus.write32(_left + 4, 7);
      if (size == 2) bus.write16(_left + 2, 7);
      execute(size == 4 ? 0x088f : 0x488f);
      expect(bus.reads, [_left, _left + size]);
      expect(accumulator(), BigInt.from(size == 4 ? 21 : -14).toUnsigned(64));
      expect(cpu.r[8], _left + size * 2);
    });

    test('MAC.$size first-transfer error takes precedence over the second', () {
      cpu.r[8] = 0x005f8010;
      cpu.r[9] = _right + 1;
      cpu.mach = 0x12345678;
      cpu.macl = 0xabcdef01;
      expect(() => execute(op), throwsA(isA<DcUnsupported>()));
      expect(bus.reads, [0x005f8010]);
      expect(bus.expevt, 0);
      expect(cpu.r[8], 0x005f8010);
      expect(cpu.r[9], _right + 1);
      expect(cpu.mach, 0x12345678);
      expect(cpu.macl, 0xabcdef01);
    });

    test(
        'MAC.$size second-transfer fault leaves pointers and accumulator unchanged',
        () {
      cpu.r[8] = _left;
      cpu.r[9] = _right + 1;
      cpu.mach = 0x12345678;
      cpu.macl = 0xabcdef01;
      bus.write32(_left, 42);
      execute(op);
      expect(cpu.instructionExecuted, isFalse);
      expect(bus.expevt, 0xe0);
      expect(bus.tea, _right + 1);
      expect(cpu.spc, _code);
      expect(cpu.r[8], _left);
      expect(cpu.r[9], _right + 1);
      expect(cpu.mach, 0x12345678);
      expect(cpu.macl, 0xabcdef01);
    });
  }

  for (final (a, b, accumulatorLow, high, expectedLow, expectedHigh) in [
    (1, 1, 0x7fffffff, 0, 0x7fffffff, 1),
    (0xffff, 1, 0x80000000, 0, 0x80000000, 1),
    (0x8000, 0x8000, 0x40000000, 1, 0x7fffffff, 1),
    (1, 2, 0x7ffffffd, 0x12345678, 0x7fffffff, 0x12345678),
    (0xffff, 2, 0x80000002, 0x12345678, 0x80000000, 0x12345678),
  ]) {
    test('MAC.W saturation clamps 32-bit accumulation with input $a,$b', () {
      bus.write16(_left, a);
      bus.write16(_right, b);
      cpu.r[8] = _left;
      cpu.r[9] = _right;
      cpu.mach = high;
      cpu.macl = accumulatorLow;
      cpu.sr = 0x400003f3;
      execute(0x489f);
      expect(cpu.macl, expectedLow);
      expect(cpu.mach, expectedHigh);
      expect(cpu.sr, 0x400003f3);
    });
  }

  test(
      'MAC.W retains a previous saturation indicator until software clears MACH',
      () {
    bus.write16(_left, 1);
    bus.write16(_right, 1);
    cpu.r[8] = _left;
    cpu.r[9] = _right;
    cpu.mach = 1;
    cpu.macl = 5;
    cpu.sr |= 2;
    execute(0x489f);
    expect(cpu.mach, 1);
    expect(cpu.macl, 6);
  });

  for (final (high, low, a, b, expectedHigh, expectedLow) in [
    (0x7fff, 0xffffffff, 1, 1, 0x7fff, 0xffffffff),
    (0xffff8000, 0, 0xffffffff, 1, 0xffff8000, 0),
    (0, 0, 0x7fffffff, 0x7fffffff, 0x7fff, 0xffffffff),
    (0xffffffff, 0xffffffff, 0x80000000, 0x7fffffff, 0xffff8000, 0),
    (0, 0xffffffff, 1, 1, 1, 0),
    (0xffffffff, 0, 0xffffffff, 1, 0xfffffffe, 0xffffffff),
  ]) {
    test('MAC.L saturation clamps agreed 48-bit state $high:$low', () {
      bus.write32(_left, a);
      bus.write32(_right, b);
      cpu.r[8] = _left;
      cpu.r[9] = _right;
      cpu.mach = high;
      cpu.macl = low;
      cpu.sr |= 2;
      execute(0x089f);
      expect(cpu.mach, expectedHigh);
      expect(cpu.macl, expectedLow);
    });
  }

  for (final (op, high, low, a, b) in [
    (0x489f, 0x12345678, 0x7fffffff, 1, 1),
    (0x089f, 0x12345678, 0, 1, 1),
    (0x089f, 0, 0, 0xffffffff, 1),
    (0x089f, 0xffffffff, 0xffffffff, 1, 1),
  ]) {
    test(
        'ambiguous saturated MAC state stops without committing operands $op/$high',
        () {
      bus.write32(_left, a);
      bus.write32(_right, b);
      cpu.r[8] = _left;
      cpu.r[9] = _right;
      cpu.mach = high;
      cpu.macl = low;
      cpu.sr |= 2;
      expect(() => execute(op), throwsA(isA<DcUnsupported>()));
      expect(cpu.r[8], _left);
      expect(cpu.r[9], _right);
      expect(cpu.mach, high);
      expect(cpu.macl, low);
      expect(cpu.pc, _code);
      expect(cpu.instructionExecuted, isFalse);
    });
  }

  test('a MAC.L loop computes a signed vector dot product', () {
    const left = [0x12345678, -42, -0x80000000, 7];
    const right = [-7, 1000, 2, -13];
    var expected = BigInt.zero;
    for (var i = 0; i < left.length; i++) {
      bus.write32(_left + i * 4, left[i]);
      bus.write32(_right + i * 4, right[i]);
      expected += BigInt.from(left[i]) * BigInt.from(right[i]);
    }
    cpu.r[8] = _left;
    cpu.r[9] = _right;
    execute(0x0028); // CLRMAC.
    for (var i = 0; i < left.length; i++) {
      execute(0x089f);
    }
    expect(accumulator(), expected.toUnsigned(64));
    expect(cpu.r[8], _left + left.length * 4);
    expect(cpu.r[9], _right + right.length * 4);
  });

  test('MAC fault in a call slot preserves source pointers and old PR', () {
    bus.write16(_code, 0xb002);
    bus.write16(_code + 2, 0x089f);
    cpu.pc = _code;
    cpu.r[8] = _left;
    cpu.r[9] = _right + 1;
    cpu.pr = 0x12345678;
    cpu.step();
    cpu.step();
    expect(cpu.spc, _code);
    expect(cpu.pr, 0x12345678);
    expect(cpu.r[8], _left);
    expect(cpu.r[9], _right + 1);
    expect(bus.expevt, 0xe0);
  });
}
