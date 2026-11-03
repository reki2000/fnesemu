import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/aica_dsp.dart';
import 'package:fnesemu_core/src/core/dc/aica_dsp_alu.dart';
import 'package:fnesemu_core/src/core/dc/aica_sound.dart';
import 'package:fnesemu_core/src/types.dart';
import 'package:test/test.dart';

void main() {
  late DcAicaDspAlu alu;
  setUp(() => alu = DcAicaDspAlu());
  int step(
          {int input = 0,
          int temporary = 0,
          int coefficient = 0,
          int ySelect = 0,
          int shift = 0,
          bool xInput = false,
          bool bAccumulator = false,
          bool zero = false,
          bool negate = false,
          bool latchY = false,
          bool latchFraction = false,
          bool latchAddress = false}) =>
      alu.step(
          input: input,
          temporary: temporary,
          coefficient: coefficient,
          ySelect: ySelect,
          shift: shift,
          xInput: xInput,
          bAccumulator: bAccumulator,
          zero: zero,
          negate: negate,
          latchY: latchY,
          latchFraction: latchFraction,
          latchAddress: latchAddress);

  test('coefficient uses signed upper thirteen bits with fractional scaling',
      () {
    step(
        input: 0x400000,
        coefficient: 0x4007,
        ySelect: 1,
        xInput: true,
        zero: true);
    expect(alu.accumulator, 0x200000);
    step(
        input: 0x400000,
        coefficient: 0x8000,
        ySelect: 1,
        xInput: true,
        zero: true);
    expect(alu.accumulator, -0x400000);
  });
  test('multiply/add matches a BigInt oracle across signed limits and wraps',
      () {
    final random = math.Random(0xa1ca);
    for (var i = 0; i < 2048; i++) {
      final input = random.nextInt(1 << 24), temp = random.nextInt(1 << 24);
      final coefficient = random.nextInt(1 << 16);
      final old = random.nextInt(1 << 26).toSigned(26);
      final useInput = random.nextBool(), useAccumulator = random.nextBool();
      final zero = random.nextBool(), negate = random.nextBool();
      alu.accumulator = old;
      step(
          input: input,
          temporary: temp,
          coefficient: coefficient,
          ySelect: 1,
          xInput: useInput,
          bAccumulator: useAccumulator,
          zero: zero,
          negate: negate);
      final x = BigInt.from(useInput ? input : temp).toSigned(24);
      final y = BigInt.from(coefficient >> 3).toSigned(13);
      var b = BigInt.from(zero
          ? 0
          : useAccumulator
              ? old
              : temp.toSigned(24));
      if (negate) b = -b;
      expect(alu.accumulator, (((x * y) >> 12) + b).toSigned(26).toInt());
    }
  });
  group('DSP buffer backend', () {
    late DcAicaDsp dsp;
    setUp(() => dsp = DcAicaDsp());
    int execute(
            {int input = 0,
            int coefficient = 0,
            int temporary = 0,
            int? writeTemporary,
            int? effect,
            bool zero = true,
            bool xInput = true,
            int ySelect = 1}) =>
        dsp.executeArithmetic(
            coefficientAddress: coefficient,
            temporaryReadAddress: temporary,
            inputAddress: input,
            temporaryWriteAddress: writeTemporary,
            effectWriteAddress: effect,
            xInput: xInput,
            zero: zero,
            ySelect: ySelect);

    test(
        'full DSP reset clears arithmetic latches alongside CPU-visible storage',
        () {
      dsp.alu.accumulator = -456;
      dsp.alu.fraction = 123;
      dsp.alu.address = 321;
      dsp.alu.yRegister = 0x123450;
      execute(effect: 15, writeTemporary: 127, ySelect: 0);
      dsp.reset();
      expect((
        dsp.alu.accumulator,
        dsp.alu.fraction,
        dsp.alu.address,
        dsp.alu.yRegister
      ), (
        0,
        0,
        0,
        0
      ));
      expect(dsp.output(15), 0);
      expect(dsp.read(0x43fc), 0);
    });
  });
}
