import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/aica.dart';
import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  const registers = 0xa0700000, wave = 0xa0800000, rtc = 0xa0710000;
  int sampleClocks(int samples) =>
      (samples * DcAica.masterHz + DcAica.sampleHz - 1) ~/ DcAica.sampleHz;

  test('retail wave RAM has direct aliases, boundaries and longword cycles',
      () {
    final bus = DcBus();
    for (final alias in [
      0x00800000,
      0x02800000,
      0x80800000,
      wave,
      0xa2800000
    ]) {
      bus.write32(alias, alias);
      expect(bus.read32(wave), alias);
    }
    bus.write32(wave + DcAica.memorySize - 4, 0xffeeddcc);
    expect(bus.read32(0x809ffffc), 0xffeeddcc);
    for (final address in [wave + DcAica.memorySize, 0xa0ffffff, 0xc0800000]) {
      expect(() => bus.read32(address), throwsA(isA<DcUnsupported>()));
    }
    for (final access in [
      () => bus.read8(wave),
      () => bus.read16(wave),
      () => bus.write8(wave, 0),
      () => bus.write16(wave, 0),
      () => bus.write32(wave + 1, 0),
    ]) {
      expect(access, throwsA(isA<DcUnsupported>()));
    }
    expect(bus.read32(wave), 0xa2800000);
  });

  test('wave RAM supports FPU pairs, store queues and cache bypass coherence',
      () {
    final bus = DcBus();
    bus.writePair(wave, 0x11223344, 0xaabbccdd);
    expect(bus.readPair(wave), (0x11223344, 0xaabbccdd));
    bus.cache.ccr = 1;
    expect(bus.read32(0x80800000), 0x11223344);
    bus.write32(wave, 0x99887766);
    expect(bus.read32(0x80800000), 0x11223344);
    bus.cpuCacheOperation(0x80800000, 1);
    expect(bus.read32(0x80800000), 0x99887766);
    bus.write32(0xff000038, 0);
    for (var i = 0; i < 8; i++) {
      bus.write32(0xe0800040 + i * 4, 0x10203040 + i);
    }
    bus.transferStoreQueue(0xe0800040);
    for (var i = 0; i < 8; i++) {
      expect(bus.read32(wave + 0x40 + i * 4), 0x10203040 + i);
    }
  });

  test('AICA MMIO widths, ARM hold and video mode bits are explicit', () {
    final bus = DcBus();
    expect(bus.aica.armReset, isTrue);
    bus.write32(registers + 0x2c00, 0xffffffff);
    for (final alias in [0x00702c00, 0x02702c00, 0x80702c00, 0xa2702c00]) {
      expect(bus.read32(alias), 0x301);
    }
    bus.write32(registers + 0x2c00, 0x300);
    expect(bus.aica.armReset, isFalse);
    expect(bus.read32(registers + 0x2c00), 0x300);
    bus.write32(registers + 0x2c00, 0x301);
    expect(bus.aica.armReset, isTrue);
    expect(() => bus.write16(registers + 0x289c, 0),
        throwsA(isA<DcUnsupported>()));
    expect(() => bus.read8(registers + 0x289c), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read32(registers + 0x2890), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write32(registers, 0xc400), throwsA(isA<DcUnsupported>()));
  });

  test('software requests and independent acknowledgements route HOLLY bit 1',
      () {
    final bus = DcBus();
    bus.systemBus.setExternal(9);
    bus.write32(registers + 0x28a0, 0xffffffff);
    bus.write32(registers + 0x28b8, 0xffffffff);
    expect(bus.read32(registers + 0x28a0), 0x20);
    expect(bus.read32(registers + 0x28b8), 0x20);
    expect(bus.systemBus.externalStatus, 9);
    bus.write32(registers + 0x28b4, 0x20);
    expect(bus.systemBus.externalStatus, 11);
    bus.write32(0xa05f6914, 2);
    expect(bus.systemBus.irlPins, 13);
    bus.write32(registers + 0x28b8, 0);
    expect(bus.systemBus.externalStatus, 11);
    bus.write32(registers + 0x28a4, 0x20);
    expect(bus.read32(registers + 0x28a0), 0);
    expect(bus.systemBus.externalStatus, 11);
    bus.write32(registers + 0x28bc, 0x20);
    expect(bus.systemBus.externalStatus, 9);
    bus.write32(registers + 0x28b4, 0xffffffff);
    expect(bus.read32(registers + 0x28b4), 0x7ff);
  });

  test('three timers overflow at their documented sample divisors', () {
    for (var prescaler = 0; prescaler < 8; prescaler++) {
      final bus = DcBus();
      for (var i = 0; i < 3; i++) {
        bus.write32(registers + 0x2890 + 4 * i, (prescaler << 8) | 255);
      }
      bus.write32(registers + 0x28b4, 0x1c0);
      final deadline = sampleClocks(1 << prescaler);
      expect(bus.aica.clocksToEvent, deadline);
      bus.tickMasterClocks(deadline - 1);
      expect(bus.aica.systemPending & 0x1c0, 0);
      bus.tickMasterClocks(1);
      expect(bus.aica.systemPending & 0x1c0, 0x1c0);
      expect(bus.aica.soundPending & 0x1c0, 0x1c0);
      expect(bus.systemBus.externalStatus, 2);
      expect(bus.aica.clocksToEvent, isNull);
      for (var i = 0; i < 3; i++) {
        expect(bus.aica.timerCounter(i), 0);
      }
    }
  });

  test('sample interrupt relatches after acknowledgement on the next sample',
      () {
    final bus = DcBus();
    bus.write32(registers + 0x28b4, 0x400);
    expect(bus.aica.clocksToEvent, 4536);
    bus.tickMasterClocks(4536);
    expect(bus.systemBus.externalStatus, 2);
    bus.write32(registers + 0x28bc, 0x400);
    expect(bus.systemBus.externalStatus, 0);
    expect(bus.aica.clocksToEvent, 4535);
    bus.tickMasterClocks(4534);
    expect(bus.systemBus.externalStatus, 0);
    bus.tickMasterClocks(1);
    expect(bus.systemBus.externalStatus, 2);
  });

  test('batched timer progression agrees with individual clocks', () {
    final batch = DcBus(), single = DcBus();
    for (final bus in [batch, single]) {
      for (var i = 0; i < 3; i++) {
        bus.write32(registers + 0x2890 + i * 4, (i << 8) | (254 - i));
      }
      bus.write32(registers + 0x28b4, 0x7ff);
    }
    for (final clocks in [1, 4534, 1, 9000, 30000]) {
      batch.tickMasterClocks(clocks);
      for (var i = 0; i < clocks; i++) {
        single.tickMasterClocks(1);
      }
      for (var i = 0; i < 3; i++) {
        expect(batch.aica.timerCounter(i), single.aica.timerCounter(i));
      }
      expect(batch.aica.soundPending, single.aica.soundPending);
      expect(batch.aica.systemPending, single.aica.systemPending);
      expect(batch.aica.clocksToEvent, single.aica.clocksToEvent);
    }
  });

  test('RTC protection, split writes, upper-bit masks and wraparound', () {
    final bus = DcBus();
    bus.write32(rtc + 4, 0x1234);
    expect(bus.read32(rtc + 4), 0);
    bus.write32(rtc + 8, 1);
    bus.write32(rtc + 4, 0xffffffff);
    bus.write32(rtc, 0xffffffff);
    expect(bus.read32(rtc), 0xffff);
    expect(bus.read32(rtc + 4), 0xffff);
    bus.write32(rtc + 4, 0);
    expect(bus.read32(rtc + 4), 0xffff);
    bus.aica.tickMasterClocks(DcAica.masterHz);
    expect(bus.read32(rtc), 0);
    expect(bus.read32(rtc + 4), 0);
    expect(() => bus.read32(rtc + 8), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write16(rtc, 0), throwsA(isA<DcUnsupported>()));
  });

  test('RTC low write resets subsecond phase, high write locks without reset',
      () {
    final bus = DcBus();
    bus.aica.tickMasterClocks(150000000);
    bus.write32(rtc + 8, 1);
    bus.write32(rtc + 4, 7);
    bus.aica.tickMasterClocks(150000000);
    expect(bus.read32(rtc + 4), 7);
    bus.write32(rtc, 2);
    bus.aica.tickMasterClocks(50000000);
    expect(bus.read32(rtc + 4), 8);
    expect(bus.read32(rtc), 2);
  });

  test('manual CPU reset retains AICA, full reset clears RAM but retains RTC',
      () {
    final core = Dc(), bus = DcBus();
    for (final target in [core.bus, bus]) {
      target.write32(wave, 0x12345678);
      target.write32(registers + 0x28b8, 0x20);
      target.write32(registers + 0x28b4, 0x20);
      target.write32(rtc + 8, 1);
      target.write32(rtc + 4, 42);
      target.write32(rtc, 0);
      target.aica.tickMasterClocks(150000000);
      Sh4(target).reset(manual: true);
      expect(target.read32(wave), 0x12345678);
      expect(target.read32(registers + 0x28b8) & 0x20, 0x20);
      expect(target.systemBus.externalStatus, 2);
    }
    core.reset();
    expect(core.bus.read32(wave), 0);
    expect(core.bus.read32(registers + 0x28b8), 0);
    core.bus.aica.tickMasterClocks(50000000);
    expect(core.bus.read32(rtc + 4), 43);
  });

  test('guest SH4 program writes and reads AICA wave RAM', () {
    final core = Dc();
    final program = Uint8List(6);
    // MOV.L R0,@R1; MOV.L @R1,R2; MOV.L R2,@R3.
    for (final (index, opcode) in [0x2102, 0x6212, 0x2322].indexed) {
      program.setUint16LE(index * 2, opcode);
    }
    core.setRom(program);
    core.cpu.pc = 0x8c010000;
    core.cpu.r[0] = 0x89abcdef;
    core.cpu.r[1] = wave;
    core.cpu.r[3] = 0xac020000;
    for (var i = 0; i < 3; i++) {
      expect(core.exec(false).stopped, isFalse, reason: core.stopReason);
    }
    expect(core.bus.ram.getUint32LE(0x20000), 0x89abcdef);
  });

  test('normal SH4 DMA copies both directions without snooping CPU cache', () {
    final bus = DcBus();
    for (var i = 0; i < 32; i++) {
      bus.ram[0x20000 + i] = i * 7;
    }
    bus.cache.ccr = 1;
    expect(bus.read32(0x80800000), 0);
    for (final (from, to) in [
      (0x0c020000, 0x00800000),
      (0x00800000, 0x0c030000)
    ]) {
      bus.dma.reset();
      bus.write32(0xffa00000, from);
      bus.write32(0xffa00004, to);
      bus.write32(0xffa00008, 1);
      bus.write32(0xffa0000c, 0x5445);
      bus.write32(0xffa00040, 1);
      bus.dma.tickTransferUnits(1);
      expect(bus.read32(0xffa00008), 0);
    }
    expect(
        bus.ram.sublist(0x30000, 0x30020), bus.ram.sublist(0x20000, 0x20020));
    expect(bus.read32(0x80800000), 0);
    expect(bus.read32(wave), 0x150e0700);
  });

  test('guest SH4 handler acknowledges the AICA timer and returns', () {
    final core = Dc()..setRom(Uint8List.fromList([0x2a, 0xe9, 9, 0]));
    final bus = core.bus;
    core.cpu.sr = 0x40000000;
    core.cpu.vbr = 0x8c030000;
    core.cpu.r[10] = 0x40;
    core.cpu.r[11] = registers + 0x28bc;
    bus.write16(0x8c030600, 0x2ba2);
    bus.write16(0x8c030602, 0x002b);
    bus.write16(0x8c030604, 9);
    bus.write32(0xa05f6934, 2);
    bus.write32(registers + 0x2890, 255);
    bus.write32(registers + 0x28b4, 0x40);
    bus.tickMasterClocks(4536);
    expect(core.cpu.irlPins, 9);
    expect(core.exec(true).executed(0), isFalse);
    expect(bus.intevt, 0x320);
    for (var i = 0; i < 4; i++) {
      expect(core.exec(true).stopped, isFalse, reason: core.stopReason);
    }
    expect(bus.systemBus.externalStatus, 0);
    expect(core.cpu.r[9], 42);
  });

  test(
      'ARM reset release executes wave-RAM instructions at rational clock edges',
      () {
    final bus = DcBus();
    for (final (i, op)
        in [0xe3a0002a, 0xe3a01c01, 0xe5810000, 0xeafffffe].indexed) {
      bus.write32(wave + 4 * i, op);
    }
    bus.tickMasterClocks(100);
    expect(bus.aica.arm.pc, 0);
    bus.write32(registers + 0x2c00, 0);
    expect(bus.aica.clocksToEvent, 9);
    bus.tickMasterClocks(8);
    expect(bus.aica.arm.pc, 0);
    bus.tickMasterClocks(1);
    expect(bus.aica.arm.pc, 4);
    expect(bus.aica.arm.r[0], 42);
    bus.tickMasterClocks(18);
    expect(bus.read32(wave + 0x100), 42);
    bus.write32(registers + 0x2c00, 1);
    expect(bus.aica.arm.pc, 0);
    expect(bus.aica.arm.cpsr, 0xd3);
    bus.tickMasterClocks(100);
    expect(bus.aica.arm.pc, 0);
    expect(bus.read32(wave + 0x100), 42);
  });

  test('SH4 starts an ARM diagnostic and both CPUs continue running', () {
    final core = Dc()..setRom(Uint8List.fromList([2, 0x21, 0xfe, 0xaf, 9, 0]));
    core.cpu.r[0] = 0;
    core.cpu.r[1] = registers + 0x2c00;
    for (final (i, op)
        in [0xe3a0002a, 0xe3a01c01, 0xe5810000, 0xeafffffe].indexed) {
      core.bus.write32(wave + 4 * i, op);
    }
    for (var i = 0; i < 1000; i++) {
      expect(core.exec(false).stopped, isFalse, reason: core.stopReason);
    }
    expect(core.bus.read32(wave + 0x100), 42);
    expect(core.bus.aica.arm.pc, 12);
    expect(core.bus.aica.arm.cycles, greaterThan(10));
  });

  test(
      'ARM writes its system-request register through the internal register map',
      () {
    final bus = DcBus();
    final program = [
      0xe59f1008,
      0xe3a00020,
      0xe5810000,
      0xeafffffe,
      0x008028b8
    ];
    for (final (i, op) in program.indexed) {
      bus.write32(wave + 4 * i, op);
    }
    bus.write32(registers + 0x28b4, 0x20);
    bus.write32(registers + 0x2c00, 0);
    bus.tickMasterClocks(100);
    expect(bus.read32(registers + 0x28b8), 0x20);
    expect(bus.systemBus.externalStatus, 2);
    expect(bus.aica.arm.r[1], 0x008028b8);
  });

  test('batched ARM scheduling matches individual master clocks', () {
    final batch = DcBus(), single = DcBus();
    final program = [
      0xe3a01c01,
      0xe3a00000,
      0xe2800001,
      0xe5810000,
      0xeafffffc
    ];
    for (final bus in [batch, single]) {
      for (final (i, op) in program.indexed) {
        bus.write32(wave + 4 * i, op);
      }
      bus.write32(registers + 0x2c00, 0);
    }
    for (final clocks in [8, 1, 17, 50, 1000, 10000]) {
      batch.tickMasterClocks(clocks);
      for (var i = 0; i < clocks; i++) {
        single.tickMasterClocks(1);
      }
      expect(batch.aica.arm.r, single.aica.arm.r);
      expect(batch.aica.arm.cpsr, single.aica.arm.cpsr);
      expect(batch.aica.arm.cycles, single.aica.arm.cycles);
      expect(batch.aica.clocksToEvent, single.aica.clocksToEvent);
      expect(batch.read32(wave + 0x100), single.read32(wave + 0x100));
    }
    Sh4(batch).reset(manual: true);
    expect(batch.aica.arm.r, single.aica.arm.r);
    expect(batch.aica.armReset, isFalse);
  });

  test('ARM development stops retain PC and leave a positive retry deadline',
      () {
    final bus = DcBus();
    bus.write32(wave, 0xe12fff1e); // ARMv4 BX is outside the ARM7DI ISA.
    bus.write32(registers + 0x2c00, 0);
    expect(() => bus.tickMasterClocks(9), throwsA(isA<DcUnsupported>()));
    expect(bus.aica.arm.pc, 0);
    expect(bus.aica.clocksToEvent, greaterThan(0));
    bus.write32(wave, 0xe3a0002a);
    bus.tickMasterClocks(9);
    expect(bus.aica.arm.r[0], 42);
    bus.aica.arm.r[1] = 0x802c00;
    bus.write32(wave + 4, 0xe5810000);
    expect(() => bus.tickMasterClocks(9), throwsA(isA<DcUnsupported>()));
    expect(bus.aica.arm.pc, 4);
    expect(bus.aica.armReset, isFalse);
  });
}
