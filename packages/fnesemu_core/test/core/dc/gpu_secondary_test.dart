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
      (0x20, 0x20000),
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
    put(0x20000 + 0x8000, [
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














}
