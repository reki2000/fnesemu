import 'dart:math' as math;
import 'package:fnesemu/util/int.dart';
import 'package:test/test.dart';
import 'package:fnesemu/core/n64/bus.dart';
import 'package:fnesemu/core/n64/cpu.dart';
import 'package:fnesemu/core/n64/graphics.dart';
import 'package:fnesemu/core/n64/registers.dart';

void main() {
  test('word cache remains synchronized with external 64-bit register writes',
      () {
    final r = N64Registers();
    for (final text in [
      '0',
      '7fffffff',
      '80000000',
      'ffffffff80000000',
      '123456789abcdef0',
      'ffffffffffffffff',
      '8000000000000000'
    ]) {
      final value = BigInt.parse(text, radix: 16).toSigned(64);
      r[8] = value;
      expect(r[8], value);
      expect(r.word(8), value.toSigned(32).toInt());
      expect(r.isWord(8), value == value.toSigned(32));
      r.setWord(8, 0x80000001);
      expect(r[8], BigInt.from(-2147483647));
      expect(r.isWord(8), isTrue);
      r.setWord(8, 7);
      expect(r[8], BigInt.from(7));
    }
    r[0] = BigInt.from(99);
    r.setWord(0, 42);
    expect(r[0], BigInt.zero);
    r.fillRange(0, 32, BigInt.zero);
    expect(r.every((v) => v == BigInt.zero), isTrue);
  });

  test('word fast paths preserve mixed-width comparisons and logical high bits',
      () {
    final cpu = Vr4300(N64Bus());
    final memory = cpu.bus;
    final ops = [
      0x0109502b, // sltu t2,t0,t1: 0x80000000 < sign-extended -1
      0x0109582a, // slt t3,t0,t1: positive < -1 is false
      0x350c0001, // ori t4,t0,1: preserve positive zero-extended high word
      0x390dffff, // xori t5,t0,ffff
      0x01097027, // nor t6,t0,t1
      0x312f00ff, // andi t7,t1,ff
      0x29020000, // slti v0,t0,0
      0x2d030001, // sltiu v1,t0,1
    ];
    for (var i = 0; i < ops.length; i++) {
      memory.ramWrite(0x1000 + i * 4, ops[i], 4);
    }
    cpu.reset(0x80001000);
    cpu.r[8] = BigInt.from(0x80000000);
    cpu.putWord(9, -1);
    for (var i = 0; i < ops.length; i++) {
      cpu.step();
    }
    expect(cpu.stopReason, isNull);
    expect(cpu.r[10], BigInt.one);
    expect(cpu.r[11], BigInt.zero);
    expect(cpu.r[12], BigInt.from(0x80000001));
    expect(cpu.r[13], BigInt.from(0x8000ffff));
    expect(cpu.r[14], BigInt.zero);
    expect(cpu.r[15], BigInt.from(255));
    expect(cpu.r[2], BigInt.zero);
    expect(cpu.r[3], BigInt.zero);
  });

  test(
      'fast integer paths agree with 64-bit reference arithmetic across widths',
      () {
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
    BigInt value() => ((BigInt.from(random.nextInt(0x100000000)) << 32) |
            BigInt.from(random.nextInt(0x100000000)))
        .toSigned(64);
    for (var iteration = 0; iteration < 80; iteration++) {
      cpu.reset(0x80001000);
      final x = iteration % 2 == 0 ? value().toSigned(32) : value(),
          y = iteration % 3 == 0 ? value().toSigned(32) : value();
      cpu.r[8] = x;
      cpu.r[9] = y;
      for (var i = 0; i < ops.length; i++) {
        cpu.step();
      }
      final mask = BigInt.from(0x9234), negative = BigInt.from(-27);
      final expected = [
        (x.toSigned(32) + y.toSigned(32)).toSigned(32),
        (x | mask).toSigned(64),
        (x ^ mask).toSigned(64),
        x & mask,
        x < y ? BigInt.one : BigInt.zero,
        x.toUnsigned(64) < y.toUnsigned(64) ? BigInt.one : BigInt.zero,
        x.toUnsigned(64) < negative.toUnsigned(64) ? BigInt.one : BigInt.zero,
        x < negative ? BigInt.one : BigInt.zero
      ];
      final registers = [10, 11, 12, 13, 14, 15, 2, 3];
      for (var i = 0; i < registers.length; i++) {
        expect(cpu.r[registers[i]], expected[i],
            reason: 'iteration $iteration op $i');
      }
    }
    cpu.r[8] = (BigInt.one << 64) + BigInt.from(5);
    expect(cpu.r[8], BigInt.from(5));
    expect(cpu.r.word(8), 5);
    expect(cpu.r.isWord(8), isTrue);
  });

  test('LWU retains a positive 64-bit value; LW sign-extends the same bits',
      () {
    final cpu = Vr4300(N64Bus());
    cpu.bus.ramWrite(0x1000, 0x9c880000, 4); // lwu t0,0(a0)
    cpu.bus.ramWrite(0x1004, 0x8c890000, 4); // lw t1,0(a0)
    cpu.bus.ramWrite(0x1008, 0x11090002, 4); // beq t0,t1 (must not branch)
    cpu.bus.ramWrite(0x100c, 0, 4);
    cpu.bus.ramWrite(0x2000, 0x80000001, 4);
    cpu.reset(0x80001000);
    cpu.putWord(4, 0x80002000);
    for (var i = 0; i < 4; i++) {
      cpu.step();
    }
    expect(cpu.r[8], BigInt.from(0x80000001));
    expect(cpu.r[9], BigInt.from(-2147483647));
    expect(cpu.r.isWord(8), isFalse);
    expect(cpu.r.isWord(9), isTrue);
    expect(cpu.pc, 0x80001010);
  });

  test(
      'two-cycle combiner uses previous alpha and inspection snapshots are stable',
      () {
    final g = N64Graphics(N64Bus());
    g.otherHigh = 1 << 20;
    g.primitive = [90, 140, 200, 80];
    g.environment = [5, 30, 20, 40];
    g.combine0 = (4 << 20) | (3 << 15) | (4 << 12) | (3 << 9) | 7;
    g.combine1 = (5 << 28) |
        (5 << 24) |
        (1 << 18) |
        (1 << 15) |
        (1 << 9) |
        (1 << 6) |
        (5 << 3) |
        3;
    final shade = <double>[20, 70, 100, 120],
        texture = <double>[30, 40, 60, 100];
    final alpha0 = shade[3] * g.primitive[3] / 255 + texture[3];
    final expected = [
      for (var c = 0; c < 3; c++)
        (((shade[c] - g.environment[c]) * g.primitive[c] / 255 +
                        texture[c] -
                        g.environment[c]) *
                    alpha0 /
                    255 +
                texture[c])
            .clamp(0, 255),
      ((alpha0 - g.environment[3]) * texture[3] / 255 + g.primitive[3])
          .clamp(0, 255)
    ];
    final first = g.combine(shade, texture);
    for (var c = 0; c < 4; c++) {
      expect(first[c], closeTo(expected[c], 1e-10));
    }
    g.combine([255, 255, 255, 255], [0, 0, 0, 0]);
    for (var c = 0; c < 4; c++) {
      expect(first[c], closeTo(expected[c], 1e-10));
    }
    final tile = g.tiles[0]
      ..size = 2
      ..line = 1;
    tile.right = 3;
    g.tmem.setRange(0, 4, [0xf8, 1, 7, 0xc1]);
    final red = g.texel(0, 0, 0);
    expect(g.texel(0, 1, 0), [0, 255, 0, 255]);
    expect(red, [255, 0, 0, 255]);
  });

  test(
      'incremental interpolation matches analytic coverage, shading and perspective UV',
      () {
    for (final textured in [false, true]) {
      final g = N64Graphics(N64Bus());
      g.width = g.scRight = g.scBottom = 64;
      g.scale = [32, 32, 511];
      g.translate = [32, 32, 511];
      g.colorImage = 0x10000;
      g.combine1 = (7 << 28) | (4 << 15) | (7 << 12) | (6 << 9);
      g.textureOn = textured;
      if (textured) {
        g.otherHigh = 2 << 20;
        final tile = g.tiles[0]
          ..size = 2
          ..line = 2
          ..sMask = 3
          ..tMask = 3;
        tile.right = tile.bottom = 7;
        for (var y = 0; y < 8; y++) {
          for (var x = 0; x < 8; x++) {
            final v = (x + y).isEven ? 0xf801 : 0x07c1;
            g.tmem[y * 16 + x * 2] = v.shr8;
            g.tmem[y * 16 + x * 2 + 1] = v;
          }
        }
      }
      final vertices = [
        N64Vertex([-0.83, -0.77, 0, 1], [233, 17, 31, 255], 0.113, 0.217),
        N64Vertex([0.71 * 0.75, -0.68 * 0.75, 0, 0.75], [19, 241, 13, 255],
            7.313, 0.419),
        N64Vertex([-0.13 * 2, 0.89 * 2, 0, 2], [11, 23, 227, 255], 0.619, 7.713)
      ];
      final xs = vertices.map((v) => v.clip[0] / v.clip[3] * 32 + 32).toList();
      final ys = vertices.map((v) => -v.clip[1] / v.clip[3] * 32 + 32).toList();
      double edge(int a, int b, double x, double y) =>
          (x - xs[a]) * (ys[b] - ys[a]) - (y - ys[a]) * (xs[b] - xs[a]);
      final area = edge(0, 1, xs[2], ys[2]);
      g.triangle(vertices[0], vertices[1], vertices[2]);
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          final a = edge(1, 2, x + 0.5, y + 0.5) / area,
              b = edge(2, 0, x + 0.5, y + 0.5) / area,
              c = 1 - a - b;
          final actual = g.bus.ramRead(g.colorImage + (y * 64 + x) * 2, 2);
          if (math.min(a, math.min(b, c)) < 0) {
            expect(actual, 0, reason: 'outside $x,$y');
            continue;
          }
          if (textured) {
            final weights = [a, b, c];
            var divisor = 0.0, s = 0.0, t = 0.0;
            for (var i = 0; i < 3; i++) {
              final weight = weights[i] / vertices[i].clip[3];
              divisor += weight;
              s += weight * vertices[i].s;
              t += weight * vertices[i].t;
            }
            final expected =
                !((s / divisor).floor() + (t / divisor).floor()).bit0
                    ? 0xf801
                    : 0x07c1;
            expect(actual, expected, reason: 'texture $x,$y');
          } else {
            expect(actual.mask1, 1);
            for (var ch = 0; ch < 3; ch++) {
              final expected = (a * vertices[0].color[ch] +
                          b * vertices[1].color[ch] +
                          c * vertices[2].color[ch])
                      .round() >>
                  3;
              // At exact quantization thresholds, floating-point reassociation
              // can differ by one RGBA16 level; coverage must remain identical.
              expect(actual.shr(11 - ch * 5).mask5 - expected,
                  inInclusiveRange(-1, 1),
                  reason: 'shade $x,$y channel $ch');
            }
          }
        }
      }
    }
  });
}
