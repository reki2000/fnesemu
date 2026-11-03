import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:fnesemu_core/src/core/dc/system_bus.dart';
import 'package:test/test.dart';

void main() {
  const base = 0xa05f6900;
  late DcBus bus;
  setUp(() => bus = DcBus());

  test(
      'normal/error status latches, clears selected ones and retains summaries',
      () {
    bus.systemBus.raiseNormal(0x28);
    bus.systemBus.raiseError(0x8100);
    bus.systemBus.setExternal(5);
    expect(bus.read32(base), 0xc0000028);
    bus.write32(base, 0xc0000008);
    expect(bus.read32(base), 0xc0000020);
    bus.write32(base + 8, 0x8000);
    expect(bus.read32(base + 8), 0x100);
    bus.systemBus.raiseError(0x10);
    bus.write32(base + 8, 0x100);
    expect(bus.read32(base + 8), 0x10);
    bus.write32(base + 8, 0xffffffff);
    expect(bus.read32(base), 0x40000020);
    bus.write32(base + 4, 0xffffffff);
    expect(bus.read32(base + 4), 5);
    bus.systemBus.setExternal(0);
    expect(bus.read32(base), 0x20);
  });





  test(
      'controller reset retains external levels; CPU reset retains HOLLY state',
      () {
    bus.systemBus.setExternal(2);
    bus.systemBus.raiseNormal(8);
    bus.write32(base + 0x34, 2);
    final cpu = Sh4(bus);
    cpu.reset(manual: true);
    expect(bus.read32(base), 0x40000008);
    expect(bus.read32(base + 0x34), 2);
    bus.systemBus.reset();
    expect(bus.read32(base), 0x40000000);
    expect(bus.systemBus.interruptLevel, 0);
    bus.systemBus.reset(clearExternal: true);
    expect(bus.read32(base), 0);
  });

  test('guest HOLLY handler acknowledges the event and resumes through RTE',
      () {
    final core = Dc()..setRom(Uint8List.fromList([0x2a, 0xe9, 9, 0]));
    addTearDown(core.dispose);
    core.cpu.sr = 0x40000000;
    core.cpu.vbr = 0x8c030000;
    core.cpu.r[10] = 8;
    core.cpu.r[11] = base;
    core.bus.write16(0x8c030600, 0x2ba2);
    core.bus.write16(0x8c030602, 0x002b);
    core.bus.write16(0x8c030604, 9);
    core.bus.write32(base + 0x30, 8);
    core.bus.systemBus.raiseNormal(8);
    expect(core.cpu.irlPins, 9);
    expect(core.exec(true).executed(0), isFalse);
    expect(core.bus.intevt, 0x320);
    expect(core.cpu.spc, Dc.programAddress);
    for (var i = 0; i < 4; i++) {
      expect(core.exec(true).stopped, isFalse);
    }
    expect(core.cpu.r[9], 42);
    expect(core.bus.systemBus.normalStatus, 0);
    expect(core.cpu.irlPins, 15);
  });

}
