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






}
