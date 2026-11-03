import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/gpu_palette.dart';
import 'package:fnesemu_core/src/core/dc/gpu_texture.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  const reg = 0xa05f8000, object = 0x100000, parameter = 0x200000;
  const copy = 0x20800000;
  late DcBus bus;
  setUp(() {
    bus = DcBus();
    bus.write32(reg + 8, 0);
  });
  void texel(int index, int value) =>
      bus.write16(0xa4060000 + index * 2, value);
  DcGpuTexture texture(
          {int tcw = 0x0800c000, int tsp = copy, int control = 0}) =>
      DcGpuTexture(bus.gpu.vram, tcw: tcw, tsp: tsp, control: control);
  int bits(double value) {
    final data = ByteData(4)..setFloat32(0, value, Endian.little);
    return data.getUint32(0, Endian.little);
  }

  void packet(List<int> words) {
    final bytes = Uint8List(32);
    for (final (i, word) in words.indexed) {
      bytes.setUint32LE(i * 4, word);
    }
    bus.gpu.writePolygon(bytes);
  }

  void init() {
    for (final entry in [
      (0x124, object),
      (0x128, parameter),
      (0x20, parameter),
      (0x12c, object + 0xffe0),
      (0x130, parameter + 0xfffc),
      (0x140, 1),
      (0x164, object + 0x1000),
      (0x144, 0x80000000)
    ]) {
      bus.write32(reg + entry.$1, entry.$2);
    }
  }

  void put(int address, List<int> words) {
    for (final (i, word) in words.indexed) {
      bus.gpu.vram.setUint32LE(address + i * 4, word);
    }
  }

  void render({bool twice = false}) {
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
    put(0x9000, [
      // A repeated tile renders without the first tile's visibility pass.
      if (twice) ...[0, object, 0x80000000, 0x80000000, 0x80000000],
      0x80000000, object, 0x80000000, 0x80000000, 0x80000000
    ]);
    for (final entry in [
      (0x2c, 0x9000),
      (0x48, 6),
      (0x4c, 16),
      (0x60, 0x400000),
      (0x68, 31 << 16),
      (0x6c, 31 << 16),
      (0x8c, 0x1000000 | (0x8000 * 2)),
      (0x14, 1)
    ]) {
      bus.write32(reg + entry.$1, entry.$2);
    }
    bus.tickMasterClocks(2);
    if (twice) bus.tickMasterClocks(2);
  }

  int pixel(int x, int y) =>
      bus.gpu.vram.getUint32LE(0x400000 + (y * 32 + x) * 4);

  test('twiddled texels follow V0 U0 V1 U1 ordering in the hardware table', () {
    texel(0, 0xf800);
    texel(1, 0x07e0);
    texel(2, 0x001f);
    texel(3, 0xffff);
    final view = texture();
    expect(view.sample(0, 0), 0xffff0000);
    expect(view.sample(0, 1 / 8), 0xff00ff00);
    expect(view.sample(1 / 8, 0), 0xff0000ff);
    expect(view.sample(1 / 8, 1 / 8), 0xffffffff);
  });

  test(
      'rectangular twiddled textures put the unmatched coordinate bits at the top',
      () {
    texel(64, 0xf800);
    texel(65, 0x07e0);
    expect(texture(tsp: copy | 8).sample(0.5, 0), 0xffff0000); // 16 by 8, U=8.
    expect(texture(tsp: copy | 1).sample(0, 0.5), 0xffff0000); // 8 by 16, V=8.
    expect(texture(tsp: copy | 8).sample(0.5, 1 / 8), 0xff00ff00);
  });





  test('MIP bilinear fast samples match the general sampler', () {
    for (var i = 0; i < 128; i++) {
      texel(i, (i * 0x9e37) & 0xffff);
    }
    // MIP-mapped, bilinear, D-adjust 1.0.
    final tex = texture(tcw: 0x8800c000, tsp: copy | 0x2000 | 0x400);
    var size = 0;
    final offsets = Int32List(tex.maxLevel + 1);
    for (var level = 0; level <= tex.maxLevel; level++) {
      offsets[level] = size;
      size += (tex.width >> level) * (tex.height >> level);
    }
    tex.cache = DcTextureCache(size, offsets);
    expect(tex.mipBilinear, isTrue);
    // Level 0 decoded up front must not stand in for smaller levels.
    tex.decodeAll();
    for (final footprint in [0.5, 1.5, 3.0]) {
      for (final (u, v) in [(0.3, 0.6), (0.07, 0.81), (0.5, 0.5)]) {
        // The second call reads the texels the first one decoded.
        final expected = tex.sample(u, v, footprint: footprint);
        expect(tex.sampleMip(u, v, footprint), expected);
        expect(tex.sampleMip(u, v, footprint), expected);
      }
    }
  });



  test('fixed-point bilinear samples match floating-point positions', () {
    for (var i = 0; i < 64; i++) {
      texel(i, (i ^ i >> 1) & 1 == 0 ? 0 : 0xffff); // A checkerboard.
    }
    final tex = texture(tsp: copy | 0x2000);
    final size = tex.width * tex.height;
    tex.cache = DcTextureCache(size, Int32List(1));
    expect(tex.sampleBilinearFixed(0x8000, 0x8000), -1);
    tex.decodeAll();
    for (final (su, sv) in [
      (0x18000, 0x24000),
      (0x6ff80, 0x10080),
      (0, 0),
      (0x28000, 0x30000),
      (0x30000, 0x28000)
    ]) {
      expect(tex.sampleBilinearFixed(su, sv),
          tex.sampleBilinear(su / (tex.width << 16), sv / (tex.height << 16)));
    }
    expect(tex.sampleBilinearFixed((tex.width - 1) << 16, 0), -1);
    expect(tex.sampleBilinearFixed(-1, 0), -1);
    expect(tex.fixedSpanReady(0, 0, (tex.width - 2) << 16, 0x10000), isTrue);
    expect(tex.fixedSpanReady(0, 0, (tex.width - 1) << 16, 0), isFalse);
  });










}
