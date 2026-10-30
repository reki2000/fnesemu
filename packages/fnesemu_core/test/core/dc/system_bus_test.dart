import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:fnesemu_core/src/core/dc/system_bus.dart';
import 'package:test/test.dart';

void main() {
  const base = 0xa05f6900;
  late DcBus bus;
  setUp(() => bus = DcBus());

  test('HOLLY registers use longwords and area-0 image aliases', () {
    for (final offset in [
      0,
      4,
      8,
      0x10,
      0x14,
      0x18,
      0x20,
      0x24,
      0x28,
      0x30,
      0x34,
      0x38,
      0x40,
      0x44,
      0x50,
      0x54
    ]) {
      expect(bus.read32(base + offset), 0);
    }
    bus.write32(base + 0x10, 0x1234);
    for (final address in [0x005f6910, 0x025f6910, 0x805f6910, 0xa25f6910]) {
      expect(bus.read32(address), 0x1234);
    }
    expect(() => bus.read8(base), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read16(base), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write8(base + 0x10, 0), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write16(base + 0x10, 0), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write32(base + 0x11, 0), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read32(base + 12), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read32(0xc05f6900), throwsA(isA<DcUnsupported>()));
    expect(bus.read32(base + 0x10), 0x1234);
  });

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

  test('reserved bits and HOLLY1/2 punch-through source are masked', () {
    bus.systemBus.raiseNormal(0xffffffff);
    bus.systemBus.raiseError(0xffffffff);
    bus.systemBus.setExternal(0xffffffff);
    expect(bus.read32(base), 0xc03fffff);
    expect(bus.read32(base + 4), 15);
    expect(bus.read32(base + 8), 0x9fffffff);
    for (final tier in [0x10, 0x20, 0x30]) {
      for (final offset in [0, 4, 8]) {
        bus.write32(base + tier + offset, 0xffffffff);
      }
      expect(bus.read32(base + tier), 0x3fffff);
      expect(bus.read32(base + tier + 4), 15);
      expect(bus.read32(base + tier + 8), 0x9fffffff);
    }
    final holly1 = DcSystemBus(holly2: false);
    holly1.raiseNormal(1 << 21);
    holly1.write(0x10, 4, 0xffffffff);
    expect(holly1.read(0, 4), 0);
    expect(holly1.read(0x10, 4), 0x1fffff);
  });

  for (final kind in [0, 1, 2]) {
    test('source kind $kind is masked by level 6 then 4 then 2', () {
      switch (kind) {
        case 0:
          bus.systemBus.raiseNormal(1);
        case 1:
          bus.systemBus.setExternal(1);
        case 2:
          bus.systemBus.raiseError(1);
      }
      expect(bus.systemBus.irlPins, 15);
      for (final tier in [0x10, 0x20, 0x30]) {
        bus.write32(base + tier + kind * 4, 1);
      }
      expect(bus.systemBus.interruptLevel, 6);
      expect(bus.systemBus.irlPins, 9);
      bus.write32(base + 0x30 + kind * 4, 0);
      expect(bus.systemBus.interruptLevel, 4);
      expect(bus.systemBus.irlPins, 11);
      bus.write32(base + 0x20 + kind * 4, 0);
      expect(bus.systemBus.interruptLevel, 2);
      expect(bus.systemBus.irlPins, 13);
      bus.write32(base + 0x10 + kind * 4, 0);
      expect(bus.systemBus.irlPins, 15);
    });
  }

  test('summary bits do not become normal interrupt sources', () {
    bus.systemBus.raiseError(1);
    bus.systemBus.setExternal(1);
    bus.write32(base + 0x30, 0xc0000000);
    expect(bus.read32(base), 0xc0000000);
    expect(bus.systemBus.interruptLevel, 0);
  });

  test('GPU/G2 trigger masks select normal and external sources independently',
      () {
    bus.write32(base + 0x40, 8);
    bus.write32(base + 0x54, 2);
    bus.systemBus.raiseNormal(8);
    expect(bus.systemBus.gpuDmaRequest, isTrue);
    expect(bus.systemBus.g2DmaRequest, isFalse);
    bus.systemBus.setExternal(2);
    expect(bus.systemBus.g2DmaRequest, isTrue);
    bus.write32(base, 8);
    expect(bus.systemBus.gpuDmaRequest, isFalse);
    bus.systemBus.setExternal(0);
    expect(bus.systemBus.g2DmaRequest, isFalse);
    bus.systemBus.raiseError(8);
    expect(bus.systemBus.gpuDmaRequest, isFalse);
    expect(bus.systemBus.g2DmaRequest, isFalse);
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

  test('HOLLY interrupt obeys SH4 IMASK and BL', () {
    final cpu = Sh4(bus);
    cpu.pc = 0x8c010000;
    bus.write16(cpu.pc, 9);
    bus.write16(cpu.pc + 2, 9);
    cpu.vbr = 0x8c030000;
    bus.write32(base + 0x30, 8);
    bus.systemBus.raiseNormal(8);
    cpu.sr = 0x40000060;
    cpu.step();
    expect(cpu.pc, 0x8c010002);
    cpu.sr = 0x50000000;
    cpu.step();
    expect(cpu.pc, 0x8c010004);
    cpu.sr = 0x40000050;
    cpu.step();
    expect(cpu.pc, 0x8c030600);
    expect(bus.intevt, 0x320);
  });
}
