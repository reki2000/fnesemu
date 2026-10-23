import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps/bus.dart';
import 'package:test/test.dart';

void main() {
  test('scratchpad widths and aliases preserve enable state and boundaries',
      () {
    final bus = Bus();
    for (final enabled in [false, true]) {
      bus.useScratchPad = enabled;
      for (final base in [0x1f800000, 0x9f800000]) {
        for (final (width, mask, read, write) in [
          (1, 0xff, bus.read8, bus.write8),
          (2, 0xffff, bus.read16, bus.write16),
          (4, 0xffffffff, bus.read32, bus.write32),
        ]) {
          for (final offset in [0, 1, 1024 - width]) {
            bus.scratchPad.fillRange(0, 1024, 0x5a);
            write(base + offset, 0x12345678 & mask);
            expect(read(base + offset), enabled ? 0x12345678 & mask : mask);
            if (!enabled) {
              expect(bus.scratchPad, everyElement(0x5a));
            } else {
              expect(bus.read32(0x1f800000 + (offset & ~3)),
                  bus.read32(0x9f800000 + (offset & ~3)));
            }
          }
        }
      }
    }
  });

  test('invalid scratchpad aliases and the following gap stay unmapped', () {
    final bus = Bus();
    for (final enabled in [false, true]) {
      bus.useScratchPad = enabled;
      bus.scratchPad.fillRange(0, 1024, 0x5a);
      for (final base in [
        0x3f800000,
        0x5f800000,
        0x7f800000,
        0xbf800000,
        0xdf800000,
        0xff800000,
      ]) {
        for (final offset in [0, 1, 0x3fc, 0x3ff]) {
          final addr = base + offset;
          bus.write8(addr, 0x12);
          bus.write16(addr, 0x1234);
          bus.write32(addr, 0x12345678);
          expect(bus.read8(addr), 0, reason: 'alias $base offset $offset');
          expect(bus.read16(addr), 0, reason: 'alias $base offset $offset');
          expect(bus.read32(addr), 0, reason: 'alias $base offset $offset');
        }
      }
      for (final base in [0x1f800000, 0x9f800000]) {
        for (final offset in [0x400, 0xffc]) {
          bus.write32(base + offset, 0x12345678);
          expect(bus.read32(base + offset), 0);
        }
      }
      expect(bus.scratchPad, everyElement(0x5a));
    }
  });

  test('RAM, ROM and scratchpad views respect their buffer offsets', () {
    final backing = Uint8List(4 * 1024 * 1024);
    final ram = Uint8List.sublistView(backing, 4096, 4096 + 2 * 1024 * 1024);
    final rom = Uint8List.sublistView(
        backing, 3 * 1024 * 1024, 3 * 1024 * 1024 + 512 * 1024);
    final scratch = Uint8List.sublistView(backing, 2048, 3072);
    final bus = Bus(mem: ram, rom: rom, scratchPad: scratch)
      ..useScratchPad = true;
    bus.write32(0x80000000, 0x12345678);
    bus.write16(0x80000004, 0xabcd);
    bus.write32(0x1f800000, 0x89abcdef);
    bus.write16(0x1f800004, 0x1234);
    bus.rom32[0] = 0xfedcba98;
    expect(ram.sublist(0, 6), [0x78, 0x56, 0x34, 0x12, 0xcd, 0xab]);
    expect(scratch.sublist(0, 6), [0xef, 0xcd, 0xab, 0x89, 0x34, 0x12]);
    expect(rom.sublist(0, 4), [0x98, 0xba, 0xdc, 0xfe]);
    expect(bus.read32(0x80000000), 0x12345678);
    expect(bus.read16(0x80000004), 0xabcd);
    expect(bus.read32(0x1f800000), 0x89abcdef);
    expect(bus.read16(0x1f800004), 0x1234);
    expect(bus.read32(0xbfc00000), 0xfedcba98);
    expect(backing.sublist(0, 8), List.filled(8, 0));
  });
}
