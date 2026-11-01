import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:test/test.dart';

void main() {
  late DcBus bus;
  late Sh4 cpu;
  const start = 0x8c010000;
  void program(List<int> words) {
    cpu.pc = start;
    for (var i = 0; i < words.length; i++) {
      bus.write16(start + i * 2, words[i]);
    }
  }

  setUp(() {
    bus = DcBus();
    cpu = Sh4(bus);
  });

  test('reset establishes documented PC, SR and VBR', () {
    expect(cpu.pc, 0xa0000000);
    expect(cpu.sr, 0x700000f0);
    expect(cpu.vbr, 0);
    expect(cpu.inDelaySlot, isFalse);
  });

  test('signed immediate arithmetic wraps at 32 bits and preserves T', () {
    program([0x0018, 0xe1ff, 0x7101, 0x71ff]);
    cpu.step();
    cpu.step();
    expect(cpu.r[1], 0xffffffff);
    cpu.step();
    expect(cpu.r[1], 0);
    cpu.step();
    expect(cpu.r[1], 0xffffffff);
    expect(cpu.t, isTrue);
  });

  test('signed and unsigned comparisons differ at the sign boundary', () {
    program([0x3122, 0x3123, 0x3126, 0x3127]);
    cpu.r[1] = 0xffffffff;
    cpu.r[2] = 1;
    for (final expected in [true, false, true, false]) {
      cpu.step();
      expect(cpu.t, expected);
    }
  });

  for (final (op, left, right, expected) in [
    (0x312c, 0xffffffff, 2, 1), // ADD.
    (0x3128, 0, 1, 0xffffffff), // SUB.
    (0x2129, 0x12345678, 0xff00ff00, 0x12005600), // AND.
    (0x212a, 0x12345678, 0xff00ff00, 0xed34a978), // XOR.
    (0x212b, 0x12345678, 0xff00ff00, 0xff34ff78), // OR.
    (0x6127, 0, 0x12345678, 0xedcba987), // NOT.
    (0x612b, 0, 0x80000000, 0x80000000), // NEG wraps.
    (0x612c, 0, 0xffffff80, 0x80), // EXTU.B.
    (0x612d, 0, 0xffff8000, 0x8000), // EXTU.W.
    (0x612e, 0, 0x00000080, 0xffffff80), // EXTS.B.
    (0x612f, 0, 0x00008000, 0xffff8000), // EXTS.W.
  ]) {
    test('integer operation ${op.toRadixString(16)} preserves T', () {
      program([op]);
      cpu.r[1] = left;
      cpu.r[2] = right;
      cpu.t = true;
      cpu.step();
      expect(cpu.r[1], expected);
      expect(cpu.t, isTrue);
    });
  }

  test('PR transfers and MOVT use their architectural register fields', () {
    program([0x412a, 0x022a, 0x0018, 0x0329, 0x0008, 0x0429]);
    cpu.r[1] = 0x12345678;
    for (var i = 0; i < 6; i++) {
      cpu.step();
    }
    expect(cpu.pr, 0x12345678);
    expect(cpu.r[2], 0x12345678);
    expect(cpu.r[3], 1);
    expect(cpu.r[4], 0);
  });

  test('negative branch displacement uses the branch address', () {
    program([0xaffd, 0x0009]);
    cpu.step();
    cpu.step();
    expect(cpu.pc, start - 2);
  });

  test('PC-relative loads align longword literals and sign extend words', () {
    program([0x9102, 0xd202, 0xc703, 0xff80, 0, 0, 0x5678, 0x1234]);
    cpu.step();
    expect(cpu.r[1], 0); // PC + 4 + 2 * 2 = start + 8.
    cpu.step();
    expect(cpu.r[2], 0x12345678);
    cpu.step();
    expect(cpu.r[0], start + 20);
    cpu.pc = start;
    bus.write16(start, 0x9101);
    cpu.step();
    expect(cpu.r[1], 0xffffff80);
  });

  test('loads sign extend and postincrement only when registers differ', () {
    program([0x6124, 0x6325, 0x6226]);
    cpu.r[2] = 0x8c020000;
    bus.write32(cpu.r[2], 0x00800080);
    cpu.step();
    expect(cpu.r[1], 0xffffff80);
    expect(cpu.r[2], 0x8c020001);
    cpu.r[2]++;
    cpu.step();
    expect(cpu.r[3], 0x80);
    expect(cpu.r[2], 0x8c020004);
    bus.write32(cpu.r[2], 0x12345678);
    cpu.step();
    expect(cpu.r[2], 0x12345678);
  });

  test('predecrement store uses original source when registers alias', () {
    program([0x2226]);
    cpu.r[2] = 0x8c020004;
    cpu.step();
    expect(cpu.r[2], 0x8c020000);
    expect(bus.read32(0x8c020000), 0x8c020004);
  });

  test('failed load and predecrement store do not alter registers or PC', () {
    program([0x6126, 0x2126]);
    cpu.r[1] = 0x12345678;
    cpu.r[2] = 0x005f8010;
    expect(cpu.step, throwsA(isA<DcUnsupported>()));
    expect(cpu.r[1], 0x12345678);
    expect(cpu.r[2], 0x005f8010);
    expect(cpu.pc, start);
    cpu.pc += 2;
    cpu.r[1] = 0x005f8014;
    expect(cpu.step, throwsA(isA<DcUnsupported>()));
    expect(cpu.r[1], 0x005f8014);
    expect(cpu.pc, start + 2);
  });

  test('BSR and RTS execute one separately stepped slot', () {
    program([0xb002, 0x7101, 0xe22a, 0x0009, 0x000b, 0x7102]);
    cpu.step();
    expect(cpu.pr, start + 4);
    expect(cpu.pc, start + 2);
    expect(cpu.inDelaySlot, isTrue);
    cpu.step();
    expect(cpu.r[1], 1);
    expect(cpu.pc, start + 8);
    cpu.step();
    cpu.step();
    expect(cpu.pc, start + 4);
    expect(cpu.r[1], 3);
    cpu.step();
    expect(cpu.r[2], 42);
  });

  test('jump captures its target before the slot changes the register', () {
    program([0x412b, 0xe100]);
    cpu.r[1] = start + 0x20;
    cpu.step();
    cpu.step();
    expect(cpu.pc, start + 0x20);
    expect(cpu.r[1], 0);
  });

  for (final (op, flag, taken, delayed) in [
    (0x8902, true, true, false),
    (0x8902, false, false, false),
    (0x8b02, false, true, false),
    (0x8b02, true, false, false),
    (0x8d02, true, true, true),
    (0x8d02, false, false, true),
    (0x8f02, false, true, true),
    (0x8f02, true, false, true),
  ]) {
    test('conditional branch ${op.toRadixString(16)} T=$flag', () {
      program([op, 0x0018]);
      cpu.t = flag;
      cpu.step();
      if (delayed) {
        expect(cpu.pc, start + 2);
        expect(cpu.inDelaySlot, isTrue);
        cpu.step();
      }
      expect(cpu.pc, start + (taken ? 8 : (delayed ? 4 : 2)));
    });
  }

  for (final op in [0xa000, 0x8900, 0x000b, 0x412b, 0x9100, 0xd100, 0xc700]) {
    test('prohibited delay-slot instruction ${op.toRadixString(16)} traps', () {
      program([0xa002, op]);
      cpu.sr = 0x60000000;
      cpu.vbr = start + 0x1000;
      cpu.step();
      final before = cpu.r.toList();
      cpu.step();
      expect(cpu.pc, start + 0x1100);
      expect(cpu.spc, start);
      expect(bus.expevt, 0x1a0);
      expect(cpu.inDelaySlot, isFalse);
      expect(cpu.r, before);
    });
  }

  test('unsupported slot preserves pending branch and reset clears it', () {
    program([0xa002, 0xffff]);
    cpu.step();
    expect(cpu.step, throwsA(isA<DcUnsupported>()));
    bus.write16(start + 2, 0x0009);
    cpu.step();
    expect(cpu.pc, start + 8);
    cpu.reset();
    expect(cpu.inDelaySlot, isFalse);
  });

  test('independent counted loop writes a result to RAM', () {
    // MOV #5,R1; MOV #0,R0; ADD R1,R0; DT R1; BF loop;
    // MOV.L R0,@R2. The expected sum is 5 + 4 + 3 + 2 + 1.
    program([0xe105, 0xe000, 0x301c, 0x4110, 0x8bfc, 0x2202]);
    cpu.r[2] = 0x8c020000;
    var instructions = 0;
    while (cpu.pc != start + 12 && instructions < 100) {
      cpu.step();
      instructions++;
    }
    expect(instructions, 18);
    expect(bus.read32(0x8c020000), 15);
    expect(cpu.pc, start + 12);
  });
}
