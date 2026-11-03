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
    core = Dc(jit: false)..setRom(Uint8List.fromList([0xfe, 0xaf, 9, 0]));
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












  test(
      'batched FIQ delivery agrees with individual clocks through guest timer reloads',
      () {
    final single = Dc();
    addTearDown(single.dispose);
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


}
