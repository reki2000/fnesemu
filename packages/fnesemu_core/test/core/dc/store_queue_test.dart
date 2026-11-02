import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:test/test.dart';

void main() {
  late DcBus bus;
  late Sh4 cpu;
  const code = 0x0c010000;
  setUp(() {
    bus = DcBus();
    cpu = Sh4(bus)..sr = 0x40000001;
    cpu.pc = code;
    cpu.vbr = 0x0c020000;
    bus.write16(code, 0x0183); // PREF @R1.
    bus.write32(0xff000038, 0x0c);
    bus.write32(0xff00003c, 0x0c);
  });

  test('queue selection and mirrored writes preserve all eight words', () {
    for (var word = 0; word < 16; word++) {
      bus.write32(0xe3fff000 + word * 4, 0x87650000 + word);
    }
    for (final (queueAddress, destination, firstWord) in [
      (0xe0001000, 0x0c001000, 0),
      (0xe000202c, 0x0c002020, 8),
    ]) {
      cpu.r[1] = queueAddress;
      cpu.step();
      for (var i = 0; i < 8; i++) {
        expect(bus.read32(destination + i * 4), 0x87650000 + firstWord + i);
      }
      expect(cpu.t, isTrue);
      expect(cpu.r[1], queueAddress);
      cpu.pc = code;
    }
    // A transfer retains queue contents for another destination.
    cpu.r[1] = 0xe0003000;
    cpu.step();
    expect(bus.read32(0x0c003000), 0x87650000);
  });

  test('quadword stores retain SH-4 high-word-first ordering', () {
    bus.writePair(0xe0000000, 0x11223344, 0x55667788);
    bus.writePair(0xe0000020, 0xaabbccdd, 0xeeff0011);
    bus.transferStoreQueue(0xe0000100);
    bus.transferStoreQueue(0xe0000120);
    expect(bus.read32(0x0c000100), 0x11223344);
    expect(bus.read32(0x0c000104), 0x55667788);
    expect(bus.read32(0x0c000120), 0xaabbccdd);
    expect(bus.read32(0x0c000124), 0xeeff0011);
  });

  test('FMOV quadword instruction fills a queue before PREF', () {
    cpu.fpscr = 0x00140001;
    cpu.fr[0] = 0x12345678;
    cpu.fr[1] = 0x9abcdef0;
    cpu.r[1] = 0xe0000080;
    bus.write16(code, 0xf10a); // FMOV DR0,@R1.
    bus.write16(code + 2, 0x0183);
    cpu.step();
    cpu.step();
    expect(bus.read32(0x0c000080), 0x12345678);
    expect(bus.read32(0x0c000084), 0x9abcdef0);
  });

  test('QACR fields, access widths, write-only queue and failed burst', () {
    bus.write32(0x1f000038, 0xffffffff);
    expect(bus.read32(0xff000038), 0x1c);
    expect(bus.read32(0xff00003c), 0x0c);
    expect(() => bus.read32(0xe0000000), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write8(0xe0000000, 1), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write16(0xe0000000, 1), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read16(0xff000038), throwsA(isA<DcUnsupported>()));
    bus.write32(0xe0000000, 42);
    cpu.r[1] = 0xe0000000;
    expect(() => cpu.step(), throwsA(isA<DcUnsupported>()));
    expect(cpu.pc, code);
    expect(cpu.instructionExecuted, isFalse);
    bus.write32(0xff000038, 0x0c);
    cpu.step();
    expect(bus.read32(0x0c000000), 42);
  });

  test('user queue write and PREF obey SQMD with read/write exception events',
      () {
    cpu.sr = 1;
    bus.write16(code, 0x2122); // MOV.L R2,@R1.
    bus.write16(code + 2, 0x0183);
    cpu.r[1] = 0xe0000080;
    cpu.r[2] = 0x12345678;
    cpu.step();
    cpu.step();
    expect(bus.read32(0x0c000080), 0x12345678);
    bus.write32(0xff000010, 0x200);
    cpu.pc = code;
    cpu.step();
    expect(bus.expevt, 0x100);
    expect(bus.tea, 0xe0000080);
    expect(cpu.spc, code);
    cpu.sr = 1;
    cpu.pc = code + 2;
    cpu.step();
    expect(bus.expevt, 0x0e0);
    expect(cpu.spc, code + 2);
  });

  test('SQ user allowance never permits fetching instructions from P4', () {
    cpu.sr = 0;
    cpu.pc = 0xe0000000;
    cpu.step();
    expect(bus.expevt, 0x0e0);
    expect(bus.tea, 0xe0000000);
  });

  test('SQ protection fault in a call slot saves branch PC and restores PR',
      () {
    bus.write32(0xff000010, 0x200);
    bus.write16(code, 0xb000);
    bus.write16(code + 2, 0x0183);
    cpu.sr = 0;
    cpu.pr = 0x1234;
    cpu.r[1] = 0xe0000000;
    cpu.step();
    cpu.step();
    expect(bus.expevt, 0x0e0);
    expect(cpu.spc, code);
    expect(cpu.pr, 0x1234);
    expect(cpu.inDelaySlot, isFalse);
  });

  test('MMUCR TI self-clears, AT enables translation, and reset clears queues',
      () {
    bus.write32(0xff000010, 0xfffffffe);
    expect(bus.read32(0x1f000010), 0xfcfcff00);
    bus.write32(0xff000010, 1);
    expect(bus.read32(0xff000010), 1);
    bus.write32(0xe0000000, 42);
    cpu.reset();
    expect(bus.read32(0xff000010), 0);
    expect(bus.read32(0xff000038), 0);
    bus.write32(0xff000038, 0x0c);
    bus.transferStoreQueue(0xe0000000);
    expect(bus.read32(0x0c000000), 0);
  });

  test('non-SQ PREF cannot fault or perform reads from unmapped addresses', () {
    cpu.sr = 0;
    for (final address in [0x12345679, 0x80000001, 0xe4000000, 0xffffffff]) {
      cpu.r[1] = address;
      cpu.pc = code;
      cpu.step();
      expect(cpu.pc, code + 2);
      expect(cpu.instructionExecuted, isTrue);
      expect(bus.expevt, 0);
    }
  });
}
