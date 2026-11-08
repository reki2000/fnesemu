import 'package:fnesemu_core/src/core/nes/rom/nes_file.dart';
import 'package:test/test.dart';

import 'test_system.dart';

void main() {
  group('rom', () {
    test('garbage in the header does not change the mapper number', () {
      final file = NesFile()
        ..load(
          ines(
            flags6: 0x10,
            header7to15: [0x44, 0x69, 0x73, 0x6b, 0x44, 0x75, 0x64, 0x65, 0x21],
          ),
        );
      expect(file.mapper, 1);
    });

  });
}
