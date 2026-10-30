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

  test(
      'signed density exponents and fractional mantissas follow documented scale',
      () {
    fog.write(0xb0, 0x00ff00);
    fog.write(0x200, 0xffff);
    fog.write(0xb8, 0xff07); // The manual's 255.0 example.
    expect(apply(0xff000000, depth: 1 / 255), 0xff00ff00);
    expect(apply(0xff000000, depth: 2 / 255), 0xff000000);
    fog.write(0xb8, 0x80ff); // Scale 1/2.
    expect(apply(0xff000000, depth: 2), 0xff00ff00);
    expect(apply(0xff000000, depth: 4), 0xff000000);
  });

  test('outlying depths clamp to the first and final table segments', () {
    fog.write(0xb8, 0x8000);
    fog.write(0xb0, 0xffffff);
    fog.write(0x200, 0x4040);
    fog.write(0x3fc, 0xc0c0);
    expect(apply(0xff000000, depth: -10), 0xff404040);
    expect(apply(0xff000000, depth: 0), 0xff404040);
    expect(apply(0xff000000, depth: 1e30), 0xffc0c0c0);
  });

  test('normal fog preserves alpha and selects the independent vertex color',
      () {
    fog.write(0xb0, 0xff0000);
    fog.write(0xb4, 0x0000ff);
    fog.write(0x200, 0xffff);
    expect(apply(0x406080a0), 0x40ff0000);
    expect(apply(0x406080a0, mode: 1, offset: 0xff112233, hasOffset: true),
        0x400000ff);
    expect(apply(0x406080a0, mode: 1, offset: 0xff000000), 0x406080a0);
    expect(apply(0x406080a0, mode: 2), 0x406080a0);
  });

  test('vertex alpha interpolates RGB using full range and ignores offset RGB',
      () {
    fog.write(0xb4, 0x0000ff);
    expect(apply(0x80ff0000, mode: 1, offset: 0x80ffffff, hasOffset: true),
        0x807f0080);
    expect(apply(0x80ff0000, mode: 1, offset: 0x80000000, hasOffset: true),
        0x807f0080);
  });

  test('table Mode 2 replaces RGB and alpha for subsequent blending', () {
    fog.write(0xb0, 0x123456);
    fog.write(0x200, 0x8080);
    expect(apply(0xffabcdef, mode: 3), 0x80123456);
  });

  test('clamp includes alpha and precedes fog, whose output can exceed bounds',
      () {
    fog.write(0xc0, 0x20304050);
    fog.write(0xbc, 0x8090a0b0);
    expect(apply(0xff00ffff, mode: 2, clamp: true), 0x8030a0b0);
    fog.write(0xb4, 0xffffff);
    expect(
        apply(0xff00ffff,
            mode: 1, offset: 0xff000000, hasOffset: true, clamp: true),
        0x80ffffff);
    expect(apply(0xff00ffff, mode: 2), 0xff00ffff);
  });

  test('inverted clamp bounds stop only when clamping is requested', () {
    fog.write(0xc0, 1);
    expect(apply(0xff000000, mode: 2), 0xff000000);
    expect(() => apply(0xff000000, mode: 2, clamp: true),
        throwsA(isA<DcUnsupported>()));
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

    test('register aliases, table limits and longword restrictions', () {
      bus.write32(reg + 0xb0, 0xffffffff);
      expect(bus.read32(0x825f80b0), 0xffffff);
      bus.write32(reg + 0x3fc, 0x12345678);
      expect(bus.read32(reg + 0x3fc), 0x5678);
      expect(() => bus.read16(reg + 0x200), throwsA(isA<DcUnsupported>()));
      expect(() => bus.write8(reg + 0xb0, 0), throwsA(isA<DcUnsupported>()));
      expect(() => bus.read32(reg + 0x400), throwsA(isA<DcUnsupported>()));
    });

    test('depth fog affects background and polygon before framebuffer packing',
        () {
      scene(tsp: 0x20000000, backgroundTsp: 0x20000000);
      bus.write32(reg + 0xb0, 0x0000ff);
      bus.write32(reg + 0x200, 0xffff);
      draw();
      expect(pixel(1, 1), 0xff0000ff);
      expect(pixel(31, 31), 0xff0000ff);
      expect(bus.systemBus.normalStatus & 7, 7);
    });

    test('per-vertex fog uses the provoking offset alpha for flat polygons',
        () {
      scene(
          tsp: 0x20400000 | (1 << 6),
          textured: true,
          offsets: [0, 0, 0xff000000]);
      bus.write32(reg + 0xb4, 0x0000ff);
      draw();
      expect(pixel(1, 1), 0xff0000ff);
    });

    test(
        'Gouraud fog interpolates offset alpha with reciprocal depth correction',
        () {
      scene(
          tsp: 0x20400000 | (1 << 6),
          textured: true,
          gouraud: true,
          offsets: [0, 0xff000000, 0],
          depths: [1, 2, 1]);
      bus.write32(reg + 0xb4, 0x0000ff);
      draw();
      // At (8.5, 0.5), the B weight after correction is (2*8.5)/(32+8.5).
      expect(pixel(8, 0), 0xff94006b);
    });

    test('color clamp operates after texture shading and before blending', () {
      scene(
          tsp: copy | 0x200000 | 0x100000 | (1 << 6),
          textured: true,
          color: 0x80ff0000);
      bus.write32(reg + 0xbc, 0x407fffff);
      bus.write32(reg + 0xc0, 0x00002030);
      draw();
      expect(pixel(1, 1), 0x407f2030);
    });

    test('Mode 2 supplies the source alpha for blending over the background',
        () {
      scene(tsp: 0x94c00000);
      bus.write32(reg + 0xb0, 0xff0000);
      bus.write32(reg + 0x200, 0x8080);
      draw();
      expect(pixel(1, 1), 0xbf800000);
    });

    test('fog register mutation during rendering retains the active settings',
        () {
      scene();
      bus.write32(reg + 0x14, 1);
      expect(() => bus.write32(reg + 0xb0, 0xffffff),
          throwsA(isA<DcUnsupported>()));
      bus.tickMasterClocks(2);
      expect(pixel(1, 1), 0xffff0000);
    });
  });
}
