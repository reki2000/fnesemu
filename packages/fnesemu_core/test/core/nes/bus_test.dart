import 'dart:typed_data';

import 'package:fnesemu_core/core/nes/mapper/namco163.dart';
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

    test('ppu registers are mirrored up to 0x3fff', () {
      final s = TestSystem();
      s.bus.write(0x3ffe, 0x3f); // $2006
      s.bus.write(0x3ffe, 0x01);
      s.bus.write(0x2007, 0x2a);
      expect(s.ppu.palette[1], 0x2a);
    });

    test('oam dma can read from any page', () {
      final s = TestSystem();
      s.mapper.mem[0] = 0x12; // 0x6000
      s.bus.write(0x4014, 0x60);
      expect(s.ppu.objRam[0], 0x12);

      s.bus.write(0x0900, 0x34); // mirrored ram
      s.bus.write(0x4014, 0x09);
      expect(s.ppu.objRam[0], 0x34);
    });

    test('expansion area is routed only to mappers which use it', () {
      final s = TestSystem();
      s.bus.mapper = MapperNamco163()
        ..setRom(Uint8List(0x2000), Uint8List(0x8000))
        ..init();
      s.bus.write(0x5000, 0x34);
      s.bus.write(0x5800, 0x12);
      expect(s.bus.read(0x5000), 0x34);
      expect(s.bus.read(0x5800), 0x12);
    });
  });
}
