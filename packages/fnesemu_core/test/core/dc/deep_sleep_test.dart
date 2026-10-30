import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:test/test.dart';

Dc machine({bool deep = true}) {
  final core = Dc()
    ..setRom(Uint8List.fromList([0x1b, 0, 0x2a, 0xe9, 0xfe, 0xaf, 9, 0]));
  core.cpu.sr = 0x40000000;
  core.cpu.vbr = 0x8c030000;
  core.bus.write32(0xff800014, 6); // RFSH and RMODE: SDRAM self-refresh.
  core.bus.write8(0xffc00010, deep ? 0x80 : 0);
  core.bus.write16(0x8c030600, 9);
  return core;
}

void configureDma(Dc core) {
  final bus = core.bus;
  bus.write32(0xffa00010, 0x0c020000);
  bus.write32(0xffa00014, 0x0c030000);
  bus.write32(0xffa00018, 2);
  bus.write32(0xffa0001c, 0x5431);
  bus.write32(0xffa00040, 1);
  bus.write32(0x0c020000, 0x12345678);
  bus.write32(0x0c020004, 0x76543210);
}

void main() {
  test('NMI wakes deep sleep at the next instruction boundary', () {
    final core = machine();
    addTearDown(core.dispose);
    core.exec(false);
    core.bus.intc.nmiHigh = false;
    core.exec(false);
    expect(core.bus.cpg.deepSleeping, isFalse);
    expect(core.cpu.sleeping, isFalse);
    expect(core.bus.intevt, 0x1c0);
  });

  for (final manual in [false, true]) {
    test('watchdog reset exits deep sleep: manual=$manual', () {
      final core = machine();
      addTearDown(core.dispose);
      core.exec(false);
      core.bus.write16(0xffc00008, 0x5aff);
      core.bus.write16(0xffc0000c, manual ? 0xa5e0 : 0xa5c0);
      core.bus.tickMasterClocks(32);
      core.exec(false);
      expect(core.bus.cpg.deepSleeping, isFalse);
      expect(core.cpu.sleeping, isFalse);
      expect(core.cpu.pc, 0xa0000000);
      expect(core.bus.expevt, manual ? 0x20 : 0);
    });
  }

  test('deep sleep holds CPU registers and leaves peripheral clocks running',
      () {
    final core = machine();
    addTearDown(core.dispose);
    core.bus.write32(0xffd8000c, 20);
    core.bus.write8(0xffd80004, 1);
    final entered = core.exec(false);
    expect(entered.stopped, isFalse);
    expect(entered.executed(0), isTrue);
    expect(core.cpu.sleeping, isTrue);
    expect(core.bus.cpg.deepSleeping, isTrue);
    final count = core.bus.read32(0xffd8000c);
    for (var i = 0; i < 32; i++) {
      final result = core.exec(false);
      expect(result.executed(0), isFalse);
      expect(result.stopped, isFalse);
    }
    expect(core.cpu.pc, Dc.programAddress + 2);
    expect(core.cpu.r[9], 0);
    expect(core.bus.read32(0xffd8000c), lessThan(count));
    core.cpu.irlPins = 5;
    expect(core.exec(false).executed(0), isFalse);
    expect(core.cpu.sleeping, isFalse);
    expect(core.bus.cpg.deepSleeping, isFalse);
    expect(core.cpu.spc, Dc.programAddress + 2);
    expect(core.bus.intevt, 0x2a0);
    expect(core.exec(false).executed(0), isTrue);
  });

  for (final deep in [false, true]) {
    test('DMA clock gating distinguishes light and deep sleep: $deep', () {
      final core = machine(deep: deep);
      addTearDown(core.dispose);
      core.exec(false);
      // Test the clock boundary with a request installed by the host harness.
      // Guest software must terminate DMA before entering deep sleep.
      configureDma(core);
      core.bus.tickMasterClocks(100);
      expect(core.bus.read32(0xffa00018), deep ? 2 : 0);
      expect(core.bus.read32(0x0c030000), deep ? 0 : 0x12345678);
      if (deep) {
        core.cpu.irlPins = 5;
        core.exec(false);
        core.bus.tickMasterClocks(100);
        expect(core.bus.read32(0xffa00018), 0);
        expect(core.bus.read32(0x0c030000), 0x12345678);
        expect(core.bus.read32(0x0c030004), 0x76543210);
      }
    });
  }

  test('deep sleep wakeup ignores BL while retaining IMASK', () {
    final core = machine();
    addTearDown(core.dispose);
    core.cpu.sr = 0x50000090;
    core.exec(false);
    core.cpu.irlPins = 6;
    core.exec(false);
    expect(core.bus.cpg.deepSleeping, isTrue);
    core.cpu.irlPins = 5;
    core.exec(false);
    expect(core.bus.cpg.deepSleeping, isFalse);
    expect(core.cpu.ssr, 0x50000090);
  });

  test('manual and full resets clear the deep sleep latch', () {
    final core = machine();
    addTearDown(core.dispose);
    core.exec(false);
    core.cpu.reset(manual: true);
    expect(core.cpu.sleeping, isFalse);
    expect(core.bus.cpg.deepSleeping, isFalse);
    expect(core.bus.cpg.standby2, 0x80);
    core.cpu.pc = Dc.programAddress;
    core.cpu.step();
    expect(core.bus.cpg.deepSleeping, isTrue);
    core.reset();
    expect(core.bus.cpg.deepSleeping, isFalse);
    expect(core.bus.cpg.standby2, 0);
  });

  test(
      'a TMU interrupt wakes deep sleep and the handler resumes the next instruction',
      () {
    final core = machine();
    addTearDown(core.dispose);
    final bus = core.bus;
    core.cpu.r[10] = 0x20;
    core.cpu.r[11] = 0xffd80010;
    bus.write16(0x8c030600, 0x2ba1); // MOV.W R10,@R11: acknowledge UNF.
    bus.write16(0x8c030602, 0x002b); // RTE.
    bus.write16(0x8c030604, 9);
    bus.write16(0xffd00004, 0x9000);
    bus.write32(0xffd8000c, 0);
    bus.write16(0xffd80010, 0x20);
    bus.write8(0xffd80004, 1);
    core.exec(false);
    for (var i = 0; i < 16; i++) {
      core.exec(false);
    }
    expect(core.cpu.sleeping, isFalse);
    expect(bus.cpg.deepSleeping, isFalse);
    expect(core.cpu.spc, Dc.programAddress + 2);
    for (var i = 0; i < 4; i++) {
      expect(core.exec(false).stopped, isFalse);
    }
    expect(core.cpu.r[9], 42);
  });
}
