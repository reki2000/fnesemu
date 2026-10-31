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

  test('CD_READ2 streams multiple sectors through drive DMA', () {
    final bus = core.bus;
    final drive = FakeCdromDrive([sector(5), sector(17), sector(31)]);
    initialize(drive);
    packet([0x31, 0x24, 0, 0, 150, 0, 0, 2, 0, 0, 152], dma: true);
    start(length: 4096);
    bus.tickMasterClocks(400000);
    expect(bus.ram.sublist(0x20000, 0x21000),
        [...sector(5).sublist(16, 2064), ...sector(17).sublist(16, 2064)]);
    expect(drive.reads, [150, 151, 152]);
    expect(bus.read32(g1 + 0x18), 0);
    expect(bus.read32(g1 + 0xf8), 4096);
    expect(bus.systemBus.externalStatus & 1, 1);
    expect(bus.systemBus.normalStatus & (1 << 14), 1 << 14);
    expect(bus.systemBus.errorStatus, 0);
  });

  test('Drive DMA commits sectors to retail AICA wave RAM without SH4 DDT', () {
    final bus = core.bus;
    initialize(FakeCdromDrive([sector(43)]));
    read();
    start(address: 0x00802000, enableDdt: false);
    bus.tickMasterClocks(200000);
    expect(
        bus.aica.memory.sublist(0x2000, 0x2800), sector(43).sublist(16, 2064));
    expect(bus.read32(dmac + 0x40), 0);
    expect(bus.read32(g1 + 0x18), 0);
    expect(bus.read32(g1 + 0xf8), 2048);
    expect(bus.systemBus.normalStatus & (1 << 14), 1 << 14);
    expect(bus.systemBus.errorStatus, 0);
  });

  test('low-word configuration writes preserve strict DMA/protection widths',
      () {
    final bus = core.bus;
    for (final offset in [0x80, 0x84, 0x88, 0x8c, 0x90, 0x94, 0xa0, 0xa4]) {
      expect(() => bus.write16(g1 + offset, 0x400), returnsNormally);
    }
    bus.write16(g1 + 0xb4, 0);
    expect(bus.g1.pioReadyEnabled, isFalse);
    bus.write16(g1 + 0xb4, 1);
    expect(bus.g1.pioReadyEnabled, isTrue);
    for (final offset in [4, 8, 12, 0x14, 0x18, 0xb8]) {
      expect(() => bus.write16(g1 + offset, 0xffff),
          throwsA(isA<DcUnsupported>()));
    }
    expect(() => bus.write8(g1 + 0x80, 1), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write16(g1 + 0x82, 1), throwsA(isA<DcUnsupported>()));
  });

  test('one sector crosses the serial FIFO and channel-0 DDT before completion',
      () {
    final bus = core.bus;
    initialize(FakeCdromDrive([sector(5)]));
    read();
    start();
    expect(bus.opticalDrive.dmaAvailable, 2048);
    expect(bus.systemBus.externalStatus, 0);
    bus.tickMasterClocks(2239);
    expect(bus.ram.sublist(0x20000, 0x20020), everyElement(0));
    bus.tickMasterClocks(1);
    expect(bus.ram.sublist(0x20000, 0x20020), everyElement(0));
    expect(bus.dma.ownsDdtRequest(bus.g1), isTrue);
    bus.tickMasterClocks(2);
    expect(bus.ram.sublist(0x20000, 0x20020), sector(5).sublist(16, 48));
    bus.tickMasterClocks(200000);
    expect(bus.ram.sublist(0x20000, 0x20800), sector(5).sublist(16, 2064));
    expect(bus.read32(g1 + 0x18), 0);
    expect(bus.read32(g1 + 4), destination);
    expect(bus.read32(g1 + 8), 2048);
    expect(bus.read32(g1 + 0xf4), destination + 2016);
    expect(bus.read32(g1 + 0xf8), 2048);
    expect(bus.read32(dmac + 4), destination + 2048);
    expect(bus.read32(dmac + 8), 0);
    expect(bus.read32(dmac + 12), 0x853c3);
    expect(bus.dma.interruptPending(0), isFalse);
    expect(bus.systemBus.normalStatus & (1 << 14), 1 << 14);
    expect(bus.systemBus.externalStatus, 1);
  });

  test(
      'Drive DMA waits for DDT enable and NMI recovery without losing FIFO data',
      () {
    final bus = core.bus;
    initialize(FakeCdromDrive([sector(9)]));
    read();
    start(enableDdt: false);
    bus.tickMasterClocks(10000);
    expect(bus.read32(g1 + 0xf8), 0);
    expect(bus.g1.busy, isTrue);
    bus.write32(dmac + 0x40, 0x8201);
    bus.dma.nmi();
    bus.tickMasterClocks(10000);
    expect(bus.read32(g1 + 0xf8), 0);
    expect(bus.read32(dmac + 0x40) & 2, 2);
    bus.write32(dmac + 0x40, 0x8201);
    bus.tickMasterClocks(200000);
    expect(bus.ram.sublist(0x20000, 0x20800), sector(9).sublist(16, 2064));
  });

  test(
      'Drive DMA bypasses CPU cache and MMU, including the supported RAM image',
      () {
    final bus = core.bus;
    initialize(FakeCdromDrive([sector(11)]));
    bus.write32(0xff00001c, 5);
    expect(bus.read32(0x8c020000), 0);
    read();
    start(address: 0x0e020000);
    bus.tickMasterClocks(200000);
    expect(bus.read32(0xac020000), 0x0e0d0c0b);
    expect(bus.read32(0x8c020000), 0);
    expect(bus.read32(g1 + 0xf4), 0x0e0207e0);
  });

  test('VRAM transfers use the aperture layout and do not require RAM DDT', () {
    final bus = core.bus;
    initialize(FakeCdromDrive([sector(17)]));
    read();
    start(address: 0x06000000, enableDdt: false);
    bus.tickMasterClocks(200000);
    expect(bus.gpu.readMemory(0x04000000, 2048, peek: true),
        sector(17).sublist(16, 2064));
    expect(bus.read32(dmac + 12), 0);
    expect(bus.systemBus.normalStatus & (1 << 14), 1 << 14);
  });

  test('protection overrun preserves completed blocks and never raises DMAC AE',
      () {
    final bus = core.bus;
    initialize(FakeCdromDrive([sector(21)]));
    read();
    start(address: 0x0c0fffe0, length: 64);
    bus.write32(g1 + 0xb8, 0x88434040);
    bus.tickMasterClocks(10000);
    expect(bus.ram.sublist(0xfffe0, 0x100000), sector(21).sublist(16, 48));
    expect(bus.ram.sublist(0x100000, 0x100020), everyElement(0));
    expect(bus.systemBus.errorStatus, 1 << 13);
    expect(bus.read32(dmac + 0x40) & 4, 0);
    expect(bus.read32(g1 + 0xf8), 32);
    expect(bus.systemBus.normalStatus & (1 << 14), 0);
  });

  test('disable withdraws pending DDT without writing or reporting completion',
      () {
    final bus = core.bus;
    initialize(FakeCdromDrive([sector(25)]));
    read();
    start(length: 32);
    bus.tickMasterClocks(2240);
    expect(bus.dma.ownsDdtRequest(bus.g1), isTrue);
    bus.write32(g1 + 0x18, 0);
    expect(bus.g1.busy, isTrue);
    bus.write32(g1 + 0x14, 0);
    bus.tickMasterClocks(10000);
    expect(bus.ram.sublist(0x20000, 0x20020), everyElement(0));
    expect(bus.read32(dmac + 12) & 2, 0);
    expect(bus.systemBus.normalStatus & (1 << 14), 0);
    expect(bus.dma.ownsDdtRequest(bus.g1), isFalse);
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
      'raw sectors cross a FIFO boundary and final undefined padding is isolated',
      () {
    final bus = core.bus;
    final a = sector(3, audio: true), b = sector(19, audio: true);
    initialize(FakeCdromDrive([a, b], audioTracks: {1}));
    read(count: 2, flags: 0x22);
    start(length: 4704);
    bus.tickMasterClocks(500000);
    expect(bus.ram.sublist(0x20000, 0x20000 + 4704), [...a, ...b]);
    expect(bus.read32(g1 + 0xf8), 4704);
    expect(bus.systemBus.externalStatus, 1);
  });

  test('non-block final length pads only its root-bus block', () {
    final bus = core.bus;
    initialize(FakeCdromDrive([sector(31)]));
    read();
    start(length: 33);
    bus.ram.fillRange(0x20000, 0x20060, 0xcc);
    bus.tickMasterClocks(10000);
    expect(bus.ram.sublist(0x20000, 0x20021), sector(31).sublist(16, 49));
    expect(bus.ram.sublist(0x20021, 0x20040), everyElement(0));
    expect(bus.ram.sublist(0x20040, 0x20060), everyElement(0xcc));
    expect(bus.read32(g1 + 0xf8), 64);
    expect(bus.opticalDrive.dmaActive,
        isTrue); // More than this host DMA was requested.
  });

  test('new media invalidates staged data before a pending root write', () {
    final bus = core.bus;
    initialize(FakeCdromDrive([sector(37)]));
    read();
    start(length: 32);
    bus.tickMasterClocks(2240);
    core.setCdromDrive(FakeCdromDrive([sector(91)]));
    bus.tickMasterClocks(10);
    expect(bus.g1.busy, isFalse);
    expect(bus.ram.sublist(0x20000, 0x20020), everyElement(0));
    expect(bus.systemBus.normalStatus & (1 << 14), 0);
    expect(bus.read32(dmac + 0x40) & 4, 0);
  });

  test('DMA can be armed before the sector reaches the SPI buffer', () {
    final bus = core.bus;
    initialize(FakeCdromDrive([sector(45)]));
    read(execute: false);
    start(length: 32);
    bus.tickMasterClocks(79);
    expect(bus.read32(g1 + 0xf8), 0);
    bus.tickMasterClocks(1);
    expect(bus.opticalDrive.dmaAvailable, 2048);
    bus.tickMasterClocks(2242);
    expect(bus.ram.sublist(0x20000, 0x20020), sector(45).sublist(16, 48));
  });

  test('large and single-clock schedules commit the same bytes and registers',
      () {
    final original = core;
    initialize(FakeCdromDrive([sector(49)]));
    read();
    start(length: 64);
    final other = Dc();
    core = other;
    initialize(FakeCdromDrive([sector(49)]));
    read();
    start(length: 64);
    core = original;
    original.bus.tickMasterClocks(10000);
    for (var i = 0; i < 10000; i++) {
      other.bus.tickMasterClocks(1);
    }
    expect(original.bus.ram.sublist(0x20000, 0x20040),
        other.bus.ram.sublist(0x20000, 0x20040));
    for (final offset in [0x18, 0xf4, 0xf8]) {
      expect(original.bus.read32(g1 + offset), other.bus.read32(g1 + offset));
    }
    expect(original.bus.dma.read(4), other.bus.dma.read(4));
    expect(
        original.bus.systemBus.normalStatus, other.bus.systemBus.normalStatus);
    expect(original.bus.systemBus.externalStatus,
        other.bus.systemBus.externalStatus);
  });

  test(
      'asynchronous sector availability is sampled before a long scheduler slice',
      () {
    final original = core, a = _PendingDrive([sector(53)]);
    initialize(a);
    read();
    start(length: 64);
    final other = Dc(), b = _PendingDrive([sector(53)]);
    core = other;
    initialize(b);
    read();
    start(length: 64);
    core = original;
    expect(original.bus.read32(g1 + 0xf8), 0);
    a.pending = b.pending = false;
    original.bus.tickMasterClocks(10000);
    for (var i = 0; i < 10000; i++) {
      other.bus.tickMasterClocks(1);
    }
    expect(
        original.bus.ram.sublist(0x20000, 0x20040), sector(53).sublist(16, 80));
    expect(original.bus.ram.sublist(0x20000, 0x20040),
        other.bus.ram.sublist(0x20000, 0x20040));
    expect(original.bus.read32(g1 + 0xf8), 64);
    expect(other.bus.read32(g1 + 0xf8), 64);
  });

  test('zero length means 32 MiB and cannot complete on a shorter SPI command',
      () {
    final bus = core.bus;
    initialize(FakeCdromDrive([sector(57)]));
    read();
    start(length: 0);
    bus.tickMasterClocks(200000);
    expect(bus.read32(g1 + 8), 0);
    expect(bus.read32(g1 + 0xf8), 2048);
    expect(bus.g1.busy, isTrue);
    expect(bus.systemBus.normalStatus & (1 << 14), 0);
    bus.write32(g1 + 0x14, 0);
    expect(bus.g1.busy, isFalse);
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

  test(
      'G1 access at DMA reports error, but cache hits and peeks do not access G1',
      () {
    final bus = core.bus;
    initialize(FakeCdromDrive([sector(41)]));
    bus.write32(0xff00001c, 5);
    bus.read32(0x80000000);
    read();
    start();
    expect(bus.read32(0x80000000), 0);
    expect(bus.peek8(0xa0000000), 0);
    expect(bus.systemBus.errorStatus, 0);
    expect(() => bus.read32(0x80000020), throwsA(isA<DcUnsupported>()));
    expect(bus.systemBus.errorStatus, 1 << 14);
    bus.write32(0xa05f6908, 1 << 14);
    expect(() => bus.read8(driveBase + 0x9c), throwsA(isA<DcUnsupported>()));
    expect(bus.systemBus.errorStatus, 1 << 14);
  });
}

class _PendingDrive extends FakeCdromDrive {
  _PendingDrive(super.sectors);
  bool pending = true;
  @override
  Uint8List? read(int lba) => pending ? null : super.read(lba);
}
