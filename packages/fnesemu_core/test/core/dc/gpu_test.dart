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

  test('VRAM boundary mirrors and compound quadwords cross the bank lanes', () {
    bus.writePair(0xa4000000, 0x12345678, 0x9abcdef0);
    expect(bus.readPair(0xa4000000), (0x12345678, 0x9abcdef0));
    expect(bus.read32(0xa5000000), 0x12345678);
    expect(bus.read32(0xa5400000), 0x9abcdef0);
    bus.write32(0xa47ffffc, 0x42434445);
    expect(bus.read32(0xa4fffffc), 0x42434445);
    expect(bus.read32(0xa57ffffc), 0x42434445);
    expect(() => bus.read32(0xa4800002), throwsA(isA<DcUnsupported>()));
  });

  test(
      'byte bus accesses stop, while debugger byte inspection remains available',
      () {
    bus.write16(0xa5000000, 0x1234);
    expect(() => bus.read8(0xa5000000), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write8(0xa5000000, 0), throwsA(isA<DcUnsupported>()));
    expect(bus.peek8(0xa5000000), 0x34);
    expect(bus.read16(0xa5000000), 0x1234);
  });

  test('copy-back and write-through caches preserve VRAM alias coherency rules',
      () {
    bus.write32(0xff00001c, 5);
    bus.write32(0x84000000, 0x11223344);
    bus.write32(0x84000004, 0x55667788);
    expect(bus.read32(0xa5000000), 0);
    bus.cache.operate(0x84000000, 2);
    expect(bus.read32(0xa5000000), 0x11223344);
    expect(bus.read32(0xa5400000), 0x55667788);
    bus.write32(0xff00001c, 1);
    bus.write32(0x84000000, 0x12345678);
    expect(bus.read32(0xa5000000), 0x12345678);
    final cached = bus.read32(0x84000000);
    expect(() => bus.write8(0x84000000, 0), throwsA(isA<DcUnsupported>()));
    expect(bus.read32(0x84000000), cached);
  });

  test('copy-back byte stores reach VRAM as a valid line write-back', () {
    bus.write32(0xff00001c, 5);
    bus.write8(0x85000000, 0x42);
    expect(bus.peek8(0xa5000000), 0);
    bus.cache.operate(0x85000000, 1);
    expect(bus.peek8(0xa5000000), 0x42);
  });

  test('store-queue burst converts every VRAM bank lane', () {
    bus.write32(0xff000038, 4);
    for (var i = 0; i < 8; i++) {
      bus.write32(0xe0000000 + i * 4, i + 1);
    }
    bus.transferStoreQueue(0xe0000000);
    expect([for (var i = 0; i < 4; i++) bus.read32(0xa5000000 + i * 4)],
        [1, 3, 5, 7]);
    expect([for (var i = 0; i < 4; i++) bus.read32(0xa5400000 + i * 4)],
        [2, 4, 6, 8]);
  });

  test('SH4 DMA quadwords transfer through VRAM address conversion', () {
    bus.writePair(0xac020000, 0x11223344, 0x55667788);
    bus.write32(0xffa00000, 0x0c020000);
    bus.write32(0xffa00004, 0x04000000);
    bus.write32(0xffa00008, 1);
    bus.write32(0xffa0000c, 0x5401);
    bus.write32(0xffa00040, 1);
    bus.tickMasterClocks(2);
    expect(bus.read32(0xa5000000), 0x11223344);
    expect(bus.read32(0xa5400000), 0x55667788);
    expect(bus.read32(0xffa00008), 0);
  });

  test('0555 RGB uses explicit concatenation bits rather than bit replication',
      () {
    display(0, 1, 1, concat: 7);
    bus.write32(0xa5000000, 0x03e07c00);
    expect(bus.gpu.image().buffer, [0xff0707ff, 0xff07ff07]);
    expect(bus.gpu.image().bytes.take(4), [255, 7, 7, 255]);
  });

  test('RGB565 expands green with two concatenation bits', () {
    display(1, 1, 1, concat: 3);
    bus.write32(0xa5000000, 0x07e0f800);
    expect(bus.gpu.image().buffer, [0xff0303fb, 0xff03ff03]);
  });

  test('packed RGB888 crosses word boundaries without using a fourth byte', () {
    display(2, 3, 1);
    bus.write32(0xa5000000, 0x66554433);
    bus.write32(0xa5000004, 0xaa998877);
    bus.write32(0xa5000008, 0xffeeddcc);
    expect(bus.gpu.image().buffer,
        [0xff334455, 0xff667788, 0xff99aacc, 0xffddeeff]);
  });

  test('RGB0888 ignores the high byte and uses 32-bit aperture scanout', () {
    display(3, 1, 2);
    bus.write32(0xa5000000, 0x12112233);
    bus.write32(0xa5000004, 0xfe445566);
    expect(bus.gpu.image().buffer, [0xff332211, 0xff665544]);
  });

  test('modulus, start addresses and VRAM wrap determine each source row', () {
    display(3, 1, 2, modulus: 2);
    bus.write32(registers + 0x50, 0x7ffffc);
    bus.write32(0xa57ffffc, 0x00112233);
    bus.write32(0xa5000004, 0x00445566);
    expect(bus.gpu.image().buffer, [0xff332211, 0xff665544]);
    bus.write32(registers + 0x54, 4);
    bus.write32(0xa500000c, 0x00778899);
    expect(bus.gpu.image(field2: true).buffer, [0xff665544, 0xff998877]);
  });

  test(
      'blanking displays border, while pixel/line doubling sets display geometry',
      () {
    display(3, 1, 1);
    bus.write32(registers + 0x40, 0x00112233);
    bus.write32(registers + 0xe8, 0x108);
    bus.write32(registers + 0x44, 0xf);
    final image = bus.gpu.image();
    expect(image.buffer, [0xff332211]);
    expect(image.width, 1);
    expect(image.height, 1);
    expect(image.displayWidth, 2);
    expect(image.displayHeight, 2);
  });

  test('GPU reset retains VRAM unless the whole core power-cycles', () {
    display(3, 1, 1);
    bus.write32(0xa5000000, 0x11223344);
    bus.gpu.reset();
    expect(bus.gpu.image().buffer, isEmpty);
    expect(bus.read32(0xa5000000), 0x11223344);
    expect(bus.read32(registers + 8), 7);
    final core = Dc();
    core.bus.write32(0xa5000000, 42);
    core.reset();
    expect(core.bus.read32(0xa5000000), 0);
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
