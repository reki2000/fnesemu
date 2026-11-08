import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/gpu_fog.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  late DcGpuFog fog;
  setUp(() => fog = DcGpuFog());
  int apply(int color,
          {double depth = 1,
          int offset = 0,
          int mode = 0,
          bool hasOffset = false,
          bool clamp = false}) =>
      fog.apply(color, depth, offset, (mode << 22) | (clamp ? 0x200000 : 0),
          hasOffset: hasOffset);

  test('register masks and documented reset colors, density and clamp bounds',
      () {
    for (final address in [0xb0, 0xb4, 0xb8, 0xbc, 0xc0]) {
      expect(fog.read(address), 0);
      fog.write(address, 0xffffffff);
    }
    expect(fog.read(0xb0), 0xffffff);
    expect(fog.read(0xb4), 0xffffff);
    expect(fog.read(0xb8), 0xffff);
    expect(fog.read(0xbc), 0xffffffff);
    expect(fog.read(0xc0), 0xffffffff);
    fog.write(0x200, 0x12345678);
    fog.write(0x3fc, 0xabcdef01);
    expect(fog.read(0x200), 0x5678);
    expect(fog.read(0x3fc), 0xef01);
    fog.reset();
    expect(fog.read(0x200), 0);
    expect(fog.read(0x3fc), 0);
    expect(fog.read(0xbc), 0);
  });

  test(
      'table entries contain both endpoints rather than fetching the next word',
      () {
    fog.write(0xb8, 0x8000); // Scale 1.
    fog.write(0xb0, 0xffffff);
    fog.write(0x200, 0x00fe);
    fog.write(0x204, 0);
    expect(apply(0x80000000), 0x80000000);
    expect(apply(0x80000000, depth: 1 + 1 / 32), 0x807f7f7f);
    expect(apply(0x80000000, depth: 1 + 1 / 16), 0x80000000);
  });

  test('table addresses use three exponent bits followed by four mantissa bits',
      () {
    fog.write(0xb8, 0x8000);
    fog.write(0xb0, 0x0000ff);
    fog.write(0x200 + 17 * 4, 0xffff); // 2 * (1 + 1/16).
    expect(apply(0xffff0000, depth: 2.125), 0xff0000ff);
    expect(apply(0xffff0000, depth: 2), 0xffff0000);
  });







  group('CPU bus and CORE rendering', () {
    const reg = 0xa05f8000, copy = 0x20800000;
    late DcBus bus;
    setUp(() {
      bus = DcBus();
      bus.write32(reg + 8, 0);
    });
    int bits(double value) {
      final bytes = ByteData(4)..setFloat32(0, value, Endian.little);
      return bytes.getUint32(0, Endian.little);
    }

    void put(int address, List<int> words) {
      for (final (i, value) in words.indexed) {
        bus.gpu.vram.setUint32LE(address + i * 4, value);
      }
    }

    void scene(
        {int tsp = copy,
        int backgroundTsp = copy,
        int color = 0xffff0000,
        bool textured = false,
        bool gouraud = false,
        List<int> offsets = const [0, 0, 0],
        List<double> depths = const [1, 1, 1]}) {
      put(0x8000, [
        0xe0000000,
        backgroundTsp,
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
      put(0x100000, [
        0x80000000 | ((textured ? 4 : 1) << 21) | (0x200000 >> 2),
        0xf0000000
      ]);
      put(0x200000, [
        0xe0000000 | (textured ? 0x03000000 : 0) | (gouraud ? 0x00800000 : 0),
        tsp,
        0x0800c000,
        for (final (i, xy)
            in [(0.0, 0.0), (32.0, 0.0), (0.0, 32.0)].indexed) ...[
          bits(xy.$1),
          bits(xy.$2),
          bits(depths[i]),
          if (textured) ...[0, 0],
          color,
          if (textured) offsets[i]
        ]
      ]);
      bus.write16(0xa4060000, 0xffff);
      for (final entry in [
        (0x2c, 0x9000),
        (0x48, 6),
        (0x4c, 16),
        (0x60, 0x400000),
        (0x68, 31 << 16),
        (0x6c, 31 << 16),
        (0x8c, 0x1000000 | (0x8000 * 2))
      ]) {
        bus.write32(reg + entry.$1, entry.$2);
      }
    }

    int pixel(int x, int y) =>
        bus.gpu.vram.getUint32LE(0x400000 + (y * 32 + x) * 4);
    void draw() {
      bus.write32(reg + 0x14, 1);
      bus.tickMasterClocks(2);
    }






  });
  test('the depth scale follows every change of the density register', () {
    fog.write(0xb0, 0xffffff);
    fog.write(0x200 + 16 * 4, 0xff00); // Depth 2 to 2 + 1/8: full fog.
    // Scale 1 maps depth 2 to table entry 16; scale 2 maps it to entry 32.
    fog.write(0xb8, 0x8000);
    final one = apply(0x80000000, depth: 2);
    fog.write(0xb8, 0x8001);
    final two = apply(0x80000000, depth: 2);
    expect(one, isNot(two));
    fog.write(0xb8, 0x8000);
    expect(apply(0x80000000, depth: 2), one);
    fog.write(0xb8, 0x80ff); // Exponent -1.
    final half = apply(0x80000000, depth: 2);
    fog.write(0xb8, 0x8000);
    fog.write(0xb8, 0x80ff);
    expect(apply(0x80000000, depth: 2), half);
    fog.reset();
    fog.write(0xb0, 0xffffff);
    fog.write(0x200 + 16 * 4, 0xff00);
    fog.write(0xb8, 0x8000);
    expect(apply(0x80000000, depth: 2), one);
  });
}
