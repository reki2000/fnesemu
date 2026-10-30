import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:test/test.dart';

void main() {
  late DcBus bus;
  late Sh4 cpu;
  const code = 0x0c010000, vector = 0x0c020000;
  setUp(() {
    bus = DcBus();
    cpu = Sh4(bus)
      ..sr = 0x40000000
      ..pc = code
      ..vbr = vector;
    bus.write16(code, 0x0009);
    bus.write16(code + 2, 0x0009);
  });

  void underflow(int channel) {
    bus.write32(0xffd8000c + channel * 12, 0);
    bus.write16(0xffd80010 + channel * 12, 0x20);
    bus.write8(0xffd80004, bus.read8(0xffd80004) | (1 << channel));
    bus.tmu.tickPeripheralClocks(4);
  }

  test('INTC register widths, reset, field masks and aliases', () {
    expect(bus.read16(0xffd00000), 0x8000);
    for (final (offset, expected) in [
      (0, 0xc380),
      (4, 0xffff),
      (8, 0xfff0),
      (12, 0xffff),
    ]) {
      bus.write16(0xffd00000 + offset, 0xffff);
      expect(bus.read16(0x1fd00000 + offset), expected);
      expect(
          () => bus.read32(0xffd00000 + offset), throwsA(isA<DcUnsupported>()));
      expect(() => bus.write8(0xffd00000 + offset, 0),
          throwsA(isA<DcUnsupported>()));
      expect(
          () => bus.read16(0xdfd00000 + offset), throwsA(isA<DcUnsupported>()));
    }
    cpu.reset();
    expect(bus.read16(0xffd00000), 0x8000);
    expect(bus.read16(0xffd00004), 0);
    expect(bus.read16(0xffd00008), 0);
    expect(bus.read16(0xffd0000c), 0);
  });

  for (var channel = 0; channel < 3; channel++) {
    test('TMU$channel stays pending while masked and enters with its event',
        () {
      underflow(channel);
      cpu.step();
      expect(cpu.pc, code + 2);
      expect(cpu.instructionExecuted, isTrue);
      bus.write16(0xffd00004, 9 << (12 - channel * 4));
      cpu.sr = 0x40000090;
      cpu.step();
      expect(cpu.pc, code + 4);
      cpu.sr = 0x40000080;
      cpu.step();
      expect(cpu.pc, vector + 0x600);
      expect(cpu.spc, code + 4);
      expect(bus.intevt, 0x400 + channel * 0x20);
      expect(cpu.instructionExecuted, isFalse);
      expect(bus.tmu.interruptPending(channel), isTrue);
    });
  }

  for (final (enable, event) in [(0x40, 0x580), (2, 0x5a0)]) {
    test('refresh event $event honors priority, IMASK and CPU entry', () {
      bus.bsc.write(28, 2, 0xa508 | enable);
      bus.bsc.write(36, 2, 0xa501);
      bus.bsc.write(40, 2, 0xa7ff);
      bus.bsc.tickBusClocks(4);
      cpu.step();
      expect(cpu.pc, code + 2);
      bus.write16(0xffd00008, 0x900);
      expect(bus.intc.pending(6, bus.tmu, bsc: bus.bsc), (9, 0x2c0));
      expect(bus.intc.pending(15, bus.tmu, bsc: bus.bsc), (9, event));
      cpu.sr = 0x40000090;
      cpu.step();
      expect(cpu.pc, code + 4);
      cpu.sr = 0x40000080;
      cpu.step();
      expect(cpu.pc, vector + 0x600);
      expect(cpu.spc, code + 4);
      expect(bus.intevt, event);
      expect(bus.bsc.interruptEvent, event);
      bus.bsc.write(28, 2, 0xa508 | enable);
      expect(bus.bsc.interruptEvent, 0);
    });
  }

  test('highest priority wins, default order breaks ties, IRL wins equal TMU',
      () {
    for (var channel = 0; channel < 3; channel++) {
      underflow(channel);
    }
    bus.write16(0xffd00004, 0x4780);
    expect(bus.intc.pending(15, bus.tmu), (8, 0x440));
    bus.write16(0xffd00004, 0x8880);
    expect(bus.intc.pending(15, bus.tmu), (8, 0x400));
    expect(bus.intc.pending(7, bus.tmu), (8, 0x2e0));
    expect(bus.intc.pending(8, bus.tmu), (8, 0x400));
  });

  test('independent IRL mode uses active-low pin levels and fixed priorities',
      () {
    bus.write16(0xffd00000, 0x80);
    for (final (pins, priority, event) in [
      (14, 13, 0x240),
      (13, 10, 0x2a0),
      (11, 7, 0x300),
      (7, 4, 0x360),
      (0, 13, 0x240),
      (15, 0, 0),
    ]) {
      expect(bus.intc.pending(pins, bus.tmu), (priority, event));
    }
  });

  test(
      'TMU request waits for branch slot and retriggers until guest clears UNF',
      () {
    bus.write16(code, 0xa000);
    cpu.step();
    underflow(0);
    bus.write16(0xffd00004, 0xf000);
    cpu.step();
    expect(cpu.pc, code + 4);
    cpu.step();
    expect(bus.intevt, 0x400);
    bus.write16(vector + 0x600, 0x002b); // RTE.
    bus.write16(vector + 0x602, 0x0009);
    cpu.step();
    cpu.step();
    expect(cpu.pc, code + 4);
    cpu.step();
    expect(cpu.pc, vector + 0x600);
    // The guest handler clears UNF with MOV.W R1,@R2.
    bus.write16(vector + 0x600, 0x2211);
    cpu.r[1] = 0x20;
    cpu.r[2] = 0xffd80010;
    cpu.step();
    expect(bus.tmu.interruptPending(0), isFalse);
  });

  test(
      'NMI edge latches despite IMASK, is consumed once, and preserves pin level',
      () {
    cpu.sr = 0x400000f0;
    bus.intc.nmiHigh = false;
    expect(bus.read16(0xffd00000), 0);
    cpu.step();
    expect(bus.intevt, 0x1c0);
    expect(cpu.ssr, 0x400000f0);
    expect(cpu.spc, code);
    expect(bus.intc.pending(15, bus.tmu), (0, 0));
    cpu.reset();
    expect(bus.intc.nmiHigh, isFalse);
    expect(bus.intc.pending(15, bus.tmu), (0, 0));
  });

  test('NMI block override admits pending edge and clears NMIB on acceptance',
      () {
    cpu.sr = 0x50000000;
    bus.intc.nmiHigh = false;
    cpu.step();
    expect(cpu.pc, code + 2);
    bus.write16(0xffd00000, 0x200);
    cpu.step();
    expect(bus.intevt, 0x1c0);
    expect(bus.read16(0xffd00000) & 0x200, 0);
  });

  test('rising edge selection and MAI hold maskable requests while NMI is low',
      () {
    bus.write16(0xffd00000, 0x4100);
    cpu.irlPins = 0;
    bus.intc.nmiHigh = false;
    cpu.step();
    expect(cpu.pc, code + 2);
    expect(bus.intc.pending(0, bus.tmu), (0, 0));
    bus.intc.nmiHigh = true;
    cpu.step();
    expect(bus.intevt, 0x1c0);
    expect(bus.intc.pending(0, bus.tmu), (15, 0x200));
  });

  test('NMI waits for the delay slot and precedes a maximum-level TMU', () {
    bus.write16(code, 0xa000);
    cpu.step();
    underflow(0);
    bus.write16(0xffd00004, 0xf000);
    bus.intc.nmiHigh = false;
    bus.intc.nmiHigh = true; // The pulse remains latched after deassertion.
    cpu.step();
    expect(cpu.pc, code + 4);
    cpu.step();
    expect(bus.intevt, 0x1c0);
    expect(cpu.spc, code + 4);
    expect(bus.intc.pending(15, bus.tmu), (15, 0x400));
    bus.write16(vector + 0x600, 0x002b);
    bus.write16(vector + 0x602, 0x0009);
    cpu.step();
    cpu.step();
    cpu.step();
    expect(bus.intevt, 0x400);
  });
}
