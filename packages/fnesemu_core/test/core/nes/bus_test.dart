import 'dart:typed_data';

import 'package:fnesemu_core/src/core/nes/mapper/namco163.dart';
import 'package:test/test.dart';

import 'test_system.dart';

void main() {
  group('bus', () {
    test('internal ram is mirrored at 0x0800-0x1fff', () {
      final s = TestSystem();
      s.bus.write(0x1801, 0x5a);
      expect(s.bus.read(0x0001), 0x5a);
      expect(s.bus.read(0x0801), 0x5a);
    });

  });
}
