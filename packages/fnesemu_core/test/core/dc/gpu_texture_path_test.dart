import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  const mode0 = 0xa05f6884, mode1 = 0xa05f6888;
  late DcBus bus;
  setUp(() {
    bus = DcBus();
    bus.write32(0xa05f8008, 0);
  });
  void send(int address, {int first = 0x11223344}) {
    for (var i = 0; i < 32; i += 4) {
      bus.write32(0xe0000000 + (address & 32) + i, first + i);
    }
    bus.write32(
        (address & 32) == 0 ? 0xff000038 : 0xff00003c, (address >> 24) & 0x1c);
    bus.transferStoreQueue(0xe0000000 | (address & 0x03ffffff));
  }

  test('board register aliases, field masks and longword restrictions', () {
    for (final address in [0x005f6880, 0x025f6880, 0x805f6880, 0xa25f6880]) {
      expect(bus.read32(address), 8);
    }
    expect(bus.read32(mode0), 0);
    expect(bus.read32(mode1), 0);
    bus.write32(mode0, 0xffffffff);
    expect(bus.read32(mode0), 1);
    expect(bus.read32(mode1), 0);
    bus.write32(0xa05f6880, 0);
    expect(bus.read32(0xa05f6880), 8);
    expect(() => bus.read32(mode0 + 1), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read8(mode0), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write16(mode1, 0), throwsA(isA<DcUnsupported>()));
  });

  test('default direct path interleaves longwords across the two VRAM banks',
      () {
    send(0x11000000);
    expect(bus.read32(0xa4000000), 0x11223344);
    expect(bus.read32(0xa4000004), 0x11223348);
    expect(bus.read32(0xa5000000), 0x11223344);
    expect(bus.read32(0xa5400000), 0x11223348);
    expect(bus.read32(0xa5000004), 0x1122334c);
    expect(bus.read32(0xa05f6880), 8);
    expect(bus.systemBus.normalStatus, 0);
  });

  test('each direct-path image selects its own 32-bit or 64-bit layout', () {
    bus.write32(mode0, 1);
    send(0x11000000);
    expect(bus.read32(0xa5000004), 0x11223348);
    expect(bus.read32(0xa5400000), 0);
    send(0x13000020, first: 0x99887700);
    expect(bus.read32(0xa4000020), 0x99887700);
    expect(bus.read32(0xa4000024), 0x99887704);
    bus.write32(mode1, 1);
    send(0x13000040, first: 0x44332200);
    expect(bus.read32(0xa5000040), 0x44332200);
    expect(bus.read32(0xa5000044), 0x44332204);
  });

  test('retail VRAM aliases and the last burst preserve bank addressing', () {
    bus.write32(mode0, 1);
    send(0x11ffffe0);
    expect(bus.read32(0xa57fffe0), 0x11223344);
    expect(bus.read32(0xa57ffffc), 0x11223360);
    send(0x11800000, first: 0xaabbcc00);
    expect(bus.read32(0xa5000000), 0xaabbcc00);
  });

  test('normal SH4 DMA writes complete texture bursts with cache bypass', () {
    bus.cache.ccr = 1;
    expect(bus.read32(0x85000000), 0);
    for (var i = 0; i < 32; i += 4) {
      bus.ram.setUint32LE(0x10000 + i, 0xff000000 + i);
    }
    for (final entry in [
      (0, 0x0c010000),
      (4, 0x11000000),
      (8, 1),
      (12, 0x1445),
      (0x40, 1)
    ]) {
      bus.write32(0xffa00000 + entry.$1, entry.$2);
    }
    bus.tickMasterClocks(2);
    expect(bus.read32(0xa4000000), 0xff000000);
    expect(bus.read32(0xa4000004), 0xff000004);
    expect(bus.read32(0x85000000), 0);
    expect(bus.read32(0xffa00008), 0);
  });

  test('allocated cache lines reach the texture path only on writeback', () {
    bus.cache.ccr = 5;
    bus.write32(0x91000000, 0x12345678, allocate: true);
    for (var i = 4; i < 32; i += 4) {
      bus.write32(0x91000000 + i, 0x12345678 + i);
    }
    expect(bus.read32(0xa4000000), 0);
    bus.cpuCacheOperation(0x91000000, 2);
    expect(bus.read32(0xa4000000), 0x12345678);
    expect(bus.read32(0xa4000004), 0x1234567c);
  });

  test(
      'FIFO reads, partial bursts and reset-held writes fail without VRAM changes',
      () {
    for (final operation in [
      () => bus.read32(0xb1000000),
      () => bus.read32(0xb3000000),
      () => bus.write32(0xb1000000, 1),
      () => bus.write16(0xb1000000, 1),
      () => bus.gpu.writeTexture(0x11000004, Uint8List(32)),
    ]) {
      expect(operation, throwsA(isA<DcUnsupported>()));
    }
    bus.write32(0xa05f8008, 4);
    expect(() => send(0x11000000), throwsA(isA<DcUnsupported>()));
    expect(bus.gpu.vram.getUint32LE(0), 0);
    expect(bus.systemBus.normalStatus, 0);
    bus.write32(0xa05f8008, 0);
    send(0x11000000);
    expect(bus.read32(0xa4000000), 0x11223344);
  });

  test(
      'engine soft resets retain board mode settings while full reset restores defaults',
      () {
    bus.write32(mode0, 1);
    bus.write32(mode1, 1);
    bus.write32(0xa05f8008, 3);
    expect(bus.read32(mode0), 1);
    expect(bus.read32(mode1), 1);
    bus.gpu.reset();
    expect(bus.read32(mode0), 0);
    expect(bus.read32(mode1), 0);
  });
}
