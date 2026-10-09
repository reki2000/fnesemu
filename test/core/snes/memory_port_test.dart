import 'dart:typed_data';

import 'package:fnesemu/core/snes/component/bus.dart';
import 'package:fnesemu/core/snes/component/ppu.dart';
import 'package:fnesemu/core/snes/rom/snes_file.dart';
import 'package:test/test.dart';

Bus _bus() {
  final rom = Uint8List(0x8000);
  rom[0x7ffd] = 0x80;
  return Bus()
    ..setRom(SnesFile()..load(rom))
    ..ppu = Ppu();
}

void main() {
  test('WMDATA reads and writes wram at WMADD, which increments', () {
    final bus = _bus();
    bus.write(0x2181, 0xff);
    bus.write(0x2182, 0xff);
    bus.write(0x2183, 0x00);
    bus.write(0x2180, 0x12);
    bus.write(0x2180, 0x34); // crosses into bank $7F
    expect(bus.read(0x7effff), 0x12);
    expect(bus.read(0x7f0000), 0x34);

    bus.write(0x2181, 0xff);
    bus.write(0x2182, 0xff);
    bus.write(0x2183, 0x00);
    expect(bus.read(0x2180), 0x12);
    expect(bus.read(0x2180), 0x34);
  });

  test('a vram read after the dummy read starts at the set address', () {
    final ppu = Ppu();
    ppu.write(0x2115, 0x80); // increment after the high byte
    ppu.write(0x2116, 0x00);
    ppu.write(0x2117, 0x10);
    for (final v in [0x11, 0x22, 0x33, 0x44]) {
      ppu.write(0x2118, v);
      ppu.write(0x2119, v + 1);
    }
    ppu.write(0x2116, 0x00);
    ppu.write(0x2117, 0x10);
    ppu.read(0x2139); // dummy read: the buffer still holds the old word
    ppu.read(0x213a);
    expect([ppu.read(0x2139), ppu.read(0x213a)], [0x11, 0x12]);
    expect([ppu.read(0x2139), ppu.read(0x213a)], [0x22, 0x23]);
  });

  test('an interleaved HiROM image is put back in order', () {
    // 4 blocks of 32KB in HiROM order 0,1,2,3 are stored as 1,3,0,2
    final hiRom = Uint8List(0x20000);
    for (var b = 0; b < 4; b++) {
      hiRom.fillRange(b * 0x8000, b * 0x8000 + 0x10, b + 1);
    }
    final header = hiRom.buffer.asUint8List(0xffc0, 0x40);
    header.fillRange(0, 21, 0x41);
    header[0x15] = 0x21;
    header[0x1c] = 0xff;
    header[0x1d] = 0xff;
    header[0x3d] = 0x80;
    final image = Uint8List(0x20000);
    for (final (to, from) in [(0, 1), (1, 3), (2, 0), (3, 2)]) {
      image.setRange(to * 0x8000, (to + 1) * 0x8000, hiRom, from * 0x8000);
    }
    final file = SnesFile()..load(image);
    expect(file.mapping, SnesMapping.hiRom);
    expect([for (var b = 0; b < 4; b++) file.rom[b * 0x8000]], [1, 2, 3, 4]);
  });
}
