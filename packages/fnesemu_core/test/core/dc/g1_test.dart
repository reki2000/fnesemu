import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

import '../../support/fake_cdrom_drive.dart';

void main() {
  const g1 = 0xa05f7400, driveBase = 0xa05f7000, dmac = 0xffa00000;
  const destination = 0x0c020000;
  late Dc core;
  Uint8List sector(int seed, {bool audio = false}) {
    final bytes = Uint8List(2352);
    if (!audio) bytes[15] = 1;
    final offset = audio ? 0 : 16, length = audio ? 2352 : 2048;
    for (var i = 0; i < length; i++) {
      bytes[offset + i] = (i + seed) & 255;
    }
    return bytes;
  }

  void packet(List<int> data, {bool dma = false, bool execute = true}) {
    final bus = core.bus;
    final bytes = List.filled(12, 0)..setRange(0, data.length, data);
    bus.write8(driveBase + 0x84, dma ? 1 : 0);
    bus.write8(driveBase + 0x90, 0);
    bus.write8(driveBase + 0x94, dma ? 0 : 8);
    bus.write8(driveBase + 0x9c, 0xa0);
    bus.tickMasterClocks(80);
    for (var i = 0; i < 12; i += 2) {
      bus.write16(driveBase + 0x80, bytes[i] | bytes[i + 1] << 8);
    }
    if (execute) bus.tickMasterClocks(80);
  }

  void initialize(FakeCdromDrive drive) {
    core.setCdromDrive(drive);
    packet([0x13, 0, 0, 0, 10]);
    for (var i = 0; i < 5; i++) {
      core.bus.read16(driveBase + 0x80);
    }
    core.bus.read8(driveBase + 0x9c);
  }

  void read({int count = 1, int flags = 0x24, bool execute = true}) => packet([
        0x30,
        flags,
        0,
        0,
        150,
        0,
        0,
        0,
        count >> 16,
        (count >> 8) & 255,
        count & 255
      ], dma: true, execute: execute);
  void start(
      {int address = destination, int length = 2048, bool enableDdt = true}) {
    final bus = core.bus;
    if (enableDdt) bus.write32(dmac + 0x40, 0x8201);
    bus.write32(g1 + 0xb8, 0x8843407f);
    bus.write32(g1 + 4, address);
    bus.write32(g1 + 8, length);
    bus.write32(g1 + 12, 1);
    bus.write32(g1 + 0x14, 1);
    bus.write32(g1 + 0x18, 1);
  }

  setUp(() {
    core = Dc(jit: false);
  });

  test('aggregate Form 2 reaches G1 DMA with subheader and dummy bytes', () {
    final raw = Uint8List.fromList(List.generate(2352, (i) => (i * 13) & 255));
    raw[15] = 2;
    raw.setRange(16, 20, [1, 2, 0x28, 0]);
    raw.setRange(20, 24, raw.sublist(16, 20));
    initialize(FakeCdromDrive([raw], isXa: true));
    read(flags: 0x26);
    start(length: 2336);
    core.bus.tickMasterClocks(250000);
    expect(core.bus.ram.sublist(0x20000, 0x20920),
        [...raw.sublist(16, 2348), 0, 0, 0, 0]);
    expect(core.bus.read32(g1 + 0x18), 0);
  });

  test('Form 1 XA data reaches G1 DMA without subheader or EDC bytes', () {
    final raw = Uint8List.fromList(List.generate(2352, (i) => (i * 13) & 255));
    raw[15] = 2;
    raw.setRange(16, 20, [1, 2, 8, 0]);
    raw.setRange(20, 24, raw.sublist(16, 20));
    initialize(FakeCdromDrive([raw], isXa: true));
    read(flags: 0x28);
    start();
    core.bus.tickMasterClocks(200000);
    expect(core.bus.ram.sublist(0x20000, 0x20800), raw.sublist(24, 2072));
    expect(core.bus.read32(g1 + 0x18), 0);
  });










  test(
      'SH4 reset withdraws DDT but G1 can reissue after software reenables DMAC',
      () {
    final bus = core.bus;
    initialize(FakeCdromDrive([sector(29)]));
    read();
    start(length: 32);
    bus.tickMasterClocks(2240);
    Sh4(bus).reset(manual: true);
    bus.tickMasterClocks(100);
    expect(bus.read32(g1 + 0xf8), 0);
    bus.write32(dmac + 0x40, 0x8201);
    bus.tickMasterClocks(2);
    expect(bus.ram.sublist(0x20000, 0x20020), sector(29).sublist(16, 48));
  });








  test(
      'guest SH4 code starts drive DMA, polls completion and reads returned RAM',
      () {
    const ops = [0x2102, 0x6212, 0x2228, 0x8bfc, 0x6342, 0x2532, 0xaffe, 9];
    final program = Uint8List(ops.length * 2);
    for (var i = 0; i < ops.length; i++) {
      program.setUint16LE(i * 2, ops[i]);
    }
    core.setRom(program);
    final bus = core.bus;
    initialize(FakeCdromDrive([sector(61)]));
    read();
    bus.write32(dmac + 0x40, 0x8201);
    bus.write32(g1 + 0xb8, 0x8843407f);
    bus.write32(g1 + 4, destination);
    bus.write32(g1 + 8, 2048);
    bus.write32(g1 + 12, 1);
    bus.write32(g1 + 0x14, 1);
    core.cpu.r[0] = 1;
    core.cpu.r[1] = g1 + 0x18;
    core.cpu.r[4] = 0xac020000;
    core.cpu.r[5] = 0xac030000;
    for (var i = 0; i < 200000 && bus.ram.getUint32LE(0x30000) == 0; i++) {
      expect(core.exec(false).stopped, isFalse, reason: core.stopReason);
    }
    expect(bus.ram.getUint32LE(0x30000), 0x403f3e3d);
    expect(bus.ram.sublist(0x20000, 0x20800), sector(61).sublist(16, 2064));
    expect(bus.systemBus.errorStatus, 0);
    expect(bus.systemBus.normalStatus & (1 << 14), 1 << 14);
  });

}

class _PendingDrive extends FakeCdromDrive {
  _PendingDrive(super.sectors);
  bool pending = true;
  @override
  Uint8List? read(int lba) => pending ? null : super.read(lba);
}
