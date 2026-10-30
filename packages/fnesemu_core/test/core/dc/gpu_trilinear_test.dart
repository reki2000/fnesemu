import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/gpu_texture.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  const secondaryDestination = 0x01000000, secondarySource = 0x02000000;
  const reg = 0xa05f8000,
      object = 0x100000,
      copy = 0x20800000,
      alpha = 0x94900000;
  late DcBus bus;
  final lists = <int>{};
  setUp(() {
    bus = DcBus();
    bus.write32(reg + 8, 0);
    lists.clear();
  });
  int bits(double value) {
    final data = ByteData(4)..setFloat32(0, value, Endian.little);
    return data.getUint32(0, Endian.little);
  }

  void packet(List<int> words) {
    final data = Uint8List(32);
    for (final (i, value) in words.indexed) {
      data.setUint32LE(i * 4, value);
    }
    bus.gpu.writePolygon(data);
  }

  void init() {
    for (final item in [
      (0x124, object),
      (0x128, 0x200000),
      (0x12c, 0x10ffe0),
      (0x130, 0x20fffc),
      (0x140, 0x10101),
      (0x164, 0x101000),
      (0x144, 0x80000000)
    ]) {
      bus.write32(reg + item.$1, item.$2);
    }
  }

  void layer(int list,
      {int color = 0xffff0000,
      double depth = 1,
      List<double>? depths,
      List<int>? colors,
      int isp = 0xe0000000,
      int tsp = copy | 0x100000,
      int? texture,
      double coordinate = 0,
      double extent = 32,
      double uvScale = 0}) {
    lists.add(list);
    packet([
      0x80800000 |
          (list << 24) |
          (texture != null ? 8 : 0) |
          (colors != null ? 2 : 0),
      isp,
      tsp,
      texture ?? 0
    ]);
    for (final (i, xy) in [(0.0, 0.0), (extent, 0.0), (0.0, extent)].indexed) {
      packet([
        i == 2 ? 0xf0000000 : 0xe0000000,
        bits(xy.$1),
        bits(xy.$2),
        bits(depths?[i] ?? depth),
        bits(coordinate + xy.$1 * uvScale),
        bits(coordinate + xy.$2 * uvScale),
        colors?[i] ?? color
      ]);
    }
  }

  void end() => packet([0]);
  void put(int address, List<int> words) {
    for (final (i, value) in words.indexed) {
      bus.gpu.vram.setUint32LE(address + i * 4, value);
    }
  }

  void prepare(
      {bool type2 = true,
      bool presort = false,
      bool? globalPresort,
      int reference = 255}) {
    put(0x8000, [
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
    put(0x9000, [
      0x80000000 | (type2 && presort ? 0x20000000 : 0),
      lists.contains(0) ? object : 0x80000000,
      0x80000000,
      lists.contains(2) ? object + 32 : 0x80000000,
      0x80000000,
      if (type2) lists.contains(4) ? object + 64 : 0x80000000
    ]);
    for (final item in [
      (0x2c, 0x9000),
      (0x48, 6),
      (0x4c, 16),
      (0x60, 0x400000),
      (0x68, 31 << 16),
      (0x6c, 31 << 16),
      (0x8c, 0x1000000 | (0x8000 * 2)),
      (0x7c, type2 ? 0x200000 : 0),
      (0x98, 0x402000 | ((globalPresort ?? presort) ? 1 : 0)),
      (0x11c, reference)
    ]) {
      bus.write32(reg + item.$1, item.$2);
    }
  }

  void draw(
      {bool type2 = true,
      bool presort = false,
      bool? globalPresort,
      int reference = 255}) {
    prepare(
        type2: type2,
        presort: presort,
        globalPresort: globalPresort,
        reference: reference);
    bus.write32(reg + 0x14, 1);
    bus.tickMasterClocks(2);
  }

  int pixel(int x, int y) =>
      bus.gpu.vram.getUint32LE(0x400000 + (y * 32 + x) * 4);

  void word(int offset, int color) => bus.write16(0xa4060000 + offset, color);
  void byte(int offset, int value) {
    final address = 0xa4060000 + (offset & ~1), shift = (offset & 1) * 8;
    bus.write16(address,
        (bus.read16(address) & ~(255 << shift)) | ((value & 255) << shift));
  }

  const rgbOffsets = [6, 8, 0x10, 0x30];
  void rgbPyramid() {
    for (final (exponent, color) in [0xffff, 0x001f, 0x07e0, 0xf800].indexed) {
      for (var i = 0; i < 1 << (2 * exponent); i++) {
        word(rgbOffsets[exponent] + 2 * i, color);
      }
    }
  }

  DcGpuTexture view(int pass, {int tcw = 0x8800c000, int adjust = 4}) =>
      DcGpuTexture(bus.gpu.vram,
          tcw: tcw,
          tsp: copy | (adjust << 8) | (pass << 13),
          palette: bus.gpu.palette);
  int weighted(int pass, double footprint, {int tcw = 0x8800c000}) {
    final texture = view(pass, tcw: tcw);
    return texture.applyPassWeight(
        texture.sample(0, 0, footprint: footprint), footprint);
  }

  int sum(int a, int b) {
    var color = 0;
    for (var shift = 0; shift < 32; shift += 8) {
      color |=
          (((a >> shift) & 255) + ((b >> shift) & 255)).clamp(0, 255) << shift;
    }
    return color & 0xffffffff;
  }

  void pass(int list, int mode,
      {bool secondary = false,
      bool translucent = false,
      double footprint = 1.5,
      int tcw = 0x8800c000,
      int? tsp}) {
    layer(list,
        color: translucent ? 0x80ffffff : 0xffffffff,
        texture: tcw,
        uvScale: footprint / 8,
        tsp: tsp ??
            (copy |
                0x400 |
                (mode << 13) |
                (mode == 3 ? 0x04000000 : 0) |
                (secondary ? secondaryDestination : 0) |
                (translucent ? 0x1000c0 : 0)));
  }

  test(
      'passes sample adjacent levels and apply complementary binary-interval weights',
      () {
    rgbPyramid();
    expect(view(2).selectLevel(1.5), 0);
    expect(view(3).selectLevel(1.5), 1);
    expect(view(2).passWeight(1.5), 0.5);
    expect(view(3).passWeight(1.5), 0.5);
    expect(weighted(2, 1.5), 0x80800000);
    expect(weighted(3, 1.5), 0x80008000);
    expect(sum(weighted(2, 1.5), weighted(3, 1.5)), 0xff808000);
    expect(sum(weighted(2, 2.5), weighted(3, 2.5)), 0xff00bf40);
  });

  test('both passes use bilinear samples at their own resolution', () {
    rgbPyramid();
    for (final (i, color) in [0xf800, 0x07e0, 0x001f, 0xffff].indexed) {
      word(0x10 + i * 2, color);
    }
    expect(view(3).sample(1 / 8, 1 / 8, footprint: 1.5), 0xff808080);
    expect(view(3).applyPassWeight(0xff808080, 1.5), 0x80404040);
    expect(view(2).sample(1 / 8, 1 / 8, footprint: 1.5), 0xffff0000);
  });

  test('the pass multiplier scales alpha as well as RGB', () {
    expect(view(2).applyPassWeight(0x80402010, 1.5), 0x40201008);
    expect(view(3).applyPassWeight(0x80402010, 1.5), 0x40201008);
    expect(view(2).applyPassWeight(0x80402010, 1), 0x80402010);
    expect(view(3).applyPassWeight(0x80402010, 1), 0);
  });

  test('the combined color remains continuous at binary level boundaries', () {
    rgbPyramid();
    for (final (d, expected) in [
      (2.0, 0xff00ff00),
      (4.0, 0xff0000ff),
      (8.0, 0xffffffff)
    ]) {
      for (final delta in [-1e-8, 0.0, 1e-8]) {
        expect(sum(weighted(2, d + delta), weighted(3, d + delta)), expected);
      }
    }
  });

  test(
      'magnification and the smallest MIP level retain a full combined contribution',
      () {
    rgbPyramid();
    for (final d in [0.0, 0.5, 1.0]) {
      expect(sum(weighted(2, d), weighted(3, d)), 0xffff0000);
    }
    for (final d in [8.0, 100.0, 1e308]) {
      expect(view(2).selectLevel(d), 3);
      expect(view(3).selectLevel(d), 3);
      expect(sum(weighted(2, d), weighted(3, d)), 0xffffffff);
    }
    expect(view(2, adjust: 15).passWeight(1e308), 1);
  });

  test('quarter-unit D adjustment changes level choice and weight together',
      () {
    expect(view(2, adjust: 2).passWeight(3), 0.5);
    expect(view(3, adjust: 2).passWeight(3), 0.5);
    expect(view(2, adjust: 8).passWeight(0.75), 0.5);
    expect(view(3, adjust: 8).selectLevel(0.75), 1);
  });

  test('non-MIP and linear-MIP pass codes keep the documented point fallback',
      () {
    word(0, 0xf800);
    word(2, 0x07e0);
    for (final tcw in [0x0800c000, 0x8c00c000]) {
      for (final mode in [2, 3]) {
        final texture = view(mode, tcw: tcw);
        expect(texture.trilinear, isFalse);
        expect(texture.bilinear, isFalse);
        expect(texture.passWeight(1.5), 1);
        expect(
            texture.sample(0, 0), tcw == 0x8c00c000 ? 0xfff80000 : 0xffff0000);
      }
    }
  });

  test('invalid footprints are rejected for both pass modes', () {
    for (final mode in [2, 3]) {
      for (final d in [double.nan, double.infinity, -1.0]) {
        expect(() => view(mode).passWeight(d), throwsA(isA<DcUnsupported>()));
        expect(() => view(mode).sample(0, 0, footprint: d),
            throwsA(isA<DcUnsupported>()));
      }
    }
  });

  test('palette lookup precedes bilinear filtering and pass weighting', () {
    bus.write32(reg + 0x108, 3);
    bus.write32(0xa05f9004, 0xffff0000);
    bus.write32(0xa05f9008, 0xff00ff00);
    for (final fourBit in [true, false]) {
      for (var i = 0; i < 32; i++) {
        byte(fourBit ? 12 + i : 24 + i, fourBit ? 0x11 : 1);
      }
      for (var i = 0; i < (fourBit ? 8 : 16); i++) {
        byte(fourBit ? 4 + i : 8 + i, fourBit ? 0x22 : 2);
      }
      if (!fourBit) {
        for (var i = 32; i < 64; i++) {
          byte(24 + i, 1);
        }
      }
      final tcw = fourBit ? 0xa800c000 : 0xb000c000;
      expect(sum(weighted(2, 1.5, tcw: tcw), weighted(3, 1.5, tcw: tcw)),
          0xff808000);
    }
  });

  test(
      'VQ passes use their selected level index streams after the shared codebook',
      () {
    for (var i = 0; i < 4; i++) {
      word(8 + 2 * i, 0xf800);
      word(16 + 2 * i, 0x07e0);
    }
    for (var i = 0; i < 16; i++) {
      byte(0x806 + i, 1);
    }
    for (var i = 0; i < 4; i++) {
      byte(0x802 + i, 2);
    }
    expect(
        sum(weighted(2, 1.5, tcw: 0xc800c000),
            weighted(3, 1.5, tcw: 0xc800c000)),
        0xff808000);
  });

  test('YUV samples are converted before bilinear filtering and pass weighting',
      () {
    for (var i = 0; i < 64; i++) {
      word(0x30 + 2 * i, 0x2880);
    }
    for (var i = 0; i < 16; i++) {
      word(0x10 + 2 * i, 0x7880);
    }
    expect(
        sum(weighted(2, 1.5, tcw: 0x9800c000),
            weighted(3, 1.5, tcw: 0x9800c000)),
        0xff505050);
  });

  test(
      'opaque two-pass TA scene combines primary Pass A and translucent Pass B',
      () {
    init();
    rgbPyramid();
    pass(0, 2);
    end();
    pass(2, 3);
    end();
    draw();
    expect(pixel(1, 1), 0xff808000);
    expect(bus.systemBus.normalStatus & 7, 7);
  });

  test('translucent three-pass TA scenes accumulate RGBA before a flush', () {
    for (final presort in [false, true]) {
      bus = DcBus();
      bus.write32(reg + 8, 0);
      init();
      rgbPyramid();
      pass(2, 2, secondary: true, translucent: true);
      pass(2, 3, secondary: true, translucent: true);
      layer(2, tsp: alpha | secondarySource);
      end();
      draw(presort: presort);
      expect(pixel(1, 1), 0xbf404000);
      expect(pixel(31, 31), 0xff000000);
    }
  });

  test(
      'the multiplier follows fog so fog color is weighted with the shaded result',
      () {
    init();
    rgbPyramid();
    pass(0, 2, tsp: 0x20004400);
    end();
    bus.write32(reg + 0xb0, 0x0000ff);
    bus.write32(reg + 0x200, 0xffff);
    draw();
    expect(pixel(1, 1), 0x80000080);
  });

  test('HOLLY2 punch-through prohibits effective trilinear filtering', () {
    init();
    rgbPyramid();
    pass(4, 2);
    end();
    expect(() => draw(), throwsA(isA<DcUnsupported>()));
    expect(bus.systemBus.normalStatus & 7, 0);
  });

  test('punch-through pass codes without MIP retain point-sample behavior', () {
    init();
    for (var i = 0; i < 64; i++) {
      word(i * 2, 0xf800);
    }
    pass(4, 2, tcw: 0x0800c000);
    end();
    draw();
    expect(pixel(1, 1), 0xffff0000);
  });
}
