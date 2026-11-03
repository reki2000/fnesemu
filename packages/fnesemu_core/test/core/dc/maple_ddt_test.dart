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

  test('full Maple reset cancels a pending source transaction', () {
    start();
    bus.maple.reset();
    bus.tickMasterClocks(100000);
    expect(bus.dma.ownsDdtRequest(bus.maple), isFalse);
    expect(controller.exchanges, 0);
    expect(bus.maple.busy, isFalse);
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
