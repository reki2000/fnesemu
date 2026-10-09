import 'package:test/test.dart';

import 'test_system.dart';

void main() {
  group('ppu', () {
    test('palette 0x3f10 mirrors are also mirrored at 0x3f30', () {
      final s = TestSystem();
      s.ppu.writeVram(0x3f30, 0x21);
      expect(s.ppu.readVram(0x3f00), 0x21);
      expect(s.ppu.readVram(0x3f10), 0x21);
    });

    test('0x2004 returns oam data', () {
      final s = TestSystem();
      s.bus.write(0x2003, 0x05);
      s.bus.write(0x2004, 0x77);
      s.bus.write(0x2003, 0x05);
      expect(s.bus.read(0x2004), 0x77);
    });
  });
}
