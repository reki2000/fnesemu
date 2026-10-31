import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:test/test.dart';

void main() {
  late DcBus bus;
  late Sh4 cpu;
  const code = 0x0c010000, vector = 0x8c020000;
  setUp(() {
    bus = DcBus();
    cpu = Sh4(bus)..sr = 0x40000000;
    cpu.pc = code;
    cpu.vbr = vector;
    bus.write16(code, 0xe12a);
    bus.write16(code + 2, 0x0009);
  });

  test('encoded IRL input validates all pin values before replacing the level',
      () {
    cpu.irlPins = 7;
    expect(() => cpu.irlPins = -1, throwsRangeError);
    expect(() => cpu.irlPins = 16, throwsRangeError);
    expect(cpu.irlPins, 7);
  });

  for (var pins = 0; pins < 15; pins++) {
    test('IRL pins $pins enter the interrupt vector with their event code', () {
      cpu.r[15] = 0x0cfffffc;
      cpu.r[1] = 10;
      cpu.bank[1] = 20;
      bus.expevt = 0x160;
      cpu.irlPins = pins;
      cpu.step();
      expect(cpu.instructionExecuted, isFalse);
      expect(cpu.pc, vector + 0x600);
      expect(cpu.spc, code);
      expect(cpu.ssr, 0x40000000);
      expect(cpu.sgr, 0x0cfffffc);
      expect(cpu.sr, 0x70000000);
      expect(cpu.r[1], 20);
      expect(cpu.bank[1], 10);
      expect(bus.intevt, 0x200 + pins * 0x20);
      expect(bus.expevt, 0x160);
      expect(cpu.irlPins, pins);
    });
  }

  test('priority must exceed IMASK; lowering IMASK exposes the asserted line',
      () {
    cpu.sr = 0x40000080;
    cpu.irlPins = 7; // Priority 8, equal to the mask.
    cpu.step();
    expect(cpu.instructionExecuted, isTrue);
    expect(cpu.r[1], 42);
    expect(bus.intevt, 0);
    cpu.sr = 0x40000070;
    cpu.step();
    expect(cpu.spc, code + 2);
    expect(cpu.sr & 0xf0, 0x70); // Acceptance does not raise IMASK.
    expect(bus.intevt, 0x2e0);
  });

  test('BL blocks even the highest IRL priority; inactive pins never interrupt',
      () {
    cpu.sr = 0x50000000;
    cpu.irlPins = 0;
    cpu.step();
    expect(cpu.pc, code + 2);
    expect(bus.intevt, 0);
    cpu.sr = 0x40000000;
    cpu.irlPins = 15;
    cpu.step();
    expect(cpu.pc, code + 4);
    expect(bus.intevt, 0);
  });

  test('asserting IRL after a call waits until its delay slot completes', () {
    bus.write16(code, 0xb002);
    bus.write16(code + 2, 0xe92a);
    cpu.step();
    cpu.irlPins = 0;
    cpu.step();
    expect(cpu.r[9], 42);
    expect(cpu.pc, code + 8);
    expect(bus.intevt, 0);
    cpu.step();
    expect(cpu.spc, code + 8);
    expect(cpu.pr, code + 4);
    expect(bus.intevt, 0x200);
  });

  test('RTE slot is protected from interrupts even after restoring BL=0', () {
    cpu.irlPins = 0;
    cpu.step();
    bus.write16(vector + 0x600, 0x002b);
    bus.write16(vector + 0x602, 0xe92a);
    cpu.step();
    expect(cpu.inDelaySlot, isTrue);
    cpu.step();
    expect(cpu.r[9], 42);
    expect(cpu.pc, code);
    cpu.step();
    expect(cpu.instructionExecuted, isFalse);
    expect(cpu.pc, vector + 0x600); // Still asserted: deliver again.
    expect(cpu.spc, code);
  });

  test('deasserting IRL in a handler allows RTE to resume the saved PC', () {
    cpu.sr = 0;
    cpu.irlPins = 10;
    cpu.step();
    bus.write16(vector + 0x600, 0x002b);
    bus.write16(vector + 0x602, 0x0009);
    cpu.irlPins = 15;
    cpu.step();
    cpu.step();
    expect(cpu.pc, code);
    expect(cpu.sr, 0);
    cpu.step();
    expect(cpu.r[1], 42);
    expect(cpu.instructionExecuted, isTrue);
  });

  test('CPU reset preserves external pin levels and clears internal state', () {
    cpu.irlPins = 4;
    cpu.reset();
    expect(cpu.irlPins, 4);
    expect(cpu.sr, 0x700000f0);
    expect(cpu.instructionExecuted, isFalse);
    expect(bus.intevt, 0);
  });
}
