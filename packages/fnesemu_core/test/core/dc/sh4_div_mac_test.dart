import 'dart:math';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:test/test.dart';

const _code = 0x0c010000, _left = 0x0c020000, _right = 0x0c030000;

class _RecordingBus extends DcBus {
  final reads = <int>[];
  @override
  int cpuRead(int address, int size,
      {bool privileged = true, bool instruction = false, bool peek = false}) {
    if (!instruction && !peek) reads.add(address);
    return super.cpuRead(address, size,
        privileged: privileged, instruction: instruction, peek: peek);
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




  }



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



}
