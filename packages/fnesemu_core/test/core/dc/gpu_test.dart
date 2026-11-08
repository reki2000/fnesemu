import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:test/test.dart';

void main() {
  late DcBus bus;
  const registers = 0xa05f8000;
  setUp(() => bus = DcBus());
  void display(int depth, int words, int lines,
      {int modulus = 1, int concat = 0}) {
    bus.write32(registers + 8, 0);
    bus.write32(registers + 0xe8, 0);
    bus.write32(registers + 0x44, 1 | (depth << 2) | (concat << 4));
    bus.write32(
        registers + 0x5c, (words - 1) | ((lines - 1) << 10) | (modulus << 20));
  }

  test('32-bit and 64-bit VRAM apertures share banks in documented order', () {
    bus.write32(0xa4000000, 0x11223344);
    bus.write32(0xa4000004, 0x55667788);
    bus.write32(0xa4000008, 0x99aabbcc);
    expect(bus.read32(0xa5000000), 0x11223344);
    expect(bus.read32(0xa5400000), 0x55667788);
    expect(bus.read32(0xa5000004), 0x99aabbcc);
    bus.write32(0xa5400004, 0xddeeff00);
    expect(bus.read32(0xa400000c), 0xddeeff00);
    expect(bus.read32(0xa6000004), 0x55667788);
    expect(bus.read32(0xa7400004), 0xddeeff00);
  });













  test('GPU reset retains VRAM unless the whole core power-cycles', () {
    display(3, 1, 1);
    bus.write32(0xa5000000, 0x11223344);
    bus.gpu.reset();
    expect(bus.gpu.image().buffer, isEmpty);
    expect(bus.read32(0xa5000000), 0x11223344);
    expect(bus.read32(registers + 8), 7);
    final core = Dc();
    addTearDown(core.dispose);
    core.bus.write32(0xa5000000, 42);
    core.reset();
    expect(core.bus.read32(0xa5000000), 0);
  });

  test('pipeline reset preserves region format, frame targets and fog registers', () {
    const settings = {0x7c: 0x27df77, 0x98: 0x800408, 0x60: 0x200000,
      0xb0: 0x123456};
    for (final entry in settings.entries) {
      bus.write32(registers + entry.key, entry.value);
    }
    bus.write32(registers + 8, 2);
    bus.write32(registers + 8, 0);
    for (final entry in settings.entries) {
      expect(bus.read32(registers + entry.key), entry.value);
    }
    bus.gpu.reset();
    expect(bus.read32(registers + 0x7c), 0x7df77);
    expect(bus.read32(registers + 0xb0), 0);
  });

  test('self-authored SH4 program draws a framebuffer through Core.exec', () {
    final writes = [
      (registers + 8, 0),
      (registers + 0xe8, 0),
      (registers + 0x5c, 1 << 20),
      (registers + 0x44, 5),
      (0xa5000000, 0x07e0f800)
    ];
    final program = Uint8List(36 + writes.length * 8);
    final bytes = ByteData.sublistView(program);
    for (var i = 0; i < writes.length; i++) {
      final offset = i * 6, literal = 36 + i * 8;
      bytes.setUint16(offset, 0xd000 | ((literal - ((offset + 4) & ~3)) ~/ 4),
          Endian.little);
      bytes.setUint16(offset + 2,
          0xd100 | ((literal + 4 - ((offset + 6) & ~3)) ~/ 4), Endian.little);
      bytes.setUint16(offset + 4, 0x2012, Endian.little);
      bytes.setUint32(literal, writes[i].$1, Endian.little);
      bytes.setUint32(literal + 4, writes[i].$2, Endian.little);
    }
    bytes.setUint16(30, 0xaffe, Endian.little);
    bytes.setUint16(32, 9, Endian.little);
    final core = Dc()..setRom(program);
    addTearDown(core.dispose);
    expect(core.imageBuffer().buffer, isEmpty);
    for (var i = 0; i < writes.length * 3; i++) {
      expect(core.exec(true).stopped, isFalse);
    }
    final image = core.imageBuffer();
    expect(image.width, 2);
    expect(image.height, 1);
    expect(image.buffer, [0xff0000f8, 0xff00fc00]);
  });
}
