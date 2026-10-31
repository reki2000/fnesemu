import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
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
      double coordinate = 0}) {
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
    for (final (i, xy) in [(0.0, 0.0), (32.0, 0.0), (0.0, 32.0)].indexed) {
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
      0x80000000,
      lists.contains(2) ? object + 32 : 0x80000000,
      0x80000000,
      if (type2) lists.contains(4) ? object + 64 : 0x80000000
    ]);
    for (final item in [
      (0x20, 0x200000),
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

  test(
      'punch-through selects the nearest alpha-accepted layer and bypasses blending',
      () {
    init();
    layer(4, color: 0x80ff0000, depth: 3, isp: 0, tsp: 0x00900000);
    layer(4, color: 0xff00ff00, depth: 1, isp: 0, tsp: 0x00900000);
    end();
    draw();
    expect(pixel(1, 1), 0xff00ff00);
    expect(bus.systemBus.normalStatus & 0x200007, 0x200007);
  });

  test('punch-through reference is inclusive and output alpha is forced opaque',
      () {
    init();
    layer(4, color: 0x80ff0000, depth: 1);
    layer(4, color: 0x7f00ff00, depth: 2);
    end();
    draw(reference: 128);
    expect(pixel(1, 1), 0xffff0000);
  });

  test('equal-depth punch-through gives later input priority', () {
    init();
    layer(4, color: 0xffff0000);
    layer(4, color: 0xff0000ff);
    end();
    draw();
    expect(pixel(1, 1), 0xff0000ff);
  });

  test('rejected punch-through pixels do not write depth or hide translucency',
      () {
    init();
    layer(4, color: 0x00ff0000, depth: 3);
    end();
    layer(2, color: 0xff00ff00, depth: 1);
    end();
    draw();
    expect(pixel(1, 1), 0xff00ff00);
  });

  test(
      'opaque, punch-through and translucent results are processed in dependency order',
      () {
    init();
    layer(2, color: 0x800000ff, depth: 3, tsp: alpha);
    end();
    layer(0, color: 0xff00ff00, depth: 0.5);
    end();
    layer(4, color: 0xffff0000, depth: 2);
    end();
    draw();
    expect(pixel(1, 1), 0xbf7f0080);
  });

  test(
      'punch-through honors Z-write disable independently of its fixed compare',
      () {
    init();
    layer(0, color: 0xff00ff00, depth: 1);
    end();
    layer(4, color: 0xffff0000, depth: 3, isp: 0x04000000);
    end();
    layer(2, color: 0xff0000ff, depth: 2);
    end();
    draw();
    expect(pixel(1, 1), 0xff0000ff);
  });

  test(
      'punch-through alpha comparison follows texture shading rather than raw texel alpha',
      () {
    init();
    bus.write16(0xa4060000, 0x7c00); // Transparent red ARGB1555.
    layer(4,
        color: 0xff00ff00,
        texture: 0x0000c000,
        tsp: copy | 0x100000 | (2 << 6));
    end();
    draw(); // Decal Alpha retains the opaque green polygon alpha/color.
    expect(pixel(1, 1), 0xff00ff00);
  });

  test('punch-through thresholds the bilinear alpha before depth commitment',
      () {
    init();
    for (final (i, value) in [0xfc00, 0x83e0, 0x801f, 0x7fff].indexed) {
      bus.write16(0xa4060000 + i * 2, value);
    }
    layer(4,
        texture: 0x0000c000, tsp: copy | 0x100000 | 0x2000, coordinate: 1 / 16);
    end();
    draw();
    expect(pixel(1, 1), 0xff000000);
    draw(reference: 191);
    expect(pixel(1, 1), 0xff808080);
  });

  test(
      'auto-sort handles intersecting planes per pixel regardless of submission order',
      () {
    init();
    layer(2, color: 0x80ff0000, depths: [1, 3, 1], tsp: alpha);
    layer(2, color: 0x800000ff, depth: 2, tsp: alpha);
    end();
    draw();
    expect(pixel(2, 1), 0x9f400080); // Red is farther here.
    expect(pixel(26, 1), 0x9f800040); // Red is nearer here.
  });

  test(
      'auto-sort uses greater-or-equal and preserves input priority at equal depth',
      () {
    init();
    layer(2, color: 0x80ff0000, isp: 0, tsp: alpha);
    layer(2, color: 0x800000ff, isp: 0, tsp: alpha);
    end();
    draw();
    expect(pixel(1, 1), 0x9f400080);
  });

  test('pre-sort follows input order while type-2 headers override global mode',
      () {
    for (final type2 in [false, true]) {
      for (final presort in [false, true]) {
        bus = DcBus();
        bus.write32(reg + 8, 0);
        lists.clear();
        init();
        layer(2, color: 0x80ff0000, depths: [1, 3, 1], tsp: alpha);
        layer(2, color: 0x800000ff, depth: 2, tsp: alpha);
        end();
        draw(
            type2: type2,
            presort: presort,
            globalPresort: type2 ? !presort : presort);
        expect(pixel(26, 1), presort ? 0x9f400080 : 0x9f800040);
      }
    }
  });

  test('opaque depth rejects hidden auto-sorted fragments', () {
    init();
    layer(0, color: 0xff0000ff, depth: 2);
    end();
    layer(2, color: 0x80ff0000, depth: 1, tsp: alpha);
    layer(2, color: 0x8000ff00, depth: 3, tsp: alpha);
    end();
    draw();
    expect(pixel(1, 1), 0xbf00807f);
  });

  test('Gouraud colors and alpha are perspective-correct across varying depth',
      () {
    init();
    layer(0, depths: [1, 0.5, 1], colors: [0xffff0000, 0xff00ff00, 0xff0000ff]);
    end();
    draw();
    expect(pixel(8, 0), 0xffd32705);
    bus = DcBus();
    bus.write32(reg + 8, 0);
    lists.clear();
    init();
    layer(4, depths: [1, 0.5, 1], colors: [0x00ffffff, 0xffffffff, 0x00ffffff]);
    end();
    draw(reference: 64);
    expect(pixel(8, 0), 0xff000000); // Correct alpha is 39, not affine 68.
  });

  test(
      'auto-sort peels equal-depth layers across an additional object-pointer block',
      () {
    init();
    for (var i = 0; i < 10; i++) {
      layer(2, color: 0xff000000 | i, isp: 0);
    }
    end();
    draw();
    expect(bus.gpu.vram.getUint32LE(object + 60) & 0xf0000000, 0xe0000000);
    expect(pixel(1, 1), 0xff000009);
    expect(bus.systemBus.normalStatus & 7, 7);
  });

  test('auto-sort list faults produce no false completion and reset recovers',
      () {
    init();
    layer(2);
    end();
    prepare();
    put(object + 36, [0xe0000000 | (object + 32)]);
    bus.write32(reg + 0x14, 1);
    expect(() => bus.tickMasterClocks(2), throwsA(isA<DcUnsupported>()));
    expect(bus.systemBus.normalStatus & 7, 0);
    expect(bus.gpu.render.clocksToEvent, greaterThan(0));
    put(object + 36, [0xf0000000]);
    bus.write32(reg + 8, 2);
    bus.write32(reg + 8, 0);
    draw();
    expect(pixel(1, 1), 0xffff0000);
    expect(bus.systemBus.normalStatus & 7, 7);
  });

  test('auto-sort keeps Z-write disable behavior across retained regions', () {
    for (final probe in [1.5, 2.5]) {
      bus = DcBus();
      bus.write32(reg + 8, 0);
      lists.clear();
      init();
      layer(0, color: 0xffffff00, depth: probe, isp: 0x80000000);
      end();
      layer(2, color: 0x80ff0000, depth: 2, tsp: alpha);
      layer(2, color: 0x8000ff00, depth: 3, tsp: alpha, isp: 0xe4000000);
      end();
      prepare(type2: false);
      put(0x9000, [
        0x10000000,
        0x80000000,
        0x80000000,
        object + 32,
        0x80000000,
        0xc0000000,
        object,
        0x80000000,
        0x80000000,
        0x80000000
      ]);
      bus.write32(reg + 0x14, 1);
      bus.tickMasterClocks(4);
      expect(pixel(1, 1), probe == 1.5 ? 0x9f408000 : 0xffffff00);
    }
  });
}
