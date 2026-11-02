import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  const reg = 0xa05f8000,
      object = 0x100000,
      parameter = 0x200000,
      copy = 0x20800000;
  late DcBus bus;
  setUp(() {
    bus = DcBus();
    bus.write32(reg + 8, 0);
  });
  int bits(double value) {
    final data = ByteData(4)..setFloat32(0, value, Endian.little);
    return data.getUint32(0, Endian.little);
  }

  int uv(double u, double v) => (bits(u) & 0xffff0000) | (bits(v) >> 16);
  void packet(List<int> words, {bool sq = false}) {
    final bytes = Uint8List(32);
    for (final (i, value) in words.indexed) {
      bytes.setUint32LE(i * 4, value);
    }
    if (!sq) {
      bus.gpu.writePolygon(bytes);
      return;
    }
    bus.write32(0xff000038, 0x10);
    for (var i = 0; i < 32; i += 4) {
      bus.write32(0xe0000000 + i, bytes.getUint32LE(i));
    }
    bus.transferStoreQueue(0xe0000000);
  }

  void init({int clip = 0}) {
    for (final item in [
      (0x124, object),
      (0x128, parameter),
      (0x20, parameter),
      (0x12c, object + 0xffe0),
      (0x130, parameter + 0xfffc),
      (0x13c, clip),
      (0x140, 1),
      (0x164, object + 0x1000),
      (0x144, 0x80000000)
    ]) {
      bus.write32(reg + item.$1, item.$2);
    }
  }

  void header(
          {int pcw = 0xa0800000,
          int isp = 0xe0000000,
          int tsp = copy,
          int texture = 0,
          int color = 0xffff0000,
          int offset = 0}) =>
      packet([pcw, isp, tsp, texture, color, offset]);
  List<int> vertexWords(
          {List<double>? coordinates, List<int>? texcoords, bool end = true}) =>
      [
        end ? 0xf0000000 : 0xe0000000,
        for (final value
            in coordinates ?? <double>[0, 0, 1, 32, 0, 1, 32, 32, 1, 0, 32])
          bits(value),
        0,
        ...(texcoords ?? [0, 0, 0])
      ];
  void quad(
      {List<double>? coordinates,
      List<int>? texcoords,
      bool end = true,
      bool sq = false}) {
    final words =
        vertexWords(coordinates: coordinates, texcoords: texcoords, end: end);
    packet(words.sublist(0, 8), sq: sq);
    packet(words.sublist(8), sq: sq);
  }

  void put(int address, List<int> words) {
    for (final (i, value) in words.indexed) {
      bus.gpu.vram.setUint32LE(address + 4 * i, value);
    }
  }

  int word(int address) => bus.gpu.vram.getUint32LE(address);
  int pixel(int x, int y) => word(0x400000 + (y * 32 + x) * 4);
  void render() {
    put(parameter + 0x8000, [
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
    put(0x9000, [0x80000000, object, 0x80000000, 0x80000000, 0x80000000]);
    for (final item in [
      (0x2c, 0x9000),
      (0x48, 6),
      (0x4c, 16),
      (0x60, 0x400000),
      (0x68, 31 << 16),
      (0x6c, 31 << 16),
      (0x8c, 0x1000000 | (0x8000 * 2)),
      (0x14, 1)
    ]) {
      bus.write32(reg + item.$1, item.$2);
    }
    bus.tickMasterClocks(2);
  }

  void objectSet(int pointer) {
    packet([0x40000000, pointer, 0, 0, 0, 0, 0, 0]);
    packet([0]);
  }

  test('TA sprite input spans two bursts and emits a flat Quad Array record',
      () {
    init();
    header();
    final words = vertexWords();
    packet(words.sublist(0, 8), sq: true);
    expect(bus.read32(reg + 0x138), parameter);
    packet(words.sublist(8), sq: true);
    packet([0]);
    expect(word(object), 0xa0000000 | (1 << 21));
    expect(word(object + 4), 0xf0000000);
    expect(bus.read32(reg + 0x138), parameter + 76);
    expect(word(parameter + 24), 0xffff0000);
    expect(word(parameter + 60), bits(0));
    expect(word(parameter + 64), bits(32));
    expect(bus.systemBus.normalStatus & 0x80, 0x80);
  });

  test(
      'flat sprites cover the whole quad and keep the third color across the diagonal',
      () {
    init();
    header();
    quad();
    packet([0]);
    render();
    for (final xy in [(0, 0), (31, 0), (0, 31), (31, 31), (15, 15)]) {
      expect(pixel(xy.$1, xy.$2), 0xffff0000);
    }
  });

  test('sprite texture UV for D is evaluated from the ABC surface plane', () {
    init();
    header(pcw: 0xa0800009, texture: 0x0800c000);
    bus.write16(0xa4060000, 0xf800); // U=0,V=0.
    bus.write16(0xa406002a, 0x001f); // U=0,V=7 in Morton order.
    bus.write16(0xa406007e, 0xffff); // U=7,V=7.
    quad(texcoords: [uv(0, 0), uv(1, 0), uv(1, 1)]);
    packet([0]);
    expect(bus.read32(reg + 0x138), parameter + 92);
    expect((word(object) >> 21) & 7, 2);
    // D's Z/UV/color storage is undefined and must not be loaded as valid attributes.
    put(parameter + 80, [0x7fc00000, 0x7fc07fc0, 0x01020304]);
    render();
    expect(pixel(0, 0), 0xffff0000);
    expect(pixel(0, 31), 0xff0000ff);
    expect(pixel(31, 31), 0xffffffff);
  });

  test(
      'sprite offset colors remain flat and are added after texture modulation',
      () {
    init();
    header(
        pcw: 0xa080000d,
        texture: 0x0800c000,
        tsp: copy | (1 << 6),
        color: 0xff808080,
        offset: 0x00010203);
    bus.write16(0xa4060000, 0xffff);
    quad();
    packet([0]);
    render();
    expect(bus.read32(reg + 0x138), parameter + 108);
    expect(pixel(0, 31), 0xff818283);
  });

  test('quad depth follows the first-three-vertex plane in both raster halves',
      () {
    init();
    header(isp: 0x80000000);
    quad(coordinates: [0, 0, 1, 32, 0, 1, 32, 32, 2, 0, 32]);
    header(isp: 0x80000000, color: 0xff0000ff);
    quad(coordinates: [0, 0, 1.5, 32, 0, 1.5, 32, 32, 1.5, 0, 32]);
    packet([0]);
    render();
    expect(pixel(1, 1), 0xff0000ff);
    expect(pixel(1, 30), 0xffff0000);
  });

  test(
      'CPU Gouraud quads ignore D depth/color fields and extrapolate ABC shading',
      () {
    init();
    put(parameter, [
      0xe0800000,
      copy,
      0,
      bits(0),
      bits(0),
      bits(1),
      0xff000000,
      bits(32),
      bits(0),
      bits(1),
      0xff800000,
      bits(32),
      bits(32),
      bits(1),
      0xff808000,
      bits(0),
      bits(32),
      0x7fc00000,
      0xff0000ff
    ]);
    objectSet(0xa0000000 | (1 << 21));
    render();
    expect(pixel(1, 30), 0xff067a00);
  });

  test(
      'quad binning includes D and applies user tile clipping to the whole box',
      () {
    for (final clip in [false, true]) {
      bus = DcBus();
      bus.write32(reg + 8, 0);
      init(clip: 1);
      packet([0x20000000, 0, 0, 0, 1, 0, 1, 0]);
      header(pcw: clip ? 0xa0820000 : 0xa0800000);
      quad(coordinates: [32, 0, 1, 64, 0, 1, 64, 32, 1, 0, 32]);
      packet([0]);
      expect(word(object), clip ? 0xf0000000 : 0xa0200000);
      expect(word(object + 32), 0xa0200000);
    }
  });

  test('quad and triangle arrays advance over complete contiguous ISP records',
      () {
    for (final quads in [false, true]) {
      bus = DcBus();
      bus.write32(reg + 8, 0);
      init();
      final records = <int>[];
      for (final item in [(0xffff0000, 0.0, 16.0), (0xff00ff00, 16.0, 32.0)]) {
        records.addAll([
          0xe0000000,
          copy,
          0,
          bits(item.$2),
          bits(0),
          bits(1),
          item.$1,
          bits(item.$3),
          bits(0),
          bits(1),
          item.$1,
          bits(item.$3),
          bits(32),
          bits(1),
          item.$1
        ]);
        if (quads) records.addAll([bits(item.$2), bits(32), 0x7fc00000, 0]);
      }
      put(parameter, records);
      objectSet((quads ? 0xa2000000 : 0x82000000) | (1 << 21));
      render();
      expect(pixel(12, 1), 0xffff0000);
      expect(pixel(28, 1), 0xff00ff00);
      if (quads) {
        expect(pixel(1, 30), 0xffff0000);
        expect(pixel(17, 30), 0xff00ff00);
      }
    }
  });

  test('half-alpha quads draw their shared diagonal exactly once', () {
    init();
    header(tsp: 0x94900000, color: 0x80ff0000);
    quad();
    packet([0]);
    render();
    for (var i = 0; i < 32; i++) {
      expect(pixel(i, i), 0xbf800000);
    }
    expect(pixel(1, 30), 0xbf800000);
  });

  test('quad size culling is evaluated once from its defining ABC plane', () {
    init();
    header(isp: 0xe8000000);
    bus.write32(reg + 0x78, bits(512));
    quad(coordinates: [0, 0, 1, 32, 0, 1, 32, 32, 1, 0, 8]);
    packet([0]);
    render();
    // ABC has determinant 1024 while ACD has 256; a separate triangle cull would lose this pixel.
    expect(pixel(0, 3), 0xffff0000);
  });

  test('a polygon global restores triangle parsing after a complete sprite',
      () {
    init();
    header();
    quad();
    packet([0x80800000, 0xe0000000, copy]);
    for (final (i, xy) in [(0.0, 0.0), (32.0, 0.0), (0.0, 32.0)].indexed) {
      packet([
        i == 2 ? 0xf0000000 : 0xe0000000,
        bits(xy.$1),
        bits(xy.$2),
        bits(1),
        0,
        0,
        0xff00ff00
      ]);
    }
    packet([0]);
    expect(bus.read32(reg + 0x138), parameter + 136);
    expect(word(object + 4), 0x40000000 | (1 << 21) | (76 >> 2));
  });

  test(
      'prohibited sprite formats and missing End Of Strip signal the parameter error',
      () {
    for (final pcw in [0xa0800002, 0xa0800010, 0xa0800008]) {
      bus = DcBus();
      bus.write32(reg + 8, 0);
      init();
      expect(() => header(pcw: pcw), throwsA(isA<DcUnsupported>()));
      expect(bus.systemBus.errorStatus & 16, 16);
    }
    bus = DcBus();
    bus.write32(reg + 8, 0);
    init();
    header();
    expect(() => quad(end: false), throwsA(isA<DcUnsupported>()));
    expect(bus.systemBus.normalStatus & 0x80, 0);
    expect(bus.systemBus.errorStatus & 16, 16);
  });
}
