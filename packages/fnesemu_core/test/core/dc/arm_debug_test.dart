import 'dart:typed_data';

import 'package:fnesemu_core/debugger.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:test/test.dart';

void main() {
  late Dc core;
  const wave = 0xa0800000, reset = 0xa0702c00;
  setUp(() {
    core = Dc()..setRom(Uint8List.fromList([0xfe, 0xaf, 9, 0]));
    for (final (i, op) in [0xe3a00001, 0xe2800001, 0xeafffffd].indexed) {
      core.bus.write32(wave + 4 * i, op);
    }
  });

  test(
      'ARM CPU identity, address space, PC, stack and disassembly are core-owned',
      () {
    expect(core.cpuInfos.map((cpu) => (cpu.no, cpu.name)),
        [(0, 'SH-4'), (1, 'ARM7DI')]);
    core.bus.aica.arm.r[13] = 0x1000;
    expect(core.stackPointer(1), 0x1000);
    expect(core.stackPointer(0), 0x8d000000);
    expect(core.programCounter(1), 0);
    expect(core.programCounter(0), Dc.programAddress);
    expect(List.generate(4, (i) => core.read(1, i)), [1, 0, 0xa0, 0xe3]);
    expect(core.disasm(1, 0).$1, contains('mov r0,#0x1'));
    expect(core.disasm(1, 0).$2, 4);
    expect(core.disasm(0, Dc.programAddress).$2, 2);
    expect(core.disasm(1, 0x400000).$1, contains('<unmapped>'));
    expect(core.dump(showApu: true), contains('AICA ARM7DI'));
  });

  test(
      'ARM trace inspection snapshots banks without changing clocks or requests',
      () {
    core.bus.write32(0xa07028b8, 0x20);
    core.bus.write32(0xa07028b4, 0x20);
    final before = core.trace(1);
    final state = List.of(before.state);
    expect(before.pc, 0);
    expect(before.regs, contains('CPSR'));
    expect(core.read(1, 0x8028b8), 0x20);
    core.disasm(1, 0x8028b8);
    expect(core.bus.systemBus.externalStatus, 2);
    expect(core.bus.aica.arm.cycles, 0);
    core.bus.aica.arm.cpsr = 0x11;
    core.bus.aica.arm.r[8] = 99;
    core.bus.aica.arm.cpsr = 0xd3;
    expect(core.trace(1).state, isNot(state));
    expect(before.state, state);
  });

  test('ExecResult reports ARM only when an instruction completes', () {
    for (var i = 0; i < 12; i++) {
      expect(core.exec(true).executed(1), isFalse);
    }
    core.bus.write32(reset, 0);
    for (var i = 0; i < 8; i++) {
      expect(core.exec(true).executed(1), isFalse);
    }
    expect(core.exec(true).executed(1), isTrue);
    expect(core.bus.aica.arm.r[0], 1);
    expect(core.exec(true).executed(1), isFalse);
    expect(core.bus.aica.arm.r[0], 1);
  });

  test('ARM reset does not masquerade as an executed instruction', () {
    core.bus.write32(reset, 0);
    for (var i = 0; i < 100; i++) {
      core.exec(false);
    }
    final serial = core.bus.aica.executedInstructions;
    expect(serial, greaterThan(0));
    core.bus.write16(core.cpu.pc, 0x2102);
    core.cpu.r[0] = 1;
    core.cpu.r[1] = reset;
    final result = core.exec(true);
    expect(result.executed(1), isFalse);
    expect(core.bus.aica.executedInstructions, serial);
    expect(core.bus.aica.arm.cycles, 0);
    expect(core.programCounter(1), 0);
  });

  test('debug scheduling exposes at most one ARM instruction per observation',
      () {
    core.bus.write16(
        0xffc00000, 0x085a); // PLL bypass, 12 master ticks per SH4 cycle.
    expect(core.bus.cpg.cpuPeriod, 12);
    core.bus.write32(reset, 0);
    var elapsed = 0, sh4Steps = 0;
    var sawClockRemainder = false;
    for (var i = 0; i < 120; i++) {
      final serial = core.bus.aica.executedInstructions;
      final result = core.exec(true);
      elapsed += result.elapsedClocks;
      if (result.executed(0)) {
        sh4Steps++;
      } else {
        sawClockRemainder = true;
      }
      expect(core.bus.aica.executedInstructions - serial, lessThanOrEqualTo(1));
      expect(result.executed(1), core.bus.aica.executedInstructions != serial);
      expect(result.stopped, isFalse, reason: core.stopReason);
    }
    expect(sawClockRemainder, isTrue);
    expect(elapsed, lessThanOrEqualTo(sh4Steps * 12));
    expect(elapsed, greaterThan((sh4Steps - 1) * 12));
    expect(core.cpuClocks, elapsed);
  });

  test('debugger step selects ARM and waits through SH4-only execution',
      () async {
    core.bus.write32(reset, 0);
    var calls = 0;
    late Debugger debugger;
    debugger = Debugger(core, onStop: () async {}, onRun: () async {
      for (var i = 0; i < 100; i++) {
        calls++;
        debugger.recordTrace();
        final result = core.exec(true);
        debugger.completeTrace(result);
        if (debugger.shouldPause(result, core.cpuClocks)) return;
      }
      fail('debugger did not stop after an ARM instruction');
    });
    debugger.selectCpu(1);
    debugger.setLogEnabled(true);
    await debugger.step();
    expect(calls, 9);
    expect(core.programCounter(1), 4);
    expect(core.bus.aica.arm.r[0], 1);
    expect(debugger.traceText(), contains('e3a00001'));
    debugger.cancelExecution();
  });

  test('ARM interrupt entry refreshes the pending handler trace', () {
    core.bus.write32(wave + 0x18, 0xe3a0002a);
    core.bus.aica.arm.cpsr = 0x13;
    core.bus.aica.arm.irq = true;
    core.bus.write32(reset, 0);
    final debugger = Debugger(core)..selectCpu(1);
    debugger.setLogEnabled(true);
    var sawEntry = false;
    for (var i = 0; i < 100; i++) {
      debugger.recordTrace();
      final result = core.exec(true);
      debugger.completeTrace(result);
      if (core.programCounter(1) == 0x18) {
        sawEntry = true;
        expect(result.executed(1), isFalse);
      }
      if (result.executed(1)) break;
    }
    expect(sawEntry, isTrue);
    expect(core.bus.aica.arm.r[0], 42);
    expect(core.bus.aica.executedInstructions, 1);
    final text = debugger.traceText();
    expect(text, contains('e3a0002a'));
    expect(text, isNot(contains('e3a00001')));
  });

  test('debug slices preserve the same CPU timeline as normal execution', () {
    final coarse = Dc()..setRom(Uint8List.fromList([0xfe, 0xaf, 9, 0]));
    for (var i = 0; i < 3; i++) {
      coarse.bus.write32(wave + 4 * i, core.bus.read32(wave + 4 * i));
    }
    for (final target in [core, coarse]) {
      target.bus.write16(0xffc00000, 0x085a);
      target.bus.write32(reset, 0);
    }
    for (var i = 0; i < 100; i++) {
      coarse.exec(false);
    }
    while (core.cpuClocks < coarse.cpuClocks) {
      core.exec(true);
    }
    expect(core.cpuClocks, 1200);
    expect(core.cpu.pc, coarse.cpu.pc);
    expect(core.cpu.r, coarse.cpu.r);
    expect(core.bus.aica.arm.debugState, coarse.bus.aica.arm.debugState);
    expect(core.bus.aica.arm.cycles, coarse.bus.aica.arm.cycles);
    expect(core.bus.aica.executedInstructions,
        coarse.bus.aica.executedInstructions);
  });

  test('PLL stabilization exposes each ARM instruction while SH4 is paused',
      () {
    core.bus.write32(reset, 0);
    core.bus.write16(0xffc00008, 0x5aff);
    core.bus.write16(0xffc00000, 0x0e13);
    expect(core.bus.cpg.stabilizing, isTrue);
    final pc = core.cpu.pc;
    var observations = 0;
    while (core.bus.cpg.stabilizing) {
      final serial = core.bus.aica.executedInstructions;
      final result = core.exec(true);
      expect(result.executed(0), isFalse);
      expect(core.bus.aica.executedInstructions - serial, lessThanOrEqualTo(1));
      if (result.executed(1)) observations++;
    }
    expect(core.cpu.pc, pc);
    expect(core.cpuClocks, 32);
    expect(observations, 3);
  });
}
