import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/gpu_texture.dart';
import 'package:fnesemu_core/src/core/dc/gpu_yuv.dart';
import 'package:test/test.dart';

void main() {
  late Uint8List memory;
  late DcGpuYuv converter;
  late List<int> interrupts;
  setUp(() {
    memory = Uint8List(0x800000);
    interrupts = [];
    converter = DcGpuYuv(memory, onNormal: interrupts.add);
    converter.write(0x148, 0x60000);
  });
  int physical(int address) =>
      (address & 3) | ((address >> 1) & 0x3ffffc) | ((address & 4) << 20);
  int byte(int address) => memory[physical(address)];
  Uint8List block({bool form422 = false, int y = 100}) {
    final result = Uint8List(form422 ? 512 : 384);
    if (form422) {
      for (final start in [0, 256]) {
        result.fillRange(start, start + 64, 160);
        result.fillRange(start + 64, start + 128, 144);
        result.fillRange(start + 128, start + 256, y);
      }
    } else {
      result.fillRange(0, 64, 160);
      result.fillRange(64, 128, 144);
      result.fillRange(128, 384, y);
    }
    return result;
  }

  void feed(Uint8List data, [int start = 0, int? end]) {
    for (var offset = start; offset < (end ?? data.length); offset += 32) {
      converter.accept(Uint8List.sublistView(data, offset, offset + 32));
    }
  }

  test('YUV rational matrix preserves neutral levels and clamps channels', () {
    expect(DcGpuTexture.yuvColor(0, 128, 128), 0xff000000);
    expect(DcGpuTexture.yuvColor(255, 128, 128), 0xffffffff);
    expect(DcGpuTexture.yuvColor(100, 160, 144), 0xff7a4e9b);
    expect(DcGpuTexture.yuvColor(200, 160, 144), 0xffdeb2ff);
  });

  test('twiddled YUV pairs horizontal texels across adjacent Morton rows', () {
    final words = ByteData.sublistView(memory);
    void put(int word, int value) {
      words.setUint16(physical(0x60000 + word * 2), value, Endian.little);
    }

    put(0, (100 << 8) | 160);
    put(2, (200 << 8) | 144);
    put(1, (50 << 8) | 96);
    put(3, (75 << 8) | 112);
    final texture = DcGpuTexture(memory, tcw: 0x1800c000, tsp: 0);
    expect(texture.sample(0, 0), 0xff7a4e9b);
    expect(texture.sample(1 / 8, 0), 0xffdeb2ff);
    expect(texture.sample(0, 1 / 8), 0xff1c4800);
    expect(texture.sample(1 / 8, 1 / 8), 0xff356114);
  });

  test('420 commits top and bottom halves at 256 and 384 input bytes', () {
    final data = block();
    for (var quadrant = 0; quadrant < 4; quadrant++) {
      data.fillRange(
          128 + quadrant * 64, 192 + quadrant * 64, (quadrant + 1) * 10);
    }
    feed(data, 0, 224);
    expect(byte(0x60001), 0);
    feed(data, 224, 256);
    expect(byte(0x60001), 10);
    expect(byte(0x60011), 20);
    expect(byte(0x60101), 0);
    expect(converter.completedBlocks, 0);
    expect(interrupts, isEmpty);
    feed(data, 256);
    expect(byte(0x60101), 30);
    expect(byte(0x60111), 40);
    expect(converter.read(0x150), 1);
    expect(interrupts, [1 << 6]);
    final texture = DcGpuTexture(memory, tcw: 0x1c00c000, tsp: 9);
    expect(texture.sample(0, 0), DcGpuTexture.yuvColor(10, 160, 144));
  });

  test('420 chroma repeats vertically while 422 supplies every row', () {
    final data = block();
    for (var row = 0; row < 8; row++) {
      data.fillRange(row * 8, row * 8 + 8, row + 120);
    }
    feed(data);
    expect([for (var row = 0; row < 4; row++) byte(0x60000 + row * 32)],
        [120, 120, 121, 121]);
    converter.write(0x148, 0x60000);
    converter.write(0x14c, 1 << 24);
    final full = block(form422: true);
    for (var row = 0; row < 16; row++) {
      final start = (row ~/ 8) * 256 + (row & 7) * 8;
      full.fillRange(start, start + 8, row + 110);
    }
    feed(full, 0, 256);
    expect(converter.completedBlocks, 0);
    feed(full, 256);
    expect([for (var row = 0; row < 16; row++) byte(0x60000 + row * 32)],
        [for (var row = 0; row < 16; row++) row + 110]);
    expect(interrupts, [64, 64]);
  });

  test('combined images place macroblocks in horizontal then vertical order',
      () {
    converter.write(0x14c, 0x101);
    for (var n = 1; n <= 4; n++) {
      feed(block(y: n * 10));
      expect(converter.completedBlocks, n);
      expect(interrupts, n == 4 ? [64] : isEmpty);
    }
    expect(byte(0x60001), 10);
    expect(byte(0x60021), 20);
    expect(byte(0x60401), 30);
    expect(byte(0x60421), 40);
  });

  test('separate blocks are contiguous and the next frame restarts at base',
      () {
    converter.write(0x14c, 0x10002);
    for (var n = 1; n <= 3; n++) {
      feed(block(y: n * 10));
    }
    expect([byte(0x60001), byte(0x60201), byte(0x60401)], [10, 20, 30]);
    expect(interrupts, [64]);
    feed(block(y: 90));
    expect(converter.completedBlocks, 1);
    expect(byte(0x60001), 90);
    expect(byte(0x60201), 20);
    expect(interrupts, [64]);
  });

  test(
      'base initialization discards partial input and count writes are ignored',
      () {
    feed(block(), 0, 128);
    expect(() => converter.write(0x14c, 0), throwsA(isA<DcUnsupported>()));
    converter.write(0x148, 0x60007);
    expect(converter.read(0x148), 0x60000);
    expect(converter.inputBytes, 0);
    converter.write(0x150, 123);
    expect(converter.read(0x150), 0);
    feed(block());
    expect(byte(0x60001), 100);
  });

  test('out of range halves stop before writes and can be reinitialized', () {
    converter.write(0x148, 0x7ffff8);
    final data = block();
    feed(data, 0, 224);
    expect(() => feed(data, 224, 256), throwsA(isA<DcUnsupported>()));
    expect(converter.inputBytes, 224);
    expect(memory.any((value) => value != 0), isFalse);
    expect(interrupts, isEmpty);
    converter.write(0x148, 0x60000);
    feed(data);
    expect(interrupts, [64]);
  });

  test(
      'store queues route YUV bursts through the CPU bus and raise HOLLY bit 6',
      () {
    final bus = DcBus();
    bus.write32(0xa05f8008, 0);
    bus.write32(0xa05f8148, 0x60000);
    bus.write32(0xff000038, 0x10);
    final data = block();
    for (var offset = 0; offset < data.length; offset += 32) {
      final words = ByteData.sublistView(data, offset, offset + 32);
      for (var i = 0; i < 8; i++) {
        bus.write32(0xe0000000 + i * 4, words.getUint32(i * 4, Endian.little));
      }
      bus.transferStoreQueue(0xe0800000);
    }
    expect(bus.read32(0xa05f8150), 1);
    expect(bus.read32(0xa05f6900) & 64, 64);
    final view = DcGpuTexture(bus.gpu.vram, tcw: 0x1c00c000, tsp: 9);
    expect(view.sample(0, 0), 0xff7a4e9b);
  });
  test('normal DMA preserves half-block boundaries with idle display timing',
      () {
    final bus = DcBus();
    bus.write32(0xa05f8008, 0);
    bus.write32(0xa05f8148, 0x60000);
    bus.ram.setRange(0x10000, 0x10180, block());
    for (final entry in [
      (0, 0x0c010000),
      (4, 0x10800000),
      (8, 12),
      (12, 0x1445),
      (0x40, 1)
    ]) {
      bus.write32(0xffa00000 + entry.$1, entry.$2);
    }
    bus.tickMasterClocks(15);
    expect(bus.gpu.yuv.inputBytes, 224);
    expect(bus.read16(0xa4060000), 0);
    bus.tickMasterClocks(1);
    expect(bus.read16(0xa4060000), 0x64a0);
    expect(bus.read32(0xa05f6900) & 64, 0);
    bus.tickMasterClocks(8);
    expect(bus.read32(0xffa00008), 0);
    expect(bus.read32(0xa05f8150), 1);
    expect(bus.read32(0xa05f6900) & 64, 64);
  });

  test('input lengths and undocumented combined dimensions stop explicitly',
      () {
    expect(
        () => converter.accept(Uint8List(16)), throwsA(isA<DcUnsupported>()));
    expect(() => converter.write(0x14c, 2), throwsA(isA<DcUnsupported>()));
    expect(() => converter.write(0x14c, 0x200), throwsA(isA<DcUnsupported>()));
    converter.write(0x14c, 0xffffffff);
    expect(converter.read(0x14c), 0x1013f3f);
  });
}
