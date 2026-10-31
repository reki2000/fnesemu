import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:test/test.dart';

void main() {
  late DcBus bus;
  late Sh4 cpu;
  const code = 0x0c010000, vector = 0x8c020000;

  void program(List<int> words, [int address = code]) {
    for (var i = 0; i < words.length; i++) {
      bus.write16(address + i * 2, words[i]);
    }
  }

  setUp(() {
    bus = DcBus();
    cpu = Sh4(bus)..sr = 0x40000000;
    cpu.pc = code;
    cpu.vbr = vector;
  });

  test('SR banks R0-R7 using MD and RB, leaving R8-R15 shared', () {
    cpu.r[0] = 10;
    cpu.bank[0] = 20;
    cpu.r[8] = 30;
    cpu.sr = 0x60000000;
    expect(cpu.r[0], 20);
    expect(cpu.bank[0], 10);
    cpu.sr = 0x20000000; // User mode always selects bank 0.
    expect(cpu.r[0], 10);
    expect(cpu.bank[0], 20);
    expect(cpu.r[8], 30);
    cpu.sr = 0x60000000;
    expect(cpu.r[0], 20);
  });

  test('LDC SR masks reserved bits and STC reads the active SR', () {
    program([0x480e, 0x0902]);
    cpu.r[8] = 0xffffffff;
    cpu.step();
    expect(cpu.sr, 0x700083f3);
    cpu.step();
    expect(cpu.r[9], 0x700083f3);
  });

  test('bank register transfers address the opposite bank', () {
    program([0x418e, 0x0282, 0x480e, 0x0382]);
    cpu.r[0] = 0x1111;
    cpu.r[1] = 0x2222;
    cpu.r[8] = 0x60000000;
    cpu.step();
    cpu.step();
    expect(cpu.r[2], 0x2222);
    cpu.step();
    expect(cpu.r[0], 0x2222);
    cpu.step();
    expect(cpu.r[3], 0x1111);
  });

  for (final (load, store, name) in [
    (0x481e, 0x0912, 'GBR'),
    (0x482e, 0x0922, 'VBR'),
    (0x483e, 0x0932, 'SSR'),
    (0x484e, 0x0942, 'SPC'),
    (0x48fa, 0x09fa, 'DBR'),
  ]) {
    test('$name register and memory transfers round trip', () {
      program([load, store]);
      cpu.r[8] = 0x89abcdef;
      cpu.step();
      cpu.step();
      expect(cpu.r[9], 0x89abcdef);
      // Memory forms use the same selector, with distinct DBR encodings.
      final memoryStore = name == 'DBR' ? 0x4af2 : (store & 0xff) | 0x4a01;
      final memoryLoad = name == 'DBR' ? 0x4af6 : (load & 0xff) - 7 | 0x4a00;
      program([memoryStore, memoryLoad, store]);
      cpu.pc = code;
      cpu.r[10] = 0x0c030004;
      cpu.step();
      expect(cpu.r[10], 0x0c030000);
      expect(bus.read32(cpu.r[10]), 0x89abcdef);
      bus.write32(cpu.r[10], 0x12345678);
      cpu.step();
      expect(cpu.r[10], 0x0c030004);
      cpu.step();
      expect(cpu.r[9], 0x12345678);
    });
  }

  test('LDC.L SR with shared source updates its pointer and banks registers',
      () {
    program([0x4807]);
    cpu.r[8] = 0x0c030000;
    cpu.r[0] = 7;
    cpu.bank[0] = 9;
    bus.write32(cpu.r[8], 0x60000000);
    cpu.step();
    expect(cpu.r[8], 0x0c030004);
    expect(cpu.r[0], 9);
    expect(cpu.bank[0], 7);
  });

  test('bank-changing LDC.L SR increments the source bank before loading SR',
      () {
    program([0x4107]);
    cpu.r[1] = 0x0c030000;
    bus.write32(cpu.r[1], 0x60000000);
    cpu.bank[1] = 42;
    cpu.step();
    expect(cpu.r[1], 42);
    expect(cpu.bank[1], 0x0c030004);
    expect(cpu.sr, 0x60000000);
    expect(cpu.pc, code + 2);
  });

  test(
      'LDC.L SR updates the old source bank for every low register in both directions',
      () {
    for (final (from, to) in [
      (0x40000000, 0x60000000),
      (0x60000000, 0x40000000),
      (0x60000000, 0x20000000),
    ]) {
      for (var register = 0; register < 8; register++) {
        cpu.reset();
        cpu.sr = from;
        cpu.pc = code;
        cpu.r[register] = 0x0c030000;
        cpu.bank[register] = 100 + register;
        cpu.r[8] = 42;
        bus.write32(0x0c030000, to);
        program([0x4007 | (register << 8)]);
        cpu.step();
        expect(cpu.sr, to);
        expect(cpu.r[register], 100 + register);
        expect(cpu.bank[register], 0x0c030004);
        expect(cpu.r[8], 42);
        expect(cpu.pc, code + 2);
      }
    }
  });

  test('LDC.L SR load failure preserves both banks and SR', () {
    program([0x4107]);
    cpu.r[1] = 0x005f8010;
    cpu.bank[1] = 42;
    expect(cpu.step, throwsA(isA<DcUnsupported>()));
    expect(cpu.sr, 0x40000000);
    expect(cpu.r[1], 0x005f8010);
    expect(cpu.bank[1], 42);
    expect(cpu.pc, code);
  });

  test('TRAPA, handler inspection and RTE restore user mode and its bank', () {
    program([0xc37f, 0xe92a]);
    program([0x002b, 0xe007], vector + 0x100);
    cpu.sr = 1;
    cpu.r[0] = 11;
    cpu.bank[0] = 22;
    cpu.r[15] = 0x0cfffffc;
    cpu.step();
    expect(cpu.spc, code + 2);
    expect(cpu.ssr, 1);
    expect(cpu.sgr, 0x0cfffffc);
    expect(cpu.r[0], 22);
    expect(cpu.pc, vector + 0x100);
    expect(bus.read32(0xff000020), 0x1fc);
    expect(bus.read32(0x1f000024), 0x160);
    cpu.step();
    expect(cpu.sr, 1);
    expect(cpu.pc, vector + 0x102);
    expect(cpu.r[0], 11);
    // Fetch the kernel slot with old MD, but use restored registers and SR.
    cpu.step();
    expect(cpu.pc, code + 2);
    expect(cpu.r[0], 7);
    expect(cpu.bank[0], 22);
    cpu.step();
    expect(cpu.r[9], 42);
  });

  for (final op in [0x410e, 0x0102, 0x4107, 0x4103, 0x002b, 0x001b, 0x0038]) {
    test('user privileged instruction ${op.toRadixString(16)} traps', () {
      program([op]);
      cpu.sr = 0;
      cpu.r[1] = 0x005f8010;
      cpu.step();
      expect(cpu.pc, vector + 0x100);
      expect(cpu.spc, code);
      expect(cpu.ssr, 0);
      expect(bus.expevt, 0x180);
      expect(cpu.bank[1], 0x005f8010);
    });
  }

  test('GBR transfers remain accessible in user mode', () {
    program([0x411e, 0x0212]);
    cpu.sr = 0;
    cpu.r[1] = 0x12345678;
    cpu.step();
    cpu.step();
    expect(cpu.r[2], 0x12345678);
    expect(bus.expevt, 0);
  });

  for (final op in [0xfffd, 0xc301, 0x410e, 0x4107, 0x002b]) {
    test('slot exception ${op.toRadixString(16)} saves branch PC and old PR',
        () {
      program([0xb002, op]);
      cpu.pr = 0x12345678;
      cpu.step();
      cpu.step();
      expect(cpu.spc, code);
      expect(cpu.pr, 0x12345678);
      expect(bus.expevt, 0x1a0);
      expect(cpu.inDelaySlot, isFalse);
    });
  }

  test('documented undefined instruction FFFD traps; unimplemented ISA stops',
      () {
    program([0xfffd]);
    cpu.step();
    expect(bus.expevt, 0x180);
    expect(cpu.spc, code);
    cpu.pc = code;
    program([0xffff]);
    expect(cpu.step, throwsA(isA<DcUnsupported>()));
  });

  test('general exception with BL set performs a manual reset retaining RAM',
      () {
    program([0xc300]);
    cpu.sr = 0x50000000;
    cpu.step();
    expect(cpu.pc, 0xa0000000);
    expect(cpu.sr, 0x700000f0);
    expect(cpu.vbr, 0);
    expect(bus.expevt, 0x20);
    expect(bus.read16(code), 0xc300);
  });

  for (final (op, event) in [(0x6125, 0xe0), (0x2125, 0x100)]) {
    test('misaligned access $event saves TEA without completing transfer', () {
      program([op]);
      cpu.r[1] = 0x0c030003;
      cpu.r[2] = 0x0c030001;
      bus.pteh = 0x55;
      cpu.step();
      expect(bus.expevt, event);
      expect(bus.tea, 0x0c030001);
      expect(bus.pteh, 0x0c030055);
      expect(cpu.spc, code);
      expect(bus.read32(0x0c030000), 0);
      expect(cpu.bank[1], 0x0c030003);
      expect(cpu.bank[2], 0x0c030001);
    });
  }

  test('user instruction fetch and data access reject privileged aliases', () {
    cpu.sr = 0;
    cpu.pc = 0x8c010000;
    cpu.step();
    expect(bus.expevt, 0xe0);
    expect(bus.tea, 0x8c010000);
    expect(cpu.spc, 0x8c010000);
    cpu.sr = 0;
    cpu.pc = code;
    program([0x6122]);
    cpu.r[2] = 0x1f000024;
    cpu.step();
    expect(bus.expevt, 0xe0);
    expect(bus.tea, 0x1f000024);
  });

  test('RTE slot data access uses restored user MD', () {
    program([0x002b, 0x6122]);
    cpu.ssr = 0;
    cpu.spc = code + 8;
    cpu.r[2] = 0x8c030000;
    cpu.step();
    cpu.step();
    expect(bus.expevt, 0xe0);
    expect(cpu.spc, code);
    expect(bus.tea, 0x8c030000);
  });

  test('fault in a branch slot saves the branch PC and inhibits PR update', () {
    program([0xb002, 0x6126]);
    cpu.r[2] = 0x0c030001;
    cpu.pr = 0x11223344;
    cpu.step();
    cpu.step();
    expect(cpu.spc, code);
    expect(cpu.pr, 0x11223344);
    expect(bus.expevt, 0xe0);
  });
}
