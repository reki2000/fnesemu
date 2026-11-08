import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/maple_controller.dart';
import 'package:fnesemu_core/src/core/dc/maple_device.dart';
import 'package:fnesemu_core/src/pad_button.dart';
import 'package:fnesemu_core/src/pad_source.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

import '../pad_helper.dart';

void main() {
  const base = 0xa05f6c00;
  late DcBus bus;
  void configure({int selection = 0, int protection = 0x6155407f}) {
    bus.write32(0xffa00040, 0x8201);
    bus.write32(base + 0x8c, protection);
    bus.write32(base + 0xe8, selection);
    bus.write32(base + 4, 0x0c010000);
  }

  void descriptor(
      int offset, int instruction, int destination, List<int> packet,
      {int selection = 0}) {
    bus.ram.setUint32LE(offset, instruction);
    bus.ram.setUint32LE(offset + 4, destination);
    for (var i = 0; i < packet.length; i++) {
      bus.ram[offset + 8 + (selection == 0 ? i ^ 3 : i)] = packet[i];
    }
  }

  void start() {
    bus.write32(base + 0x14, 1);
    bus.write32(base + 0x18, 1);
  }

  setUp(() => bus = DcBus());

  test('official device-information example and HOLLY completion interrupt',
      () {
    configure();
    // System Architecture: MSB31 request 01200000, response 0500201c.
    bus.ram.setUint32LE(0x10000, 0x80000000);
    bus.ram.setUint32LE(0x10004, 0x0c020000);
    bus.ram.setUint32LE(0x10008, 0x01200000);
    bus.write32(0xa05f6910, 1 << 12);
    bus.ram.fillRange(0x20000, 0x200a0, 0xcc);
    start();
    expect(bus.read32(base + 0x18), 1);
    expect(bus.read32(base + 0x84), 0x800000ff);
    expect(bus.ram[0x20000], 0xcc);
    bus.tickMasterClocks(1000000);
    expect(bus.read32(base + 0x18), 0);
    expect(bus.read32(base + 4), 0x0c010000);
    expect(bus.ram.getUint32LE(0x20000), 0x0500201c);
    expect(bus.ram.getUint32LE(0x20004), 1);
    expect(bus.ram.getUint32LE(0x20008), 0x000f06fe);
    expect(bus.ram.sublist(0x20074, 0x20080), everyElement(0));
    expect(bus.ram[0x20080], 0xcc);
    expect(bus.systemBus.normalStatus & 0x1000, 0x1000);
    expect(bus.systemBus.irlPins, 13);
    expect(bus.systemBus.errorStatus, 0);
  });











  test('core input routes ports and reset retains attachments', () {
    final dc = Dc();
    addTearDown(dc.dispose);
    final controller = DcMapleController();
    dc.bus.maple.controllers[2] = controller;
    dc.padDown(2, DcMapleController.x);
    dc.padDown(2, DcMapleController.rightTrigger);
    dc.padDown(-1, DcMapleController.a);
    dc.padDown(4, DcMapleController.a);
    final identify = Uint8List.fromList([1, 0xa0, 0x80, 0]);
    controller.exchange(identify, 2);
    final request = Uint8List.fromList([9, 0xa0, 0x80, 1, 0, 0, 0, 1]);
    expect(controller.exchange(request, 2)!.sublist(8, 12), [255, 251, 255, 0]);
    controller.exchange(Uint8List.fromList([3, 0xa0, 0x80, 0]), 2);
    expect(controller.exchange(request, 2), isNull);
    controller.exchange(identify, 2);
    expect(controller.exchange(request, 2)![9], 251);
    dc.padUp(2, DcMapleController.x);
    expect(controller.exchange(request, 2)![9], 255);
    dc.padUp(2, DcMapleController.rightTrigger);
    dc.reset();
    expect(dc.bus.maple.controllers[2], same(controller));
    controller.exchange(identify, 2);
    expect(controller.exchange(request, 2)!.sublist(8),
        [255, 255, 0, 0, 128, 128, 128, 128]);
    expect(dc.buttons, contains(DcMapleController.start));
  });





  void hardware({int system = 0x3a980000}) {
    configure();
    descriptor(0x10000, 0x80000000, 0x0c020000, [3, 0x20, 0, 0]);
    bus.write32(base + 0x80, system);
    bus.write32(base + 0x10, 1);
    bus.write32(base + 0x14, 1);
  }












  test('discovery gates input and kill requires an electrical reset', () {
    final controller = bus.maple.controllers[0]!;
    final identify = Uint8List.fromList([1, 32, 0, 0]);
    final condition = Uint8List.fromList([9, 32, 0, 1, 0, 0, 0, 1]);
    expect(controller.exchange(condition, 0), isNull);
    expect(controller.exchange(identify, 0)![0], 5);
    controller.source = PadState()..press(0, DcMapleController.a);
    expect(controller.exchange(condition, 0)![8] & 4, 0);
    expect(controller.exchange(Uint8List.fromList([4, 32, 0, 0]), 0)![0], 7);
    expect(controller.exchange(identify, 0), isNull);
    expect(controller.exchange(condition, 0), isNull);
    expect(controller.exchange(Uint8List.fromList([3, 32, 0, 0]), 0), isNull);
    controller.resetDevice();
    expect(controller.exchange(condition, 0), isNull);
    expect(controller.exchange(identify, 0)![0], 5);
    expect(controller.exchange(condition, 0)![8] & 4, 0);
  });

  group('electrical RESET control pattern', () {
    Uint8List identify(int port) =>
        Uint8List.fromList([1, (port << 6) | 32, port << 6, 0]);
    Uint8List condition(int port) =>
        Uint8List.fromList([9, (port << 6) | 32, port << 6, 1, 0, 0, 0, 1]);
    void resetPattern({int port = 0, int instruction = 0x80000300}) {
      configure();
      bus.ram.setUint32LE(0x10000, instruction | (port << 16));
      start();
    }

    test('single-clock and batched schedules commit the same reset', () {
      final first = _ResetObserver();
      bus.maple.controllers[0]!.expansions[0] = first;
      resetPattern();
      for (var i = 0; i < 2802; i++) {
        bus.tickMasterClocks(1);
      }
      expect(first.resets, 1);
      expect(first.clocks, 2802);
      expect(bus.read32(base + 0x18), 0);
    });
  });

}

class _ResetObserver implements DcMapleDevice {
  int resets = 0, clocks = 0;
  @override
  void resetDevice() => resets++;
  @override
  void tickMasterClocks(int elapsed) => clocks += elapsed;
  @override
  Uint8List? exchange(Uint8List request, int port) => null;
}
