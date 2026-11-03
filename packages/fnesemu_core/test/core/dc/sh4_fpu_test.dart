import 'dart:math';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/float.dart';
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
    cpu.vbr = 0x8c030000;
  });

  test('FPU reset and FPSCR bank selection preserve raw register bits', () {
    expect(cpu.fpscr, 0x40001);
    cpu.fr[1] = 0x01234567;
    cpu.xf[1] = 0x89abcdef;
    execute(0xfbfd);
    expect(cpu.fr[1], 0x89abcdef);
    expect(cpu.xf[1], 0x01234567);
    execute(0xfbfd);
    expect(cpu.fr[1], 0x01234567);
    execute(0xf3fd);
    expect(cpu.fpscr & 0x100000, 0x100000);
    cpu.reset();
    expect(cpu.fr, everyElement(0));
    expect(cpu.xf, everyElement(0));
    expect(cpu.fpscr, 0x40001);
  });


  test('single FMOV preserves NaN payloads and all transfer addressing modes',
      () {
    cpu.fr[2] = 0x7fc01234;
    cpu.r[8] = data;
    cpu.r[9] = data;
    cpu.r[0] = 4;
    execute(0xf82a); // FMOV FR2,@R8.
    expect(bus.read32(data), 0x7fc01234);
    execute(0xf198); // FMOV @R9,FR1.
    expect(cpu.fr[1], 0x7fc01234);
    execute(0xf42c); // FMOV FR2,FR4.
    expect(cpu.fr[4], 0x7fc01234);
    execute(0xf827); // FMOV FR2,@(R0,R8).
    execute(0xf386); // FMOV @(R0,R8),FR3.
    expect(cpu.fr[3], 0x7fc01234);
    execute(0xf599); // FMOV @R9+,FR5.
    expect(cpu.fr[5], 0x7fc01234);
    expect(cpu.r[9], data + 4);
    execute(0xf92b); // FMOV FR2,@-R9.
    expect(cpu.r[9], data);
    expect(bus.read32(data), 0x7fc01234);
  });

















  test(
      'host single-precision paths match the exact model in both rounding modes',
      () {
    final random = Random(1);
    int single() {
      final kind = random.nextInt(16);
      final sign = random.nextBool() ? 0x80000000 : 0;
      if (kind == 0) return sign;
      final exponent =
          kind < 8 ? 120 + random.nextInt(16) : 1 + random.nextInt(254);
      // Near-all-zero or all-one fractions exercise carries and ties.
      final fraction = kind < 4
          ? (random.nextBool() ? 0 : 0x7fffff) ^ random.nextInt(4)
          : random.nextInt(0x800000);
      return sign | (exponent << 23) | fraction;
    }

    const format = DcFloat.single;
    for (var i = 0; i < 50000; i++) {
      final control = random.nextInt(2);
      // The first cases put the double FMAC sum on a single midpoint, so a
      // tiny addend decides the side.
      final midpoint = i < 8;
      final low = midpoint
          ? 14
          : const [0, 1, 2, 3, 4, 5, 14, 0x2d, 0x3d][random.nextInt(9)];
      final a = midpoint ? (i & 2) << 30 | 0x21800000 : single(),
          b = midpoint ? 0x3f800001 : single(),
          f0 = midpoint ? (i & 1) << 31 | 0x3fc00000 : single();
      final integer = random.nextInt(1 << 32).toSigned(32);
      final x = BigInt.from(a), y = BigInt.from(b);
      final expected = switch (low) {
        < 4 => format.binary(['add', 'sub', 'mul', 'div'][low], x, y, control),
        4 || 5 => format.compare(x, y, control, greater: low == 5),
        14 => format.multiplyAdd(BigInt.from(f0), y, x, control),
        0x2d => format.fromInteger(integer, control),
        _ => format.toInteger(x, control),
      };
      if (expected.flags & (DcFloat.error | DcFloat.invalid) != 0) continue;
      cpu
        ..fpscr = control
        ..fpul = integer & 0xffffffff;
      cpu.fr
        ..[0] = f0
        ..[1] = a
        ..[2] = b;
      execute(low == 0x2d
          ? 0xf12d
          : low == 0x3d
              ? 0xf13d
              : 0xf120 | low);
      final reason = 'op $low: ${[a, b, f0, integer]}, RM $control';
      expect(
          low == 4 || low == 5
              ? (cpu.t ? 1 : 0)
              : (low == 0x3d ? cpu.fpul : cpu.fr[1]),
          expected.bits.toInt(),
          reason: reason);
      expect(
          cpu.fpscr, control | (expected.flags << 12) | (expected.flags << 2),
          reason: reason);
    }
    // FIPR and FTRV round the exact sum of four products once.
    int near() =>
        (random.nextBool() ? 0x80000000 : 0) |
        ((124 + random.nextInt(6)) << 23) |
        random.nextInt(0x800000);
    // Exponent spreads beyond the exact 64-bit window.
    int spread() =>
        (random.nextBool() ? 0x80000000 : 0) |
        ((110 + random.nextInt(30)) << 23) |
        random.nextInt(0x800000);
    List<BigInt> big(Iterable<int> values) => [...values.map(BigInt.from)];
    for (var i = 0; i < 20000; i++) {
      final control = random.nextInt(2);
      final value = i % 4 < 2 ? near : (i % 8 < 6 ? spread : single);
      final vector = [for (var j = 0; j < 4; j++) value()];
      final matrix = [for (var j = 0; j < 16; j++) value()];
      final fipr = i.isOdd;
      cpu.fpscr = control;
      cpu.fr.setAll(0, [...vector, ...matrix.take(4)]);
      cpu.xf.setAll(0, matrix);
      execute(fipr ? 0xf1ed : 0xf1fd);
      final rows = fipr
          ? [format.innerProduct(big(vector), big(matrix.take(4)), control)]
          : [
              for (var row = 0; row < 4; row++)
                format.innerProduct(
                    big(vector),
                    big([for (var c = 0; c < 4; c++) matrix[row + 4 * c]]),
                    control)
            ];
      final flags = rows.fold(0, (flags, row) => flags | row.flags);
      if (flags & DcFloat.invalid != 0) continue;
      final reason = 'vector $vector matrix $matrix RM $control';
      expect(fipr ? cpu.fr.sublist(3, 4) : cpu.fr.sublist(0, 4),
          [for (final row in rows) row.bits.toInt()],
          reason: reason);
      expect(cpu.fpscr, control | (flags << 12) | (flags << 2), reason: reason);
    }
  });
}
