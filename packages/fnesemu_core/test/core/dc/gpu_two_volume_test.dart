import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
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
      (0x140, 0x11111),
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
      bool shadow = false}) {
    lists.add(list);
    packet([
      0x80800000 |
          (list << 24) |
          (shadow ? 0x80 : 0) |
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
        if (texture == null) ...[
          0,
          0,
          colors?[i] ?? color
        ] else ...[
          bits(coordinate),
          bits(coordinate),
          colors?[i] ?? color
        ]
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
      lists.contains(1) ? object + 32 : 0x80000000,
      lists.contains(2) ? object + 64 : 0x80000000,
      lists.contains(3) ? object + 96 : 0x80000000,
      if (type2) lists.contains(4) ? object + 128 : 0x80000000
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

  void modifier(int list, int instruction,
      {double depth = 2, double extent = 32, int cull = 0, bool sq = false}) {
    lists.add(list);
    packet([
      0x80800000 | (list << 24) | (instruction != 0 ? 0x40 : 0),
      (instruction << 29) | (cull << 27)
    ]);
    final words = [
      0xf0000000,
      bits(0),
      bits(0),
      bits(depth),
      bits(extent),
      bits(0),
      bits(depth),
      bits(0),
      bits(extent),
      bits(depth),
      0x7fc00000,
      0xffffffff,
      0xffffffff,
      0xffffffff,
      0xffffffff,
      0xffffffff
    ];
    for (var half = 0; half < 2; half++) {
      if (sq) {
        bus.write32(0xff000038, 0x10);
        for (var i = 0; i < 8; i++) {
          bus.write32(0xe0000000 + i * 4, words[half * 8 + i]);
        }
        bus.transferStoreQueue(0xe0000000);
      } else {
        packet(words.sublist(half * 8, half * 8 + 8));
      }
    }
  }

  int vertexFormat = 0;
  bool vertexTextured = false, vertexUV16 = false;
  void global(int list,
      {int colorType = 0,
      bool textured = false,
      bool offset = false,
      bool uv16 = false,
      bool gouraud = false,
      int tsp0 = copy,
      int tsp1 = copy,
      int tcw0 = 0x0800c000,
      int tcw1 = 0x0800e000,
      List<double> face0 = const [1, 1, 0, 0],
      List<double> face1 = const [1, 0, 1, 0],
      int strip = 0}) {
    lists.add(list);
    vertexFormat = colorType;
    vertexTextured = textured;
    vertexUV16 = uv16;
    packet([
      0x808000c0 |
          (list << 24) |
          (colorType << 4) |
          (textured ? 8 : 0) |
          (offset ? 4 : 0) |
          (gouraud ? 2 : 0) |
          (uv16 ? 1 : 0) |
          (strip << 18),
      0xe0000000,
      tsp0,
      tcw0,
      tsp1,
      tcw1,
      0,
      0
    ]);
    if (colorType == 2) {
      packet([
        for (final value in [...face0, ...face1]) bits(value)
      ]);
    }
  }

  void vertex(double x, double y,
      {bool end = false,
      double z = 1,
      int color0 = 0xffff0000,
      int color1 = 0xff00ff00,
      int offset0 = 0,
      int offset1 = 0,
      double intensity0 = 1,
      double intensity1 = 1,
      double offIntensity0 = 1,
      double offIntensity1 = 1,
      double u0 = 0,
      double v0 = 0,
      double u1 = 0,
      double v1 = 0}) {
    final packed = vertexFormat == 0;
    int uv(double u, double v) => (bits(u) & 0xffff0000) | (bits(v) >> 16);
    final words = [
      end ? 0xf0000000 : 0xe0000000,
      bits(x),
      bits(y),
      bits(z),
      if (vertexTextured) ...[
        vertexUV16 ? uv(u0, v0) : bits(u0),
        vertexUV16 ? 0 : bits(v0),
        packed ? color0 : bits(intensity0),
        packed ? offset0 : bits(offIntensity0),
        vertexUV16 ? uv(u1, v1) : bits(u1),
        vertexUV16 ? 0 : bits(v1),
        packed ? color1 : bits(intensity1),
        packed ? offset1 : bits(offIntensity1),
        0,
        0,
        0,
        0
      ] else ...[
        packed ? color0 : bits(intensity0),
        packed ? color1 : bits(intensity1),
        0,
        0
      ]
    ];
    packet(words.sublist(0, 8));
    if (vertexTextured) packet(words.sublist(8, 16));
  }

  void triangle(
      {double z = 1,
      int color0 = 0xffff0000,
      int color1 = 0xff00ff00,
      double u0 = 0,
      double u1 = 0,
      double intensity0 = 1,
      double intensity1 = 1,
      int offset0 = 0,
      int offset1 = 0}) {
    for (final (i, xy) in [(0.0, 0.0), (32.0, 0.0), (0.0, 32.0)].indexed) {
      vertex(xy.$1, xy.$2,
          end: i == 2,
          z: z,
          color0: color0,
          color1: color1,
          u0: u0,
          u1: u1,
          intensity0: intensity0,
          intensity1: intensity1,
          offset0: offset0,
          offset1: offset1);
    }
  }

  void volume([int list = 1, double extent = 16]) {
    modifier(list, 1, extent: extent);
    end();
  }

  test('TA stores both global pairs, both colors and single-material skip', () {
    init();
    global(0, tsp0: copy, tsp1: copy | 0x100000);
    triangle();
    end();
    expect(bus.read32(reg + 0x138), 0x200050);
    expect(bus.gpu.vram.getUint32LE(0x200004), copy);
    expect(bus.gpu.vram.getUint32LE(0x20000c), copy | 0x100000);
    expect(bus.gpu.vram.getUint32LE(0x200020), 0xffff0000);
    expect(bus.gpu.vram.getUint32LE(0x200024), 0xff00ff00);
    expect(bus.gpu.vram.getUint32LE(object) & 0x01e00000, 0x01200000);
  });

  test('parameter selection chooses color 0 outside and color 1 inside', () {
    init();
    global(0);
    triangle();
    end();
    volume();
    draw();
    expect(pixel(1, 1), 0xff00ff00);
    expect(pixel(20, 1), 0xffff0000);
  });

  test('absence of a modifier volume selects parameter 0', () {
    init();
    global(0);
    triangle();
    end();
    draw();
    expect(pixel(1, 1), 0xffff0000);
  });
























}
