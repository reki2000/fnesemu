import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/cpg.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:test/test.dart';

void main() {
  late DcBus bus;
  late Sh4 cpu;
  const base = 0xffc00000;
  setUp(() {
    bus = DcBus();
    cpu = Sh4(bus)..sr = 0x40000000;
    cpu.pc = 0xac010000;
    cpu.vbr = 0x8c030000;
    bus.write16(cpu.pc, 9);
  });

  test('CPG reset, aliases, watchdog keys and register access widths', () {
    expect(bus.read16(base), 0xe0a);
    expect([bus.cpg.cpuPeriod, bus.cpg.busPeriod, bus.cpg.peripheralPeriod],
        [1, 2, 4]);
    bus.write16(base, 0xfe0a);
    expect(bus.read16(0x1fc00000), 0xe0a);
    bus.write16(base + 8, 0x5bff);
    bus.write16(base + 12, 0xa4ff);
    expect(bus.read8(base + 8), 0);
    expect(bus.read8(base + 12), 0);
    bus.write16(base + 8, 0x5aff);
    expect(bus.read8(base + 8), 255);
    bus.write8(base + 16, 255);
    expect(bus.read8(base + 16), 0x80);
    expect(() => bus.read32(base), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read16(base + 8), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write8(base + 8, 0), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read16(0xdfc00000), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write16(base, 0xe00), throwsA(isA<DcUnsupported>()));
    expect(bus.read16(base), 0xe0a);
  });

  test('all documented divider combinations produce the specified clock edges',
      () {
    for (final (setting, cpuDivider, busDivider, peripheralDivider) in [
      (0x008, 1, 2, 2),
      (0x00a, 1, 2, 4),
      (0x00c, 1, 2, 8),
      (0x011, 1, 3, 3),
      (0x013, 1, 3, 6),
      (0x01a, 1, 4, 4),
      (0x01c, 1, 4, 8),
      (0x023, 1, 6, 6),
      (0x02c, 1, 8, 8),
      (0x05a, 2, 4, 4),
      (0x05c, 2, 4, 8),
      (0x063, 2, 6, 6),
      (0x06c, 2, 8, 8),
      (0x0a3, 3, 6, 6),
      (0x0ec, 4, 8, 8),
    ]) {
      final clock = DcCpg();
      clock.write(0, 2, 0xe00 | setting);
      clock.advance(clock.stabilizationClocks);
      expect(clock.cpuPeriod, cpuDivider);
      expect(clock.busPeriod, busDivider);
      expect(clock.peripheralPeriod, peripheralDivider);
      expect(clock.advance(240), (240 ~/ peripheralDivider, 240 ~/ busDivider));
    }
  });

  test(
      'PLL restart uses two watchdog stabilization passes when PLL2 is enabled',
      () {
    final clock = DcCpg();
    clock.write(0, 2, 0x80a);
    expect(clock.stabilizing, isFalse);
    expect([clock.cpuPeriod, clock.busPeriod, clock.peripheralPeriod],
        [6, 12, 24]);
    expect(clock.advance(120), (5, 10));
    clock.write(8, 2, 0x5afe);
    clock.write(0, 2, 0xe0a);
    expect(clock.stabilizationClocks, 128);
    expect(clock.advance(64), (0, 0));
    expect(clock.stabilizing, isTrue);
    expect(clock.read(8, 1), 254);
    expect(clock.advance(64), (0, 0));
    expect(clock.stabilizing, isFalse);
    expect(clock.read(8, 1), 0);
    expect(clock.read(12, 1), 0);
  });

  for (var divider = 0; divider < 8; divider++) {
    test('watchdog interval divider $divider counts and requests its interrupt',
        () {
      bus.write16(base + 8, 0x5afe);
      bus.write16(base + 12, 0xa580 | divider);
      bus.write16(0xffd00008, 0x9000);
      final clocks = 2 * (32 << divider);
      bus.tickMasterClocks(clocks - 1);
      expect(bus.cpg.interruptPending, isFalse);
      bus.tickMasterClocks(1);
      expect(bus.read8(base + 8), 0);
      expect(bus.read8(base + 12) & 8, 8);
      cpu.step();
      expect(bus.intevt, 0x560);
      expect(cpu.pc, 0x8c030600);
      expect(cpu.instructionExecuted, isFalse);
    });
  }

  test(
      'clock changes requiring stabilization reject a running watchdog atomically',
      () {
    bus.write16(base + 12, 0xa580);
    expect(() => bus.write16(base, 0xe13), throwsA(isA<DcUnsupported>()));
    expect(bus.read16(base), 0xe0a);
    bus.write16(
        base, 0xe08); // Peripheral divider change needs no stabilization.
    expect(bus.cpg.stabilizing, isFalse);
    expect(bus.cpg.peripheralPeriod, 2);
  });

  test('module clock gates freeze timer, serial and DMA progress', () {
    bus.write32(0xffd8000c, 0);
    bus.write16(0xffd80010, 0x20);
    bus.write8(0xffd80004, 1);
    final sent = <int>[];
    bus.scif.onTransmit = sent.add;
    bus.write8(0xffe80004, 0);
    bus.write16(0xffe80008, 0x20);
    bus.write8(0xffe8000c, 65);
    bus.write32(0xffa00000, 0x0c020000);
    bus.write32(0xffa00004, 0x0c030000);
    bus.write32(0xffa00008, 1);
    bus.write32(0xffa0000c, 0x5435);
    bus.write32(0xffa00040, 1);
    bus.write8(base + 4, 0x1c);
    bus.tickMasterClocks(1280);
    expect(bus.read32(0xffd8000c), 0);
    expect(bus.read32(0xffa00008), 1);
    expect(sent, isEmpty);
    bus.write8(base + 4, 0);
    bus.tickMasterClocks(1280);
    expect(bus.tmu.interruptPending(0), isTrue);
    expect(bus.read32(0xffa00008), 0);
    expect(sent, [65]);
  });

  for (final manual in [false, true]) {
    test(
        'watchdog ${manual ? "manual" : "power"} reset retains CPG state and external RAM',
        () {
      bus.write16(base, 0xe08);
      bus.write32(0x0c020000, 42);
      bus.write32(0xf4000000, 1);
      bus.write32(0xf6000000, 0x100);
      bus.write8(base + 4, 0x60);
      bus.write16(base + 8, 0x5aff);
      bus.write16(base + 12, manual ? 0xa5e0 : 0xa5c0);
      bus.tickMasterClocks(32);
      cpu.step();
      expect(cpu.pc, 0xa0000000);
      expect(cpu.instructionExecuted, isFalse);
      expect(bus.expevt, manual ? 0x20 : 0);
      expect(bus.read16(base), 0xe08);
      expect(bus.read8(base + 12) & 0xd0, 0xd0);
      expect(bus.read8(base + 4), 0);
      expect(bus.read32(0x0c020000), 42);
      expect(bus.read32(0xf4000000) & 1, manual ? 1 : 0);
      expect(bus.read32(0xf6000000) & 0x100, manual ? 0x100 : 0);
    });
  }

  test(
      'ordinary manual reset holds clock registers but full reset restores mode 5',
      () {
    bus.write16(base, 0xe08);
    bus.write16(base + 8, 0x5a55);
    bus.write16(base + 12, 0xa502);
    bus.write8(base + 4, 0x10);
    cpu.reset(manual: true);
    expect(bus.read16(base), 0xe08);
    expect(bus.read8(base + 8), 0x55);
    expect(bus.read8(base + 12), 2);
    expect(bus.read8(base + 4), 0x10);
    cpu.reset();
    expect(bus.read16(base), 0xe0a);
    expect(bus.read8(base + 8), 0);
    expect(bus.read8(base + 12), 0);
  });

  test('Core waits for clock stabilization without executing an instruction',
      () {
    final core = Dc()..setRom(Uint8List.fromList([0x2a, 0xe9]));
    core.bus.write16(base + 8, 0x5aff);
    core.bus.write16(base, 0xe13);
    final waiting = core.exec(true);
    expect(waiting.elapsedClocks, 32);
    expect(waiting.executed(0), isFalse);
    expect(core.cpu.pc, Dc.programAddress);
    expect(core.bus.cpg.stabilizing, isFalse);
    expect(core.exec(true).executed(0), isTrue);
    expect(core.cpu.r[9], 42);
  });

  test('Core accounts divided CPU cycles and detects crossed slice deadlines',
      () {
    final core = Dc()..setRom(Uint8List.fromList([0xfe, 0xaf, 9, 0]));
    core.bus.write16(base + 8, 0x5aff);
    core.bus.write16(base, 0xeec);
    core.exec(true);
    var crossed = false;
    while (core.cpuClocks < core.clocksInScanline) {
      final result = core.exec(true);
      expect(result.elapsedClocks, 4);
      crossed = result.scanlineRendered;
    }
    expect(crossed, isTrue);
    expect(core.cpuClocks, 6352);
  });

  test(
      'SLEEP leaves peripherals running and a timer handler resumes the next instruction',
      () {
    final core = Dc()..setRom(Uint8List.fromList([0x1b, 0, 0x2a, 0xe9]));
    core.cpu.sr = 0x40000000;
    core.cpu.vbr = 0x8c030000;
    core.cpu.r[10] = 0x20;
    core.cpu.r[11] = 0xffd80010;
    core.bus.write16(0x8c030600, 0x2ba1);
    core.bus.write16(0x8c030602, 0x002b);
    core.bus.write16(0x8c030604, 9);
    core.bus.write16(0xffd00004, 0x9000);
    core.bus.write32(0xffd8000c, 0);
    core.bus.write16(0xffd80010, 0x20);
    core.bus.write8(0xffd80004, 1);
    expect(core.exec(true).executed(0), isTrue);
    expect(core.cpu.sleeping, isTrue);
    for (var i = 0; i < 15; i++) {
      expect(core.exec(true).executed(0), isFalse);
    }
    expect(core.exec(true).executed(0), isFalse);
    expect(core.cpu.sleeping, isFalse);
    expect(core.cpu.spc, Dc.programAddress + 2);
    for (var i = 0; i < 4; i++) {
      expect(core.exec(true).stopped, isFalse);
    }
    expect(core.cpu.r[9], 42);
  });

  test('SLEEP ignores BL for wakeup but retains the interrupt mask', () {
    bus.write16(cpu.pc, 0x001b);
    cpu.sr = 0x50000090;
    cpu.step();
    expect(cpu.sleeping, isTrue);
    cpu.irlPins = 6;
    cpu.step();
    expect(cpu.sleeping, isTrue);
    cpu.irlPins = 5;
    cpu.step();
    expect(cpu.sleeping, isFalse);
    expect(cpu.spc, 0xac010002);
    expect(cpu.ssr, 0x50000090);
    expect(bus.intevt, 0x2a0);
  });

  test('SCIF module stop rejects input and defers queued output', () {
    final output = <int>[];
    bus.scif.onTransmit = output.add;
    bus.write8(base + 4, 8);
    bus.write16(0xffe80008, 0x30);
    bus.write8(0xffe8000c, 0x42);
    bus.scif.receiveFrame(0x24);
    bus.scif.receiveBreak();
    bus.tickMasterClocks(100000);
    expect(output, isEmpty);
    expect(bus.read16(0xffe8001c) & 31, 0);
    expect(bus.read16(0xffe80010) & 0x10, 0);
    bus.write8(base + 4, 0);
    bus.scif.receiveFrame(0x24);
    expect(bus.read16(0xffe8001c) & 31, 1);
    bus.tickMasterClocks(400000);
    expect(output, [0x42]);
  });

  test(
      'batched master clocks match individual clocks for dividers and interval overflow',
      () {
    final batch = DcCpg(), single = DcCpg();
    for (final clock in [batch, single]) {
      clock.write(8, 2, 0x5afa);
      clock.write(12, 2, 0xa580);
    }
    final result = batch.advance(10003);
    var peripheral = 0, busEdges = 0;
    for (var i = 0; i < 10003; i++) {
      final tick = single.advance(1);
      peripheral += tick.$1;
      busEdges += tick.$2;
    }
    expect(result, (peripheral, busEdges));
    expect(batch.read(8, 1), single.read(8, 1));
    expect(batch.read(12, 1), single.read(12, 1));
  });
}
