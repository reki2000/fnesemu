import 'dart:typed_data';

import 'package:fnesemu/core/gba/bus.dart';
import 'package:test/test.dart';

void main() {
  test('aligned fetches retain mirrors, open bus and cartridge reloads', () {
    final bus = Bus();
    for (final ram in [bus.bios, bus.ewram, bus.iwram]) {
      for (var i = 0; i < ram.length; i++) {
        ram[i] = (i * 17 + 3) & 255;
      }
    }
    for (final length in [5, 8]) {
      bus.cart.load(Uint8List.fromList(List.generate(length, (i) => i + length)));
      for (final base in [0, 0x10000000, 0x02000000, 0x02040000,
          0x03000000, 0x03008000, 0x08000000, 0x0a000000, 0x0c000000,
          0x0d000000]) {
        for (final offset in [0, 2, 4, 6]) {
          expect(bus.fetch16(base + offset), bus.read16(base + offset));
        }
        for (final offset in [0, 4, 8]) {
          expect(bus.fetch32(base + offset), bus.read32(base + offset));
        }
      }
      for (final address in [0x00003ffc, 0x00004000, 0x0203fffc,
          0x03007ffc, 0x08000000 + length + 4]) {
        final aligned = address & ~3;
        expect(bus.fetch32(aligned), bus.read32(aligned));
        expect(bus.fetch16(aligned + 2), bus.read16(aligned + 2));
      }
    }
    bus.write32(0x03000000, 0x12345678);
    expect(bus.fetch32(0x03008000), 0x12345678);
  });

  test('timer enable and cascade changes take effect on the next tick', () {
    final timers = Bus().timers;
    timers.write16(0, 0xffff);
    timers.write16(4, 0xfffc);
    timers.write16(2, 0x80);
    timers.write16(6, 0x84);
    timers.tick(1);
    expect(timers.read16(0), 0xffff);
    expect(timers.read16(4), 0xfffd);
    timers.write16(2, 0);
    timers.write16(6, 0x80);
    timers.tick(2);
    expect(timers.read16(4), 0xffff);
    timers.reset();
    timers.tick(1000);
    expect(timers.read16(0), 0);
    expect(timers.read16(4), 0);
  });
}
