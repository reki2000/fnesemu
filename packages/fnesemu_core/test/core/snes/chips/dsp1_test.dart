import 'dart:typed_data';

import 'package:fnesemu_core/src/core/snes/component/bus.dart';
import 'package:fnesemu_core/src/core/snes/rom/snes_file.dart';
import 'package:test/test.dart';

void main() {
  group('DSP-1', () {
    // HiROM image with the DSP-1: data at $6000, status at $7000
    Bus dspBus() {
      final rom = Uint8List(0x10000);
      for (var i = 0; i < 21; i++) {
        rom[0xffc0 + i] = 0x41;
      }
      rom[0xffd5] = 0x21;
      rom[0xffd6] = 0x03;
      rom[0xffdc] = 0xff;
      rom[0xffdd] = 0xff;
      rom[0xfffd] = 0x80;
      return Bus()..setRom(SnesFile()..load(rom));
    }

    void command(Bus bus, int command, List<int> params) {
      bus.write(0x6000, command);
      for (final p in params) {
        bus.write(0x6000, p & 0xff);
        bus.write(0x6000, (p >> 8) & 0xff);
      }
    }

    int result(Bus bus) {
      final v = bus.read(0x6000) | bus.read(0x6000) << 8;
      return (v ^ 0x8000) - 0x8000;
    }

    test('is ready and multiplies Q15 values', () {
      final bus = dspBus();
      expect(bus.read(0x7000) & 0x80, 0x80);
      command(bus, 0x00, [0x4000, -0x2000]);
      expect(result(bus), -0x1000);
    });

  });
}
