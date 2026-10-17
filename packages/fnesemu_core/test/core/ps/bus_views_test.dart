import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps/bus.dart';
import 'package:test/test.dart';

void main() {
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
