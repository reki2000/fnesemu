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
        // Non-textured packed color uses word 4; textured polygons keep U/V first.
        if (texture == null) ...[
          colors?[i] ?? color,
          0,
          0
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

  void texel(int index, int sr) => bus.write16(0xa4060000 + index * 2, sr);
  DcGpuTexture texture({int tcw = 0x2000c000, int tsp = copy}) =>
      DcGpuTexture(bus.gpu.vram, tcw: tcw, tsp: tsp);
  int sample(double u, double v,
          {int parameters = 0x0000ff00,
          int tcw = 0x2000c000,
          int tsp = copy,
          double footprint = 1}) =>
      texture(tcw: tcw, tsp: tsp)
          .sample(u, v, footprint: footprint, bumpParameters: parameters);
  void bumpLayer(int list,
      {int parameters = 0x80000000,
      int color = 0xff000000,
      int tsp = copy | 0x80,
      int tcw = 0x2000c000,
      bool floating = false,
      bool offset = true,
      bool gouraud = false,
      bool uv16 = false,
      List<int>? lights,
      double uvScale = 0}) {
    lists.add(list);
    packet([
      0x80800008 |
          (list << 24) |
          (offset ? 4 : 0) |
          (gouraud ? 2 : 0) |
          (uv16 ? 1 : 0) |
          (floating ? 0x10 : 0),
      0xe0000000,
      tsp,
      tcw
    ]);
    for (final (i, xy) in [(0.0, 0.0), (32.0, 0.0), (0.0, 32.0)].indexed) {
      final light = lights?[i] ?? parameters;
      final words = [
        i == 2 ? 0xf0000000 : 0xe0000000,
        bits(xy.$1),
        bits(xy.$2),
        bits(1),
        uv16
            ? ((bits(xy.$1 * uvScale) & 0xffff0000) |
                (bits(xy.$2 * uvScale) >> 16))
            : bits(xy.$1 * uvScale),
        uv16 ? 0 : bits(xy.$2 * uvScale),
        if (!floating) ...[
          color,
          light
        ] else ...[
          0,
          0,
          for (final shift in [24, 16, 8, 0])
            bits(((color >> shift) & 255) / 255),
          for (final shift in [24, 16, 8, 0])
            bits(((light >> shift) & 255) / 255)
        ]
      ];
      packet(words.sublist(0, 8));
      if (floating) packet(words.sublist(8, 16));
    }
  }

  test('aligned horizontal and vertical normals produce full brightness', () {
    expect(DcGpuTexture.bumpColor(0, 0x0000ff00), 0xffffffff);
    expect(DcGpuTexture.bumpColor(0xff00, 0x00ff0000), 0xffffffff);
    expect(DcGpuTexture.bumpColor(0, 0xff000000), 0xffffffff);
    expect(DcGpuTexture.bumpColor(0, 0x40000000), 0x40ffffff);
  });

  test('the hemisphere dot product handles oblique normals and light rotation',
      () {
    expect(DcGpuTexture.bumpColor(0x8000, 0x00808000), 0xb5ffffff);
    expect(DcGpuTexture.bumpColor(0x8040, 0x00808000), 0x5bffffff);
    expect(DcGpuTexture.bumpColor(0x0040, 0x0000ff40), 0xffffffff);
    expect(DcGpuTexture.bumpColor(0x0080, 0x0000ff00), 0x00ffffff);
  });

  test('the 255 angle endpoint denotes 256 for S, R and Q', () {
    expect(DcGpuTexture.bumpColor(0xfe00, 0x0000ff00), 0x03ffffff);
    expect(DcGpuTexture.bumpColor(0xff00, 0x0000ff00), 0x00ffffff);
    expect(DcGpuTexture.bumpColor(0x00fe, 0x0000ffc0), 0x0dffffff);
    expect(DcGpuTexture.bumpColor(0x00ff, 0x0000ffc0), 0x00ffffff);
    expect(DcGpuTexture.bumpColor(0x00c0, 0x0000fffe), 0x0dffffff);
    expect(DcGpuTexture.bumpColor(0x00c0, 0x0000ffff), 0x00ffffff);
  });

  test('negative and excessive brightness clamp to the alpha range', () {
    expect(DcGpuTexture.bumpColor(0x0080, 0x4000ff00), 0x00ffffff);
    expect(DcGpuTexture.bumpColor(0xff00, 0x80ff0000), 0xffffffff);
    expect(DcGpuTexture.bumpColor(0xff00, 0x40800000), 0xc0ffffff);
  });

  test('all four shading modes consume white RGB and computed brightness alpha',
      () {
    final tex = DcGpuTexture.bumpColor(0, 0x80000000);
    final expected = [0x80ffffff, 0x80402010, 0x80a09088, 0x40402010];
    for (var mode = 0; mode < 4; mode++) {
      expect(DcGpuTexture.shade(0x80402010, tex, 0, mode << 6), expected[mode]);
    }
    expect(DcGpuTexture.shade(0x80402010, 0x00ffffff, 0, 0x80080), 0x80ffffff);
  });

  test('point sampling decodes twiddled S/R words in V0 U0 order', () {
    texel(0, 0);
    texel(1, 0x0080);
    texel(2, 0x0040);
    texel(3, 0x00ff);
    expect(sample(0, 0), 0xffffffff);
    expect(sample(0, 1 / 8), 0x00ffffff);
    expect(sample(1 / 8, 0), 0x00ffffff);
    expect(sample(1 / 8, 1 / 8), 0xffffffff);
  });

  test('bilinear filtering combines derived alpha values and keeps RGB white',
      () {
    texel(0, 0);
    texel(1, 0x0080);
    texel(2, 0x0080);
    texel(3, 0);
    expect(sample(1 / 16, 1 / 16, tsp: copy | 0x2000), 0x80ffffff);
  });

  test('the functional filter does not average opposite azimuth byte endpoints',
      () {
    texel(0, 0);
    texel(1, 0x00ff);
    texel(2, 0x00ff);
    texel(3, 0);
    expect(sample(1 / 16, 1 / 16, tsp: copy | 0x2000), 0xffffffff);
  });

  test('repeat, mirror and clamp select the expected angular texels', () {
    texel(0, 0);
    texel(42, 0x0080);
    expect(sample(-1 / 8, 0), 0x00ffffff);
    expect(sample(-1 / 8, 0, tsp: copy | 0x40000), 0xffffffff);
    expect(sample(-10, 0, tsp: copy | 0x10000), 0xffffffff);
  });

  test('rectangular twiddled bump maps use unmatched coordinate bits', () {
    texel(64, 0xff00);
    expect(sample(0.5, 0, tsp: copy | 8, parameters: 0x00ff0000), 0xffffffff);
  });

  test(
      'functional MIP sampling uses the padded 16-bit offsets including texel three',
      () {
    texel(0x30 ~/ 2, 0);
    texel(0x10 ~/ 2, 0x8000);
    texel(8 ~/ 2, 0x4000);
    texel(6 ~/ 2, 0xff00);
    for (final (d, expected) in [
      (1.0, 0x00ffffff),
      (2.0, 0xb4ffffff),
      (4.0, 0x62ffffff),
      (8.0, 0xffffffff)
    ]) {
      expect(
          sample(0, 0,
              tcw: 0xa000c000,
              tsp: copy | 0x400,
              footprint: d,
              parameters: 0x00ff0000),
          expected);
    }
  });

  test('TA packed light parameters generate a Decal Alpha surface', () {
    init();
    bumpLayer(0);
    end();
    draw();
    expect(pixel(1, 1), 0xff808080);
    expect(pixel(20, 1), 0xff808080);
  });

  test(
      'the light parameters come from the provoking vertex without interpolation',
      () {
    init();
    bumpLayer(0, lights: [0xff000000, 0, 0x80000000]);
    end();
    draw();
    expect(pixel(1, 1), 0xff808080);
    expect(pixel(20, 1), 0xff808080);
  });

  test('K bytes replace Offset Color and are not added to shaded RGB', () {
    init();
    bumpLayer(0, parameters: 0x00ff0000);
    end();
    draw();
    expect(pixel(1, 1), 0xff000000);
  });

  test('floating color input and 16-bit UV preserve the packed K parameters',
      () {
    init();
    bumpLayer(0, floating: true, uv16: true);
    end();
    draw();
    expect(bus.gpu.vram.getUint32LE(0x200050), 0x80000000);
    expect(pixel(1, 1), 0xff808080);
  });

  test(
      'flat bump validation rejects missing offset parameters and Gouraud mode',
      () {
    for (final (offset, gouraud) in [(false, false), (true, true)]) {
      bus = DcBus();
      bus.write32(reg + 8, 0);
      init();
      bumpLayer(0, offset: offset, gouraud: gouraud);
      end();
      expect(() => draw(), throwsA(isA<DcUnsupported>()));
      expect(bus.systemBus.normalStatus & 7, 0);
    }
  });

  test('TA rejects intensity color conversion for bump parameters', () {
    init();
    packet([0x8080002c, 0xe0000000, copy | 0x80, 0x2000c000]);
    expect(() => packet([bits(1), 0, 0, 0, bits(1), 0, 0, 0]),
        throwsA(isA<DcUnsupported>()));
    expect(bus.systemBus.errorStatus & 16, 16);
  });

  test('TA checks bump intensity restrictions in the second volume as well',
      () {
    init();
    packet([0x808000ec, 0xe0000000, copy, 0x0800c000, copy, 0x2000c000]);
    expect(() => packet([bits(1), 0, 0, 0, bits(1), 0, 0, 0]),
        throwsA(isA<DcUnsupported>()));
    expect(bus.systemBus.errorStatus & 16, 16);
  });

  test(
      'method A combines bump and ordinary texture RGB while preserving texture alpha control',
      () {
    init();
    bumpLayer(2);
    bus.write16(0xa4070000, 0xf800);
    layer(2, texture: 0x0800e000, color: 0x80ffffff, tsp: 0x409000c0);
    end();
    draw();
    expect(pixel(1, 1), 0x80800000);
  });

  test('method B produces the same RGB with brightness-dependent output alpha',
      () {
    init();
    bus.write16(0xa4070000, 0xf800);
    layer(2, texture: 0x0800e000, color: 0x80ffffff, tsp: copy | 0x1000c0);
    bumpLayer(2, tsp: 0x10800000);
    end();
    draw();
    expect(pixel(1, 1), 0x40800000);
  });

  test(
      'secondary-buffer bump plus texture plus flush produces translucent output',
      () {
    for (final presort in [false, true]) {
      bus = DcBus();
      bus.write32(reg + 8, 0);
      init();
      bumpLayer(2, tsp: copy | 0x80 | secondaryDestination);
      bus.write16(0xa4070000, 0xf800);
      layer(2,
          texture: 0x0800e000,
          color: 0x80ffffff,
          tsp: 0x409000c0 | secondaryDestination);
      layer(2, tsp: alpha | secondarySource);
      end();
      draw(presort: presort);
      expect(pixel(1, 1), 0xbf400000);
    }
  });

  test(
      'two-volume selection supplies an independent light vector for each material',
      () {
    init();
    lists.add(0);
    packet([
      0x808000cc,
      0xe0000000,
      copy | 0x80,
      0x2000c000,
      copy | 0x80,
      0x2000c000
    ]);
    for (final (i, xy) in [(0.0, 0.0), (32.0, 0.0), (0.0, 32.0)].indexed) {
      packet([
        i == 2 ? 0xf0000000 : 0xe0000000,
        bits(xy.$1),
        bits(xy.$2),
        bits(1),
        0,
        0,
        0xff000000,
        0
      ]);
      packet([0, 0, 0xff000000, 0xff000000, 0, 0, 0, 0]);
    }
    end();
    modifier(1, 1, extent: 16);
    end();
    draw();
    expect(pixel(1, 1), 0xffffffff);
    expect(pixel(20, 1), 0xff000000);
  });

  test(
      'functional trilinear passes combine their independently evaluated bump normals',
      () {
    init();
    for (var i = 0; i < 64; i++) {
      bus.write16(0xa4060030 + i * 2, 0);
    }
    for (var i = 0; i < 16; i++) {
      bus.write16(0xa4060010 + i * 2, 0xff00);
    }
    bumpLayer(0,
        parameters: 0x00ff0000,
        tcw: 0xa000c000,
        tsp: copy | 0x4480,
        uvScale: 1.5 / 8);
    end();
    bumpLayer(2,
        parameters: 0x00ff0000,
        tcw: 0xa000c000,
        tsp: copy | 0x04006480,
        uvScale: 1.5 / 8);
    end();
    draw();
    expect(pixel(1, 1), 0xff808080);
  });

  test('each strip triangle uses the light vector of its own third vertex', () {
    init();
    lists.add(0);
    packet([0x8080000c, 0xe0000000, copy | 0x80, 0x2000c000]);
    for (final (i, xy)
        in [(0.0, 0.0), (32.0, 0.0), (0.0, 32.0), (32.0, 32.0)].indexed) {
      packet([
        i == 3 ? 0xf0000000 : 0xe0000000,
        bits(xy.$1),
        bits(xy.$2),
        bits(1),
        0,
        0,
        0xff000000,
        i == 3 ? 0xff000000 : 0x80000000
      ]);
    }
    end();
    draw();
    expect(pixel(1, 1), 0xff808080);
    expect(pixel(31, 31), 0xffffffff);
  });

  test('punch-through compares the generated bump alpha after shading', () {
    for (final (light, expected) in [
      (0x0000ff00, 0xffffffff),
      (0x0000ff80, 0xff000000)
    ]) {
      bus = DcBus();
      bus.write32(reg + 8, 0);
      init();
      bumpLayer(4, parameters: light, tsp: alpha);
      end();
      draw();
      expect(pixel(1, 1), expected);
    }
  });

  test(
      'a sprite uses the same ABC light parameters across both coverage triangles',
      () {
    init();
    lists.add(0);
    packet([
      0xa080000d,
      0xe0000000,
      copy | 0x80,
      0x2000c000,
      0xff000000,
      0x80000000
    ]);
    packet([
      0xf0000000,
      bits(0),
      bits(0),
      bits(1),
      bits(32),
      bits(0),
      bits(1),
      bits(32)
    ]);
    packet([bits(32), bits(1), bits(0), bits(32), 0, 0, 0, 0]);
    end();
    draw();
    expect(pixel(1, 1), 0xff808080);
    expect(pixel(31, 31), 0xff808080);
  });
}
