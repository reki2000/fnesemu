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
      (0x20, 0x200000),
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












}
