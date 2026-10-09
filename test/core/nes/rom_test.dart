import 'package:fnesemu/core/nes/rom/nes_file.dart';
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

    test('nes 2.0 mapper bits 8-11 are read from byte 8', () {
      final file = NesFile()
        ..load(
          ines(flags6: 0x50, header7to15: [0x48, 0x01, 0, 0, 0, 0, 0, 0, 0]),
        );
      expect(file.mapper, 0x145);
    });
  });
}
