import 'package:fnesemu_core/src/core/snes/component/cpu.dart';
import 'package:fnesemu_core/src/core/snes/component/ppu.dart';
import 'package:fnesemu_core/src/core/snes/rom/snes_file.dart';
import 'package:fnesemu_core/src/core/snes/snes.dart';
import 'package:fnesemu_core/src/pad_button.dart';
import 'package:fnesemu_core/src/pad_source.dart';
import 'package:fnesemu_core/src/util/int.dart';
import 'package:test/test.dart';

import 'test_rom.dart';

void main() {
  group('bus', () {

    test('multiply / divide unit', () {
      final bus = busWith(loRom());
      bus.write(0x4202, 12);
      bus.write(0x4203, 10);
      expect(bus.read(0x4216) | bus.read(0x4217).shl8, 120);

      bus.write(0x4204, 0x34);
      bus.write(0x4205, 0x12);
      bus.write(0x4206, 0x10);
      expect(bus.read(0x4214) | bus.read(0x4215).shl8, 0x123);
      expect(bus.read(0x4216) | bus.read(0x4217).shl8, 0x4);

      bus.write(0x4206, 0); // divide by zero
      expect(bus.read(0x4214) | bus.read(0x4215).shl8, 0xffff);
      expect(bus.read(0x4216) | bus.read(0x4217).shl8, 0x1234);
    });
  });

  group('timer irq', () {

  });

}
