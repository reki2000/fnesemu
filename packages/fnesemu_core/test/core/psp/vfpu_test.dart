import 'dart:typed_data';

import 'package:fnesemu_core/src/core/psp/allegrex.dart';
import 'package:fnesemu_core/src/core/psp/memory.dart';
import 'package:test/test.dart';

import 'fixture.dart';

/// Assembles [build] at the user base, appends a self loop and runs the
/// processor for [steps] instructions (the same harness as cpu_test).
(Allegrex, PspMemory) run(void Function(Asm) build, {int steps = 80}) {
  final asm = Asm(0x08800000);
  build(asm);
  asm.label('end');
  asm.jTo('end');
  asm.nop();
  final words = asm.finish();
  final mem = PspMemory();
  for (var i = 0; i < words.length; i++) {
    mem.write32(0x08800000 + i * 4, words[i]);
  }
  final cpu = Allegrex(mem);
  cpu.jumpTo(0x08800000);
  for (var i = 0; i < steps; i++) {
    expect(cpu.step(), isTrue, reason: 'step $i');
  }
  return (cpu, mem);
}

int floatBits(double value) {
  final data = ByteData(4)..setFloat32(0, value);
  return data.getUint32(0);
}

/// A VFPU operand: matrix, column, row packed as the encoding has them.
int reg(int matrix, int column, int row) =>
    (row << 5) | (matrix << 2) | column;

/// Moves a general register into a VFPU single register (mtv).
int mtv(int rt, int operand) => 0x48e80000 | (rt << 16) | (operand & 0xff);

/// Moves a VFPU single register into a general register (mfv).
int mfv(int rt, int operand) => 0x48680000 | (rt << 16) | (operand & 0xff);

/// A load or store of a quad register: [operand] at [offset] from [rs].
int lvq(int operand, int rs, int offset) =>
    (0x36 << 26) |
    (rs << 21) |
    ((operand & 0x1f) << 16) |
    (offset & 0xfffc) |
    ((operand >> 5) & 3);
int svq(int operand, int rs, int offset) =>
    (0x3e << 26) |
    (rs << 21) |
    ((operand & 0x1f) << 16) |
    (offset & 0xfffc) |
    ((operand >> 5) & 3);

void main() {
  group('loads and stores', () {
    test('quad load and store round trip at a large offset', () {
      final mem = PspMemory();
      mem.write32(0x08810000 + 22672, floatBits(1.5));
      mem.write32(0x08810000 + 22676, floatBits(-2.5));
      mem.write32(0x08810000 + 22680, floatBits(3.5));
      mem.write32(0x08810000 + 22684, floatBits(-4.5));
      final asm = Asm(0x08800000);
      asm.li(Reg.t3, 0x08810000);
      asm.word(lvq(reg(1, 0, 0), Reg.t3, 22672));
      asm.word(svq(reg(1, 0, 0), Reg.t3, 22688));
      asm.label('end');
      asm.jTo('end');
      asm.nop();
      final words = asm.finish();
      for (var i = 0; i < words.length; i++) {
        mem.write32(0x08800000 + i * 4, words[i]);
      }
      final cpu = Allegrex(mem);
      cpu.jumpTo(0x08800000);
      for (var i = 0; i < 40; i++) {
        expect(cpu.step(), isTrue, reason: 'step $i');
      }
      // C100 is column 0 of matrix 1: elements 16, 20, 24, 28.
      expect(cpu.v[16], floatBits(1.5));
      expect(cpu.v[20], floatBits(-2.5));
      expect(cpu.v[24], floatBits(3.5));
      expect(cpu.v[28], floatBits(-4.5));
      // The store wrote the same column back out at the second offset.
      expect(mem.read32(0x08810000 + 22688), floatBits(1.5));
      expect(mem.read32(0x08810000 + 22692), floatBits(-2.5));
      expect(mem.read32(0x08810000 + 22696), floatBits(3.5));
      expect(mem.read32(0x08810000 + 22700), floatBits(-4.5));
    });
  });

  group('arithmetic and prefixes', () {
    test('vadd with a swizzle and a negation from the prefix', () {
      final (cpu, _) = run((a) {
        // Fill C100 with (1.5, -2.5, 3.5, -4.5) through mtv singles:
        // S100, S110, S120, S130 are its column elements in order.
        a.li(Reg.t0, floatBits(1.5));
        a.word(mtv(Reg.t0, reg(1, 0, 0)));
        a.li(Reg.t0, floatBits(-2.5));
        a.word(mtv(Reg.t0, reg(1, 0, 1)));
        a.li(Reg.t0, floatBits(3.5));
        a.word(mtv(Reg.t0, reg(1, 0, 2)));
        a.li(Reg.t0, floatBits(-4.5));
        a.word(mtv(Reg.t0, reg(1, 0, 3)));
        a.li(Reg.t0, floatBits(10));
        a.word(mtv(Reg.t0, reg(1, 1, 0)));
        a.li(Reg.t0, floatBits(20));
        a.word(mtv(Reg.t0, reg(1, 1, 1)));
        a.li(Reg.t0, floatBits(30));
        a.word(mtv(Reg.t0, reg(1, 1, 2)));
        a.li(Reg.t0, floatBits(40));
        a.word(mtv(Reg.t0, reg(1, 1, 3)));
        // vpfxs -y, -x, -w, -z (swizzles 1,0,3,2, negated)
        a.word(0xdc000000 | 0xf0000 | (1 | (0 << 2) | (3 << 4) | (2 << 6)));
        a.word(0x60058480); // vadd.q C000, C100, C110
      });
      // (2.5 + 10, -1.5 + 20, 4.5 + 30, -3.5 + 40)
      expect(cpu.v[0], floatBits(12.5));
      expect(cpu.v[4], floatBits(18.5));
      expect(cpu.v[8], floatBits(34.5));
      expect(cpu.v[12], floatBits(36.5));
    });

    test('vmov with a constant prefix writes the constants', () {
      final (cpu, _) = run((a) {
        a.word(0xdc00f0e4); // vpfxs 0, 1, 2, 1/2 (constants)
        a.word(0xd0008480); // vmov.q C000, C100
      });
      expect(cpu.v[0], floatBits(0));
      expect(cpu.v[4], floatBits(1));
      expect(cpu.v[8], floatBits(2));
      expect(cpu.v[12], floatBits(0.5));
    });

    test('row pairs and triples run along the row their low bits name',
        () {
      final (cpu, _) = run((a) {
        for (var i = 0; i < 3; i++) {
          a.li(Reg.t0, floatBits(i + 1.0));
          a.word(mtv(Reg.t0, reg(1, 0, i))); // C100 = 1, 2, 3
        }
        for (var c = 0; c < 4; c++) {
          a.li(Reg.t0, floatBits(c + 5.0));
          a.word(mtv(Reg.t0, reg(1, c, 3))); // R103 = 5, 6, 7, 8
        }
        a.word(0xd0008423); // vmov.t R003, C100: row 3, columns 0-2
        a.word(0xd0008449); // vmov.t C211, C100: column 1, rows 1-3
        a.word(0xd0006782); // vmov.p C020, R123: row 3, columns 2-3
      });
      expect([cpu.v[12], cpu.v[13], cpu.v[14]],
          [floatBits(1), floatBits(2), floatBits(3)]);
      expect([cpu.v[37], cpu.v[41], cpu.v[45]],
          [floatBits(1), floatBits(2), floatBits(3)]);
      expect([cpu.v[2], cpu.v[6]], [floatBits(7), floatBits(8)]);
    });

    test('moves preserve denormals and NaN payloads', () {
      final (cpu, _) = run((a) {
        a.li(Reg.t0, 0x000116c2); // a positive denormal
        a.word(mtv(Reg.t0, reg(1, 0, 0)));
        a.li(Reg.t0, 0x7fbfffff); // a NaN with a payload
        a.word(mtv(Reg.t0, reg(1, 0, 1)));
        a.word(0xd0008480); // vmov.q C000, C100
        a.word(0xd0018481); // vabs.q C010, C100
      });
      expect(cpu.v[0], 0x000116c2);
      expect(cpu.v[4], 0x7fbfffff);
      // vabs of the denormal and the NaN keeps their bits too.
      expect(cpu.v[1], 0x000116c2);
      expect(cpu.v[5], 0x7fbfffff);
    });

    test('vmin and vmax order a NaN as a signed infinity', () {
      final (cpu, _) = run((a) {
        a.li(Reg.t0, 0x7fbfffff); // +NaN in S100
        a.word(mtv(Reg.t0, reg(1, 0, 0)));
        a.li(Reg.t0, floatBits(3));
        a.word(mtv(Reg.t0, reg(1, 1, 0))); // 3 in S110
        a.word(0x6d058480); // vmin.q C000, C100, C110
        a.word(0x6d858481); // vmax.q C010, C100, C110
      });
      // vmin(+NaN, 3) = 3, vmax(+NaN, 3) = +NaN (payload kept).
      expect(cpu.v[0], floatBits(3));
      expect(cpu.v[1], 0x7fbfffff);
    });
  });

  group('conversions and constants', () {
    test('vcst writes the named constant', () {
      final (cpu, _) = run((a) {
        a.word(0xd0698080); // vcst.q C000, VFPU_PI
      });
      for (final at in [0, 4, 8, 12]) {
        expect(cpu.v[at], 0x40490fdb);
      }
    });

    test('vc2i expands bytes to the top of each lane', () {
      final (cpu, _) = run((a) {
        a.li(Reg.t0, 0x01234567);
        a.word(mtv(Reg.t0, reg(0, 0, 0))); // S000
        a.word(0xd0398081); // vc2i.q C010, S000
      });
      expect(cpu.v[1], 0x67000000);
      expect(cpu.v[5], 0x45000000);
      expect(cpu.v[9], 0x23000000);
      expect(cpu.v[13], 0x01000000);
    });

    test('vf2h truncates and flushes values below the half range', () {
      final (cpu, _) = run((a) {
        a.li(Reg.t0, 0x3f801fff); // 1.0 plus mantissa bits a half drops
        a.word(mtv(Reg.t0, reg(1, 0, 0)));
        a.li(Reg.t0, 0x38000000); // 2^-15, below the smallest normal half
        a.word(mtv(Reg.t0, reg(1, 0, 1)));
        a.word(0xd032048c); // vf2h.p S300, C100
      }, steps: 20);
      expect(cpu.v[48], 0x00003c00);
    });

    test('viim converts its signed immediate to a float', () {
      final (cpu, _) = run((a) {
        a.word(0xdf0000ff); // viim.s S000, 255
        a.word(0xdf01ffff); // viim.s S010, -1
      });
      expect(cpu.v[0], 0x437f0000);
      expect(cpu.v[1], 0xbf800000);
    });

    test('vf2iz maps a NaN to the largest integer', () {
      final (cpu, _) = run((a) {
        a.li(Reg.t0, 0x7fc00000); // NaN
        a.word(mtv(Reg.t0, reg(1, 0, 0)));
        a.word(0xd2208480); // vf2iz.q C000, C100, 0
      });
      expect(cpu.v[0], 0x7fffffff);
    });
  });

  group('reductions and products', () {
    test('vdot sums the whole prefix view, constants included', () {
      final (cpu, _) = run((a) {
        // C100 = (1, 2, 3, 9), C200 = (1, 1, 1, 5) via mtv singles.
        final s = [1.0, 2.0, 3.0, 9.0];
        final t = [1.0, 1.0, 1.0, 5.0];
        for (var i = 0; i < 4; i++) {
          a.li(Reg.t0, floatBits(s[i]));
          a.word(mtv(Reg.t0, reg(1, 0, i)));
          a.li(Reg.t0, floatBits(t[i]));
          a.word(mtv(Reg.t0, reg(2, 0, i)));
        }
        // vpfxs x, y, z, 3 and vpfxt x, y, z, 1/2: lane 3 is constant.
        a.word(0xdc000000 | 0x8824);
        a.word(0xdd000000 | 0x80e4);
        a.word(0x64888400); // vdot.t S000, C100, C200
      });
      // 1 + 2 + 3 from the lanes, plus 3 * 1/2 from the constant lane.
      expect(cpu.v[0], floatBits(7.5));
    });

    test('vmmul reads its first source transposed', () {
      final (cpu, _) = run((a) {
        // M100 = [[1, 2], [3, 4]], M200 = [[5, 6], [7, 8]] by rows
        final m1 = [1.0, 2.0, 3.0, 4.0], m2 = [5.0, 6.0, 7.0, 8.0];
        for (var i = 0; i < 4; i++) {
          a.li(Reg.t0, floatBits(m1[i]));
          a.word(mtv(Reg.t0, reg(1, i % 2, i ~/ 2)));
          a.li(Reg.t0, floatBits(m2[i]));
          a.word(mtv(Reg.t0, reg(2, i % 2, i ~/ 2)));
        }
        a.word(0xf0080480); // vmmul.p M000, M100, M200
      }, steps: 40);
      // transpose(M100) * M200 = [[26, 30], [38, 44]]
      expect([cpu.v[0], cpu.v[1], cpu.v[4], cpu.v[5]],
          [floatBits(26), floatBits(30), floatBits(38), floatBits(44)]);
    });

    test('vtfm reads its matrix transposed like vmmul', () {
      final (cpu, _) = run((a) {
        // M100 = [[1, 2], [3, 4]] by rows, C200 = (5, 6)
        final m1 = [1.0, 2.0, 3.0, 4.0];
        for (var i = 0; i < 4; i++) {
          a.li(Reg.t0, floatBits(m1[i]));
          a.word(mtv(Reg.t0, reg(1, i % 2, i ~/ 2)));
        }
        a.li(Reg.t0, floatBits(5));
        a.word(mtv(Reg.t0, reg(2, 0, 0)));
        a.li(Reg.t0, floatBits(6));
        a.word(mtv(Reg.t0, reg(2, 0, 1)));
        a.word(0xf0880480); // vtfm2.p C000, M100, C200
      }, steps: 40);
      // transpose(M100) * (5, 6) = (23, 34)
      expect([cpu.v[0], cpu.v[4]], [floatBits(23), floatBits(34)]);
    });

    test('vidt writes the identity line its operand names', () {
      final (cpu, _) = run((a) {
        a.word(0xd0038087); // vidt.q, column 3 of M1
        a.word(0xd00380a6); // vidt.q, row 2 of M1
        a.word(0xd0038049); // vidt.t, column 1 of M2 from row 1
      });
      // column 3 of M1: one at row 3
      expect([cpu.v[16 + 3], cpu.v[16 + 7], cpu.v[16 + 11], cpu.v[16 + 15]],
          [floatBits(0), floatBits(0), floatBits(0), floatBits(1)]);
      // row 2 of M1: one at column 2
      expect([cpu.v[24], cpu.v[25], cpu.v[26], cpu.v[27]],
          [floatBits(0), floatBits(0), floatBits(1), floatBits(0)]);
      // rows 1-3 of column 1 of M2: one at row 1
      expect([cpu.v[32 + 5], cpu.v[32 + 9], cpu.v[32 + 13]],
          [floatBits(1), floatBits(0), floatBits(0)]);
    });

    test('vhdp does not read the last lane of its first source', () {
      final (cpu, _) = run((a) {
        // C100 = (1, 2, 3, NaN), C200 = (1, 1, 1, 5)
        final s = [1.0, 2.0, 3.0, double.nan];
        final t = [1.0, 1.0, 1.0, 5.0];
        for (var i = 0; i < 4; i++) {
          a.li(Reg.t0, floatBits(s[i]));
          a.word(mtv(Reg.t0, reg(1, 0, i)));
          a.li(Reg.t0, floatBits(t[i]));
          a.word(mtv(Reg.t0, reg(2, 0, i)));
        }
        a.word(0x66088480); // vhdp.q S000, C100, C200
      });
      expect(cpu.v[0], floatBits(11));
    });

    test('vcrsp forms its components in reverse order', () {
      // With the destination equal to the first source, the z and y
      // components land before x is formed, and x reads them back.
      final (cpu, _) = run((a) {
        final s = [1.0, 2.0, 3.0];
        final t = [101.0, 102.0, 103.0];
        for (var i = 0; i < 3; i++) {
          a.li(Reg.t0, floatBits(s[i]));
          a.word(mtv(Reg.t0, reg(0, 0, i)));
          a.li(Reg.t0, floatBits(t[i]));
          a.word(mtv(Reg.t0, reg(1, 0, i)));
        }
        a.word(0xf2848000); // vcrsp.t C000, C000, C100
      });
      expect(cpu.v[0], floatBits(-1040709));
      expect(cpu.v[4], floatBits(-10203));
      expect(cpu.v[8], floatBits(-100));
    });

    test('vmmul.p writes only the pair submatrix', () {
      final mem = PspMemory();
      // Both source matrices hold 2.0 in every element.
      for (var i = 0; i < 32; i++) {
        mem.write32(0x08808000 + i * 4, floatBits(2));
      }
      final asm = Asm(0x08800000);
      asm.li(Reg.t3, 0x08808000);
      asm.word(lvq(reg(1, 0, 0), Reg.t3, 0));
      asm.word(lvq(reg(1, 1, 0), Reg.t3, 16));
      asm.word(lvq(reg(1, 2, 0), Reg.t3, 32));
      asm.word(lvq(reg(1, 3, 0), Reg.t3, 48));
      asm.word(lvq(reg(2, 0, 0), Reg.t3, 64));
      asm.word(lvq(reg(2, 1, 0), Reg.t3, 80));
      asm.word(lvq(reg(2, 2, 0), Reg.t3, 96));
      asm.word(lvq(reg(2, 3, 0), Reg.t3, 112));
      asm.word(0xf0082480); // vmmul.p M000, M100, M200
      asm.label('end');
      asm.jTo('end');
      asm.nop();
      final words = asm.finish();
      for (var i = 0; i < words.length; i++) {
        mem.write32(0x08800000 + i * 4, words[i]);
      }
      final cpu = Allegrex(mem);
      cpu.jumpTo(0x08800000);
      for (var i = 0; i < 60; i++) {
        expect(cpu.step(), isTrue, reason: 'step $i');
      }
      // The 2x2 product of all-2.0 matrices is all 8.0; the rest of
      // M000 keeps the fresh context's canonical NaN pattern.
      expect(cpu.v[0], floatBits(8));
      expect(cpu.v[1], floatBits(8));
      expect(cpu.v[4], floatBits(8));
      expect(cpu.v[5], floatBits(8));
      expect(cpu.v[2], 0x7f800001);
      expect(cpu.v[8], 0x7f800001);
    });
  });

  group('control registers', () {
    test('vcmov moves on a set or clear code, or lane by lane', () {
      final (cpu, _) = run((a) {
        // C100 = (1, 2, 3, 4), C200 = (1, 0, 3, 0)
        final c1 = [1.0, 2.0, 3.0, 4.0], c2 = [1.0, 0.0, 3.0, 0.0];
        for (var i = 0; i < 4; i++) {
          a.li(Reg.t0, floatBits(c1[i]));
          a.word(mtv(Reg.t0, reg(1, 0, i)));
          a.li(Reg.t0, floatBits(c2[i]));
          a.word(mtv(Reg.t0, reg(2, 0, i)));
        }
        a.word(0xd006808c); // vzero.q C300
        a.word(0xd0068090); // vzero.q C400
        a.word(0xd0068094); // vzero.q C500
        a.word(0x6c088481); // vcmp.q EQ, C100, C200: lanes 0 and 2
        a.word(0xd2a6848c); // vcmovt.q C300, C100, 6
        a.word(0xd2ae8490); // vcmovf.q C400, C100, 6
        a.word(0xd2a98494); // vcmovf.q C500, C100, 1: code 1 is clear
      }, steps: 60);
      List<int> column(int m) =>
          [for (var i = 0; i < 4; i++) cpu.v[m * 16 + i * 4]];
      expect(column(3),
          [floatBits(1), floatBits(0), floatBits(3), floatBits(0)]);
      expect(column(4),
          [floatBits(0), floatBits(2), floatBits(0), floatBits(4)]);
      expect(column(5), [for (final x in [1.0, 2.0, 3.0, 4.0]) floatBits(x)]);
    });

    test('vcmp tells NaN and infinity apart', () {
      int lane0(int cond, int bits) {
        final (cpu, _) = run((a) {
          a.li(Reg.t0, bits);
          a.word(mtv(Reg.t0, reg(1, 0, 0)));
          a.word(0x6c040400 | cond); // vcmp.s cond, S100, S100
        }, steps: 20);
        return cpu.vcc & 1;
      }

      const nan = 0x7fc00000, inf = 0x7f800000, one = 0x3f800000;
      // EN, EI, ES, NN, NI, NS on NaN, infinity and 1.0
      final conds = [9, 10, 11, 13, 14, 15];
      expect([for (final c in conds) lane0(c, nan)], [1, 0, 1, 0, 1, 0]);
      expect([for (final c in conds) lane0(c, inf)], [0, 1, 1, 1, 0, 0]);
      expect([for (final c in conds) lane0(c, one)], [0, 0, 0, 1, 1, 1]);
    });

    test('the random state registers mask writes to twenty bits', () {
      final (cpu, _) = run((a) {
        a.li(Reg.t0, -1);
        a.word(0x48e80000 | (Reg.t0 << 16) | 136); // mtvc t0, $136
        a.word(0x48680000 | (Reg.t1 << 16) | 136); // mfvc t1, $136
      });
      expect(cpu.r[Reg.t1], 0x3f8fffff);
    });

    test('the condition codes read back through mfvc', () {
      final (cpu, _) = run((a) {
        a.li(Reg.t0, 0x25);
        a.word(0x48e80000 | (Reg.t0 << 16) | 131); // mtvc t0, $131
        a.word(0x48680000 | (Reg.t1 << 16) | 131); // mfvc t1, $131
      });
      expect(cpu.r[Reg.t1], 0x25);
    });
  });
}
