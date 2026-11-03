import 'dart:math' as math;

import 'package:fnesemu_core/src/core/n64/bus.dart';
import 'package:fnesemu_core/src/core/n64/cpu.dart';
import 'package:fnesemu_core/src/core/n64/graphics.dart';
import 'package:fnesemu_core/src/core/n64/registers.dart';
import 'package:fnesemu_core/src/util/int.dart';
import 'package:test/test.dart';

void main() {
  test('register file stores 64-bit values and sign-extends word writes', () {
    final r = N64Registers();
    for (final value in [
      0,
      0x7fffffff,
      0x80000000,
      -0x80000000,
      0x123456789abcdef0,
      -1,
      1 << 63,
    ]) {
      r[8] = value;
      expect(r[8], value);
      expect(r.word(8), value.toSigned(32));
      r.setWord(8, 0x80000001);
      expect(r[8], -2147483647);
      r.setWord(8, 7);
      expect(r[8], 7);
    }
    r[0] = 99;
    r.setWord(0, 42);
    expect(r[0], 0);
    r.fillRange(0, 32, 0);
    expect(r.every((v) => v == 0), isTrue);
  });


  int random64(math.Random random) =>
      random.nextInt(1 << 32) << 32 | random.nextInt(1 << 32);
  BigInt unsigned(int v) => BigInt.from(v).toUnsigned(64);

  test('integer ops agree with BigInt reference arithmetic across widths', () {
    final random = math.Random(4300);
    final cpu = Vr4300(N64Bus());
    final ops = [
      0x01095021,
      0x350b9234,
      0x390c9234,
      0x310d9234,
      0x0109702a,
      0x0109782b,
      0x2d02ffe5,
      0x2903ffe5
    ];
    for (var i = 0; i < ops.length; i++) {
      cpu.bus.ramWrite(0x1000 + i * 4, ops[i], 4);
    }
    for (var iteration = 0; iteration < 80; iteration++) {
      cpu.reset(0x80001000);
      final x = iteration % 2 == 0
              ? random64(random).toSigned(32)
              : random64(random),
          y = iteration % 3 == 0
              ? random64(random).toSigned(32)
              : random64(random);
      cpu.r[8] = x;
      cpu.r[9] = y;
      for (var i = 0; i < ops.length; i++) {
        cpu.step();
      }
      const mask = 0x9234, negative = -27;
      final expected = [
        (x.toSigned(32) + y.toSigned(32)).toSigned(32),
        x | mask,
        x ^ mask,
        x & mask,
        x < y ? 1 : 0,
        unsigned(x) < unsigned(y) ? 1 : 0,
        unsigned(x) < unsigned(negative) ? 1 : 0,
        x < negative ? 1 : 0
      ];
      final registers = [10, 11, 12, 13, 14, 15, 2, 3];
      for (var i = 0; i < registers.length; i++) {
        expect(cpu.r[registers[i]], expected[i],
            reason: 'iteration $iteration op $i');
      }
    }
  });

  test('64-bit multiply and divide agree with BigInt reference arithmetic', () {
    final random = math.Random(64);
    final cpu = Vr4300(N64Bus());
    final ops = [
      0x0109001c, // dmult t0,t1
      0x00005010, // mfhi t2
      0x00005812, // mflo t3
      0x0109001d, // dmultu t0,t1
      0x00006010, // mfhi t4
      0x00006812, // mflo t5
      0x0109001e, // ddiv t0,t1
      0x00007010, // mfhi t6
      0x00007812, // mflo t7
      0x0109001f, // ddivu t0,t1
      0x00008010, // mfhi s0
      0x00008812, // mflo s1
    ];
    for (var i = 0; i < ops.length; i++) {
      cpu.bus.ramWrite(0x1000 + i * 4, ops[i], 4);
    }
    final edges = [0, 1, -1, 2, 1 << 63, (1 << 63) - 1, 0xffffffff, 1 << 32];
    for (var iteration = 0; iteration < 200; iteration++) {
      final x = iteration < 64 ? edges[iteration % 8] : random64(random);
      var y = iteration < 64 ? edges[iteration ~/ 8] : random64(random);
      if (iteration % 5 == 0 && iteration >= 64) y = y.toSigned(32);
      if (y == 0) y = 3;
      cpu.reset(0x80001000);
      cpu.r[8] = x;
      cpu.r[9] = y;
      for (var i = 0; i < ops.length; i++) {
        cpu.step();
      }
      final bx = BigInt.from(x), by = BigInt.from(y);
      final ux = unsigned(x), uy = unsigned(y);
      int s64(BigInt v) => v.toSigned(64).toInt();
      final reason = 'x=$x y=$y';
      expect(cpu.r[10], s64((bx * by) >> 64), reason: reason);
      expect(cpu.r[11], s64(bx * by), reason: reason);
      expect(cpu.r[12], s64((ux * uy) >> 64), reason: reason);
      expect(cpu.r[13], s64(ux * uy), reason: reason);
      expect(cpu.r[14], s64(bx.remainder(by)), reason: reason);
      expect(cpu.r[15], s64(bx ~/ by), reason: reason);
      expect(cpu.r[16], s64(ux.remainder(uy)), reason: reason);
      expect(cpu.r[17], s64(ux ~/ uy), reason: reason);
    }
  });



}
