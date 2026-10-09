import 'dart:math' as math;
import 'package:fnesemu/util/int.dart';
import 'package:test/test.dart';
import 'package:fnesemu/core/n64/bus.dart';
import 'package:fnesemu/core/n64/cpu.dart';
import 'package:fnesemu/core/n64/graphics.dart';
import 'package:fnesemu/core/n64/registers.dart';

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

  test('mixed-width comparisons and logical ops keep high bits', () {
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
    cpu.r[8] = 0x80000000;
    cpu.putWord(9, -1);
    for (var i = 0; i < ops.length; i++) {
      cpu.step();
    }
    expect(cpu.stopReason, isNull);
    expect(cpu.r[10], 1);
    expect(cpu.r[11], 0);
    expect(cpu.r[12], 0x80000001);
    expect(cpu.r[13], 0x8000ffff);
    expect(cpu.r[14], 0);
    expect(cpu.r[15], 255);
    expect(cpu.r[2], 0);
    expect(cpu.r[3], 0);
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
    expect(cpu.r[8], 0x80000001);
    expect(cpu.r[9], -2147483647);
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
