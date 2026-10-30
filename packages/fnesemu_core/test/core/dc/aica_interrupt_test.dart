import 'dart:typed_data';

import 'package:fnesemu_core/debugger.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  const base = 0xa0700000, wave = 0xa0800000;
  late Dc core;
  setUp(() {
    core = Dc()..setRom(Uint8List.fromList([0xfe, 0xaf, 9, 0]));
  });

  Uint8List firmware(
      {int clear = 0x20, bool timer = false, bool byteEnd = false}) {
    final bytes = Uint8List(0x300);
    final boot = [0xe10f0000, 0xe3c00040, 0xe129f000, 0xeafffffe];
    for (final (i, op) in boot.indexed) {
      bytes.setUint32LE(i * 4, op);
    }
    bytes.setUint32LE(0x1c, 0xea000037); // B 100h from the FIQ vector.
    final ops = <int>[], literals = <(int, int)>[];
    void load(int reg, int value) {
      literals.add((ops.length, value));
      ops.add(0xe59f0000 | (reg << 12));
    }

    load(8, 0x802d00);
    ops.add(0xe5989000);
    load(10, 0x400);
    ops.add(0xe58a9000);
    load(10, 0x404);
    ops.addAll([0xe59ab000, 0xe28bb001, 0xe58ab000]);
    load(8, 0x8028a4);
    load(9, clear);
    ops.add(0xe5889000);
    if (timer) {
      load(8, 0x802890);
      ops.addAll([0xe3a090ff, 0xe5889000]);
    }
    load(8, 0x802d04);
    ops.addAll([0xe3a09001, byteEnd ? 0xe5c89000 : 0xe5889000, 0xe25ef004]);
    final pool = 0x100 + ops.length * 4;
    for (final (i, literal) in literals.indexed) {
      final (instruction, value) = literal;
      ops[instruction] |= pool + 4 * i - (0x108 + instruction * 4);
      bytes.setUint32LE(pool + 4 * i, value);
    }
    for (final (i, op) in ops.indexed) {
      bytes.setUint32LE(0x100 + i * 4, op);
    }
    return bytes;
  }

  void level(int source, int code) {
    for (var bit = 0; bit < 3; bit++) {
      core.bus.write32(
          base + 0x28a8 + 4 * bit, code & (1 << bit) != 0 ? 1 << source : 0);
    }
  }

  void software(int code) {
    level(5, code);
    core.bus.write32(base + 0x289c, 0x20);
    core.bus.write32(base + 0x28a0, 0x20);
  }

  test('a real ARM handler reads L, clears the source, ends FIQ and resumes',
      () {
    core.bus.aica.memory.setAll(0, firmware());
    software(5);
    expect(core.bus.aica.armInterruptLevel, 5);
    expect(core.bus.aica.arm.fiq, isFalse); // CPU remains held in reset.
    core.bus.write32(base + 0x2c00, 0);
    for (var i = 0; i < 2000; i++) {
      expect(core.exec(false).stopped, isFalse, reason: core.stopReason);
    }
    expect(core.bus.aica.memory.getUint32LE(0x400), 5);
    expect(core.bus.aica.memory.getUint32LE(0x404), 1);
    expect(core.bus.aica.arm.mode, 0x13);
    expect(core.bus.aica.arm.pc, 12);
    expect(core.bus.aica.arm.fiq, isFalse);
    expect(core.bus.aica.armInterruptLevel, 0);
    expect(core.bus.aica.soundPending & 0x20, 0);
    expect(core.bus.systemBus.externalStatus, 0);
  });

  test(
      'timer FIQs repeat after guest reload and remain independent of SH4 requests',
      () {
    core.bus.aica.memory.setAll(0, firmware(clear: 0x40, timer: true));
    level(6, 3);
    core.bus.write32(base + 0x2890, 255);
    core.bus.write32(base + 0x289c, 0x40);
    core.bus.write32(base + 0x28b4, 0x40);
    core.bus.write32(base + 0x2c00, 0);
    core.bus.tickMasterClocks(20000);
    expect(core.bus.aica.memory.getUint32LE(0x400), 3);
    expect(core.bus.aica.memory.getUint32LE(0x404), 4);
    expect(core.bus.aica.soundPending & 0x40, 0);
    expect(core.bus.aica.systemPending & 0x40, 0x40);
    expect(core.bus.systemBus.externalStatus, 2);
  });

  test('level zero suppresses delivery while the ARM F mask delays acceptance',
      () {
    core.bus.aica.memory.setAll(0, firmware());
    software(0);
    core.bus.write32(base + 0x2c00, 0);
    core.bus.tickMasterClocks(1000);
    expect(core.bus.aica.armInterruptLevel, 0);
    expect(core.bus.aica.memory.getUint32LE(0x404), 0);
    core.bus.write32(base + 0x289c, 0);
    level(5, 5);
    core.bus.write32(base + 0x289c, 0x20);
    core.bus.tickMasterClocks(2000);
    expect(core.bus.aica.memory.getUint32LE(0x404), 1);
  });

  test(
      'source clearing does not replace the latched number before M acknowledgement',
      () {
    final aica = core.bus.aica;
    software(5);
    core.bus.write32(base + 0x28a4, 0x20);
    core.bus.write32(base + 0x289c, 0);
    expect(aica.armInterruptLevel, 5);
    expect(aica.read(0x2d00, 1, fromArm: true), 5);
    expect(aica.read(0x2d01, 1, fromArm: true), 0);
    aica.write(0x2d04, 4, 1, fromArm: true);
    expect(aica.armInterruptLevel, 0);
    expect(aica.arm.fiq, isFalse);
    expect(() => core.bus.read32(base + 0x2d00), throwsA(isA<DcUnsupported>()));
    expect(() => core.bus.write32(base + 0x2d04, 1),
        throwsA(isA<DcUnsupported>()));
    expect(() => aica.write(0x2d04, 4, 2, fromArm: true),
        throwsA(isA<DcUnsupported>()));
  });

  test('bits 7 through 10 share SCILV group seven', () {
    for (final source in [7, 8, 10]) {
      final aica = core.bus.aica;
      aica.reset();
      core.bus.write32(base + 0x2894, 255);
      core.bus.write32(base + 0x2898, 255);
      level(7, 6);
      core.bus.write32(base + 0x289c, 1 << source);
      core.bus.tickMasterClocks(4536);
      expect(aica.armInterruptLevel, 6, reason: 'source $source');
    }
  });

  test('the functional encoder chooses the highest level and rearms after end',
      () {
    final aica = core.bus.aica;
    core.bus.write32(base + 0x2890, 255);
    core.bus.tickMasterClocks(4536);
    core.bus.write32(base + 0x28a8, 0x20);
    core.bus.write32(base + 0x28ac, 0x40);
    core.bus.write32(base + 0x28b0, 0x20);
    core.bus.write32(base + 0x28a0, 0x20);
    core.bus.write32(base + 0x289c, 0x60);
    expect(aica.armInterruptLevel, 5);
    core.bus.write32(base + 0x28a4, 0x20);
    aica.write(0x2d04, 4, 1, fromArm: true);
    expect(aica.armInterruptLevel, 0);
    core.bus.write32(base + 0x2c00, 0);
    core.bus.tickMasterClocks(9);
    expect(aica.armInterruptLevel, 2);
    expect(
        aica.arm.mode, 0x13); // Reset CPSR masks FIQ until firmware enables it.
  });

  test('byte end writes preserve RP while a high-byte write changes only RP',
      () {
    final aica = core.bus.aica;
    core.bus.aica.memory.setAll(0, firmware(byteEnd: true));
    aica.write(0x2d04, 4, 0x100, fromArm: true);
    software(5);
    core.bus.write32(base + 0x2c00, 0);
    core.bus.tickMasterClocks(2000);
    expect(aica.readProtected, isTrue);
    expect(aica.armInterruptLevel, 0);
    expect(aica.memory.getUint32LE(0x400), 5);
    expect(() => core.bus.read32(wave + 0x400), throwsA(isA<DcUnsupported>()));
    expect(core.read(1, 0x400), 5); // Debug inspection has no bus cycle.
    aica.write(0x2d05, 1, 0, fromArm: true);
    expect(aica.readProtected, isFalse);
    expect(core.bus.read32(wave + 0x400), 5);
  });

  test(
      'ARM byte lanes preserve counters and clear only the written pending bits',
      () {
    final aica = core.bus.aica;
    aica.write(0x2890, 4, 0x2ff);
    aica.write(0x2890, 1, 0xfe, fromArm: true);
    core.bus.tickMasterClocks(
        18141); // Four samples: one increment at divisor four.
    expect(aica.timerCounter(0), 255);
    aica.write(0x28a0, 1, 0x20, fromArm: true);
    expect(aica.soundPending & 0x420, 0x420);
    aica.write(0x28a5, 1, 4, fromArm: true);
    expect(aica.soundPending & 0x420, 0x20);
    aica.write(0, 1, 0x7f, fromArm: true);
    aica.write(1, 1, 1, fromArm: true);
    expect(aica.read(0, 4), 0x17f);
    expect(aica.read(2, 1, fromArm: true), 0);
    expect(() => core.bus.write8(base, 0), throwsA(isA<DcUnsupported>()));
  });

  test(
      'MRWINH pauses ARM fetches without accumulating retroactive instructions',
      () {
    final aica = core.bus.aica;
    aica.memory.setUint32LE(0, 0xe2800001);
    aica.memory.setUint32LE(4, 0xeafffffd);
    core.bus.write32(base + 0x2c00, 0);
    core.bus.tickMasterClocks(1000);
    final r0 = aica.arm.r[0],
        pc = aica.arm.pc,
        serial = aica.executedInstructions;
    core.bus.write32(base + 0x2880, 4);
    aica.write(0x2880, 1, 0,
        fromArm: true); // ARM cannot change its own inhibit bit.
    expect(aica.memoryInhibit, 4);
    core.bus.tickMasterClocks(100000);
    expect(aica.arm.r[0], r0);
    expect(aica.arm.pc, pc);
    expect(aica.executedInstructions, serial);
    expect(aica.clocksToEvent, isNull);
    core.bus.write32(base + 0x2880, 0);
    core.bus.tickMasterClocks(1000);
    expect(aica.arm.r[0], greaterThan(r0));
  });

  test('system inhibition applies to bus cycles while cache hits remain local',
      () {
    final bus = core.bus, aica = bus.aica;
    bus.write32(wave + 0x100, 0x11223344);
    bus.cache.ccr = 5;
    expect(bus.read32(0x80800100), 0x11223344);
    bus.write32(base + 0x2880, 8);
    bus.write32(0x80800100, 0x55667788);
    expect(bus.read32(0x80800100), 0x55667788);
    expect(() => bus.read32(wave + 0x100), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write32(wave + 0x100, 0), throwsA(isA<DcUnsupported>()));
    expect(aica.memory.getUint32LE(0x100), 0x11223344);
    bus.write32(base + 0x2880, 0);
    bus.cpuCacheOperation(0x80800100, 2);
    expect(aica.memory.getUint32LE(0x100), 0x55667788);
    aica.write(0x2d04, 4, 0x100, fromArm: true);
    bus.write32(wave + 0x100, 0xabcdef01); // RP prohibits reads, not writes.
    expect(() => bus.read32(wave + 0x100), throwsA(isA<DcUnsupported>()));
    expect(bus.read32(wave + 0x100, peek: true), 0xabcdef01);
  });

  test('G2 reads stop without false completion and resume after RP clears', () {
    final bus = core.bus, aica = bus.aica;
    for (var i = 0; i < 32; i++) {
      aica.memory[0x2000 + i] = i + 1;
    }
    aica.write(0x2d04, 4, 0x100, fromArm: true);
    bus.write32(0xffa00040, 0x8201);
    const g2 = 0xa05f7800;
    bus.write32(g2, 0x00802000);
    bus.write32(g2 + 4, 0x0c020000);
    bus.write32(g2 + 8, 0x80000020);
    bus.write32(g2 + 12, 1);
    bus.write32(g2 + 0xbc, 0x4659007f);
    bus.write32(g2 + 20, 1);
    bus.write32(g2 + 24, 1);
    expect(() => bus.tickMasterClocks(1000), throwsA(isA<DcUnsupported>()));
    expect(bus.read32(g2 + 24), 1);
    expect(bus.systemBus.normalStatus & (1 << 15), 0);
    expect(bus.systemBus.errorStatus, 0);
    aica.write(0x2d04, 4, 0, fromArm: true);
    bus.tickMasterClocks(1000);
    expect(bus.ram.sublist(0x20000, 0x20020), List.generate(32, (i) => i + 1));
    expect(bus.read32(g2 + 24), 0);
  });

  test('normal SH4 DMA cannot bypass read protection on wave memory', () {
    final bus = core.bus, aica = bus.aica;
    aica.memory.setUint32LE(0x2000, 0x11223344);
    aica.write(0x2d04, 4, 0x100, fromArm: true);
    bus.write32(0xffa00000, 0x00802000);
    bus.write32(0xffa00004, 0x0c020000);
    bus.write32(0xffa00008, 1);
    bus.write32(0xffa0000c, 0x5435);
    bus.write32(0xffa00040, 1);
    expect(() => bus.dma.tickTransferUnits(1), throwsA(isA<DcUnsupported>()));
    expect(bus.read32(0xffa00008), 1);
    expect(bus.ram.getUint32LE(0x20000), 0);
    aica.write(0x2d04, 4, 0, fromArm: true);
    bus.dma.tickTransferUnits(1);
    expect(bus.ram.getUint32LE(0x20000), 0x11223344);
  });

  test('all eight programmable codes retain their three SCILV bits', () {
    for (var code = 0; code < 8; code++) {
      core.bus.aica.reset();
      software(code);
      expect(core.bus.aica.armInterruptLevel, code);
    }
  });

  test(
      'batched FIQ delivery agrees with individual clocks through guest timer reloads',
      () {
    final single = Dc();
    final program = firmware(clear: 0x40, timer: true);
    for (final target in [core, single]) {
      final bus = target.bus;
      bus.aica.memory.setAll(0, program);
      bus.write32(base + 0x28a8, 0x40);
      bus.write32(base + 0x28ac, 0x40);
      bus.write32(base + 0x2890, 255);
      bus.write32(base + 0x289c, 0x40);
      bus.write32(base + 0x2c00, 0);
    }
    for (final clocks in [1, 35, 4500, 10003, 5000, 743]) {
      core.bus.tickMasterClocks(clocks);
      for (var i = 0; i < clocks; i++) {
        single.bus.tickMasterClocks(1);
      }
      expect(core.bus.aica.arm.debugState, single.bus.aica.arm.debugState);
      expect(core.bus.aica.arm.cycles, single.bus.aica.arm.cycles);
      expect(
          core.bus.aica.armInterruptLevel, single.bus.aica.armInterruptLevel);
      expect(core.bus.aica.soundPending, single.bus.aica.soundPending);
      expect(core.bus.aica.clocksToEvent, single.bus.aica.clocksToEvent);
      expect(core.bus.aica.memory.sublist(0x400, 0x408),
          single.bus.aica.memory.sublist(0x400, 0x408));
    }
  });

  test('actual AICA FIQ entry refreshes the debugger pending trace', () async {
    core.bus.aica.memory.setAll(0, firmware());
    software(5);
    core.bus.write32(base + 0x2c00, 0);
    core.bus.tickMasterClocks(
        27); // Boot has enabled FIQ; the main loop has not retired.
    expect(core.bus.aica.arm.pc, 12);
    late Debugger debugger;
    debugger = Debugger(core, onStop: () async {}, onRun: () async {
      for (var i = 0; i < 100; i++) {
        debugger.recordTrace();
        final result = core.exec(true);
        expect(result.stopped, isFalse, reason: core.stopReason);
        debugger.completeTrace(result);
        if (debugger.shouldPause(result, core.cpuClocks)) return;
      }
      fail('did not step into the FIQ vector');
    });
    debugger.selectCpu(1);
    debugger.setLogEnabled(true);
    await debugger.step();
    expect(core.bus.aica.arm.pc, 0x100);
    expect(debugger.traceText(), contains('ea000037'));
    expect(debugger.traceText(), isNot(contains('eafffffe')));
    debugger.cancelExecution();
  });

  test('full reset clears controls while CPU-only resets retain the AICA state',
      () {
    final aica = core.bus.aica;
    software(5);
    aica.write(0x2d04, 4, 0x100, fromArm: true);
    core.bus.write32(base + 0x2880, 12);
    Sh4(core.bus).reset(manual: true);
    expect(aica.readProtected, isTrue);
    expect(aica.memoryInhibit, 12);
    expect(aica.armInterruptLevel, 5);
    core.reset();
    expect(aica.readProtected, isFalse);
    expect(aica.memoryInhibit, 0);
    expect(aica.armInterruptLevel, 0);
  });
}
