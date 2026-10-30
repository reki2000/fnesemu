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
    core = Dc();
    bus = core.bus;
    for (var i = 0; i < 256; i++) {
      bus.ram[0x20000 + i] = (i * 3 + 7) & 255;
      bus.aica.memory[0x2000 + i] = (i * 5 + 11) & 255;
    }
  });

  test('G2 aliases, access widths, version and modem/timeout settings', () {
    for (final address in [0x005f7880, 0x025f7880, 0x805f7880, 0xa25f7880]) {
      expect(bus.read32(address), 0x12);
    }
    expect(bus.read32(base + 0x90), 0x3ff);
    bus.write32(base + 0x94, 0xffffffff);
    expect(bus.read32(base + 0x94), 0xfff);
    expect(() => bus.write32(base + 0x98, 1), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write32(base + 0x9c, 0x18), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read8(base), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write16(base, 0), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read32(base + 0xbc), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write32(base + 0x80, 0), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write32(base + 24, 1), throwsA(isA<DcUnsupported>()));
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

  test('AICA to RAM fills a FIFO before DDT and bypasses CPU cache', () {
    bus.cache.ccr = 1;
    final cached = bus.read32(0x8c020000);
    setup(direction: 1);
    bus.tickMasterClocks(128);
    expect(bus.read32(0xac020000), cached);
    expect(bus.read32(base + 0xc0), target + 32);
    expect(bus.read32(base + 0xc4), source);
    expect(bus.systemBus.normalStatus & (1 << 15), 0);
    bus.tickMasterClocks(2);
    expect(bus.ram.sublist(0x20000, 0x20020),
        bus.aica.memory.sublist(0x2000, 0x2020));
    expect(bus.read32(0x8c020000), cached);
    expect(bus.read32(0xffa00004), source + 32);
    expect(bus.systemBus.normalStatus & (1 << 15), 1 << 15);
  });

  test('texture transfers use both apertures without enabling SH4 DMA', () {
    for (var i = 0; i < 8; i++) {
      bus.write32(0xa5001000 + 4 * i, 0x12340000 + i);
    }
    setup(root: 0x05001000, ddt: false);
    bus.tickMasterClocks(200);
    expect(bus.aica.memory.getUint32LE(0x2000), 0x12340000);
    bus.write32(base + 20, 0);
    setup(root: 0x04001000, direction: 1, ddt: false);
    bus.tickMasterClocks(200);
    for (var i = 0; i < 8; i++) {
      expect(bus.read32(0xa4001000 + 4 * i), 0x12340000 + i);
    }
    expect(bus.read32(0xffa00040), 0);
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

  test('protection key and per-block overrun preserve only committed bytes',
      () {
    setup(root: 0x0c0fffe0, length: 0x80000040);
    bus.write32(base + 0xbc, 0x46594040);
    for (var i = 0; i < 64; i++) {
      bus.ram[0xfffe0 + i] = i;
    }
    final second = bus.aica.memory.sublist(0x2020, 0x2040);
    bus.tickMasterClocks(500);
    expect(
        bus.aica.memory.sublist(0x2000, 0x2020), List.generate(32, (i) => i));
    expect(bus.aica.memory.sublist(0x2020, 0x2040), second);
    expect(bus.systemBus.errorStatus, 1 << 19);
    expect(bus.systemBus.normalStatus & (1 << 15), 0);
    expect(bus.read32(0xffa00040) & 4, 0);
    core.reset();
    bus.write32(
        base + 0xbc, 0x4658007f); // Wrong key retains default protection.
    bus.write32(base, target);
    bus.write32(base + 4, source);
    bus.write32(base + 8, 0x80000020);
    bus.write32(base + 20, 1);
    bus.write32(base + 24, 1);
    bus.tickMasterClocks(100);
    expect(bus.systemBus.errorStatus, 1 << 19);
  });

  test(
      'disable cancels queued DDT and leaves partial G2 writes without an end IRQ',
      () {
    setup();
    bus.tickMasterClocks(18);
    final afterFirst = bus.aica.memory.sublist(0x2000, 0x2020);
    bus.write32(base + 20, 0);
    bus.tickMasterClocks(1000);
    expect(bus.aica.memory.sublist(0x2000, 0x2020), afterFirst);
    expect(bus.systemBus.normalStatus & (1 << 15), 0);
    expect(bus.read32(base + 24), 0);
  });

  test('suspend waits for a staged block, then resumes at the next block', () {
    setup(length: 0x80000040, trigger: 4);
    bus.tickMasterClocks(18);
    bus.write32(base + 28, 1);
    bus.tickMasterClocks(1000);
    expect(bus.read32(base + 24), 1);
    expect(bus.read32(base + 28), 0x30);
    expect(bus.read32(base + 0xc0), target + 32);
    expect(bus.read32(base + 0xc8), 32);
    bus.write32(base + 28, 0);
    bus.tickMasterClocks(500);
    expect(bus.read32(base + 24), 0);
    expect(bus.aica.memory.sublist(0x2000, 0x2040),
        bus.ram.sublist(0x20000, 0x20040));
  });

  test('external request initiates an armed DMA and gates blocks', () {
    bus.g2.setTransferRequest(0, false);
    setup(trigger: 5, length: 0x80000040, start: false);
    bus.tickMasterClocks(1000);
    expect(bus.read32(base + 24), 0);
    bus.g2.setTransferRequest(0, true);
    expect(bus.read32(base + 24), 1);
    bus.tickMasterClocks(18);
    bus.g2.setTransferRequest(0, false);
    bus.tickMasterClocks(1000);
    expect(bus.read32(base + 0xc0), target + 32);
    expect(bus.read32(base + 28), 0x10);
    bus.g2.setTransferRequest(0, true);
    bus.tickMasterClocks(500);
    expect(bus.read32(base + 24), 0);
  });

  test('normal trigger pulses repeat even while status remains latched', () {
    setup(trigger: 2, length: 32);
    bus.write32(0xa05f6950, 8);
    expect(bus.read32(base + 24), 0);
    for (var i = 0; i < 2; i++) {
      bus.systemBus.raiseNormal(8);
      expect(bus.read32(base + 24), 1);
      bus.tickMasterClocks(200);
      expect(bus.read32(base + 24), 0);
      expect(bus.read32(base + 20), 1);
    }
  });

  test('AICA external interrupt and pending-mask enable initiate G2 DMA', () {
    setup(trigger: 2);
    bus.aica.write(0x28b8, 4, 0x20);
    bus.aica.write(0x28b4, 4, 0x20);
    expect(bus.read32(base + 24), 0);
    bus.write32(0xa05f6954, 2);
    expect(bus.read32(base + 24), 1);
    bus.tickMasterClocks(200);
    expect(bus.read32(base + 24), 0);
  });

  test(
      'enabled-channel programming is visible but cannot alter its latched transfer',
      () {
    setup(length: 0x80000040);
    bus.write32(base, 0x00803000);
    bus.write32(base + 8, 0x80000020);
    expect(bus.read32(base), 0x00803000);
    bus.tickMasterClocks(500);
    expect(bus.aica.memory.sublist(0x2000, 0x2040),
        bus.ram.sublist(0x20000, 0x20040));
    bus.write32(base + 20, 1);
    bus.write32(base + 24, 1);
    bus.tickMasterClocks(200);
    expect(bus.aica.memory.sublist(0x3000, 0x3020),
        bus.ram.sublist(0x20000, 0x20020));
  });

  test('zero length is 32 MiB and cannot complete after one block', () {
    setup(length: 0x80000000);
    bus.tickMasterClocks(130);
    expect(bus.read32(base + 24), 1);
    expect(bus.read32(base + 0xc8), 0x1ffffe0);
    expect(bus.systemBus.normalStatus & (1 << 15), 0);
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

  test(
      'invalid address and trigger modes report distinct errors without a transfer',
      () {
    bus.write32(base, 0x01000000);
    expect(bus.systemBus.errorStatus, 1 << 15);
    bus.write32(0xa05f6908, 0xffffffff);
    bus.write32(base + 4, 0x05800000);
    expect(bus.systemBus.errorStatus, 1 << 15);
    bus.write32(0xa05f6908, 0xffffffff);
    bus.g2.setTransferRequest(0, false);
    setup(trigger: 1, length: 32, start: false);
    expect(() => bus.write32(base + 24, 1), throwsA(isA<DcUnsupported>()));
    expect(bus.read32(base + 24), 0);
    expect(bus.systemBus.normalStatus & (1 << 15), 0);
  });

  test('unimplemented external endpoints stop with a positive retry deadline',
      () {
    bus.write32(base + 0x20, 0x01000000);
    bus.write32(base + 0x24, source);
    bus.write32(base + 0x28, 0x80000020);
    bus.write32(base + 0xbc, 0x4659007f);
    bus.write32(0xffa00040, 0x8201);
    bus.write32(base + 0x34, 1);
    bus.write32(base + 0x38, 1);
    expect(() => bus.tickMasterClocks(1000), throwsA(isA<DcUnsupported>()));
    expect(bus.g2.clocksToEvent, greaterThan(0));
    expect(bus.read32(base + 0x38), 1);
    expect(bus.systemBus.normalStatus & (1 << 16), 0);
    bus.write32(base + 0x34, 0);
    bus.tickMasterClocks(100);
    expect(bus.read32(base + 0x38), 0);
  });

  test(
      'root reads are staged while G2 input words arrive at separate deadlines',
      () {
    setup();
    bus.tickMasterClocks(2);
    final staged = bus.ram.sublist(0x20000, 0x20020);
    bus.ram.fillRange(0x20000, 0x20020, 0xff);
    bus.write32(
        base + 0xbc, 0x46597f00); // A completed root read remains staged.
    bus.tickMasterClocks(128);
    expect(bus.aica.memory.sublist(0x2000, 0x2020), staged);
    bus.write32(base + 20, 0);
    setup(direction: 1);
    bus.tickMasterClocks(16);
    bus.aica.memory.setUint32LE(0x2004, 0xdeadbeef);
    bus.tickMasterClocks(114);
    expect(bus.ram.getUint32LE(0x20000),
        Uint8List.fromList(staged).getUint32LE(0));
    expect(bus.ram.getUint32LE(0x20004), 0xdeadbeef);
  });

  test('guest SH4 starts G2 DMA, polls completion and reads the AICA result',
      () {
    final program = Uint8List(16);
    final ops = [0x2102, 0x6212, 0x2228, 0x8bfc, 0x6342, 0x2532, 0xaffe, 9];
    for (final (i, op) in ops.indexed) {
      program.setUint16LE(i * 2, op);
    }
    core.setRom(program);
    for (var i = 0; i < 32; i++) {
      bus.ram[0x20000 + i] = i + 1;
    }
    setup(start: false);
    core.cpu.r[0] = 1;
    core.cpu.r[1] = base + 24;
    core.cpu.r[4] = 0xa0802000;
    core.cpu.r[5] = 0xac030000;
    for (var i = 0; i < 1000; i++) {
      expect(core.exec(false).stopped, isFalse, reason: core.stopReason);
    }
    expect(bus.ram.getUint32LE(0x30000), 0x04030201);
    expect(bus.systemBus.normalStatus & (1 << 15), 1 << 15);
    expect(bus.systemBus.errorStatus, 0);
  });

  test('SPG DMA deadlines match the next actual programmable interrupt', () {
    for (final mask in [8, 16, 32]) {
      for (final mode in [0, 1, 2]) {
        for (final initial in [0, 1, 55, 140, 450]) {
          final spg = DcBus().gpu.spg;
          spg.load = 0x00040008;
          spg.control = 0x100;
          spg.vblankInterrupt = 0x00040001;
          spg.hblankInterrupt = (3 << 16) | (mode << 12) | 2;
          spg.tickMasterClocks(initial);
          final expected = spg.clocksToInterrupt(mask);
          var fired = false, elapsed = 0;
          spg.onInterrupt = (sources) {
            if (sources & mask != 0) fired = true;
          };
          while (!fired && elapsed < 1000) {
            spg.tickMasterClocks(1);
            elapsed++;
          }
          expect(fired, isTrue);
          expect(expected, elapsed, reason: '$mask/$mode/$initial');
        }
      }
    }
  });

  test('G2 writes and active sound reads preserve sample-edge ordering', () {
    final single = Dc();
    final batchAudio = <double>[], singleAudio = <double>[];
    core.onAudio((packet) => batchAudio.addAll(packet.buffer));
    single.onAudio((packet) => singleAudio.addAll(packet.buffer));
    for (final system in [core, single]) {
      final targetBus = system.bus;
      targetBus.aica.memory.fillRange(0x2000, 0x2020, 0);
      for (var i = 0; i < 16; i++) {
        targetBus.ram.setUint16LE(0x20000 + i * 2, 16384);
      }
      const audio = 0xa0700000;
      targetBus.write32(audio, 0x4200);
      targetBus.write32(audio + 4, 0x2008);
      targetBus.write32(audio + 8, 0);
      targetBus.write32(audio + 12, 2);
      targetBus.write32(audio + 0x10, 31);
      targetBus.write32(audio + 0x14, 0x3fe0);
      targetBus.write32(audio + 0x24, 0xf00);
      targetBus.write32(audio + 0x28, 4);
      for (var offset = 0x2c; offset <= 0x3c; offset += 4) {
        targetBus.write32(audio + offset, 0x1ff8);
      }
      targetBus.write32(audio + 0x2800, 15);
      targetBus.write32(audio, 0xc200);
      targetBus.tickMasterClocks(4512);
      targetBus.write32(0xffa00040, 0x8201);
      targetBus.write32(base + 0xbc, 0x4659007f);
      targetBus.write32(base, target);
      targetBus.write32(base + 4, source);
      targetBus.write32(base + 8, 0x80000020);
      targetBus.write32(base + 20, 1);
      targetBus.write32(base + 24, 1);
    }
    const remaining = 1160998 - 4512;
    bus.tickMasterClocks(remaining);
    for (var i = 0; i < remaining; i++) {
      single.bus.tickMasterClocks(1);
    }
    expect(batchAudio, singleAudio);
    expect(batchAudio[0], 0);
    expect(batchAudio[2], 0.5);
  });

  test(
      'Drive DMA completion chains disc sectors through RAM into G2 wave memory',
      () {
    const driveBase = 0xa05f7000, g1 = 0xa05f7400;
    final raw = Uint8List(2352)..[15] = 1;
    for (var i = 0; i < 2048; i++) {
      raw[16 + i] = (i * 13 + 5) & 255;
    }
    core.setCdromDrive(FakeCdromDrive([raw]));
    void packet(List<int> data, bool dma) {
      final bytes = List.filled(12, 0)..setRange(0, data.length, data);
      bus.write8(driveBase + 0x84, dma ? 1 : 0);
      bus.write8(driveBase + 0x90, 10);
      bus.write8(driveBase + 0x94, 0);
      bus.write8(driveBase + 0x9c, 0xa0);
      bus.tickMasterClocks(80);
      for (var i = 0; i < 12; i += 2) {
        bus.write16(driveBase + 0x80, bytes[i] | bytes[i + 1] << 8);
      }
      bus.tickMasterClocks(80);
    }

    packet([0x13, 0, 0, 0, 10], false);
    for (var i = 0; i < 5; i++) {
      bus.read16(driveBase + 0x80);
    }
    bus.read8(driveBase + 0x9c);
    packet([0x30, 0x24, 0, 0, 150, 0, 0, 0, 0, 0, 1], true);
    setup(trigger: 2, length: 0x80000800);
    bus.write32(0xa05f6950, 1 << 14);
    bus.write32(g1 + 0xb8, 0x8843007f);
    bus.write32(g1 + 4, source);
    bus.write32(g1 + 8, 2048);
    bus.write32(g1 + 12, 1);
    bus.write32(g1 + 20, 1);
    bus.write32(g1 + 24, 1);
    bus.tickMasterClocks(400000);
    expect(bus.ram.sublist(0x20000, 0x20800), raw.sublist(16, 2064));
    expect(bus.aica.memory.sublist(0x2000, 0x2800), raw.sublist(16, 2064));
    expect(bus.read32(base + 24), 0);
    expect(bus.systemBus.normalStatus & ((1 << 14) | (1 << 15)),
        (1 << 14) | (1 << 15));
    expect(bus.systemBus.errorStatus, 0);
    expect(bus.dma.interruptPending(0), isFalse);
  });

  test(
      'a new hardware trigger cannot consume root clocks from before assertion',
      () {
    setup(trigger: 2, root: 0x05001000, ddt: false);
    bus.write32(0xa05f6950, 32);
    bus.write32(0xa5001000, 0x11111111);
    final spg = bus.gpu.spg;
    spg.load = 0x00020008;
    spg.control = 0x100;
    spg.hblankInterrupt = (3 << 16) | 0x2000;
    bus.tickMasterClocks(45);
    expect(bus.read32(base + 24), 1);
    expect(bus.read32(base + 0xc4), 0x05001000);
    bus.write32(0xa5001000, 0xdeadbeef);
    bus.tickMasterClocks(1);
    expect(bus.read32(base + 0xc4), 0x05001020);
    bus.tickMasterClocks(128);
    expect(bus.aica.memory.getUint32LE(0x2000), 0xdeadbeef);
    expect(bus.read32(base + 24), 0);
  });

  test('four G2 channels arbitrate complete bursts in round-robin order', () {
    final writes = <int>[], interrupts = <int>[];
    final devices = [0x00800000, 0x01000000, 0x03000000, 0x14000000];
    final dma = DcDmac((a, b, c, d) => true);
    final g2 = DcG2(dma,
        readRoot: (_) => Uint8List(32),
        writeRoot: (_, __) {},
        readG2: (_) => 0,
        writeG2: (address, _) {
          if (address & 31 == 0) {
            writes.add(devices.indexWhere(
                (start) => address >= start && address < start + 64));
          }
        },
        hardwareRequest: () => false,
        onNormal: interrupts.add,
        onError: (error) => fail('unexpected G2 error $error'));
    for (var i = 0; i < 4; i++) {
      g2.write(i * 32, 4, devices[i]);
      g2.write(i * 32 + 4, 4, 0x05000000);
      g2.write(i * 32 + 8, 4, 0x80000040);
      g2.write(i * 32 + 20, 4, 1);
      g2.write(i * 32 + 24, 4, 1);
    }
    for (var clock = 0; clock < 1200; clock++) {
      g2.prepare();
      final ticket = g2.serialTicket;
      g2.tickRootUnits(clock.isOdd ? 1 : 0);
      g2.tickMasterClocks(1, ticket);
    }
    expect(writes, [0, 1, 2, 3, 0, 1, 2, 3]);
    expect(interrupts, [1 << 15, 1 << 16, 1 << 17, 1 << 18]);
  });
}
