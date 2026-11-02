import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:test/test.dart';

void main() {
  late DcBus bus;
  setUp(() => bus = DcBus());

  test('absent optional G2 device exposes both byte identification registers', () {
    for (final address in [0x00600000, 0x02600000, 0x80600000, 0xa0600000]) {
      expect(bus.read8(address), 255);
      expect(bus.read8(address + 4), 255);
    }
    expect(() => bus.read8(0xa0600008), throwsA(isA<DcUnsupported>()));
    for (final address in [0x01000400, 0x81000400, 0xa1000400]) {
      expect(bus.read8(address + 15), 255);
      expect(bus.read16(address + 14), 65535);
      expect(bus.read32(address + 12), 0xffffffff);
      expect(bus.read32(address + 16), 0xffffffff);
      expect(() => bus.write32(address, 1), throwsA(isA<DcUnsupported>()));
    }
    expect(bus.read32(0xa1fffffc), 0xffffffff);
    expect(() => bus.read16(0xa1000401), throwsA(isA<DcUnsupported>()));
  });

  test('little-endian reads, writes and direct aliases', () {
    bus.write32(0x8c000000, 0x89abcdef);
    expect(bus.ram.take(4), [0xef, 0xcd, 0xab, 0x89]);
    for (final address in [0x0c000000, 0x2c000000, 0x8c000000, 0xac000000]) {
      expect(bus.read32(address), 0x89abcdef);
      expect(bus.read16(address + 2), 0x89ab);
    }
    bus.write16(0xac000002, 0x7654);
    bus.write8(0x0c000000, 0x12);
    expect(bus.read32(0x8c000000), 0x7654cd12);
  });

  test('aligned RAM boundaries and area 3 mirrors', () {
    bus.write32(0x0cfffffc, 0x12345678);
    for (final address in [0x0dfffffc, 0x0efffffc, 0x0ffffffc, 0x8ffffffc]) {
      expect(bus.read32(address), 0x12345678);
    }
    expect(() => bus.read32(0x10000000), throwsA(isA<DcUnsupported>()));
  });

  test('boot ROM is readable through reset alias and is read-only', () {
    bus.bios[0] = 0x12;
    bus.bios[DcBus.biosSize - 1] = 0x34;
    expect(bus.read8(0xa0000000), 0x12);
    expect(bus.read8(0x801fffff), 0x34);
    expect(() => bus.write8(0xa0000000, 0xff), throwsA(isA<DcUnsupported>()));
    expect(bus.bios[0], 0x12);
    expect(bus.read8(0x00200000), 255);
  });

  test('unimplemented regions cannot alias RAM', () {
    for (final address in [0xcc000000, 0xec000000, 0x005f8010, 0x08000000]) {
      expect(() => bus.read32(address), throwsA(isA<DcUnsupported>()));
      expect(() => bus.write32(address, 1), throwsA(isA<DcUnsupported>()));
    }
    expect(bus.read32(0x0c000000), 0);
  });
}
