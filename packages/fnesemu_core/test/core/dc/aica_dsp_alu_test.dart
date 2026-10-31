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
  test('negative fractional products floor rather than truncate toward zero',
      () {
    step(input: -1, coefficient: 8, ySelect: 1, xInput: true, zero: true);
    expect(alu.accumulator, -1);
  });
  test('X and B independently select temporary, input and old accumulator', () {
    alu.fraction = 2048;
    step(input: 20, temporary: 8, xInput: true);
    expect(alu.accumulator, 18);
    step(input: 20, temporary: 8, bAccumulator: true);
    expect(alu.accumulator, 22);
    step(input: 20, temporary: 8, bAccumulator: true, negate: true);
    expect(alu.accumulator, -18);
    step(input: 20, temporary: 8, zero: true, negate: true);
    expect(alu.accumulator, 4);
  });
  test('Y latch retains input bits 23 through 4 for the next step', () {
    alu.yRegister = 0x400000;
    step(input: -1, temporary: 4096, ySelect: 2, zero: true, latchY: true);
    expect(alu.accumulator, 2048);
    expect(alu.yRegister, 0xfffff0);
    step(temporary: 4096, ySelect: 2, zero: true);
    expect(alu.accumulator, -1);
    step(temporary: 4096, ySelect: 3, zero: true);
    expect(alu.accumulator, 4095);
  });
  test('protected shifters saturate and unprotected shifters wrap to 24 bits',
      () {
    for (final value in [
      -0x2000000,
      -0x800001,
      -0x400001,
      -1,
      0,
      0x400000,
      0x800000,
      0x1ffffff
    ]) {
      for (var mode = 0; mode < 4; mode++) {
        alu.accumulator = value;
        final result = step(shift: mode);
        final scaled =
            BigInt.from(value) * BigInt.from(mode == 1 || mode == 2 ? 2 : 1);
        final expected = mode < 2
            ? (scaled < BigInt.from(-0x800000)
                ? -0x800000
                : scaled > BigInt.from(0x7fffff)
                    ? 0x7fffff
                    : scaled.toInt())
            : scaled.toSigned(24).toInt();
        expect(result, expected, reason: 'mode=$mode accumulator=$value');
      }
    }
  });
  test('shifter output uses old accumulator independently from the new sum',
      () {
    alu.accumulator = 123;
    expect(step(temporary: 456), 123);
    expect(alu.accumulator, 456);
    expect(step(), 456);
  });
  test(
      'fraction latch selects signed upper bits or unsigned interpolation bits',
      () {
    alu.accumulator = -0x1000;
    step(latchFraction: true);
    expect(alu.fraction, -2);
    alu.accumulator = 0x123456;
    step(latchFraction: true, shift: 3);
    expect(alu.fraction, 0x456);
  });
  test(
      'address latch selects sign-extended input or shifted interpolation bits',
      () {
    step(input: 0x801234, latchAddress: true);
    expect(alu.address, 0xf80);
    alu.accumulator = -0x123456;
    step(input: 0x7f0000, shift: 3, latchAddress: true);
    expect(alu.address, 0xedc);
  });
  test('fraction latch reads precede writes within a decoded step', () {
    alu.fraction = 2048;
    alu.accumulator = -0x800000;
    step(temporary: 100, zero: true, latchFraction: true);
    expect(alu.accumulator, 50);
    expect(alu.fraction, -4096);
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

    test('MEMS input and pipelined TEMP/EFREG writes preserve signed data', () {
      dsp.write(0x4400, 0);
      dsp.write(0x4404, 0xc000);
      dsp.write(0x3000, 0x8000);
      expect(execute(writeTemporary: 7, effect: 3), 0);
      expect(dsp.alu.accumulator, 0x400000);
      expect(execute(writeTemporary: 7, effect: 3, ySelect: 0), 0x400000);
      expect(dsp.read(0x403c), 0x4000);
      expect(dsp.output(3), 0x4000);
    });
    test('MIXS and external inputs align their signed binary points to 24 bits',
        () {
      dsp.write(0x3000, 0x4000);
      final mix = Float64List(16)..[15] = -0.25;
      dsp.latchMix(mix);
      execute(input: 47);
      expect(dsp.alu.accumulator, -0x100000);
      dsp.setExternalInput(0x4000, 0xc000);
      execute(input: 48);
      expect(dsp.alu.accumulator, 0x200000);
      execute(input: 49);
      expect(dsp.alu.accumulator, -0x200000);
    });
    test('aliased TEMP read and write consume the previous buffer contents',
        () {
      dsp.write(0x4000, 100);
      dsp.alu.accumulator = 123;
      execute(writeTemporary: 0, zero: false, xInput: false, ySelect: 0);
      expect(dsp.alu.accumulator, 100);
      expect(dsp.read(0x4000), 123);
      execute(writeTemporary: 0, zero: false, xInput: false, ySelect: 0);
      expect(dsp.alu.accumulator, 123);
      expect(dsp.read(0x4000), 100);
    });
    test('decoded arithmetic output enters the existing stereo effect mixer',
        () {
      dsp.write(0x3000, 0x8000);
      dsp.setExternalInput(0xc000, 0);
      execute(input: 48);
      execute(effect: 6, ySelect: 0);
      final sound = DcAicaSound(Uint8List(0x200000), dsp: dsp);
      final packets = <AudioBuffer>[];
      sound.setAudio(packets.add);
      sound.control = 15;
      sound.writeOutput(0x2018, 15 << 8);
      sound.advance(256);
      expect(packets.single.buffer, everyElement(0.5));
    });
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
