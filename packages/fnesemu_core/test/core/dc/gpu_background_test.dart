import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  const reg = 0xa05f8000, copy = 0x20800000;
  late DcBus bus;
  int bits(double value) {
    final bytes = ByteData(4)..setFloat32(0, value, Endian.little);
    return bytes.getUint32(0, Endian.little);
  }

  void put(int address, List<int> words) {
    for (final (i, word) in words.indexed) {
      bus.gpu.vram.setUint32LE(address + i * 4, word);
    }
  }

  void background(
      {bool textured = true,
      bool gouraud = false,
      bool uv16 = false,
      bool offset = false,
      int tsp = copy,
      int tcw = 0x0800c000,
      List<int> colors = const [0xffffffff, 0xffffffff, 0xffffffff],
      List<double> depths = const [1, 1, 1],
      int offsetColor = 0,
      int strip = 0,
      double depth = 0}) {
    final isp = (textured ? 0x02000000 : 0) |
        (gouraud ? 0x00800000 : 0) |
        (uv16 ? 0x00400000 : 0) |
        (offset ? 0x01000000 : 0);
    final skip =
        1 + (textured ? (uv16 ? 1 : 2) : 0) + (textured && offset ? 1 : 0);
    final words = <int>[isp, tsp, tcw, ...List.filled(strip * (skip + 3), 0)];
    for (var i = 0; i < 3; i++) {
      final x = i == 1 ? 32.0 : 0.0, y = i == 2 ? 32.0 : 0.0;
      words.addAll([bits(x), bits(y), bits(depths[i])]);
      if (textured) {
        if (uv16) {
          words.add((bits(x / 32) & 0xffff0000) | (bits(y / 32) >> 16));
        } else {
          words.addAll([bits(x / 32), bits(y / 32)]);
        }
      }
      words.add(colors[i]);
      if (textured && offset) words.add(offsetColor);
    }
    put(0x8000, words);
    bus.write32(reg + 0x8c, (skip << 24) | 0x10000 | strip);
    bus.write32(reg + 0x88, bits(depth));
  }

  void draw({int opaque = 0x80000000, int pack = 6}) {
    put(0x9000, [0x80000000, opaque, 0x80000000, 0x80000000, 0x80000000]);
    for (final (offset, value) in [
      (0x2c, 0x9000),
      (0x48, pack),
      (0x4c, 16),
      (0x60, 0x400000),
      (0x68, 31 << 16),
      (0x6c, 31 << 16)
    ]) {
      bus.write32(reg + offset, value);
    }
    bus.write32(reg + 0x14, 1);
    bus.tickMasterClocks(2);
  }

  int pixel(int x, int y) =>
      bus.gpu.vram.getUint32LE(0x400000 + (y * 32 + x) * 4);
  void foreground(double depth, {int tsp = copy}) {
    void packet(List<int> words) {
      final bytes = Uint8List(32);
      for (final (i, word) in words.indexed) {
        bytes.setUint32LE(i * 4, word);
      }
      bus.gpu.writePolygon(bytes);
    }

    for (final (offset, value) in [
      (0x124, 0x100000),
      (0x128, 0x20000),
      (0x12c, 0x10ffe0),
      (0x130, 0x2fffc),
      (0x140, 1),
      (0x164, 0x101000),
      (0x144, 0x80000000)
    ]) {
      bus.write32(reg + offset, value);
    }
    packet([0x80800000, 0xc0000000, tsp, 0]);
    for (final (i, xy) in [(0.0, 0.0), (32.0, 0.0), (0.0, 32.0)].indexed) {
      packet([
        i == 2 ? 0xf0000000 : 0xe0000000,
        bits(xy.$1),
        bits(xy.$2),
        bits(depth),
        0xffabcdef,
        0,
        0,
        0
      ]);
    }
    packet([0]);
  }

  setUp(() {
    bus = DcBus();
    bus.write32(reg + 8, 0);
    bus.write32(reg + 0x80, 0);
    for (var i = 0; i < 64; i++) {
      bus.write16(0xa4060000 + i * 2, [0xf800, 0x07e0, 0x001f, 0xffff][i & 3]);
    }
  });

  test('textured background uses all three vertices and covers the full tile',
      () {
    background();
    draw();
    expect(pixel(0, 0), 0xffff0000);
    expect(pixel(4, 0), 0xff0000ff);
    expect(pixel(0, 4), 0xff00ff00);
    expect(pixel(31, 31), 0xffffffff);
  });
  test('UV16 background data uses its shorter documented skip', () {
    background(uv16: true);
    draw();
    expect(pixel(4, 0), 0xff0000ff);
    expect(pixel(0, 4), 0xff00ff00);
  });
  test('tag strip offset selects the correct three background vertices', () {
    background(strip: 3);
    draw();
    expect(pixel(0, 0), 0xffff0000);
    expect(pixel(4, 0), 0xff0000ff);
  });
  test('Gouraud colors use vertex Z independently of zero background depth',
      () {
    background(
        textured: false,
        gouraud: true,
        colors: [0xffff0000, 0xff00ff00, 0xff0000ff]);
    draw();
    expect(pixel(8, 8), 0xff804040);
  });
  test('perspective Gouraud interpolation does not use the depth-test plane',
      () {
    background(
        textured: false,
        gouraud: true,
        depths: [1, 2, 4],
        depth: 7,
        colors: [0xffff0000, 0xff00ff00, 0xff0000ff]);
    draw();
    expect(pixel(8, 8), 0xff404080);
  });
  test(
      'background initializes color without ordinary source/destination blending',
      () {
    background(
        textured: false,
        gouraud: true,
        tsp: 0x00900000,
        colors: [0x80abcdef, 0x80abcdef, 0x80abcdef]);
    draw();
    expect(pixel(8, 8), 0x80abcdef);
    background(textured: false, colors: [0xff777777, 0xff777777, 0xff777777]);
    draw(pack: 1);
    expect(bus.gpu.vram.getUint16LE(0x400000), 0x73ae);
    expect(bus.gpu.vram.getUint16LE(0x400002), 0x73ae);
    draw(pack: 9);
    expect(bus.gpu.vram.getUint16LE(0x400000), 0x73ae);
    expect(bus.gpu.vram.getUint16LE(0x400002), 0x7bcf);
    foreground(1, tsp: copy | 0x02000000);
    background(
        textured: false,
        tsp: copy | 0x01000000,
        colors: [0xff123456, 0xff123456, 0xff123456]);
    draw(opaque: 0x100000);
    expect(pixel(1, 1), 0xff123456);
    expect(pixel(31, 31), 0);
    background(tsp: copy | 0x01000000);
    draw(opaque: 0x100000);
    expect(pixel(4, 0), 0xff0000ff);
  });
  test('offset color is decoded at its documented position after UV and base',
      () {
    background(offset: true, tsp: copy | 0x40, offsetColor: 0x000000ff);
    draw();
    expect(pixel(0, 0), 0xffff00ff);
  });
  test('background depth controls foreground occlusion instead of vertex depth',
      () {
    foreground(0.5);
    background(depth: 1, depths: [0.1, 0.1, 0.1]);
    draw(opaque: 0x100000);
    expect(pixel(0, 0), 0xffff0000);
    background(depth: 0, depths: [10, 10, 10]);
    draw(opaque: 0x100000);
    expect(pixel(0, 0), 0xffabcdef);
  });
  test('background supersampling uses the shared texture-origin and UV path',
      () {
    background(tsp: copy | 0x1000);
    // Each half pixel now spans one texel in both directions.
    bus.gpu.vram.setUint32LE(0x8000 + (3 + 6 + 3) * 4, bits(8));
    bus.gpu.vram.setUint32LE(0x8000 + (3 + 12 + 4) * 4, bits(8));
    draw();
    expect(pixel(0, 0), 0xff808080);
  });
  test(
      'background MIP selection uses vertex UV/Z rather than the constant depth plane',
      () {
    for (var i = 0; i < 64; i++) {
      bus.write16(0xa4060030 + i * 2, 0xf800);
    }
    for (var i = 0; i < 16; i++) {
      bus.write16(0xa4060010 + i * 2, 0x7e0);
    }
    for (var i = 0; i < 4; i++) {
      bus.write16(0xa4060008 + i * 2, 0x1f);
    }
    bus.write16(0xa4060006, 0xffff);
    background(tcw: 0x8800c000, tsp: copy | 0x400, depth: 0);
    bus.gpu.vram.setUint32LE(0x8000 + 12 * 4, bits(16));
    bus.gpu.vram.setUint32LE(0x8000 + 19 * 4, bits(16));
    draw();
    expect(pixel(0, 0), 0xff0000ff);
    expect(pixel(31, 31), 0xff0000ff);
    // A footprint of 1.5 splits the two MIP passes equally.
    for (final (mode, expected) in [(2, 0x80800000), (3, 0x80008000)]) {
      background(tcw: 0x8800c000, tsp: copy | 0x400 | (mode << 13));
      bus.gpu.vram.setUint32LE(0x8000 + 12 * 4, bits(6));
      bus.gpu.vram.setUint32LE(0x8000 + 19 * 4, bits(6));
      draw();
      expect(pixel(0, 0), expected);
      expect(pixel(31, 31), expected);
    }
  });

  test('invalid skip and degenerate shading planes retain explicit stops', () {
    background();
    bus.write32(reg + 0x8c, 0x01010000);
    expect(draw, throwsA(isA<DcUnsupported>()));
    bus.gpu.reset();
    background(gouraud: true, textured: false);
    bus.gpu.vram.setUint32LE(0x8000 + 7 * 4, 0);
    bus.gpu.vram.setUint32LE(0x8000 + 12 * 4, 0);
    expect(draw, throwsA(isA<DcUnsupported>()));
  });
}
