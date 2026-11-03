import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  const base = 0xa0700000, wave = 0xa0800000;
  late DcBus bus;
  setUp(() => bus = DcBus());

  void start(
      {int memory = 0x10000,
      int register = 0x10,
      int length = 12,
      bool reverse = false,
      bool clear = false}) {
    bus.write32(base + 0x2880, (memory >> 7) & 0xfe00);
    bus.write32(base + 0x2884, memory & 0xffff);
    bus.write32(base + 0x2888, register | (clear ? 0x8000 : 0));
    bus.write32(base + 0x288c, length | (reverse ? 0x8000 : 0) | 1);
  }

  test('internal DMA advances longwords asynchronously and signals both ends',
      () {
    bus.write32(wave + 0x10000, 0x11);
    bus.write32(wave + 0x10004, 0x42);
    bus.write32(wave + 0x10008, 0x53);
    bus.write32(base + 0x28b4, 0x10);
    start();
    expect(bus.read32(base + 0x288c), 1);
    bus.tickMasterClocks(8);
    expect(bus.read32(base + 0x10), 0);
    bus.tickMasterClocks(1);
    expect(bus.read32(base + 0x10), 0x11);
    expect(bus.aica.internalDmaRemaining, 8);
    expect(bus.aica.systemPending & 0x10, 0);
    bus.tickMasterClocks(18);
    expect(bus.read32(base + 0x14), 0x42);
    expect(bus.read32(base + 0x18), 0x53);
    expect(bus.read32(base + 0x288c), 0);
    expect(bus.aica.soundPending & 0x10, 0x10);
    expect(bus.systemBus.externalStatus, 2);
    bus.write32(base + 0x28bc, 0x10);
    expect(bus.systemBus.externalStatus, 0);
    expect(bus.aica.soundPending & 0x10, 0x10);
  });






  test('completion latches FIQ while ARM reset holds off delivery', () {
    bus.write32(base + 0x28a8, 0x10);
    bus.write32(base + 0x28b0, 0x10);
    bus.write32(base + 0x289c, 0x10);
    start(length: 4);
    bus.tickMasterClocks(9);
    expect(bus.aica.armInterruptLevel, 5);
    expect(bus.aica.arm.fiq, isFalse);
    bus.write32(base + 0x2c00, 0);
    expect(bus.aica.arm.fiq, isTrue);
  });




  test('batched DMA agrees with individual master clocks', () {
    final other = DcBus();
    for (final target in [bus, other]) {
      for (var i = 0; i < 12; i++) {
        target.write32(wave + 0x10000 + 4 * i, i);
      }
      target.write32(base + 0x2880, 0x200);
      target.write32(base + 0x2884, 0);
      target.write32(base + 0x2888, 0x10);
      target.write32(base + 0x288c, 49);
    }
    bus.tickMasterClocks(10000);
    for (var i = 0; i < 10000; i++) {
      other.tickMasterClocks(1);
    }
    for (var offset = 0x10; offset < 0x40; offset += 4) {
      expect(bus.read32(base + offset), other.read32(base + offset));
    }
    expect(bus.aica.soundPending, other.aica.soundPending);
    expect(bus.aica.systemPending, other.aica.systemPending);
  });
}
