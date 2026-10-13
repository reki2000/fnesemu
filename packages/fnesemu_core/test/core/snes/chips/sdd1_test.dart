import 'package:fnesemu_core/src/core/snes/component/bus.dart';
import 'package:fnesemu_core/src/core/snes/rom/snes_file.dart';
import 'package:test/test.dart';

import '../test_rom.dart';

void main() {
  group('S-DD1', () {
    test('maps 1MB rom banks into \$C0-\$FF', () {
      final rom = loRom(romType: 0x43, sramSizeByte: 3, size: 0x400000);
      rom[0x200010] = 0xa5;
      final bus = Bus()..setRom(SnesFile()..load(rom));
      expect(bus.read(0xc00010), 0);
      bus.write(0x4804, 2);
      expect(bus.read(0x4804), 2);
      expect(bus.read(0xc00010), 0xa5);
    });

    test('\$F0-\$FF low halves are rom, not LoROM sram', () {
      final rom = loRom(romType: 0x43, sramSizeByte: 3, size: 0x400000);
      rom[0x3e63a1] = 0x81;
      final bus = Bus()..setRom(SnesFile()..load(rom));
      expect(bus.read(0xfe63a1), 0x81);
      bus.write(0xfe63a1, 0x00); // rom is read-only
      expect(bus.read(0xfe63a1), 0x81);
      bus.write(0x700010, 0x5a); // sram stays at $70-$7D
      expect(bus.read(0x700010), 0x5a);
    });
  });
}
