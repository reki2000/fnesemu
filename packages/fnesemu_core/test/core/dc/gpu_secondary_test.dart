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
      (0x128, 0x20000),
      (0x12c, 0x10ffe0),
      (0x130, 0x2fffc),
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
      double extent = 32}) {
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
        texture == null ? (colors?[i] ?? color) : bits(coordinate),
        bits(coordinate),
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

  test('secondary-only rendering leaves the primary framebuffer intact', () {
    init();
    layer(0, tsp: copy | secondaryDestination);
    end();
    draw();
    expect(pixel(1, 1), 0xff000000);
    expect(bus.systemBus.normalStatus & 7, 7);
  });

  test('flush copies stored RGBA and ignores its own base alpha and Use Alpha',
      () {
    init();
    layer(0, color: 0x80ff0000, tsp: copy | secondaryDestination | 0x100000);
    layer(0, color: 0x0000ff00, tsp: copy | secondarySource);
    end();
    draw();
    expect(pixel(1, 1), 0x80ff0000);
    expect(pixel(31, 31), 0xff000000);
  });

  test('multiple secondary draws accumulate all ARGB channels before a flush',
      () {
    init();
    layer(0, color: 0x40800000, tsp: copy | secondaryDestination | 0x100000);
    layer(0,
        color: 0x20004000,
        tsp: copy | 0x04000000 | secondaryDestination | 0x100000);
    layer(0, tsp: copy | secondarySource);
    end();
    draw();
    expect(pixel(1, 1), 0x60804000);
  });

  test('both selectors blend stored source and destination in place', () {
    init();
    layer(0, color: 0x80402010, tsp: copy | secondaryDestination | 0x100000);
    layer(0, tsp: 0x80800000 | secondarySource | secondaryDestination);
    layer(0, tsp: copy | secondarySource);
    end();
    draw();
    expect(pixel(1, 1), 0x40201008);
  });

  test('other-color and destination-alpha factors use the selected destination',
      () {
    init();
    layer(0, color: 0x80402010, tsp: copy | secondaryDestination | 0x100000);
    layer(0, color: 0xffffffff, tsp: 0x40800000 | secondaryDestination);
    layer(0, color: 0xffff0000, tsp: 0xc0800000 | secondaryDestination);
    layer(0, tsp: copy | secondarySource);
    end();
    draw();
    expect(pixel(1, 1), 0x80800000);
  });

  test('flush alpha controls blending with the primary background', () {
    init();
    layer(0, color: 0x80ff0000, tsp: copy | secondaryDestination | 0x100000);
    end();
    layer(2, color: 0xffffffff, tsp: alpha | secondarySource);
    end();
    draw(presort: true);
    expect(pixel(1, 1), 0xbf800000);
  });

  test('flush geometry crops the secondary pixels that are copied', () {
    init();
    layer(0, tsp: copy | secondaryDestination);
    layer(0, tsp: copy | secondarySource, extent: 16);
    end();
    draw();
    expect(pixel(1, 1), 0xffff0000);
    expect(pixel(20, 1), 0xff000000);
  });

  test(
      'secondary draws share depth testing and Z-write disable with primary draws',
      () {
    for (final disable in [false, true]) {
      bus = DcBus();
      bus.write32(reg + 8, 0);
      init();
      layer(0,
          depth: 3,
          tsp: copy | secondaryDestination,
          isp: 0xc0000000 | (disable ? 0x04000000 : 0));
      layer(0, depth: 2, color: 0xff0000ff, isp: 0xc0000000);
      end();
      draw();
      expect(pixel(1, 1), disable ? 0xff0000ff : 0xff000000);
    }
  });

  test('auto-sort resolves a secondary source after its farther writer', () {
    init();
    layer(2, depth: 2, tsp: alpha | secondarySource);
    layer(2,
        depth: 1,
        color: 0x80ff0000,
        tsp: copy | secondaryDestination | 0x100000);
    end();
    draw();
    expect(pixel(1, 1), 0xbf800000);
  });

  test('auto-sort applies each layer before selecting the next secondary value',
      () {
    init();
    layer(2, depth: 3, tsp: copy | secondarySource);
    layer(2,
        depth: 2,
        color: 0x4000ff00,
        tsp: copy | secondaryDestination | 0x100000);
    layer(2,
        depth: 1,
        color: 0x80ff0000,
        tsp: copy | secondaryDestination | 0x100000);
    end();
    draw();
    expect(pixel(1, 1), 0x4000ff00);
  });

  test('uninitialized secondary source stops without a completion interrupt',
      () {
    init();
    layer(0, tsp: copy | secondarySource);
    end();
    expect(() => draw(), throwsA(isA<DcUnsupported>()));
    expect(bus.systemBus.normalStatus & 7, 0);
    expect(bus.gpu.render.busy, isTrue);
  });

  test(
      'an uninitialized destination is allowed only for independent overwrites',
      () {
    for (final tsp in [copy | 0x04000000, 0x40800000, 0xc0800000]) {
      bus = DcBus();
      bus.write32(reg + 8, 0);
      init();
      layer(0, tsp: tsp | secondaryDestination);
      end();
      expect(() => draw(), throwsA(isA<DcUnsupported>()));
      expect(bus.systemBus.normalStatus & 7, 0);
    }
  });

  test(
      'a fresh tile cannot consume stale secondary pixels from the prior scene',
      () {
    init();
    layer(0, tsp: copy | secondaryDestination);
    end();
    draw();
    init();
    layer(0, tsp: copy | secondarySource);
    end();
    expect(() => draw(), throwsA(isA<DcUnsupported>()));
  });

  test('flush skips texture, UV, shading, fog and color clamp processing', () {
    init();
    layer(0, color: 0x80402010, tsp: copy | secondaryDestination | 0x100000);
    final parameter = bus.read32(reg + 0x138);
    layer(0,
        texture: 0x2000c000,
        colors: [0, 0, 0],
        tsp: 0x20e00000 | secondarySource);
    end();
    // CPU-authored CORE parameters need not contain usable shading data on a flush.
    for (var i = 0; i < 3; i++) {
      put(parameter + 12 + i * 24 + 12, [0x7fc00000, 0x7fc00000]);
    }
    bus.write32(reg + 0xc0, 0xffffffff);
    bus.write32(reg + 0xbc, 0);
    draw();
    expect(pixel(1, 1), 0x80402010);
  });

  test('presorted input does not defer an early flush until a later writer',
      () {
    init();
    layer(2, depth: 2, tsp: copy | secondarySource);
    layer(2, depth: 1, tsp: copy | secondaryDestination);
    end();
    expect(() => draw(presort: true), throwsA(isA<DcUnsupported>()));
  });

  test(
      'punch-through selects secondary alpha and stores opaque accepted pixels',
      () {
    init();
    layer(0, color: 0x80402010, tsp: copy | secondaryDestination | 0x100000);
    end();
    layer(4, depth: 2, tsp: alpha | secondarySource);
    end();
    draw(reference: 129);
    expect(pixel(1, 1), 0xff000000);
    draw(reference: 128);
    expect(pixel(1, 1), 0xff402010);
    bus = DcBus();
    bus.write32(reg + 8, 0);
    lists.clear();
    init();
    layer(4, color: 0x80402010, tsp: alpha | secondaryDestination);
    end();
    layer(2, depth: 2, tsp: copy | secondarySource);
    end();
    draw(reference: 128);
    expect(pixel(1, 1), 0xff402010);
  });
  test(
      'a textured secondary draw can be flushed without fetching another texture',
      () {
    init();
    bus.write16(0xa4060000, 0x001f);
    layer(0, texture: 0x0800c000, tsp: copy | secondaryDestination);
    layer(0, tsp: copy | secondarySource);
    end();
    draw();
    expect(pixel(1, 1), 0xff0000ff);
  });

  test('initialization validity is tracked for each covered secondary pixel',
      () {
    init();
    layer(0, tsp: copy | secondaryDestination, extent: 16);
    layer(0, tsp: copy | secondarySource);
    end();
    expect(() => draw(), throwsA(isA<DcUnsupported>()));
    expect(bus.systemBus.normalStatus & 7, 0);
  });

  test('retained consecutive regions preserve secondary color and validity',
      () {
    init();
    layer(0, color: 0x80402010, tsp: copy | secondaryDestination | 0x100000);
    end();
    layer(2, tsp: copy | secondarySource);
    end();
    prepare(type2: false, presort: true);
    put(0x9000, [
      0x10000000,
      object,
      0x80000000,
      0x80000000,
      0x80000000,
      0xc0000000,
      0x80000000,
      0x80000000,
      object + 32,
      0x80000000
    ]);
    bus.write32(reg + 0x14, 1);
    bus.tickMasterClocks(2);
    expect(pixel(1, 1), 0);
    expect(bus.gpu.render.busy, isTrue);
    bus.tickMasterClocks(2);
    expect(pixel(1, 1), 0x80402010);
    expect(bus.systemBus.normalStatus & 7, 7);
  });
}
