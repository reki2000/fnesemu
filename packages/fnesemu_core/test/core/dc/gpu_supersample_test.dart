import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/gpu_texture.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  const reg = 0xa05f8000, copy = 0x20800000, ss = 0x1000;
  late DcBus bus;
  setUp(() {
    bus = DcBus();
    bus.write32(reg + 8, 0);
  });
  void texel(int index, int value) =>
      bus.write16(0xa4060000 + index * 2, value);
  DcGpuTexture texture({int tcw = 0x0800c000, int tsp = copy | ss}) =>
      DcGpuTexture(bus.gpu.vram, tcw: tcw, tsp: tsp, palette: bus.gpu.palette);
  const corners = [(0.125, 0.0), (0.0, 0.125), (0.125, 0.125)];
  void colors() {
    for (var i = 0; i < 64; i++) {
      texel(i, [0xf800, 0x07e0, 0x001f, 0xffff][i & 3]);
    }
  }

  int average(List<int> colors) {
    var value = 0;
    for (var shift = 0; shift < 32; shift += 8) {
      final sum =
          colors.fold<int>(0, (sum, color) => sum + ((color >> shift) & 255));
      value |= ((sum + 2) ~/ 4) << shift;
    }
    return value;
  }

  void render(
      {int tsp = copy | ss,
      bool perspective = false,
      bool textureHalf = false}) {
    bus.write32(reg + 0x80, textureHalf ? 4 : 0);
    int bits(double value) {
      final data = ByteData(4)..setFloat32(0, value, Endian.little);
      return data.getUint32(0, Endian.little);
    }

    void packet(List<int> words) {
      final bytes = Uint8List(32);
      for (final (i, word) in words.indexed) {
        bytes.setUint32LE(i * 4, word);
      }
      bus.gpu.writePolygon(bytes);
    }

    void put(int address, List<int> words) {
      for (final (i, word) in words.indexed) {
        bus.gpu.vram.setUint32LE(address + i * 4, word);
      }
    }

    for (final (offset, value) in [
      (0x124, 0x100000),
      (0x128, 0x200000),
      (0x20, 0x200000),
      (0x12c, 0x10ffe0),
      (0x130, 0x20fffc),
      (0x140, 1),
      (0x164, 0x101000),
      (0x144, 0x80000000)
    ]) {
      bus.write32(reg + offset, value);
    }
    packet([0x80800008, 0xe0000000, tsp, 0x0800c000]);
    for (final (i, xy) in [(0.0, 0.0), (32.0, 0.0), (0.0, 32.0)].indexed) {
      packet([
        i == 2 ? 0xf0000000 : 0xe0000000,
        bits(xy.$1),
        bits(xy.$2),
        bits(perspective ? [1.0, 2.0, 4.0][i] : 1.0),
        bits(xy.$1 / 4),
        bits(xy.$2 / 4),
        0xffffffff
      ]);
    }
    packet([0]);
    put(0x200000 + 0x8000, [
      0xe0000000,
      copy,
      0,
      0,
      0,
      0,
      0xff000000,
      0,
      0,
      0,
      0xff000000,
      0,
      0,
      0,
      0xff000000
    ]);
    put(0x9000, [0x80000000, 0x100000, 0x80000000, 0x80000000, 0x80000000]);
    for (final (offset, value) in [
      (0x2c, 0x9000),
      (0x48, 6),
      (0x4c, 16),
      (0x60, 0x400000),
      (0x68, 31 << 16),
      (0x6c, 31 << 16),
      (0x8c, 0x1000000 | 0x10000),
      (0x14, 1)
    ]) {
      bus.write32(reg + offset, value);
    }
    bus.tickMasterClocks(2);
  }

  test('four explicit point samples average all ARGB channels', () {
    colors();
    expect(texture().sample(0, 0, extraSamples: corners), 0xff808080);
    expect(texture(tsp: copy).sample(0, 0), 0xffff0000);
  });
  test('each subpoint uses the selected bilinear filter before averaging', () {
    colors();
    const points = [(0.0, 0.0), (0.0625, 0.0), (0.0, 0.0625), (0.0625, 0.0625)];
    final plain = texture(tsp: copy | 0x2000);
    final expected = average([for (final (u, v) in points) plain.sample(u, v)]);
    expect(
        texture(tsp: copy | ss | 0x2000)
            .sample(0, 0, extraSamples: points.sublist(1)),
        expected);
  });
  test(
      'TA and CORE evaluate half-pixel screen locations without extra coverage',
      () {
    colors();
    render(tsp: copy);
    expect(bus.gpu.vram.getUint32LE(0x400000), 0xffff0000);
    render();
    expect(bus.gpu.vram.getUint32LE(0x400000), 0xff808080);
    expect(bus.gpu.vram.getUint32LE(0x400000 + (31 * 32 + 31) * 4), 0xff000000);
  });
}
