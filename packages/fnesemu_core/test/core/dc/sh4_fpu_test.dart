import 'package:fnesemu_core/src/core/dc/bus.dart';
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

  for (final (load, store, push, pop, status) in [
    (0x485a, 0x095a, 0x4f52, 0x4f56, false),
    (0x486a, 0x096a, 0x4f62, 0x4f66, true),
  ]) {
    test('FPUL/FPSCR register and stack transfers status=$status', () {
      cpu.r[8] = status ? 0xffffffff : 0x89abcdef;
      cpu.r[15] = data + 4;
      execute(load);
      execute(store);
      expect(cpu.r[9], status ? 0x3fffff : 0x89abcdef);
      execute(push);
      expect(bus.read32(data), cpu.r[9]);
      bus.write32(data, 0x12345678);
      execute(pop);
      expect(cpu.r[15], data + 4);
      execute(store);
      expect(cpu.r[9], status ? 0x345678 : 0x12345678);
    });
  }

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
      'quadword transfers preserve SH-4 word order and use XD for odd operands',
      () {
    cpu.fpscr = 0x100000;
    cpu.fr[2] = 0x11223344;
    cpu.fr[3] = 0x55667788;
    cpu.r[8] = data;
    cpu.r[9] = data;
    execute(0xf82a);
    expect(bus.read32(data), 0x11223344);
    expect(bus.read32(data + 4), 0x55667788);
    execute(0xf198); // Odd n selects XD0.
    expect(cpu.xf[0], 0x11223344);
    expect(cpu.xf[1], 0x55667788);
    execute(0xf41c); // XD0 to DR4.
    expect(cpu.fr[4], 0x11223344);
    expect(cpu.fr[5], 0x55667788);
  });

  test('single arithmetic, FSTS/FLDS, FLOAT and FTRC execute end to end', () {
    cpu.fpscr = 0;
    cpu.fpul = 3;
    execute(0xf22d);
    expect(cpu.fr[2], 0x40400000);
    execute(0xf39d); // FLDI1 FR3.
    execute(0xf230);
    expect(cpu.fr[2], 0x40800000);
    execute(0xf232);
    execute(0xf23d);
    expect(cpu.fpul, 4);
    execute(0xf40d);
    expect(cpu.fr[4], 4);
    execute(0xf21d);
    expect(cpu.fpul, 0x40800000);
    execute(0xf24d);
    expect(cpu.fr[2], 0xc0800000);
    execute(0xf25d);
    expect(cpu.fr[2], 0x40800000);
    execute(0xf26d);
    expect(cpu.fr[2], 0x40000000);
  });

  test('double arithmetic uses even FR high/low pairs', () {
    cpu.fpscr = 0x80000;
    cpu.fr[0] = 0x3ff00000;
    cpu.fr[1] = 0;
    cpu.fr[2] = 0x40000000;
    cpu.fr[3] = 0;
    execute(0xf020);
    expect(cpu.fr[0], 0x40080000);
    expect(cpu.fr[1], 0);
    execute(0xf00d); // Raw transfer remains available in double mode.
    expect(cpu.fr[0], cpu.fpul);
  });

  test(
      'unconditional O/U/I trap leaves destination unchanged on exact arithmetic',
      () {
    cpu.fpscr = 0x80; // Enable I.
    cpu.fr[1] = cpu.fr[2] = 0x3f800000;
    execute(0xf120);
    expect(cpu.fr[1], 0x3f800000);
    expect(bus.expevt, 0x120);
    expect(cpu.spc, code);
    expect(cpu.instructionExecuted, isFalse);
    expect(cpu.fpscr & 0x3f000, 0);
  });

  test('FPU flags are sticky while causes refresh each arithmetic instruction',
      () {
    cpu.fpscr = 0;
    cpu.fr[1] = 0x3f800000;
    cpu.fr[2] = 0;
    execute(0xf123);
    expect(cpu.fr[1], 0x7f800000);
    expect(cpu.fpscr & 0x3f000, 0x8000);
    expect(cpu.fpscr & 0x7c, 0x20);
    cpu.fr[1] = cpu.fr[2] = 0x3f800000;
    execute(0xf120);
    expect(cpu.fpscr & 0x3f000, 0);
    expect(cpu.fpscr & 0x7c, 0x20);
  });

  test('enabled invalid comparison preserves T and unmodified raw operands',
      () {
    cpu.fpscr = 0x800; // Enable V.
    cpu.fr[1] = 0x7fc00001;
    cpu.fr[2] = 0;
    cpu.t = true;
    execute(0xf124);
    expect(cpu.t, isTrue);
    expect(cpu.fr[1], 0x7fc00001);
    expect(bus.expevt, 0x120);
    expect(cpu.fpscr & 0x10040, 0x10040);
  });

  for (final op in [0xf120, 0xf128, 0x485a, 0x096a]) {
    test('SR.FD disables FPU opcode ${op.toRadixString(16)} before effects',
        () {
      cpu.sr |= 0x8000;
      cpu.fr[1] = 0x12345678;
      cpu.r[8] = data;
      execute(op);
      expect(bus.expevt, 0x800);
      expect(cpu.fr[1], 0x12345678);
      expect(cpu.r[8], data);
    });
  }

  test('FPU disable in a call slot saves branch PC and restores old PR', () {
    cpu.sr |= 0x8000;
    bus.write16(code, 0xb002);
    bus.write16(code + 2, 0xf120);
    cpu.pc = code;
    cpu.pr = 42;
    cpu.step();
    cpu.step();
    expect(bus.expevt, 0x820);
    expect(cpu.spc, code);
    expect(cpu.pr, 42);
  });

  test('quadword store alignment exception is atomic', () {
    cpu.fpscr = 0x100000;
    cpu.fr[2] = 1;
    cpu.fr[3] = 2;
    cpu.r[8] = data + 4;
    execute(0xf82a);
    expect(bus.expevt, 0x100);
    expect(bus.read32(data + 4), 0);
    expect(bus.read32(data + 8), 0);
    expect(cpu.r[8], data + 4);
  });

  test('FIPR and FTRV read complete vectors before writing their results', () {
    cpu.fpscr = 0;
    for (var i = 0; i < 4; i++) {
      cpu.fr[i] = 0x3f800000;
      cpu.fr[4 + i] = 0x40000000;
      for (var j = 0; j < 4; j++) {
        cpu.xf[i + j * 4] = i == j ? 0x3f800000 : 0;
      }
    }
    execute(0xf4ed); // FIPR FV0,FV4: 1*2 four times = 8.
    expect(cpu.fr[7], 0x41000000);
    expect(cpu.fpscr & 0x1004, 0x1004);
    final before = cpu.fr.sublist(4, 8);
    execute(0xf5fd); // FTRV XMTRX,FV4, with identity matrix.
    expect(cpu.fr.sublist(4, 8), before);
    cpu.fpscr = 0x800; // FTRV traps on enabled V even for finite exact results.
    execute(0xf5fd);
    expect(cpu.fr.sublist(4, 8), before);
    expect(bus.expevt, 0x120);
  });

  test('FSCA quadrant endpoints and FSRRA special values update inexact flags',
      () {
    cpu.fpscr = 0;
    cpu.fpul = 0x4000;
    execute(0xf2fd);
    expect(cpu.fr[2], 0x3f800000);
    expect(cpu.fr[3], 0);
    expect(cpu.fpscr & 0x1004, 0x1004);
    cpu.fr[2] = 0x40800000;
    execute(0xf27d);
    expect(cpu.fr[2], 0x3f000000);
    expect(cpu.fpscr & 0x1004, 0x1004);
    cpu.fr[2] = 0x80000000;
    execute(0xf27d);
    expect(cpu.fr[2], 0xff800000);
    expect(cpu.fpscr & 0x8020, 0x8020);
  });

  test('FCNVSD and FCNVDS round trip FPUL through an even double register', () {
    cpu.fpscr = 0x80000;
    cpu.fpul = 0x3fc00000;
    execute(0xf4ad);
    expect(cpu.fr[4], 0x3ff80000);
    expect(cpu.fr[5], 0);
    execute(0xf4bd);
    expect(cpu.fpul, 0x3fc00000);
  });

  test('FPU denormal error is unconditional and leaves destination unchanged',
      () {
    cpu.fpscr = 0;
    cpu.fr[1] = 0x3f800000;
    cpu.fr[2] = 1;
    execute(0xf120);
    expect(bus.expevt, 0x120);
    expect(cpu.fpscr & 0x3f000, 0x20000);
    expect(cpu.fpscr & 0x7c, 0);
    expect(cpu.fr[1], 0x3f800000);
  });

  test('raw moves and sign operations preserve FPSCR cause and sticky flags',
      () {
    cpu.fpscr = 0x3107c;
    cpu.fr[2] = 0xffc01234;
    execute(0xf12c);
    execute(0xf15d);
    expect(cpu.fr[1], 0x7fc01234);
    execute(0xf14d);
    expect(cpu.fr[1], 0xffc01234);
    expect(cpu.fpscr, 0x3107c);
  });

  test(
      'quadword read fault preserves floating registers and postincrement source',
      () {
    cpu.fpscr = 0x100000;
    cpu.xf[0] = 123;
    cpu.xf[1] = 456;
    cpu.r[9] = data + 4;
    execute(0xf199);
    expect(bus.expevt, 0xe0);
    expect(cpu.r[9], data + 4);
    expect(cpu.xf[0], 123);
    expect(cpu.xf[1], 456);
  });

  test('matrix transform uses XF column-major order and saves all input lanes',
      () {
    cpu.fpscr = 0;
    const integers = [
      0x3f800000,
      0x40000000,
      0x40400000,
      0x40800000,
      0x40a00000,
      0x40c00000,
      0x40e00000,
      0x41000000,
      0x41100000,
      0x41200000,
      0x41300000,
      0x41400000,
      0x41500000,
      0x41600000,
      0x41700000,
      0x41800000,
    ];
    cpu.xf.setAll(0, integers);
    cpu.fr.setAll(4, integers.take(4));
    execute(0xf5fd);
    expect(
        cpu.fr.sublist(4, 8), [0x42b40000, 0x42c80000, 0x42dc0000, 0x42f00000]);
    expect(cpu.xf, integers);
  });
}
