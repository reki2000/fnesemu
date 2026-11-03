import 'package:test/test.dart';

import 'test_system.dart';

void main() {
  group('apu', () {

    test('dmc irq is raised at the end of a non-looped sample', () {
      final s = TestSystem();
      s.vector(0xfffe, 0x9000);
      s.apu.write(0x4010, 0x8f); // irq, fastest
      s.apu.write(0x4012, 0x00);
      s.apu.write(0x4013, 0x00); // 1 byte
      s.apu.write(0x4015, 0x10);
      s.apu.exec(2000);
      expect(s.apu.read(0x4015) & 0x80, 0x80);

      s.apu.write(0x4015, 0x00); // acknowledge
      expect(s.apu.read(0x4015) & 0x80, 0);
    });

  });
}
