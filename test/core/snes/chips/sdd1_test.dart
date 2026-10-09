import 'package:fnesemu/core/snes/component/bus.dart';
import 'package:fnesemu/core/snes/rom/snes_file.dart';
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
  });
}
