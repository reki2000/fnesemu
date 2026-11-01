import 'dart:math';

import 'package:fnesemu_core/src/core/dc/bsc.dart';
import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:test/test.dart';

void main() {
  test(
      'refresh counters require the documented key including RFCR upper six bits',
      () {
    final bsc = DcBsc();
    for (final offset in [28, 32, 36, 40]) {
      bsc.write(offset, 2, 0x1234);
      expect(bsc.read(offset, 2), 0);
    }
    bsc.write(32, 2, 0xa5ab);
    bsc.write(36, 2, 0xa5cd);
    bsc.write(40, 2, 0xa7ff);
    expect(bsc.read(32, 2), 0xab);
    expect(bsc.read(36, 2), 0xcd);
    expect(bsc.read(40, 2), 1023);
  });

  test(
      'all refresh divider settings produce the first match on the correct edge',
      () {
    const divisors = [4, 16, 64, 256, 1024, 2048, 4096];
    for (var setting = 1; setting <= 7; setting++) {
      final bsc = DcBsc();
      bsc.write(28, 2, 0xa500 | (setting << 3));
      bsc.write(36, 2, 0xa503);
      bsc.tickBusClocks(divisors[setting - 1] * 3 - 1);
      expect(bsc.read(40, 2), 0);
      bsc.tickBusClocks(1);
      expect(bsc.read(32, 2), 0);
      expect(bsc.read(40, 2), 1);
      expect(bsc.read(28, 2) & 0x80, 0x80);
    }
  });

  test('disabled clock holds and zero constant matches after eight-bit wrap',
      () {
    final bsc = DcBsc();
    bsc.tickBusClocks(1000000);
    expect(bsc.read(40, 2), 0);
    bsc.write(28, 2, 0xa508);
    bsc.tickBusClocks(4 * 256 - 1);
    expect(bsc.read(32, 2), 255);
    expect(bsc.read(40, 2), 0);
    bsc.tickBusClocks(1);
    expect(bsc.read(32, 2), 0);
    expect(bsc.read(40, 2), 1);
  });

  test('RFCR wraps at 1024 or 512 and status flags are write-zero-to-clear',
      () {
    for (final limit in [512, 1024]) {
      final bsc = DcBsc();
      bsc.write(28, 2, 0xa508 | (limit == 512 ? 1 : 0));
      bsc.write(36, 2, 0xa501);
      bsc.write(40, 2, 0xa400 | (limit - 1));
      bsc.tickBusClocks(4);
      expect(bsc.read(40, 2), 0);
      expect(bsc.read(28, 2) & 0x84, 0x84);
      bsc.write(28, 2, 0xa58c | (limit == 512 ? 1 : 0));
      expect(bsc.read(28, 2) & 0x84, 0x84);
      bsc.write(28, 2, 0xa508);
      expect(bsc.read(28, 2) & 0x84, 0);
      bsc.write(28, 2, 0xa54a);
      expect(bsc.read(28, 2), 0x4a);
      expect(bsc.interruptEvent, 0);
    }
  });

  test('latched refresh flags request enabled interrupts until cleared', () {
    final bsc = DcBsc();
    bsc.write(28, 2, 0xa508);
    bsc.write(36, 2, 0xa501);
    bsc.write(40, 2, 0xa7ff);
    bsc.tickBusClocks(4);
    expect(bsc.interruptEvent, 0);
    bsc.write(28, 2, 0xa5ce);
    expect(bsc.interruptEvent, 0x580);
    expect(bsc.interruptEvent, 0x580);
    bsc.write(28, 2, 0xa54e);
    expect(bsc.interruptEvent, 0x5a0);
    bsc.write(28, 2, 0xa54a);
    expect(bsc.interruptEvent, 0);
  });

  test('batched counter matches agree with independent per-clock stepping', () {
    final bsc = DcBsc(), random = Random(13);
    bsc.write(28, 2, 0xa518);
    bsc.write(32, 2, 0xa5fa);
    bsc.write(36, 2, 0xa507);
    var count = 250, refresh = 0, phase = 0;
    for (var trial = 0; trial < 100; trial++) {
      final clocks = random.nextInt(10000);
      for (var i = 0; i < clocks; i++) {
        phase++;
        if (phase != 64) continue;
        phase = 0;
        count = (count + 1) % 256;
        if (count == 7) {
          count = 0;
          refresh = (refresh + 1) % 1024;
        }
      }
      bsc.tickBusClocks(clocks);
      expect(bsc.read(32, 2), count);
      expect(bsc.read(40, 2), refresh);
    }
  });

  test('manual reset retains registers, counters and divider phase', () {
    final bsc = DcBsc();
    bsc.write(28, 2, 0xa508);
    bsc.write(36, 2, 0xa501);
    bsc.tickBusClocks(3);
    bsc.reset(powerOn: false);
    bsc.tickBusClocks(1);
    expect(bsc.read(40, 2), 1);
    bsc.reset();
    expect(bsc.read(28, 2), 0);
    expect(bsc.read(40, 2), 0);
  });

  test('SDRAM precharge and address-encoded 32/64-bit mode writes are separate',
      () {
    final bsc = DcBsc();
    bsc.writeMode(1, 0xff940190, 1);
    expect(bsc.precharges[1], 1);
    expect(bsc.mode[1], 0);
    bsc.write(20, 4, 0x40000000);
    bsc.write(4, 2, 0);
    bsc.writeMode(1, 0xff940190, 1);
    expect(bsc.mode[1], 0x32);
    bsc.write(4, 2, 0x3ffc);
    bsc.writeMode(0, 0xff900088, 1);
    expect(bsc.mode[0], 0x22);
    expect(
        () => bsc.writeMode(0, 0xff900088, 2), throwsA(isA<DcUnsupported>()));
    bsc.write(4, 2, 0x10);
    expect(
        () => bsc.writeMode(0, 0xff900088, 1), throwsA(isA<DcUnsupported>()));
  });

  test('CPU bus maps P4/area-7 aliases and uses the CPG bus-clock divider', () {
    final bus = DcBus();
    bus.write16(0xff800024, 0xa501);
    bus.write16(0x1f80001c, 0xa508);
    bus.tickMasterClocks(bus.cpg.busPeriod * 4);
    expect(bus.read16(0xff800028), 1);
    expect(bus.read16(0x1f800028), 1);
    bus.write8(0xff940190, 0);
    expect(bus.bsc.precharges[1], 1);
    bus.resetCpuRegisters(manual: true);
    expect(bus.read16(0xff800028), 1);
    bus.resetCpuRegisters();
    expect(bus.read16(0xff800028), 0);
  });
}
