import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/maple_controller.dart';
import 'package:fnesemu_core/src/core/dc/maple_device.dart';
import 'package:fnesemu_core/src/pad_button.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  const base = 0xa05f6c00;
  late DcBus bus;
  void configure({int selection = 1, int protection = 0x6155407f}) {
    bus.write32(0xffa00040, 0x8201);
    bus.write32(base + 0x8c, protection);
    bus.write32(base + 0xe8, selection);
    bus.write32(base + 4, 0x0c010000);
  }

  void descriptor(
      int offset, int instruction, int destination, List<int> packet,
      {int selection = 1}) {
    bus.ram.setUint32LE(offset, instruction);
    bus.ram.setUint32LE(offset + 4, destination);
    for (var i = 0; i < packet.length; i++) {
      bus.ram[offset + 8 + (selection == 1 ? i ^ 3 : i)] = packet[i];
    }
  }

  void start() {
    bus.write32(base + 0x14, 1);
    bus.write32(base + 0x18, 1);
  }

  setUp(() => bus = DcBus());

  test('register reset, aliases, access widths and protected configuration',
      () {
    expect(bus.read32(base + 0x80), 0x3a980000);
    expect(bus.read32(base + 0x84), 255);
    for (final address in [0x005f6ce8, 0x025f6ce8, 0x805f6ce8, 0xa25f6ce8]) {
      expect(bus.read32(address), 1);
    }
    expect(() => bus.read8(base + 4), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write16(base + 4, 0), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read32(base + 0x8c), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read32(0xc05f6ce8), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write32(base + 0x18, 1), throwsA(isA<DcUnsupported>()));
    configure();
    bus.write32(base + 0x14, 1);
    expect(() => bus.write32(base + 0x80, 0), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write32(base + 0x10, 0), throwsA(isA<DcUnsupported>()));
  });

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

  for (final selection in [0, 1]) {
    test('condition input, analog axes and byte order $selection', () {
      configure(selection: selection);
      final controller = bus.maple.controllers[0]!;
      controller.exchange(Uint8List.fromList([1, 32, 0, 0]), 0);
      controller.setButton(DcMapleController.a, true);
      controller.setButton(DcMapleController.y, true);
      controller.setButton(PadButton.left, true);
      controller.setAnalog(right: 0x11, left: 0x22, stickX: 0x33, stickY: 0x44);
      descriptor(0x10000, 0x80000001, 0x0c020000, [9, 0x20, 0, 1, 0, 0, 0, 1],
          selection: selection);
      start();
      bus.tickMasterClocks(100000);
      expect(
          List.generate(
              16, (i) => bus.ram[0x20000 + (selection == 1 ? i ^ 3 : i)]),
          [
            8,
            0,
            0x20,
            3,
            0,
            0,
            0,
            1,
            0xbb,
            0xfd,
            0x11,
            0x22,
            0x33,
            0x44,
            128,
            128
          ]);
      expect(bus.read32(base + 0xfc), 0x0c020000);
      expect(bus.read32(base + 0xf8), 0x0c020020);
    });
  }

  test('all four ports and consecutive descriptors', () {
    configure();
    for (var port = 0; port < 4; port++) {
      bus.maple.controllers[port] = DcMapleController();
      descriptor(0x10000 + port * 12, (port == 3 ? 0x80000000 : 0) | port << 16,
          0x0c020000 + port * 128, [1, (port << 6) | 0x20, port << 6, 0]);
    }
    start();
    bus.tickMasterClocks(1000000);
    for (var port = 0; port < 4; port++) {
      expect(bus.ram.getUint32LE(0x20000 + port * 128),
          0x0500201c | port << 22 | port << 14);
    }
    expect(bus.systemBus.normalStatus, 1 << 12);
  });

  test('missing device times out and continues the list', () {
    configure();
    descriptor(0x10000, 0x10000, 0x0c020000, [1, 0x60, 0x40, 0]);
    descriptor(0x1000c, 0x80000000, 0x0c020020, [3, 0x20, 0, 0]);
    start();
    bus.tickMasterClocks(63999);
    expect(bus.read32(base + 0x18), 1);
    expect(bus.ram.getUint32LE(0x20000), 0);
    bus.tickMasterClocks(5); // Source DDT, serial timeout and root write.
    expect(bus.ram.getUint32LE(0x20000), 0xffffffff);
    bus.tickMasterClocks(100000);
    expect(bus.ram.getUint32LE(0x20020), 0x07002000);
  });

  test('disable finishes current exchange without completion or next command',
      () {
    configure();
    descriptor(0x10000, 0, 0x0c020000, [3, 0x20, 0, 0]);
    descriptor(0x1000c, 0x80000000, 0x0c020020, [3, 0x20, 0, 0]);
    start();
    bus.tickMasterClocks(2);
    bus.write32(base + 0x18, 0);
    bus.write32(base + 0x14, 0);
    expect(bus.read32(base + 0x18), 1);
    bus.tickMasterClocks(100000);
    expect(bus.ram.getUint32LE(0x20000), 0x07002000);
    expect(bus.ram.getUint32LE(0x20020), 0);
    expect(bus.systemBus.normalStatus & 0x3fffff, 0);
    expect(bus.read32(base + 0x18), 0);
  });

  test('NOP delay has no response destination and supports split ticks', () {
    configure();
    bus.ram.fillRange(0, 32, 0xcc);
    bus.ram.setUint32LE(0x10000, 0x700);
    descriptor(0x10004, 0x80000000, 0x0c020000, [3, 0x20, 0, 0]);
    start();
    bus.tickMasterClocks(31999);
    expect(bus.read32(base + 0x18), 1);
    bus.tickMasterClocks(1);
    expect(bus.ram.getUint32LE(0x20000), 0);
    bus.tickMasterClocks(100000);
    expect(bus.ram.getUint32LE(0x20000), 0x07002000);
    expect(bus.ram.sublist(0, 32), everyElement(0xcc));
  });

  test('protection key and illegal start error occur on write and start', () {
    bus.write32(base + 0x8c, 0x1234407f);
    bus.write32(base + 4, 0x0c010000);
    expect(bus.systemBus.errorStatus, 1 << 8);
    bus.write32(0xa05f6908, 1 << 8);
    start();
    expect(bus.systemBus.errorStatus, 1 << 8);
    expect(bus.read32(base + 0x18), 0);
  });

  test('fetch overrun stops before sending packet', () {
    configure(protection: 0x61554040);
    bus.write32(base + 4, 0x0c0fffe0);
    bus.ram.setUint32LE(0xfffe0, 0x800000ff);
    start();
    bus.tickMasterClocks(2);
    expect(bus.systemBus.errorStatus, 1 << 9);
    expect(bus.systemBus.normalStatus & 0x3fffff, 0);
    expect(bus.read32(base + 0x18), 0);
  });

  test('32-byte response blocks respect protection before each write', () {
    configure(protection: 0x61554040);
    descriptor(0x10000, 0x80000000, 0x0c0fffe0, [1, 0x20, 0, 0]);
    bus.ram.fillRange(0x100000, 0x100080, 0xcc);
    start();
    bus.tickMasterClocks(1000000);
    expect(bus.ram.getUint32LE(0xfffe0), 0x0500201c);
    expect(bus.ram.sublist(0x100000, 0x100080), everyElement(0xcc));
    expect(bus.systemBus.errorStatus, 1 << 9);
    expect(bus.systemBus.normalStatus & 0x3fffff, 0);
  });

  test('illegal instruction patterns and reserved bits raise HOLLY error', () {
    for (final instruction in [0x80000100, 0x80000500, 0x80000800]) {
      configure();
      bus.ram.setUint32LE(0x10000, instruction);
      start();
      bus.tickMasterClocks(2);
      expect(bus.systemBus.errorStatus, 1 << 11);
      expect(bus.read32(base + 0x18), 0);
      bus.maple.reset();
      bus.systemBus.reset();
    }
  });

  test('source RAM mirror and physical-area end protection', () {
    configure();
    bus.write32(base + 4, 0x0d010000);
    descriptor(0x10000, 0x80000000, 0x0fffffe0, [1, 0x20, 0, 0]);
    start();
    bus.tickMasterClocks(1000000);
    expect(bus.systemBus.errorStatus, 1 << 9);
    expect(bus.ram.getUint32LE(0xffffe0), 0x0500201c);
    expect(bus.ram.getUint32LE(0), 0);
  });

  test('Core pad API routes ports and reset retains attachments', () {
    final dc = Dc();
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
    dc.reset();
    expect(dc.bus.maple.controllers[2], same(controller));
    controller.exchange(identify, 2);
    expect(controller.exchange(request, 2)!.sublist(8),
        [255, 255, 0, 0, 128, 128, 128, 128]);
    expect(dc.buttons, contains(DcMapleController.start));
  });

  test('DMA response bypasses cached CPU data', () {
    configure();
    descriptor(0x10000, 0x80000000, 0x0c020000, [3, 0x20, 0, 0]);
    bus.write32(0xff00001c, 5);
    expect(bus.read32(0x8c020000), 0);
    start();
    bus.tickMasterClocks(100000);
    expect(bus.read32(0xac020000), 0x07002000);
    expect(bus.read32(0x8c020000), 0);
  });

  test('disable remains an abort if software reenables before exchange ends',
      () {
    configure();
    descriptor(0x10000, 0, 0x0c020000, [3, 0x20, 0, 0]);
    descriptor(0x1000c, 0x80000000, 0x0c020020, [3, 0x20, 0, 0]);
    start();
    bus.tickMasterClocks(
        2); // Let the DDT source read start serial transmission.
    bus.write32(base + 0x14, 0);
    bus.write32(base + 0x14, 1);
    bus.tickMasterClocks(100000);
    expect(bus.read32(base + 0x18), 0);
    expect(bus.ram.getUint32LE(0x20000), 0x07002000);
    expect(bus.ram.getUint32LE(0x20020), 0);
    expect(bus.systemBus.normalStatus, 0);
  });

  test('VBlank over notification is independent of programmed video IRQ line',
      () {
    configure();
    descriptor(0x10000, 0x80000000, 0x0c020000, [1, 0x20, 0, 0]);
    bus.gpu.spg.write(0xd8, (9 << 16) | 99);
    bus.gpu.spg.write(0xdc, (8 << 16) | 1);
    bus.gpu.spg.write(0xcc, (8 << 16) | 7);
    bus.gpu.spg.write(0xd0, 0x100);
    start();
    bus.tickMasterClocks(2000);
    expect(bus.systemBus.normalStatus & (1 << 13), 1 << 13);
    expect(bus.systemBus.normalStatus & 24, 0);
    expect(bus.read32(base + 0x18), 1);
    bus.tickMasterClocks(100000);
    expect(bus.systemBus.normalStatus & (1 << 12), 1 << 12);
  });

  test('large and single-clock ticks produce the same transfer/video result',
      () {
    void setup(DcBus target) {
      target.write32(0xffa00040, 0x8201);
      target.write32(base + 0x8c, 0x6155407f);
      target.write32(base + 4, 0x0c010000);
      target.ram.setUint32LE(0x10000, 0x80000000);
      target.ram.setUint32LE(0x10004, 0x0c020000);
      target.ram.setUint32LE(0x10008, 0x03200000);
      target.gpu.spg.write(0xd8, (9 << 16) | 99);
      target.gpu.spg.write(0xdc, (8 << 16) | 1);
      target.gpu.spg.write(0xd0, 0x100);
      target.write32(base + 0x14, 1);
      target.write32(base + 0x18, 1);
    }

    final other = DcBus();
    setup(bus);
    setup(other);
    bus.tickMasterClocks(20000);
    for (var i = 0; i < 20000; i++) {
      other.tickMasterClocks(1);
    }
    expect(
        bus.ram.sublist(0x20000, 0x20020), other.ram.sublist(0x20000, 0x20020));
    expect(bus.systemBus.normalStatus, other.systemBus.normalStatus);
    expect(bus.gpu.spg.status, other.gpu.spg.status);
  });

  void hardware({int system = 0x3a980000}) {
    configure();
    descriptor(0x10000, 0x80000000, 0x0c020000, [3, 0x20, 0, 0]);
    bus.write32(base + 0x80, system);
    bus.write32(base + 0x10, 1);
    bus.write32(base + 0x14, 1);
  }

  test('hardware mode ignores software starts and disabled blank edges', () {
    hardware();
    bus.write32(base + 0x18, 1);
    expect(bus.maple.busy, isFalse);
    bus.write32(base + 0x14, 0);
    bus.maple.verticalBlankOut();
    expect(bus.maple.busy, isFalse);
    bus.write32(base + 0x14, 1);
    bus.maple.verticalBlankOut();
    expect(bus.maple.busy, isTrue);
    bus.tickMasterClocks(8004);
    expect(bus.ram.getUint32LE(0x20000), 0x07002000);
    expect(bus.systemBus.normalStatus, 1 << 12);
  });

  test(
      'hardware delay separates start status from move status and packet fetch',
      () {
    hardware(system: 0x3a980002);
    bus.maple.verticalBlankOut();
    expect(bus.read32(base + 0x18), 1);
    expect(bus.read32(base + 0x84), 255);
    bus.tickMasterClocks(519999);
    expect(bus.ram.getUint32LE(0x20000), 0);
    expect(bus.read32(base + 0x84), 255);
    // Descriptor data is consumed when the delay expires.
    bus.ram.setUint32LE(0x10008, 0x04200000);
    bus.tickMasterClocks(1);
    expect(bus.read32(base + 0x84), 0x800000ff);
    bus.tickMasterClocks(7999);
    expect(bus.ram.getUint32LE(0x20000), 0);
    bus.tickMasterClocks(5);
    expect(bus.ram.getUint32LE(0x20000), 0x07002000);
  });

  test('delay cancellation performs no exchange or completion notification',
      () {
    hardware(system: 0x3a980001);
    bus.maple.verticalBlankOut();
    bus.tickMasterClocks(259999);
    bus.write32(base + 0x14, 0);
    expect(bus.maple.busy, isFalse);
    bus.tickMasterClocks(1000000);
    expect(bus.ram.getUint32LE(0x20000), 0);
    expect(bus.systemBus.normalStatus, 0);
  });

  test('automatic hardware mode repeats, single mode requires a clear', () {
    for (final single in [false, true]) {
      bus.maple.reset();
      bus.systemBus.reset();
      hardware(system: 0x3a980000 | (single ? 0x1000 : 0));
      bus.maple.verticalBlankOut();
      bus.maple.verticalBlankOut(); // A busy edge cannot queue another chain.
      bus.tickMasterClocks(8004);
      bus.write32(0xa05f6900, 1 << 12);
      bus.maple.verticalBlankOut();
      expect(bus.maple.busy, !single);
      if (single) {
        bus.write32(base + 0x88, 0);
        bus.maple.verticalBlankOut();
        expect(bus.maple.busy, isFalse);
        bus.write32(base + 0x88, 1);
        bus.maple.verticalBlankOut();
        expect(bus.maple.busy, isTrue);
      }
      bus.tickMasterClocks(8004);
      expect(bus.systemBus.normalStatus, 1 << 12);
    }
  });

  test('switching software to hardware while disabled rearms single mode', () {
    hardware(system: 0x3a981000);
    bus.maple.verticalBlankOut();
    bus.tickMasterClocks(8004);
    bus.write32(base + 0x14, 0);
    bus.write32(base + 0x14, 1);
    bus.maple.verticalBlankOut();
    expect(bus.maple.busy, isFalse);
    bus.write32(base + 0x14, 0);
    bus.write32(base + 0x10, 0);
    bus.write32(base + 0x10, 1);
    bus.write32(base + 0x14, 1);
    bus.maple.verticalBlankOut();
    expect(bus.maple.busy, isTrue);
  });

  test('protection is checked at trigger and again at delayed fetch', () {
    hardware(system: 0x3a980001);
    bus.write32(base + 0x8c, 0x61557f7f);
    bus.maple.verticalBlankOut();
    expect(bus.systemBus.errorStatus, 1 << 8);
    expect(bus.maple.busy, isFalse);
    bus.write32(0xa05f6908, 1 << 8);
    bus.write32(base + 0x8c, 0x6155407f);
    bus.maple.verticalBlankOut();
    bus.write32(base + 0x8c, 0x61557f7f);
    bus.tickMasterClocks(260000);
    expect(bus.systemBus.errorStatus, 1 << 9);
    expect(bus.maple.busy, isFalse);
  });

  test('SPG blank end initiates at its edge without credit for earlier clocks',
      () {
    hardware();
    bus.gpu.spg.setFastClock(true);
    bus.gpu.spg.write(0xd8, (99 << 16) | 26);
    bus.gpu.spg.write(0xdc, (3 << 16) | 90);
    bus.gpu.spg.write(0xcc, (7 << 16) | 91);
    bus.gpu.spg.write(0xd0, 0x100);
    expect(bus.gpu.spg.clocksToVerticalBlankOut, 600);
    bus.tickMasterClocks(599);
    expect(bus.maple.busy, isFalse);
    bus.tickMasterClocks(1);
    expect(bus.maple.busy, isTrue);
    expect(bus.ram.getUint32LE(0x20000), 0);
    bus.tickMasterClocks(7999);
    expect(bus.ram.getUint32LE(0x20000), 0);
    bus.tickMasterClocks(5);
    expect(bus.ram.getUint32LE(0x20000), 0x07002000);
    expect(bus.systemBus.normalStatus & 0x1000, 0x1000);
  });

  test(
      'automatic SPG initiation repeats once per field without software writes',
      () {
    hardware();
    bus.gpu.spg.setFastClock(true);
    bus.gpu.spg.write(0xd8, (99 << 16) | 26);
    bus.gpu.spg.write(0xdc, (3 << 16) | 90);
    bus.gpu.spg.write(0xd0, 0x100);
    bus.tickMasterClocks(8604);
    expect(bus.ram.getUint32LE(0x20000), 0x07002000);
    bus.ram.fillRange(0x20000, 0x20020, 0);
    bus.write32(0xa05f6900, 1 << 12);
    bus.tickMasterClocks(11995);
    expect(bus.maple.busy, isFalse);
    bus.tickMasterClocks(1);
    expect(bus.maple.busy, isTrue);
    bus.tickMasterClocks(8004);
    expect(bus.ram.getUint32LE(0x20000), 0x07002000);
    expect(bus.systemBus.normalStatus & 0x1000, 0x1000);
  });

  test('disabled or unreachable SPG blank end cannot initiate hardware DMA',
      () {
    hardware();
    bus.gpu.spg.write(0xd8, (9 << 16) | 26);
    bus.gpu.spg.write(0xdc, (10 << 16) | 8);
    bus.gpu.spg.write(0xd0, 0x100);
    expect(bus.gpu.spg.clocksToVerticalBlankOut, isNull);
    bus.tickMasterClocks(100000);
    expect(bus.maple.busy, isFalse);
    bus.gpu.spg.write(0xdc, (3 << 16) | 8);
    bus.gpu.spg.write(0xd0, 0);
    expect(bus.gpu.spg.clocksToVerticalBlankOut, isNull);
    bus.tickMasterClocks(100000);
    expect(bus.maple.busy, isFalse);
  });

  test('SPG edge deadline preserves fractional phase through field wrap', () {
    hardware();
    bus.gpu.spg.setFastClock(true);
    bus.gpu.spg.write(0xd8, (9 << 16) | 8);
    bus.gpu.spg.write(0xdc, (2 << 16) | 8);
    bus.gpu.spg.write(0xd0, 0x100);
    bus.tickMasterClocks(7);
    expect(bus.gpu.spg.clocksToVerticalBlankOut, 127);
    bus.tickMasterClocks(126);
    expect(bus.maple.busy, isFalse);
    bus.tickMasterClocks(1);
    expect(bus.maple.busy, isTrue);
    // Two lines occupy 133 1/3 master clocks; the next edge is at clock 800.
    expect(bus.gpu.spg.clocksToVerticalBlankOut, 666);
    bus.tickMasterClocks(666);
    expect(bus.gpu.spg.scanline, 2);
    expect(bus.gpu.spg.clocksToVerticalBlankOut, 667);
  });

  test('SPG hardware initiation is invariant to scheduler batch size', () {
    void setup(DcBus target) {
      target.write32(0xffa00040, 0x8201);
      target.write32(base + 0x8c, 0x6155407f);
      target.write32(base + 4, 0x0c010000);
      target.ram.setUint32LE(0x10000, 0x80000000);
      target.ram.setUint32LE(0x10004, 0x0c020000);
      target.ram.setUint32LE(0x10008, 0x03200000);
      target.write32(base + 0x80, 0x3a981001);
      target.write32(base + 0x10, 1);
      target.write32(base + 0x14, 1);
      target.gpu.spg.setFastClock(true);
      target.gpu.spg.write(0xd8, (9 << 16) | 26);
      target.gpu.spg.write(0xdc, (3 << 16) | 8);
      target.gpu.spg.write(0xd0, 0x100);
    }

    final other = DcBus();
    setup(bus);
    setup(other);
    bus.tickMasterClocks(268604);
    for (var i = 0; i < 268604; i++) {
      other.tickMasterClocks(1);
    }
    expect(bus.ram.getUint32LE(0x20000), 0x07002000);
    expect(
        bus.ram.sublist(0x20000, 0x20020), other.ram.sublist(0x20000, 0x20020));
    expect(bus.systemBus.normalStatus, other.systemBus.normalStatus);
    expect(bus.maple.busy, other.maple.busy);
    expect(bus.gpu.spg.status, other.gpu.spg.status);
  });

  test('discovery gates input and kill requires an electrical reset', () {
    final controller = bus.maple.controllers[0]!;
    final identify = Uint8List.fromList([1, 32, 0, 0]);
    final condition = Uint8List.fromList([9, 32, 0, 1, 0, 0, 0, 1]);
    expect(controller.exchange(condition, 0), isNull);
    expect(controller.exchange(identify, 0)![0], 5);
    controller.setButton(DcMapleController.a, true);
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

    test('reset commits after its serial interval and recovers killed devices',
        () {
      final device = bus.maple.controllers[0]!;
      device.exchange(identify(0), 0);
      device.exchange(Uint8List.fromList([4, 32, 0, 0]), 0);
      resetPattern();
      bus.tickMasterClocks(2801);
      expect(device.exchange(identify(0), 0), isNull);
      expect(bus.read32(base + 0x18), 1);
      bus.tickMasterClocks(1);
      expect(device.exchange(condition(0), 0), isNull);
      expect(device.exchange(identify(0), 0)![0], 5);
      expect(bus.read32(base + 0x18), 0);
      expect(bus.systemBus.normalStatus & (1 << 12), 1 << 12);
    });
    test('electrical reset retains held input while requiring discovery again',
        () {
      final device = bus.maple.controllers[0]!;
      device.setButton(DcMapleController.a, true);
      device.exchange(identify(0), 0);
      resetPattern();
      bus.tickMasterClocks(2802);
      expect(device.exchange(condition(0), 0), isNull);
      device.exchange(identify(0), 0);
      expect(device.exchange(condition(0), 0)![8] & 4, 0);
    });
    test('only the selected port and its expansion devices reset', () {
      final other = DcMapleController();
      bus.maple.controllers[1] = other;
      other.exchange(identify(1), 1);
      final first = _ResetObserver(), second = _ResetObserver();
      bus.maple.controllers[0]!.expansions[0] = first;
      other.expansions[1] = second;
      resetPattern(port: 1);
      bus.tickMasterClocks(2802);
      expect(first.resets, 0);
      expect(second.resets, 1);
      expect(other.exchange(condition(1), 1), isNull);
    });
    test('RESET consumes only an instruction word and chains into discovery',
        () {
      configure();
      bus.ram.setUint32LE(0x10000, 0x3ff);
      descriptor(0x10004, 0x80000000, 0x0c020000, [1, 32, 0, 0]);
      bus.ram.fillRange(0, 32, 0xcc);
      start();
      bus.tickMasterClocks(300000);
      expect(bus.ram.getUint32LE(0x20000), 0x0500201c);
      expect(bus.ram.sublist(0, 32), everyElement(0xcc));
      expect(bus.systemBus.errorStatus, 0);
    });
    test('empty ports generate no response write or timeout error', () {
      bus.ram.fillRange(0, 32, 0xa5);
      resetPattern(port: 3, instruction: 0x800003ff);
      bus.tickMasterClocks(2802);
      expect(bus.ram.sublist(0, 32), everyElement(0xa5));
      expect(bus.systemBus.errorStatus, 0);
      expect(bus.read32(base + 0x18), 0);
    });
    test('disabling DMA lets an in-flight reset finish without completion IRQ',
        () {
      final child = _ResetObserver();
      bus.maple.controllers[0]!.expansions[0] = child;
      resetPattern();
      bus.tickMasterClocks(100);
      bus.write32(base + 0x14, 0);
      bus.tickMasterClocks(2702);
      expect(child.resets, 1);
      expect(bus.read32(base + 0x18), 0);
      expect(bus.systemBus.normalStatus & (1 << 12), 0);
    });
    test('one MHz mode doubles the functional RESET serial interval', () {
      final child = _ResetObserver();
      bus.maple.controllers[0]!.expansions[0] = child;
      configure();
      bus.write32(base + 0x80, 0x3a980100);
      bus.ram.setUint32LE(0x10000, 0x80000300);
      start();
      bus.tickMasterClocks(5601);
      expect(child.resets, 0);
      bus.tickMasterClocks(1);
      expect(child.resets, 1);
    });
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

  test('unsupported functions, unknown commands and malformed frames', () {
    final controller = bus.maple.controllers[0]!;
    controller.exchange(Uint8List.fromList([1, 32, 0, 0]), 0);
    expect(
        controller.exchange(
            Uint8List.fromList([9, 32, 0, 1, 0, 0, 0, 2]), 0)![0],
        0xfe);
    expect(
        controller.exchange(Uint8List.fromList([0x7f, 32, 0, 0]), 0)![0], 0xfd);
    expect(controller.exchange(Uint8List.fromList([1, 33, 0, 0]), 0), isNull);
    expect(controller.exchange(Uint8List.fromList([9, 32, 0, 1]), 0), isNull);
    expect(
        () => controller.setAnalog(right: 256, left: 0, stickX: 0, stickY: 0),
        throwsRangeError);
    expect(() => controller.exchange(Uint8List.fromList([2, 32, 0, 0]), 0),
        throwsA(isA<DcUnsupported>()));
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
