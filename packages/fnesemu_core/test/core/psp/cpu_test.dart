import 'package:fnesemu_core/src/core/psp/allegrex.dart';
import 'package:fnesemu_core/src/core/psp/memory.dart';
import 'package:test/test.dart';

import 'fixture.dart';

/// Assembles [build] at the user base, appends a self loop and runs the
/// processor for [steps] instructions.
(Allegrex, PspMemory) run(void Function(Asm) build, {int steps = 60}) {
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

void main() {
  group('integer arithmetic', () {
    test('add, sub and comparisons', () {
      final (cpu, _) = run((a) {
        a.li(Reg.t0, 7);
        a.li(Reg.t1, 6);
        a.r(Reg.t0, Reg.t1, Reg.t2, 0, 0x21); // addu
        a.r(Reg.t0, Reg.t1, Reg.t3, 0, 0x23); // subu
        a.li(Reg.t4, -1);
        a.r(Reg.t4, Reg.t1, Reg.t5, 0, 0x2a); // slt: -1 < 6
        a.r(Reg.t4, Reg.t1, Reg.t6, 0, 0x2b); // sltu: 0xffffffff > 6
        a.lui(Reg.t7, 0x8000);
        a.ori(Reg.s0, Reg.t7, 0x00f0);
      });
      expect(cpu.r[Reg.t2], 13);
      expect(cpu.r[Reg.t3], 1);
      expect(cpu.r[Reg.t5], 1);
      expect(cpu.r[Reg.t6], 0);
      expect(cpu.r[Reg.s0], 0x800000f0.toSigned(32));
    });

    test('multiply and divide, including the zero divisor convention', () {
      final (cpu, _) = run((a) {
        a.li(Reg.t0, -6);
        a.li(Reg.t1, 7);
        a.r(Reg.t0, Reg.t1, 0, 0, 0x18); // mult
        a.r(0, 0, Reg.t2, 0, 0x12); // mflo
        a.r(0, 0, Reg.t3, 0, 0x10); // mfhi
        a.li(Reg.t4, -1);
        a.r(Reg.t4, Reg.t1, 0, 0, 0x19); // multu 0xffffffff * 7
        a.r(0, 0, Reg.t5, 0, 0x12);
        a.r(0, 0, Reg.t6, 0, 0x10);
        a.r(Reg.t0, Reg.zero, 0, 0, 0x1a); // div by zero
        a.r(0, 0, Reg.t7, 0, 0x12);
        a.r(0, 0, Reg.s0, 0, 0x10);
        a.li(Reg.s1, 100);
        a.li(Reg.s2, 7);
        a.r(Reg.s1, Reg.s2, 0, 0, 0x1a); // div
        a.r(0, 0, Reg.s3, 0, 0x12);
        a.r(0, 0, Reg.s4, 0, 0x10);
      });
      expect(cpu.r[Reg.t2], -42);
      expect(cpu.r[Reg.t3], -1);
      expect(cpu.r[Reg.t5], 0xfffffff9.toSigned(32));
      expect(cpu.r[Reg.t6], 6);
      expect(cpu.r[Reg.t7], 1); // dividend < 0 -> lo is 1
      expect(cpu.r[Reg.s0], -6); // hi is the dividend
      expect(cpu.r[Reg.s3], 14);
      expect(cpu.r[Reg.s4], 2);
    });

    test('mul, madd and msub accumulate in 64 bits', () {
      int special2(int rs, int rt, int rd, int fn) =>
          (0x1c << 26) | (rs << 21) | (rt << 16) | (rd << 11) | fn;
      final (cpu, _) = run((a) {
        a.li(Reg.t0, 0x10000);
        a.li(Reg.t1, 0x10000);
        a.word(special2(Reg.t0, Reg.t1, Reg.t2, 2)); // mul -> 0x100000000
        a.r(Reg.t0, Reg.t1, 0, 0, 0x18); // mult: hi 1, lo 0
        a.word(special2(Reg.t0, Reg.t1, 0, 0)); // madd: hi 2, lo 0
        a.r(0, 0, Reg.t3, 0, 0x10); // mfhi
        a.word(special2(Reg.t0, Reg.t1, 0, 4)); // msub: hi 1, lo 0
        a.r(0, 0, Reg.t4, 0, 0x10);
        a.r(0, 0, Reg.t5, 0, 0x12);
      });
      expect(cpu.r[Reg.t2], 0);
      expect(cpu.r[Reg.t3], 2);
      expect(cpu.r[Reg.t4], 1);
      expect(cpu.r[Reg.t5], 0);
    });

    test('shifts and rotates', () {
      final (cpu, _) = run((a) {
        a.li(Reg.t0, 0x80000001);
        a.r(0, Reg.t0, Reg.t1, 4, 0x03); // sra -> 0xf8000000
        a.r(0, Reg.t0, Reg.t2, 4, 0x02); // srl -> 0x08000000
        a.r(1, Reg.t0, Reg.t3, 4, 0x02); // rotr by 4 -> 0x18000000
        a.li(Reg.t4, 8);
        a.r(Reg.t4, Reg.t0, Reg.t5, 1, 0x06); // rotrv by 8 -> 0x01800000
        a.r(Reg.t4, Reg.t0, Reg.t6, 0, 0x04); // sllv by 8
      });
      expect(cpu.r[Reg.t1], 0xf8000000.toSigned(32));
      expect(cpu.r[Reg.t2], 0x08000000);
      expect(cpu.r[Reg.t3], 0x18000000);
      expect(cpu.r[Reg.t5], 0x01800000);
      expect(cpu.r[Reg.t6], 0x00000100);
    });

    test('clz and clo', () {
      int clz(int rs, int rd, int fn) =>
          (0x1c << 26) | (rs << 21) | (rd << 16) | fn;
      final (cpu, _) = run((a) {
        a.li(Reg.t0, 0x00f00000);
        a.word(clz(Reg.t0, Reg.t1, 0x20));
        a.word(clz(Reg.t0, Reg.t2, 0x21));
        a.li(Reg.t3, 0);
        a.word(clz(Reg.t3, Reg.t4, 0x20));
      });
      expect(cpu.r[Reg.t1], 8);
      expect(cpu.r[Reg.t2], 0); // the value starts with a zero bit
      expect(cpu.r[Reg.t4], 32);
    });

    test('clz and clo in the special encoding the toolchain emits', () {
      final (cpu, _) = run((a) {
        a.li(Reg.t0, 0x00f00000);
        a.r(Reg.t0, 0, Reg.t1, 0, 0x16); // clz t1, t0
        a.li(Reg.t2, 0xff000000);
        a.r(Reg.t2, 0, Reg.t3, 0, 0x17); // clo t3, t2
        a.r(Reg.zero, 0, Reg.t4, 0, 0x16); // clz of zero is 32
      });
      expect(cpu.r[Reg.t1], 8);
      expect(cpu.r[Reg.t3], 8);
      expect(cpu.r[Reg.t4], 32);
    });

    test('max and min keep the larger or smaller signed operand', () {
      final (cpu, _) = run((a) {
        a.li(Reg.t0, 5);
        a.li(Reg.t1, -3);
        a.r(Reg.t0, Reg.t1, Reg.t2, 0, 0x2c); // max t2, t0, t1
        a.r(Reg.t0, Reg.t1, Reg.t3, 0, 0x2d); // min t3, t0, t1
        a.li(Reg.t4, -7);
        a.li(Reg.t5, -9);
        a.r(Reg.t4, Reg.t5, Reg.t6, 0, 0x2c); // max of two negatives
        a.r(Reg.t4, Reg.t5, Reg.t7, 0, 0x2d); // min of two negatives
      });
      expect(cpu.r[Reg.t2], 5);
      expect(cpu.r[Reg.t3], -3);
      expect(cpu.r[Reg.t6], -7);
      expect(cpu.r[Reg.t7], -9);
    });
  });

  group('bit field operations', () {
    int special3(int rs, int rt, int rd, int sa, int fn) =>
        (0x1f << 26) | (rs << 21) | (rt << 16) | (rd << 11) | (sa << 6) | fn;

    test('ext and ins', () {
      final (cpu, _) = run((a) {
        a.li(Reg.t0, 0x12345678);
        a.word(special3(Reg.t0, Reg.t1, 7, 8, 0x00)); // ext 8 bits at 8
        a.li(Reg.t2, 0);
        a.word(special3(Reg.t0, Reg.t2, 11, 4, 0x04)); // ins at 4, size 8
      });
      expect(cpu.r[Reg.t1], 0x56);
      expect(cpu.r[Reg.t2], 0x780);
    });

    test('seb, seh, wsbh and bitrev', () {
      final (cpu, _) = run((a) {
        a.li(Reg.t0, 0x80);
        a.word(special3(0, Reg.t0, Reg.t1, 0x10, 0x20)); // seb
        a.li(Reg.t2, 0x8000);
        a.word(special3(0, Reg.t2, Reg.t3, 0x18, 0x20)); // seh
        a.li(Reg.t4, 0x11223344);
        a.word(special3(0, Reg.t4, Reg.t5, 0x02, 0x20)); // wsbh
        a.li(Reg.t6, 0x80000001);
        a.word(special3(0, Reg.t6, Reg.t7, 0x0d, 0x20)); // bitrev
      });
      expect(cpu.r[Reg.t1], -128);
      expect(cpu.r[Reg.t3], -32768);
      expect(cpu.r[Reg.t5], 0x22114433);
      expect(cpu.r[Reg.t7], 0x80000001.toSigned(32));
    });
  });

  group('branches', () {
    test('the delay slot runs and jal links past it', () {
      final (cpu, _) = run((a) {
        a.li(Reg.s0, 0);
        a.beq(Reg.zero, Reg.zero, 'target');
        a.addiu(Reg.s0, Reg.s0, 1); // delay slot
        a.addiu(Reg.s0, Reg.s0, 100); // skipped
        a.label('target');
        a.addiu(Reg.s0, Reg.s0, 2);
        a.jalTo('sub');
        a.nop();
        a.jTo('end');
        a.nop();
        a.label('sub');
        a.addiu(Reg.s1, Reg.ra, 0);
        a.jr(Reg.ra);
        a.nop();
      });
      expect(cpu.r[Reg.s0], 3);
      // The link is the address after the delay slot of the jal (word 7).
      expect(cpu.r[Reg.s1], 0x08800000 + 7 * 4);
    });
  });

  group('memory', () {
    test('loads sign-extend and unaligned pairs compose', () {
      final (cpu, mem) = run((a) {
        a.li(Reg.t0, 0x08900000);
        a.li(Reg.t1, 0x11223344);
        a.sw(Reg.t1, 0, Reg.t0);
        a.li(Reg.t2, 0x55667788);
        a.sw(Reg.t2, 4, Reg.t0);
        a.lb(Reg.t3, 0, Reg.t0); // 0x44
        a.sb(Reg.t1, 8, Reg.t0);
        a.li(Reg.t4, 0x80);
        a.sb(Reg.t4, 9, Reg.t0);
        a.lb(Reg.t5, 9, Reg.t0); // -128
        a.lbu(Reg.t6, 9, Reg.t0); // 128
        a.addiu(Reg.t7, Reg.t0, 1);
        a.i(0x22, Reg.t7, Reg.s0, 3); // lwl s0, 3(t7)
        a.i(0x26, Reg.t7, Reg.s0, 0); // lwr s0, 0(t7)
      });
      expect(cpu.r[Reg.t3], 0x44);
      expect(cpu.r[Reg.t5], -128);
      expect(cpu.r[Reg.t6], 128);
      expect(cpu.r[Reg.s0], 0x88112233.toSigned(32));
      expect(mem.read32(0x08900000), 0x11223344);
    });

    test('unaligned merges touch only their own bytes', () {
      final (cpu, mem) = run((a) {
        a.li(Reg.t0, 0x08900000);
        a.li(Reg.t1, 0x11223344);
        a.sw(Reg.t1, 0, Reg.t0); // bytes 44 33 22 11
        a.li(Reg.s0, 0xaabbccdd);
        a.i(0x22, Reg.t0, Reg.s0, 1); // lwl: top bytes become 33 44
        a.li(Reg.s1, 0xaabbccdd);
        a.i(0x26, Reg.t0, Reg.s1, 1); // lwr: low bytes become 33 22 11
        a.sw(Reg.zero, 4, Reg.t0);
        a.li(Reg.s2, 0x55667788);
        a.i(0x2a, Reg.t0, Reg.s2, 5); // swl: bytes 4-5 become 66 55
        a.i(0x2e, Reg.t0, Reg.s2, 5); // swr: bytes 5-7 become 88 77 66
      });
      expect(cpu.r[Reg.s0], 0x3344ccdd.toSigned(32));
      expect(cpu.r[Reg.s1], 0xaa112233.toSigned(32));
      expect(mem.read32(0x08900004), 0x66778866);
    });

    test('unaligned pairs compose at every offset', () {
      final (cpu, mem) = run((a) {
        a.li(Reg.t0, 0x08900000);
        a.li(Reg.t1, 0x11223344);
        a.sw(Reg.t1, 0, Reg.t0);
        a.li(Reg.t2, 0x55667788);
        a.sw(Reg.t2, 4, Reg.t0); // bytes 44 33 22 11 88 77 66 55
        for (var offset = 1; offset <= 3; offset++) {
          final dst = Reg.s0 + offset - 1;
          a.i(0x22, Reg.t0, dst, offset + 3); // lwl at the word end
          a.i(0x26, Reg.t0, dst, offset); // lwr at the word start
        }
        // Store a word at offset 2 of a zeroed destination and read it
        // back through aligned loads.
        a.li(Reg.t3, 0x08900100);
        a.sw(Reg.zero, 0, Reg.t3);
        a.sw(Reg.zero, 4, Reg.t3);
        a.li(Reg.t4, 0xa1b2c3d4);
        a.i(0x2a, Reg.t3, Reg.t4, 5); // swl at the word end
        a.i(0x2e, Reg.t3, Reg.t4, 2); // swr at the word start
      });
      expect(cpu.r[Reg.s0], 0x88112233.toSigned(32));
      expect(cpu.r[Reg.s1], 0x77881122.toSigned(32));
      expect(cpu.r[Reg.s2], 0x66778811.toSigned(32));
      expect(mem.read32(0x08900100), 0xc3d40000);
      expect(mem.read32(0x08900104), 0x0000a1b2);
    });

    test('ll and sc succeed together and fail after a store', () {
      final (cpu, mem) = run((a) {
        a.li(Reg.t0, 0x08900000);
        a.li(Reg.t1, 41);
        a.sw(Reg.t1, 0, Reg.t0);
        a.i(0x30, Reg.t0, Reg.t2, 0); // ll t2
        a.addiu(Reg.t3, Reg.t2, 1);
        a.i(0x38, Reg.t0, Reg.t3, 0); // sc t3 -> 1, stores 42
        a.i(0x30, Reg.t0, Reg.t4, 0); // ll t4
        a.sw(Reg.t1, 4, Reg.t0); // any store clears the link
        a.i(0x38, Reg.t0, Reg.t3, 0); // sc t3 -> 0
        a.addiu(Reg.s0, Reg.t3, 0);
      });
      expect(cpu.r[Reg.t2], 41);
      expect(cpu.r[Reg.s0], 0);
      expect(mem.read32(0x08900000), 42);
    });
  });

  group('fpu', () {
    int cop1(int fmt, int ft, int fs, int fd, int fn) =>
        (0x11 << 26) | (fmt << 21) | (ft << 16) | (fs << 11) | (fd << 6) | fn;

    test('single precision arithmetic and conversion', () {
      final (cpu2, _) = run((a) {
        a.li(Reg.t0, 3);
        a.word((0x11 << 26) | (4 << 21) | (Reg.t0 << 16)); // mtc1 t0, f0
        a.word(cop1(0x14, 0, 0, 1, 0x20)); // cvt.s.w f1, f0 -> 3.0
        a.word(cop1(0x10, 1, 1, 2, 0x02)); // mul.s f2, f1, f1 -> 9.0
        a.word(cop1(0x10, 0, 2, 3, 0x24)); // cvt.w.s f3, f2 -> 9
        a.word((0x11 << 26) | (0 << 21) | (Reg.t1 << 16) | (3 << 11)); // mfc1
        a.li(Reg.t2, 0x40200000); // 2.5f
        a.word((0x11 << 26) | (4 << 21) | (Reg.t2 << 16) | (4 << 11));
        a.word(cop1(0x10, 0, 4, 5, 0x0d)); // trunc.w.s f5, f4 -> 2
        a.word((0x11 << 26) | (0 << 21) | (Reg.t3 << 16) | (5 << 11));
      });
      expect(cpu2.r[Reg.t1], 9);
      expect(cpu2.r[Reg.t3], 2);
    });

    test('compare and conditional branch', () {
      final (cpu, _) = run((a) {
        a.li(Reg.t0, 0x3f800000); // 1.0f
        a.word((0x11 << 26) | (4 << 21) | (Reg.t0 << 16)); // mtc1 -> f0
        a.word((0x11 << 26) | (4 << 21) | (Reg.t0 << 16) | (1 << 11)); // f1
        a.word(cop1(0x10, 1, 0, 0, 0x32)); // c.eq.s f0, f1
        a.word((0x11 << 26) | (8 << 21) | (1 << 16) | 2); // bc1t +2 words
        a.nop();
        a.li(Reg.s0, 111);
        a.li(Reg.s0, 222);
      });
      expect(cpu.r[Reg.s0], 222);
    });

    test('the signaling compare conditions lt and le set the flag', () {
      int bc1(int tf, int offset) =>
          (0x11 << 26) | (8 << 21) | (tf << 16) | (offset & 0xffff);
      final (cpu, _) = run((a) {
        a.li(Reg.s0, 0);
        a.li(Reg.t0, 0x3f800000); // 1.0f
        a.word((0x11 << 26) | (4 << 21) | (Reg.t0 << 16)); // mtc1 -> f0
        a.li(Reg.t0, 0x40000000); // 2.0f
        a.word((0x11 << 26) | (4 << 21) | (Reg.t0 << 16) | (1 << 11)); // f1
        a.word(cop1(0x10, 1, 0, 0, 0x3c)); // c.lt.s f0, f1: true
        a.word(bc1(1, 2)); // bc1t skips the error mark
        a.nop();
        a.li(Reg.s0, 100);
        a.word(cop1(0x10, 0, 1, 0, 0x3e)); // c.le.s f1, f0: false
        a.word(bc1(1, 2)); // bc1t must not skip
        a.nop();
        a.addiu(Reg.s0, Reg.s0, 1);
        a.word(cop1(0x10, 1, 0, 0, 0x3e)); // c.le.s f0, f1: true
        a.word(bc1(0, 2)); // bc1f must not skip
        a.nop();
        a.addiu(Reg.s0, Reg.s0, 2);
      });
      expect(cpu.r[Reg.s0], 3);
    });

    test('double arithmetic through paired single loads and stores', () {
      // This processor has no LDC1 or SDC1 (their encodings belong to
      // the multimedia loads and stores), so doubles move as pairs.
      final (cpu, mem) = run((a) {
        a.li(Reg.t0, 0x08900000);
        a.li(Reg.t1, 0x3ff00000); // 1.0 double, high word
        a.sw(Reg.t1, 4, Reg.t0);
        a.sw(Reg.zero, 0, Reg.t0);
        a.i(0x31, Reg.t0, 0, 0); // lwc1 f0, 0(t0)
        a.i(0x31, Reg.t0, 1, 4); // lwc1 f1, 4(t0)
        a.word(cop1(0x11, 0, 0, 2, 0x00)); // add.d f2, f0, f0 -> 2.0
        a.i(0x39, Reg.t0, 2, 8); // swc1 f2, 8(t0)
        a.i(0x39, Reg.t0, 3, 12); // swc1 f3, 12(t0)
      });
      expect(mem.read32(0x0890000c), 0x40000000);
      expect(mem.read32(0x08900008), 0);
    });
  });

  test('syscall delivers its code field', () {
    final mem = PspMemory();
    final asm = Asm(0x08800000);
    asm.syscall(0x1234);
    asm.label('end');
    asm.jTo('end');
    asm.nop();
    final words = asm.finish();
    for (var i = 0; i < words.length; i++) {
      mem.write32(0x08800000 + i * 4, words[i]);
    }
    final cpu = Allegrex(mem);
    var seen = -1;
    cpu.onSyscall = (code) => seen = code;
    cpu.jumpTo(0x08800000);
    cpu.step();
    expect(seen, 0x1234);
  });

  test('an unimplemented coprocessor instruction stops the step', () {
    final mem = PspMemory();
    mem.write32(0x08800000, (0x12 << 26) | (1 << 21)); // COP2, rs 1
    final cpu = Allegrex(mem);
    cpu.jumpTo(0x08800000);
    expect(cpu.step(), isFalse);
  });
}
