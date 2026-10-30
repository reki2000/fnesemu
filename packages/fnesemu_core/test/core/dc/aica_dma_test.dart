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

  test('reverse DMA reads registers and bypasses SH4 cache', () {
    bus.write32(base + 0x10, 0x1214);
    bus.write32(base + 0x14, 0x5678);
    bus.write32(base + 0x18, 0x3210);
    bus.cache.ccr = 1;
    expect(bus.read32(0x80810000), 0);
    start(reverse: true);
    bus.tickMasterClocks(27);
    expect(bus.read32(wave + 0x10000), 0x1214);
    expect(bus.read32(wave + 0x10004), 0x5678);
    expect(bus.read32(wave + 0x10008), 0x3210);
    expect(bus.read32(0x80810000), 0);
    expect(bus.read32(base + 0x288c), 0x8000);
  });

  test('DGATE clears either destination without reading a write-only source',
      () {
    bus.write32(base + 0x10, 0x1214);
    start(clear: true, length: 4);
    bus.tickMasterClocks(9);
    expect(bus.read32(base + 0x10), 0);
    bus.write32(wave + 0x10000, 0xffffffff);
    start(clear: true, reverse: true, register: 0x2890, length: 4);
    bus.tickMasterClocks(9);
    expect(bus.read32(wave + 0x10000), 0);
    expect(bus.read32(base + 0x2888), 0x8000);
  });

  test('descriptor readback exposes only documented readable fields', () {
    for (final offset in [0x2880, 0x2884]) {
      expect(() => bus.read32(base + offset), throwsA(isA<DcUnsupported>()));
    }
    bus.write32(base + 0x2888, 0xffff);
    bus.write32(base + 0x288c, 0xfffe);
    expect(bus.read32(base + 0x2888), 0x8000);
    expect(bus.read32(base + 0x288c), 0x8000);
  });

  test('active descriptors cannot change and DEXE zero cannot abort', () {
    start();
    for (final entry in [
      (0x2880, 0),
      (0x2884, 4),
      (0x2888, 0x20),
      (0x288c, 0x800d)
    ]) {
      expect(() => bus.write32(base + entry.$1, entry.$2),
          throwsA(isA<DcUnsupported>()));
    }
    bus.write32(base + 0x288c, 12);
    bus.write32(base + 0x2880, 0x208);
    expect(bus.aica.internalDmaBusy, isTrue);
    bus.tickMasterClocks(27);
    expect(bus.aica.internalDmaBusy, isFalse);
  });

  test('retail boundaries, zero length and descriptor overlap stop explicitly',
      () {
    for (final run in [
      () => start(memory: 0x1ffffc, length: 8),
      () => start(register: 0x45c4, length: 8),
      () => start(register: 0x2880, length: 4),
      () => start(register: 0x287c, length: 8),
      () => start(length: 0),
    ]) {
      expect(run, throwsA(isA<DcUnsupported>()));
      expect(bus.aica.internalDmaBusy, isFalse);
      expect(bus.aica.systemPending & 0x10, 0);
    }
    start(memory: 0x1ffffc, length: 4, clear: true, reverse: true);
    bus.tickMasterClocks(9);
    expect(bus.aica.internalDmaBusy, isFalse);
  });

  test('unsupported register preserves the failed word without a false end',
      () {
    start(register: 0x48, length: 4);
    expect(() => bus.tickMasterClocks(9), throwsA(isA<DcUnsupported>()));
    expect(bus.aica.internalDmaRemaining, 4);
    expect(bus.aica.clocksToEvent, greaterThan(0));
    expect(bus.aica.systemPending & 0x10, 0);
    bus.aica.reset();
    expect(bus.aica.internalDmaBusy, isFalse);
    start(length: 4);
    bus.tickMasterClocks(9);
    expect(bus.aica.internalDmaBusy, isFalse);
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

  test('ARM byte writes preserve the other descriptor lanes', () {
    final aica = bus.aica;
    aica.write(0x2880, 4, 0x200, fromArm: true);
    aica.write(0x2884, 1, 0x20, fromArm: true);
    aica.write(0x2885, 1, 0x01, fromArm: true);
    aica.memory.setUint32LE(0x10120, 0x4301);
    aica.write(0x2888, 1, 0x10, fromArm: true);
    aica.write(0x288c, 1, 5, fromArm: true);
    bus.tickMasterClocks(9);
    expect(bus.read32(base + 0x10), 0x4301);
  });

  test('guest ARM instructions start and poll DMA before publishing completion',
      () {
    final ops = <int>[
      0xe59f0038, // LDR R0, base literal at 40h.
      0xe59f1038, // LDR R1, DMEA-high literal at 44h.
      0xe5801000, // STR R1, [R0].
      0xe3a01000,
      0xe5801004,
      0xe3a01010,
      0xe5801008,
      0xe3a01005,
      0xe580100c,
      0xe590100c, // Poll DEXE.
      0xe3110001,
      0x1afffffc,
      0xe59f2010, // LDR R2, result address at 48h.
      0xe3a01001,
      0xe5821000,
      0xeafffffe,
      0x802880, 0x200, 0x600,
    ];
    final code = Uint8List(ops.length * 4);
    for (final (i, opcode) in ops.indexed) {
      code.setUint32LE(i * 4, opcode);
    }
    bus.aica.memory.setAll(0, code);
    bus.write32(wave + 0x10000, 0x1111);
    bus.write32(base + 0x2c00, 0);
    bus.tickMasterClocks(3000);
    expect(bus.read32(base + 0x10), 0x1111);
    expect(bus.aica.memory.getUint32LE(0x600), 1);
    expect(bus.aica.internalDmaBusy, isFalse);
    expect(bus.aica.systemPending & 0x10, 0x10);
  });

  test('earlier SH4 DMA writes reach wave RAM before an internal read edge',
      () {
    bus.write32(0xac020000, 0x1111);
    bus.write32(0xffa00000, 0x0c020000);
    bus.write32(0xffa00004, 0x00810000);
    bus.write32(0xffa00008, 1);
    bus.write32(0xffa0000c, 0x5435);
    bus.write32(0xffa00040, 1);
    start(length: 4);
    bus.tickMasterClocks(9);
    expect(bus.read32(base + 0x10), 0x1111);
    expect(bus.read32(0xffa00008), 0);
    expect(bus.aica.internalDmaBusy, isFalse);
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
