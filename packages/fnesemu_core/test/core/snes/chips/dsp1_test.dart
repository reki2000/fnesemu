import 'dart:typed_data';

import 'package:fnesemu_core/core/snes/component/bus.dart';
import 'package:fnesemu_core/core/snes/rom/snes_file.dart';
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

    test('inverts a coefficient and an exponent', () {
      final bus = dspBus();
      command(bus, 0x10, [0x4000, 0]); // 0.5 -> 2 = 0x7fff * 2^1
      expect(result(bus), 0x7fff);
      expect(result(bus), 1);
      command(bus, 0x10, [0x6000, 0]); // 0.75 -> 1.333 = 0x5555 * 2^1
      expect(result(bus), 0x5555);
      expect(result(bus), 1);
    });

    test('raster goes on with the next line', () {
      final bus = dspBus();
      // a view looking straight down from the height 64
      command(bus, 0x02, [0, 0, 0, 64, 128, 0, 0]);
      for (var i = 0; i < 4; i++) {
        result(bus);
      }
      command(bus, 0x0a, [0]);
      final line0 = [for (var i = 0; i < 4; i++) result(bus)];
      final line1 = [for (var i = 0; i < 4; i++) result(bus)];
      expect(line0, [128, 0, 0, 128]); // a ground pixel is half a dot
      expect(line1, [128, 0, 0, 128]);
    });

    test('a write of \$8000 ends the raster command', () {
      final bus = dspBus();
      command(bus, 0x0a, [0]);
      for (var i = 0; i < 3; i++) {
        result(bus);
      }
      bus.write(0x6000, 0x00); // \$8000 in place of reading D
      bus.write(0x6000, 0x80);
      command(bus, 0x00, [0x4000, 0x4000]); // the next command runs
      expect(result(bus), 0x2000);
    });
  });
}
