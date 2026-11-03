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






  test('manual CPU reset retains AICA, full reset clears RAM but retains RTC',
      () {
    final core = Dc(), bus = DcBus();
    addTearDown(core.dispose);
    var now = DateTime.utc(2026);
    for (final target in [core.bus, bus]) {
      target.aica.clock = () => now;
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
    now = now.add(const Duration(seconds: 1));
    expect(core.bus.read32(rtc + 4), 43);
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

}
