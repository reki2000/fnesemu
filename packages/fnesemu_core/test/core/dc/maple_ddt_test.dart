import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/maple_controller.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

import '../../support/fake_cdrom_drive.dart';

void main() {
  const maple = 0xa05f6c00, dmac = 0xffa00000;
  late DcBus bus;
  late _Controller controller;
  void descriptor(
      int offset, int instruction, int destination, List<int> bytes) {
    bus.ram.setUint32LE(offset, instruction);
    bus.ram.setUint32LE(offset + 4, destination);
    for (var i = 0; i < bytes.length; i++) {
      bus.ram[offset + 8 + (i ^ 3)] = bytes[i];
    }
  }

  void start({bool enableDdt = true}) {
    if (enableDdt) bus.write32(dmac + 0x40, 0x8201);
    bus.write32(maple + 0x8c, 0x6155407f);
    bus.write32(maple + 0xe8, 0);
    bus.write32(maple + 4, 0x0c010000);
    bus.write32(maple + 0x14, 1);
    bus.write32(maple + 0x18, 1);
  }

  setUp(() {
    bus = DcBus();
    controller = _Controller();
    bus.maple.controllers[0] = controller;
    descriptor(0x10000, 0x80000000, 0x0c020000, [3, 32, 0, 0]);
  });
  test('disabled DDT waits without consuming packets or modifying receive RAM',
      () {
    start(enableDdt: false);
    bus.tickMasterClocks(1000000);
    expect(controller.exchanges, 0);
    expect(bus.maple.busy, isTrue);
    expect(bus.ram.getUint32LE(0x20000), 0);
    expect(bus.systemBus.normalStatus & (1 << 12), 0);
    bus.write32(dmac + 0x40, 0x8201);
    bus.tickMasterClocks(10000);
    expect(controller.exchanges, 1);
    expect(bus.ram.getUint32LE(0x20000), 0x07002000);
    expect(bus.maple.busy, isFalse);
  });
  test('source and receive transfers each occupy a distinct root-bus unit', () {
    start();
    expect(bus.dma.ownsDdtRequest(bus.maple), isTrue);
    expect(bus.read32(dmac), 0x0c010000);
    bus.tickMasterClocks(1);
    expect(controller.exchanges, 0);
    bus.tickMasterClocks(1);
    expect(controller.exchanges, 1);
    expect(bus.read32(dmac), 0x0c010020);
    bus.tickMasterClocks(7999);
    expect(bus.ram.getUint32LE(0x20000), 0);
    bus.tickMasterClocks(1);
    expect(bus.ram.getUint32LE(0x20000), 0);
    expect(bus.maple.busy, isTrue);
    bus.tickMasterClocks(2);
    expect(bus.read32(dmac + 4), 0x0c020020);
    expect(bus.read32(dmac + 8), 0);
    expect(bus.read32(dmac + 12) & 3, 3);
    expect(bus.ram.getUint32LE(0x20000), 0x07002000);
    expect(bus.maple.busy, isFalse);
  });
  test(
      'receive blocks become visible separately and completion follows the last write',
      () {
    descriptor(0x10000, 0x80000000, 0x0c020000, [1, 32, 0, 0]);
    bus.ram.fillRange(0x20000, 0x20080, 0xcc);
    start();
    bus.tickMasterClocks(97603);
    expect(bus.ram.sublist(0x20000, 0x20080), everyElement(0xcc));
    bus.tickMasterClocks(1);
    expect(bus.ram.getUint32LE(0x20000), 0x0500201c);
    expect(bus.ram.sublist(0x20020, 0x20080), everyElement(0xcc));
    expect(bus.maple.busy, isTrue);
    expect(bus.systemBus.normalStatus & (1 << 12), 0);
    bus.tickMasterClocks(6);
    expect(bus.maple.busy, isFalse);
    expect(bus.read32(dmac + 4), 0x0c020080);
    expect(bus.systemBus.normalStatus & (1 << 12), 1 << 12);
  });

  test('source and receive DDT waits do not report a serial VBlank overrun',
      () {
    start(enableDdt: false);
    bus.maple.verticalBlankIn();
    expect(bus.systemBus.normalStatus & (1 << 13), 0);
    bus.write32(dmac + 0x40, 0x8201);
    bus.tickMasterClocks(8002);
    bus.dma.nmi();
    bus.maple.verticalBlankIn();
    expect(bus.systemBus.normalStatus & (1 << 13), 0);
    expect(bus.maple.busy, isTrue);
  });

  test('NMI pauses a ready response and recovery never repeats its exchange',
      () {
    start();
    bus.tickMasterClocks(8002);
    bus.dma.nmi();
    bus.tickMasterClocks(10000);
    expect(bus.maple.busy, isTrue);
    expect(bus.ram.getUint32LE(0x20000), 0);
    expect(controller.exchanges, 1);
    expect(bus.read32(dmac + 0x40) & 2, 2);
    bus.write32(dmac + 0x40, 0x8201);
    bus.tickMasterClocks(2);
    expect(bus.maple.busy, isFalse);
    expect(bus.ram.getUint32LE(0x20000), 0x07002000);
    expect(controller.exchanges, 1);
  });
  test('a DMAC reset withdraws a queued response and retry preserves its data',
      () {
    start();
    bus.tickMasterClocks(8002);
    expect(bus.dma.ownsDdtRequest(bus.maple), isTrue);
    bus.dma.reset();
    bus.tickMasterClocks(1000);
    expect(bus.maple.busy, isTrue);
    expect(bus.ram.getUint32LE(0x20000), 0);
    bus.write32(dmac + 0x40, 0x8201);
    bus.tickMasterClocks(2);
    expect(bus.maple.busy, isFalse);
    expect(bus.ram.getUint32LE(0x20000), 0x07002000);
    expect(controller.exchanges, 1);
  });

  test(
      'DMAC standby freezes the root transaction rather than Maple device clocks',
      () {
    bus.cpg.standby = 0x10;
    start();
    bus.tickMasterClocks(20000);
    expect(controller.exchanges, 0);
    expect(bus.maple.busy, isTrue);
    expect(controller.clocks, 20000);
    bus.cpg.standby = 0;
    bus.tickMasterClocks(10000);
    expect(bus.maple.busy, isFalse);
  });
  test(
      'disabling before source completion cancels the request without an exchange',
      () {
    start();
    bus.write32(maple + 0x14, 0);
    expect(bus.dma.ownsDdtRequest(bus.maple), isFalse);
    bus.tickMasterClocks(100000);
    expect(controller.exchanges, 0);
    expect(bus.ram.getUint32LE(0x20000), 0);
    expect(bus.systemBus.normalStatus & (1 << 12), 0);
  });
  test('full Maple reset cancels a pending source transaction', () {
    start();
    bus.maple.reset();
    bus.tickMasterClocks(100000);
    expect(bus.dma.ownsDdtRequest(bus.maple), isFalse);
    expect(controller.exchanges, 0);
    expect(bus.maple.busy, isFalse);
  });
  test(
      'prefetched command bytes remain a snapshot until the aligned block retires',
      () {
    descriptor(0x10000, 0, 0x0c020000, [1, 32, 0, 0]);
    descriptor(0x1000c, 0x80000001, 0x0c020100, [9, 32, 0, 1, 0, 0, 0, 1]);
    start();
    bus.tickMasterClocks(2);
    bus.ram.setUint32LE(0x10018, 2);
    bus.tickMasterClocks(200000);
    expect(bus.ram.getUint32LE(0x20100), 0x08002003);
    expect(bus.read32(dmac), 0x0c010020);
    expect(controller.exchanges, 2);
  });
  test('maximum packet payload fetches every required 32-byte source block',
      () {
    final packet = List<int>.filled(1024, 0)
      ..setRange(0, 4, [0x7f, 32, 0, 255]);
    descriptor(0x10000, 0x800000ff, 0x0c020000, packet);
    start();
    bus.tickMasterClocks(1000000);
    expect(bus.read32(dmac), 0x0c010420);
    expect(bus.ram.getUint32LE(0x20000), 0xfd002000);
    expect(bus.maple.busy, isFalse);
  });
  test('a queued external DDT owner runs before Maple can fetch its descriptor',
      () {
    bus.write32(dmac + 0x40, 0x8201);
    final owner = Object();
    var transfers = 0;
    expect(
        bus.dma.requestDdt32(owner, 0x0c030000, write: true, transfer: (_, __) {
          transfers++;
          return true;
        }),
        isTrue);
    start();
    bus.tickMasterClocks(2);
    expect(transfers, 1);
    expect(controller.exchanges, 0);
    bus.tickMasterClocks(2);
    expect(controller.exchanges, 1);
    bus.tickMasterClocks(10000);
    expect(bus.ram.getUint32LE(0x20000), 0x07002000);
  });
  test(
      'an unsupported device packet remains replayable after source DDT completes',
      () {
    descriptor(0x10000, 0x80000000, 0x0c020000, [2, 32, 0, 0]);
    start();
    expect(() => bus.tickMasterClocks(2), throwsA(isA<DcUnsupported>()));
    expect(bus.dma.ownsDdtRequest(bus.maple), isFalse);
    expect(() => bus.tickMasterClocks(1), throwsA(isA<DcUnsupported>()));
    expect(bus.systemBus.normalStatus & (1 << 12), 0);
    expect(bus.ram.getUint32LE(0x20000), 0);
  });

  test(
      'G1 and Maple share channel zero without corrupting either receive buffer',
      () {
    const driveBase = 0xa05f7000, g1 = 0xa05f7400;
    void packet(List<int> values, {bool dma = false}) {
      final bytes = List<int>.filled(12, 0)..setRange(0, values.length, values);
      bus.write8(driveBase + 0x84, dma ? 1 : 0);
      bus.write8(driveBase + 0x90, 0);
      bus.write8(driveBase + 0x94, dma ? 0 : 8);
      bus.write8(driveBase + 0x9c, 0xa0);
      bus.tickMasterClocks(80);
      for (var i = 0; i < 12; i += 2) {
        bus.write16(driveBase + 0x80, bytes[i] | bytes[i + 1] << 8);
      }
      bus.tickMasterClocks(80);
    }

    final raw = Uint8List(2352)..[15] = 1;
    for (var i = 0; i < 2048; i++) {
      raw[16 + i] = (i + 17) & 255;
    }
    bus.opticalDrive.attach(FakeCdromDrive([raw]));
    packet([0x13, 0, 0, 0, 10]);
    for (var i = 0; i < 5; i++) {
      bus.read16(driveBase + 0x80);
    }
    packet([0x30, 0x24, 0, 0, 150, 0, 0, 0, 0, 0, 1], dma: true);
    bus.write32(g1 + 0xb8, 0x8843407f);
    bus.write32(g1 + 4, 0x0c030000);
    bus.write32(g1 + 8, 2048);
    bus.write32(g1 + 12, 1);
    bus.write32(g1 + 0x14, 1);
    bus.write32(g1 + 0x18, 1);
    start();
    bus.tickMasterClocks(200000);
    expect(bus.ram.sublist(0x30000, 0x30800), raw.sublist(16, 2064));
    expect(bus.ram.getUint32LE(0x20000), 0x07002000);
    expect(bus.maple.busy, isFalse);
    expect(bus.g1.busy, isFalse);
    expect(bus.systemBus.errorStatus, 0);
    expect(bus.systemBus.normalStatus & ((1 << 12) | (1 << 14)),
        (1 << 12) | (1 << 14));
  });
}

class _Controller extends DcMapleController {
  int exchanges = 0, clocks = 0;
  @override
  Uint8List? exchange(Uint8List packet, int port) {
    exchanges++;
    return super.exchange(packet, port);
  }

  @override
  void tickMasterClocks(int elapsed) {
    clocks += elapsed;
    super.tickMasterClocks(elapsed);
  }
}
