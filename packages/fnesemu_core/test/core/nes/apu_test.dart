import 'package:test/test.dart';

import 'test_system.dart';

void main() {
  group('apu', () {
    test('writing 0x80- to 0x4011 does not overflow the mixer', () {
      final s = TestSystem();
      s.apu.write(0x4011, 0xff);
      s.apu.write(0x4015, 0x10);
      expect(() => s.apu.exec(2000), returnsNormally);
    });

    test('direct 0x4011 writes are output', () {
      final s = TestSystem();
      s.apu.write(0x4011, 0x40);
      final out = s.apu.exec(100);
      expect(out.last, greaterThan(0));
    });

    test('disabling a channel clears its length counter', () {
      final s = TestSystem();
      s.apu.write(0x4015, 0x01);
      s.apu.write(0x4003, 0x08);
      expect(s.apu.read(0x4015) & 0x01, 0x01);
      s.apu.write(0x4015, 0x00);
      expect(s.apu.read(0x4015) & 0x01, 0x00);
    });

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

    test('looped dmc sample does not raise irq', () {
      final s = TestSystem();
      s.apu.write(0x4010, 0xcf); // irq, loop, fastest
      s.apu.write(0x4013, 0x00);
      s.apu.write(0x4015, 0x10);
      s.apu.exec(2000);
      expect(s.apu.read(0x4015) & 0x80, 0);
    });
  });
}
