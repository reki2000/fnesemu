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

  test('scale bits have no intensity effect in parameter-selection mode', () {
    init();
    bus.write32(reg + 0x74, 128);
    global(0);
    triangle();
    end();
    volume();
    draw();
    expect(pixel(1, 1), 0xff00ff00);
  });

  test('each material selects its own texture control word', () {
    init();
    bus.write16(0xa4060000, 0xf800);
    bus.write16(0xa4070000, 0x001f);
    global(0, textured: true);
    triangle();
    end();
    volume();
    draw();
    expect(pixel(1, 1), 0xff0000ff);
    expect(pixel(20, 1), 0xffff0000);
  });

  test('32-bit and upper-half UV pairs are independent for each material', () {
    for (final uv16 in [false, true]) {
      bus = DcBus();
      bus.write32(reg + 8, 0);
      init();
      bus.write16(0xa4060000, 0xf800);
      bus.write16(0xa4060004, 0x07e0);
      global(0, textured: true, uv16: uv16, tcw1: 0x0800c000);
      triangle(u1: 1 / 8);
      end();
      volume();
      draw();
      expect(pixel(1, 1), 0xff00ff00);
      expect(pixel(20, 1), 0xffff0000);
    }
  });

  test('textured vertices stage both bursts before emitting a partition', () {
    init();
    global(0, textured: true);
    vertex(0, 0);
    vertex(32, 0);
    packet([0xf0000000, bits(0), bits(32), bits(1), 0, 0, 0xffff0000, 0]);
    expect(bus.read32(reg + 0x138), 0x200000);
    packet([0, 0, 0xff00ff00, 0, 0, 0, 0, 0]);
    expect(bus.read32(reg + 0x138), 0x200080);
  });

  test('both offset colors participate in their own shading calculation', () {
    init();
    bus.write16(0xa4060000, 0);
    bus.write16(0xa4070000, 0);
    global(0, textured: true, offset: true);
    triangle(offset0: 0x00102030, offset1: 0x00405060);
    end();
    volume();
    draw();
    expect(pixel(1, 1), 0xff405060);
    expect(pixel(20, 1), 0xff102030);
    expect(bus.gpu.vram.getUint32LE(object) & 0x00e00000, 4 << 21);
  });

  test('non-textured inputs ignore Offset and store the fixed-zero ISP flag',
      () {
    init();
    global(0, offset: true);
    triangle();
    end();
    volume();
    draw();
    expect(bus.gpu.vram.getUint32LE(0x200000) & 0x01000000, 0);
    expect(pixel(1, 1), 0xff00ff00);
  });

  test('each material derives MIP gradients from its own UV set', () {
    init();
    for (final (offset, count, color) in [
      (0x30, 64, 0xf800),
      (0x10, 16, 0x07e0),
      (8, 4, 0x001f),
      (6, 1, 0xffff)
    ]) {
      for (var i = 0; i < count; i++) {
        bus.write16(0xa4060000 + offset + i * 2, color);
      }
    }
    global(0,
        textured: true,
        tcw0: 0x8800c000,
        tcw1: 0x8800c000,
        tsp0: copy | 0x400,
        tsp1: copy | 0x400);
    for (final (i, xy) in [(0.0, 0.0), (32.0, 0.0), (0.0, 32.0)].indexed) {
      vertex(xy.$1, xy.$2, end: i == 2, u1: xy.$1 / 2, v1: xy.$2 / 2);
    }
    end();
    volume();
    draw();
    expect(pixel(1, 1), 0xff0000ff);
    expect(pixel(20, 1), 0xffff0000);
  });

  test(
      'a failed second material does not leave area filtering active after retry',
      () {
    init();
    bus.write16(0xa4060000, 0xf800);
    bus.write16(0xa4070000, 0x07e0);
    global(0, textured: true, tcw1: 0x2000c000);
    triangle();
    layer(0, color: 0xff0000ff, tsp: copy);
    end();
    volume();
    expect(() => draw(), throwsA(isA<DcUnsupported>()));
    expect(bus.systemBus.normalStatus & 7, 0);
    put(0x200010, [0x0800e000]);
    bus.tickMasterClocks(2);
    expect(pixel(1, 1), 0xff0000ff);
    expect(pixel(20, 1), 0xff0000ff);
    expect(bus.systemBus.normalStatus & 7, 7);
  });

  test('TSP blending and alpha settings switch with the selected material', () {
    init();
    global(0, tsp0: alpha, tsp1: alpha);
    triangle(color0: 0x80ff0000, color1: 0x400000ff);
    end();
    volume();
    draw();
    expect(pixel(1, 1), 0xcf000040);
    expect(pixel(20, 1), 0xbf800000);
  });

  test('fog mode is selected independently for the two TSP words', () {
    init();
    global(0, tsp1: 0x20000000);
    triangle();
    end();
    volume();
    bus.write32(reg + 0xb0, 0x0000ff);
    bus.write32(reg + 0x200, 0xffff);
    draw();
    expect(pixel(1, 1), 0xff0000ff);
    expect(pixel(20, 1), 0xffff0000);
  });

  test('Intensity A supplies separate face colors and alpha values', () {
    init();
    global(0, colorType: 2, face1: [0.5, 0, 1, 0]);
    triangle(intensity0: 0.5, intensity1: 0.25);
    end();
    volume();
    draw();
    expect(bus.gpu.vram.getUint32LE(0x200020), 0xff7f0000);
    expect(bus.gpu.vram.getUint32LE(0x200024), 0x7f003f00);
    expect(pixel(1, 1), 0xff003f00);
    expect(pixel(20, 1), 0xff7f0000);
  });

  test('Intensity B reuses both preceding face-color sets', () {
    init();
    global(0, colorType: 2);
    triangle();
    global(0, colorType: 3);
    triangle(intensity0: 0.25, intensity1: 0.5);
    end();
    volume();
    draw();
    expect(pixel(1, 1), 0xff007f00);
    expect(pixel(20, 1), 0xff3f0000);
  });

  test('textured intensity expands both base and offset colors from each face',
      () {
    init();
    bus.write16(0xa4060000, 0);
    bus.write16(0xa4070000, 0);
    global(0, colorType: 2, textured: true, offset: true);
    triangle();
    end();
    volume();
    draw();
    expect(pixel(1, 1), 0xff00ff00);
    expect(pixel(20, 1), 0xffff0000);
  });

  test('Intensity A stages a long global even without textures or offsets', () {
    init();
    packet([0x808000e0, 0xe0000000, copy, 0, copy, 0, 0, 0]);
    expect(() => bus.write32(reg + 0x144, 0x80000000),
        throwsA(isA<DcUnsupported>()));
    expect(bus.read32(reg + 0x138), 0x200000);
  });

  test(
      'reserved floating, missing Shadow and sprite combinations report errors',
      () {
    for (final pcw in [0x808000d0, 0x80800040, 0xa08000c0]) {
      bus = DcBus();
      bus.write32(reg + 8, 0);
      init();
      expect(() => packet([pcw, 0xe0000000, copy, 0, copy]),
          throwsA(isA<DcUnsupported>()));
      expect(bus.systemBus.errorStatus & 16, 16);
    }
  });

  test('Intensity B requires both face-color sets', () {
    init();
    expect(() => global(0, colorType: 3), throwsA(isA<DcUnsupported>()));
    expect(bus.systemBus.errorStatus & 16, 16);
  });

  test('Gouraud interpolation uses the selected material colors', () {
    init();
    global(0, gouraud: true);
    vertex(0, 0, color0: 0xff000000, color1: 0xff000000);
    vertex(32, 0, color0: 0xffff0000, color1: 0xff00ff00);
    vertex(0, 32, end: true, color0: 0xff000000, color1: 0xff000000);
    end();
    volume();
    draw();
    expect(pixel(1, 1), 0xff000c00);
    expect(pixel(20, 1), 0xffa30000);
  });

  test(
      'auto-sorted translucent modifiers select each layer material at its depth',
      () {
    init();
    global(2, tsp0: alpha, tsp1: alpha);
    triangle(z: 1, color0: 0x80ff0000, color1: 0x8000ff00);
    global(2, tsp0: alpha, tsp1: alpha);
    triangle(z: 3, color0: 0x800000ff, color1: 0x80ffff00);
    end();
    volume(3);
    draw();
    expect(pixel(1, 1), 0x9f004080);
    expect(pixel(20, 1), 0x9f400080);
  });

  test('valid punch-through parameters preserve alpha while changing RGB', () {
    init();
    global(4);
    triangle();
    end();
    volume();
    draw();
    expect(pixel(1, 1), 0xff00ff00);
    expect(pixel(20, 1), 0xffff0000);
  });

  test('a selected secondary source ignores that material shader data', () {
    init();
    layer(0, color: 0xff0000ff, tsp: copy | secondaryDestination);
    global(0, tsp1: copy | secondarySource);
    triangle();
    end();
    volume();
    draw();
    expect(pixel(1, 1), 0xff0000ff);
    expect(pixel(20, 1), 0xffff0000);
  });

  test('one-triangle strip partitions retain both attribute sets and winding',
      () {
    init();
    global(0);
    vertex(0, 0);
    vertex(32, 0);
    vertex(0, 32);
    vertex(32, 32, end: true);
    end();
    volume(1, 64);
    draw();
    expect(bus.read32(reg + 0x138), 0x2000d0);
    expect(pixel(1, 1), 0xff00ff00);
    expect(pixel(31, 31), 0xff00ff00);
  });

  test(
      'counted triangle arrays advance over five-word headers and doubled attributes',
      () {
    init();
    global(0);
    triangle();
    global(0);
    triangle(color0: 0xff0000ff, color1: 0xffffff00);
    end();
    volume();
    put(object, [0x83200000, 0xf0000000]);
    draw();
    expect(pixel(1, 1), 0xffffff00);
    expect(pixel(20, 1), 0xff0000ff);
  });

  test('quad D shading is ignored for both material planes', () {
    init();
    global(0);
    triangle();
    end();
    volume(1, 64);
    put(0x210000, [
      0xe0000000,
      copy,
      0,
      copy,
      0,
      for (final xy in [(0.0, 0.0), (32.0, 0.0), (32.0, 32.0)]) ...[
        bits(xy.$1),
        bits(xy.$2),
        bits(1),
        0xffff0000,
        0xff00ff00
      ],
      bits(0),
      bits(32),
      0x7fc00000,
      0x7fc00000,
      0x7fc00000
    ]);
    put(object, [0xa1204000, 0xf0000000]);
    draw();
    expect(pixel(1, 1), 0xff00ff00);
    expect(pixel(31, 31), 0xff00ff00);
  });

  test(
      'parameter allocation includes both header pairs and both attribute sets',
      () {
    init();
    bus.write32(reg + 0x130, 0x200048);
    global(0);
    expect(() => triangle(), throwsA(isA<DcUnsupported>()));
    expect(bus.systemBus.errorStatus & 4, 4);
    expect(bus.systemBus.normalStatus & 0x80, 0);
  });
}
