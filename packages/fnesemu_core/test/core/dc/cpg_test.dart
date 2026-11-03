import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/cpg.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
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
