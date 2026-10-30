import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/gpu_modifier.dart';
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

  void intensity([int scale = 128]) => bus.write32(reg + 0x74, 0x100 | scale);

  test('shadow control defaults, masks and register width', () {
    expect(bus.read32(reg + 0x74), 0);
    bus.write32(reg + 0x74, 0xffffffff);
    expect(bus.read32(reg + 0x74), 0x1ff);
    expect(() => bus.write16(reg + 0x74, 0), throwsA(isA<DcUnsupported>()));
  });

  test('TA consumes two modifier bursts and stores an XYZ-only Triangle Array',
      () {
    init();
    modifier(1, 1, sq: true);
    end();
    expect(bus.gpu.vram.getUint32LE(object + 32), 0x80000000);
    expect(bus.gpu.vram.getUint32LE(0x200000), 0x20000000);
    expect(bus.gpu.vram.getUint32LE(0x200004), 0);
    expect(bus.gpu.vram.getUint32LE(0x200008), 0);
    expect(bus.gpu.vram.getUint32LE(0x200024), bits(0));
    expect(bus.read32(reg + 0x138), 0x200030);
    expect(bus.systemBus.normalStatus & 0x100, 0x100);
    expect(bus.systemBus.errorStatus, 0);
  });

  test('partial modifier packets neither allocate parameters nor finish a list',
      () {
    init();
    packet([0x81800040, 0x20000000]);
    packet([
      0xf0000000,
      bits(0),
      bits(0),
      bits(2),
      bits(32),
      bits(0),
      bits(2),
      bits(0)
    ]);
    expect(bus.read32(reg + 0x138), 0x200000);
    expect(bus.systemBus.normalStatus & 0x100, 0);
    bus.write32(reg + 8, 1);
    bus.write32(reg + 8, 0);
    expect(bus.read32(reg + 0x138), 0);
  });

  test(
      'modifier globals ignore color/texture fields and do not become long globals',
      () {
    init();
    packet([0x8180006f, 0x27ffffff, 0xffffffff, 0xffffffff]);
    packet([0xf0000000, 0, 0, bits(2), bits(32), 0, bits(2), 0]);
    packet([bits(32), bits(2), 0, 0, 0, 0, 0, 0]);
    end();
    expect(bus.gpu.vram.getUint32LE(0x200000), 0x20000000);
    expect(bus.systemBus.normalStatus & 0x100, 0x100);
  });

  test(
      'invalid modifier last flags and reserved shadow bits report parameter errors',
      () {
    for (final words in [
      [0x81800000, 0x20000000],
      [0x81800040, 0],
      [0x81800040, 0x60000000],
      [0x818000c0, 0x20000000]
    ]) {
      bus = DcBus();
      bus.write32(reg + 8, 0);
      init();
      expect(() => packet(words), throwsA(isA<DcUnsupported>()));
      expect(bus.systemBus.errorStatus & 16, 16);
    }
  });

  test('a front planar volume scales only shadow-enabled polygons', () {
    for (final shadow in [false, true]) {
      bus = DcBus();
      bus.write32(reg + 8, 0);
      init();
      intensity();
      layer(0, shadow: shadow, color: 0xffff8040, tsp: copy);
      end();
      modifier(1, 1);
      end();
      draw();
      expect(pixel(1, 1), shadow ? 0xff7f4020 : 0xffff8040);
    }
  });

  test('shadow factors use the documented denominator 256 rather than 255', () {
    for (final (scale, expected) in [
      (0, 0xff000000),
      (128, 0xff7f0000),
      (255, 0xfffe0000)
    ]) {
      bus = DcBus();
      bus.write32(reg + 8, 0);
      init();
      intensity(scale);
      layer(0, shadow: true, tsp: copy);
      end();
      modifier(1, 1);
      end();
      draw();
      expect(pixel(1, 1), expected);
    }
  });

  test('a volume behind the surface does not shade it', () {
    init();
    intensity();
    layer(0, shadow: true, tsp: copy);
    end();
    modifier(1, 1, depth: 0.5);
    end();
    draw();
    expect(pixel(1, 1), 0xffff0000);
  });

  test('a closed slab shades surfaces between its front and back faces', () {
    for (final (depth, expected) in [
      (0.25, 0xffff0000),
      (1.0, 0xff7f0000),
      (4.0, 0xffff0000)
    ]) {
      bus = DcBus();
      bus.write32(reg + 8, 0);
      init();
      intensity();
      layer(0, depth: depth, shadow: true, tsp: copy);
      end();
      modifier(1, 0, depth: 3);
      modifier(1, 1, depth: 0.5);
      end();
      draw();
      expect(pixel(1, 1), expected);
    }
  });

  test(
      'crossing two faces in one volume cancels rather than accumulating opacity',
      () {
    init();
    intensity();
    layer(0, shadow: true, tsp: copy);
    end();
    modifier(1, 0);
    modifier(1, 0);
    modifier(1, 1, depth: 0.5);
    end();
    draw();
    expect(pixel(1, 1), 0xffff0000);
  });

  test('separate inclusion volumes combine by union', () {
    init();
    intensity();
    layer(0, shadow: true, tsp: copy);
    end();
    modifier(1, 1, extent: 16);
    modifier(1, 1);
    end();
    draw();
    expect(pixel(1, 1), 0xff7f0000);
    expect(pixel(20, 1), 0xff7f0000);
  });

  test('Outside Last removes its interior from a prior inclusion area', () {
    init();
    intensity();
    layer(0, shadow: true, tsp: copy);
    end();
    modifier(1, 1);
    modifier(1, 2, extent: 16);
    end();
    draw();
    expect(pixel(1, 1), 0xffff0000);
    expect(pixel(20, 1), 0xff7f0000);
  });

  test(
      'modifier culling uses the same determinant convention as normal geometry',
      () {
    init();
    intensity();
    layer(0, shadow: true, tsp: copy);
    end();
    modifier(1, 1, cull: 3);
    end();
    draw();
    expect(pixel(1, 1), 0xffff0000);
  });

  test('opaque replay shades against the original destination exactly once',
      () {
    init();
    intensity();
    layer(0, shadow: true, color: 0x80ff0000, tsp: alpha);
    end();
    modifier(1, 1);
    end();
    draw();
    expect(pixel(1, 1), 0xcf200000);
  });

  test('failed modifier prepasses restore retained tile state before retry',
      () {
    init();
    intensity();
    layer(0, shadow: true, color: 0x80ff0000, tsp: alpha);
    end();
    final parameter = bus.read32(reg + 0x138);
    modifier(1, 0);
    end();
    prepare();
    put(0x9000, [
      0x10000000,
      0x80000000,
      0x80000000,
      0x80000000,
      0x80000000,
      0x80000000,
      0xc0000000,
      object,
      object + 32,
      0x80000000,
      0x80000000,
      0x80000000
    ]);
    bus.write32(reg + 0x14, 1);
    bus.tickMasterClocks(2);
    expect(() => bus.tickMasterClocks(2), throwsA(isA<DcUnsupported>()));
    expect(bus.systemBus.normalStatus & 7, 0);
    put(parameter, [0x20000000]);
    bus.tickMasterClocks(2);
    expect(pixel(1, 1), 0xcf200000);
    expect(bus.systemBus.normalStatus & 7, 7);
  });

  test('opaque modifiers also shade accepted punch-through pixels', () {
    init();
    intensity();
    layer(4, shadow: true, tsp: copy);
    end();
    modifier(1, 1);
    end();
    draw();
    expect(pixel(1, 1), 0xff7f0000);
  });

  test('opaque modifiers do not leak their area mask into translucent objects',
      () {
    init();
    intensity();
    layer(0, shadow: true, color: 0xff0000ff, tsp: copy);
    end();
    modifier(1, 1, depth: 3);
    end();
    layer(2, shadow: true, depth: 2, color: 0x8000ff00, tsp: alpha);
    end();
    draw();
    expect(pixel(1, 1), 0xbf00803f);
  });

  test(
      'translucent modifiers evaluate the depth of each sorted layer separately',
      () {
    init();
    intensity();
    layer(2, shadow: true, depth: 3, color: 0x800000ff, tsp: alpha);
    layer(2, shadow: true, depth: 1, color: 0x80ff0000, tsp: alpha);
    end();
    modifier(3, 1, depth: 2);
    end();
    draw();
    expect(pixel(1, 1), 0xa7100080);
  });

  test(
      'pre-sorted translucent modifiers stop because the manual requires auto-sort',
      () {
    init();
    intensity();
    layer(2, shadow: true);
    end();
    modifier(3, 1);
    end();
    expect(() => draw(presort: true), throwsA(isA<DcUnsupported>()));
    expect(bus.systemBus.normalStatus & 7, 0);
  });

  test(
      'secondary writes and flushes participate in opaque replay without duplicate blending',
      () {
    init();
    intensity();
    layer(0, shadow: true, tsp: copy | secondaryDestination);
    layer(0, tsp: copy | secondarySource);
    end();
    modifier(1, 1);
    end();
    draw();
    expect(pixel(1, 1), 0xff7f0000);
  });

  test('shadow pointers are stored independently of the vertex skip field', () {
    init();
    intensity();
    layer(0, shadow: true, tsp: copy);
    end();
    expect(bus.gpu.vram.getUint32LE(object) & 0x01e00000, 0x01200000);
    draw();
    expect(pixel(1, 1), 0xffff0000);
  });

  group('CPU-authored modifier geometry', () {
    late DcGpuModifier engine;
    setUp(() {
      engine = DcGpuModifier(
          readWord: bus.gpu.vram.getUint32LE, culled: (area, isp) => area == 0);
    });
    void record(int address, int instruction, double z, {bool quad = false}) {
      put(address, [
        instruction << 29,
        0x7fc00000,
        0xffffffff,
        bits(0),
        bits(0),
        bits(z),
        bits(32),
        bits(0),
        bits(z),
        bits(quad ? 32 : 0),
        bits(32),
        bits(z),
        if (quad) ...[bits(0), bits(32), 0x7fc00000]
      ]);
    }

    Uint8List evaluate() => engine.evaluate(
        0x100000, 0, 0, 0, Float64List(1024)..fillRange(0, 1024, 1), 0.5);

    test('counted triangle arrays advance by each XYZ record', () {
      record(0x200000, 0, 2);
      record(0x200030, 1, 0.5);
      put(0x100000, [0x82080000, 0xf0000000]);
      expect(evaluate()[33], 1);
    });

    test('quad D uses the ABC depth plane and shared edges toggle only once',
        () {
      record(0x200000, 1, 2, quad: true);
      put(0x100000, [0xa0080000, 0xf0000000]);
      expect(evaluate().where((value) => value == 1).length, 1024);
    });

    test('active masks exclude absent translucent fragments', () {
      record(0x200000, 1, 2);
      put(0x100000, [0x80080000, 0xf0000000]);
      final active = Uint8List(1024)..[33] = 1;
      final result = engine.evaluate(
          0x100000, 0, 0, 0, Float64List(1024)..fillRange(0, 1024, 1), 0.5,
          active: active);
      expect(result.where((value) => value == 1).length, 1);
    });
  });
}
