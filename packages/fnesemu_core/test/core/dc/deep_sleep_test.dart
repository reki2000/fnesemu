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





}
