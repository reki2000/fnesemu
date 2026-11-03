import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/dmac.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/g2.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

import '../../support/fake_cdrom_drive.dart';

void main() {
  const base = 0xa05f7800, source = 0x0c020000, target = 0x00802000;
  late Dc core;
  late DcBus bus;
  void setup(
      {int root = source,
      int device = target,
      int length = 0x80000020,
      int direction = 0,
      int trigger = 0,
      bool ddt = true,
      bool start = true}) {
    bus.write32(base + 0xbc, 0x4659007f);
    if (ddt) bus.write32(0xffa00040, 0x8201);
    bus.write32(base, device);
    bus.write32(base + 4, root);
    bus.write32(base + 8, length);
    bus.write32(base + 12, direction);
    bus.write32(base + 16, trigger);
    bus.write32(base + 20, 1);
    if (start && trigger & 2 == 0) bus.write32(base + 24, 1);
  }

  setUp(() {
    core = Dc(jit: false);
    bus = core.bus;
    for (var i = 0; i < 256; i++) {
      bus.ram[0x20000 + i] = (i * 3 + 7) & 255;
      bus.aica.memory[0x2000 + i] = (i * 5 + 11) & 255;
    }
  });

  test('RAM to AICA stages DDT before eight G2 longword cycles and completion',
      () {
    setup();
    final old = bus.aica.memory.sublist(0x2000, 0x2020);
    bus.tickMasterClocks(17);
    expect(bus.aica.memory.sublist(0x2000, 0x2020), old);
    expect(bus.read32(0xffa00000), source + 32);
    expect(bus.read32(base + 0xc4), source + 32);
    expect(bus.read32(base + 0xc0), target);
    expect(bus.dma.interruptPending(0), isFalse);
    bus.tickMasterClocks(1);
    expect(bus.aica.memory.sublist(0x2000, 0x2004),
        bus.ram.sublist(0x20000, 0x20004));
    expect(bus.systemBus.normalStatus & (1 << 15), 0);
    bus.tickMasterClocks(112);
    expect(bus.aica.memory.sublist(0x2000, 0x2020),
        bus.ram.sublist(0x20000, 0x20020));
    expect(bus.read32(base + 24), 0);
    expect(bus.read32(base + 20), 0);
    expect(bus.read32(base + 0xc0), target + 32);
    expect(bus.read32(base + 0xc4), source + 32);
    expect(bus.read32(base + 0xc8),
        32); // Returns to programmed length after completion.
    expect(bus.systemBus.normalStatus & (1 << 15), 1 << 15);
  });



  test('DDT stalls, NMI and CPU reset retain an armed external G2 transfer',
      () {
    setup(ddt: false);
    bus.tickMasterClocks(1000);
    expect(bus.read32(base + 24), 1);
    bus.write32(0xffa00040, 0x8201);
    bus.tickMasterClocks(1);
    Sh4(bus).reset(manual: true);
    bus.tickMasterClocks(1000);
    expect(bus.read32(base + 24), 1);
    bus.write32(0xffa00040, 0x8201);
    bus.dma.nmi();
    bus.tickMasterClocks(1000);
    expect(bus.read32(0xffa00040) & 2, 2);
    bus.write32(0xffa00040, 0x8201);
    bus.tickMasterClocks(1000);
    expect(bus.read32(base + 24), 0);
    expect(bus.aica.memory.sublist(0x2000, 0x2020),
        bus.ram.sublist(0x20000, 0x20020));
  });









  test('SPG initiated DMA batches agree with individual master clocks', () {
    setup(trigger: 2);
    bus.write32(0xa05f6950, 8);
    final single = DcBus();
    single.ram.setRange(0x20000, 0x20020, bus.ram.sublist(0x20000, 0x20020));
    single.write32(0xffa00040, 0x8201);
    single.write32(base + 0xbc, 0x4659007f);
    for (var offset = 0; offset <= 20; offset += 4) {
      single.write32(base + offset, bus.read32(base + offset));
    }
    single.write32(0xa05f6950, 8);
    for (final targetBus in [bus, single]) {
      final spg = targetBus.gpu.spg;
      spg.load = 0x00020008;
      spg.control = 0x100;
      spg.vblankInterrupt = 0x00020001;
    }
    bus.tickMasterClocks(500);
    for (var i = 0; i < 500; i++) {
      single.tickMasterClocks(1);
    }
    expect(bus.aica.memory.sublist(0x2000, 0x2020),
        single.aica.memory.sublist(0x2000, 0x2020));
    expect(bus.read32(base + 24), 0);
    expect(bus.systemBus.normalStatus, single.systemBus.normalStatus);
  });









}
