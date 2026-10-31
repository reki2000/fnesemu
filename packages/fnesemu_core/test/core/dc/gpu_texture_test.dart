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

  test('linear colors zero-extend while twiddled colors replicate high bits',
      () {
    texel(0, 0xffff);
    expect(texture().sample(0, 0), 0xffffffff);
    expect(texture(tcw: 0x0c00c000).sample(0, 0), 0xfff8fcf8);
    expect(texture(tcw: 0x1000c000).sample(0, 0), 0xffffffff);
    expect(texture(tcw: 0x1400c000).sample(0, 0), 0xf0f0f0f0);
    expect(texture(tcw: 0x0000c000).sample(0, 0), 0xffffffff);
    expect(texture(tcw: 0x0400c000).sample(0, 0), 0xfff8f8f8);
    texel(0, 0x7fff);
    expect(texture(tcw: 0x0000c000).sample(0, 0), 0x00ffffff);
    expect(texture(tcw: 0x3800c000).sample(0, 0), 0x00ffffff);
  });

  test('linear layout uses row-major storage and TEXT_CONTROL stride', () {
    texel(32, 0x07e0);
    texel(64, 0x001f);
    final stride = texture(tcw: 0x0e00c000, tsp: copy | 24, control: 1);
    expect(stride.sample(0, 1 / 8), 0xff00fc00);
    final plain = texture(tcw: 0x0c00c000, tsp: copy | 24);
    expect(plain.sample(0, 1 / 8), 0xff0000f8);
    expect(() => texture(tcw: 0x0e00c000), throwsA(isA<DcUnsupported>()));
  });

  test(
      'repeat, mirror and clamp handle negative coordinates with clamp precedence',
      () {
    for (var i = 0; i < 8; i++) {
      texel(i, i);
    }
    final plain = texture(tcw: 0x0c00c000);
    expect(plain.sample(-1 / 8, 0), 0xff000038);
    expect(plain.sample(1, 0), 0xff000000);
    final mirror = texture(tcw: 0x0c00c000, tsp: copy | 0x40000);
    expect(mirror.sample(-1 / 8, 0), 0xff000000);
    expect(mirror.sample(1, 0), 0xff000038);
    final clamp = texture(tcw: 0x0c00c000, tsp: copy | 0x50000);
    expect(clamp.sample(-10, 0), 0xff000000);
    expect(clamp.sample(2, 0), 0xff000038);
  });

  test('bilinear filtering averages the four adjacent texels and wraps edges',
      () {
    texel(0, 0xf800);
    texel(1, 0x07e0);
    texel(2, 0x001f);
    texel(3, 0xffff);
    final view = texture(tsp: copy | 0x2000);
    expect(view.sample(1 / 16, 1 / 16), 0xff808080);
    expect(texture().sample(1 / 16, 1 / 16), 0xffff0000);
    texel(42, 0xffff); // U=7,V=0 in the documented alternating-bit order.
    expect(view.sample(15 / 16, 0), 0xffff8080);
    expect(texture(tsp: copy | 0x12000).sample(15 / 16, 0), 0xffffffff);
    expect(texture(tsp: copy | 0x4000).sample(1 / 16, 1 / 16), 0xffff0000);
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

  test('span invalidation drops only the twiddled texels stored there', () {
    final tex = texture();
    tex.cache = DcTextureCache(tex.width * tex.height, Int32List(1));
    tex.decodeAll();
    final stamps = tex.cache!.stamps, generation = tex.cache!.generation;
    // Twiddled index 6 holds V bits 0b10 and U bits 0b1.
    tex.invalidateSpan(tex.base + 12, tex.base + 14);
    for (var i = 0; i < stamps.length; i++) {
      expect(stamps[i], i == 2 * tex.width + 1 ? 0 : generation);
    }
    expect(tex.cache!.complete, isNot(generation));
  });

  test('palette versions track the entries a texture selects', () {
    final palette = DcGpuPalette()..write(0x40, 4, 0x1234);
    final low = palette.versionOf(0, 16), high = palette.versionOf(16, 16);
    expect(high, greaterThan(low));
    palette.write(0x40, 4, 0x1234);
    expect(palette.versionOf(16, 16), high);
    palette.write(0x3fc, 4, 1);
    expect(palette.versionOf(0, 16), low);
    expect(palette.versionOf(0, 256), greaterThan(high));
    palette.control = 1;
    expect(palette.versionOf(0, 16), greaterThan(low));
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

  test(
      'all four shading instructions and ignore-alpha use checked integer results',
      () {
    final expected = [0x80814223, 0x80210a05, 0x8061321b, 0x40210a05];
    for (var mode = 0; mode < 4; mode++) {
      expect(DcGpuTexture.shade(0x80402010, 0x80804020, 0x00010203, mode << 6),
          expected[mode]);
    }
    expect(
        DcGpuTexture.shade(
            0x80402010, 0x80804020, 0x00010203, (3 << 6) | 0x80000),
        0x80210a05);
    // The gray fast path matches modulation with equal RGB channels.
    for (final (texel, gray, offset, tsp) in [
      (0x80ff7f01, 0xe0, 0xff060606, 3 << 6),
      (0x12fe0080, 0xff, 0x00fcfdfe, 1 << 6),
      (0x00345678, 0x01, 0x00000000, (3 << 6) | 0x80000),
    ]) {
      expect(
          DcGpuTexture.shadeGray(
              texel, gray, offset, tsp & 0x80000 != 0 ? 0xff000000 : 0),
          DcGpuTexture.shade(0xff000000 | gray * 0x10101, texel, offset, tsp));
    }
  });

  test(
      'TA writes packed 32-bit UV parameters and CORE samples uploaded texture data',
      () {
    init();
    final upload = Uint8List(32)
      ..setUint16LE(0, 0xf800)
      ..setUint16LE(4, 0x07e0);
    bus.write32(0xff000038, 0x10);
    for (var i = 0; i < 32; i += 4) {
      bus.write32(0xe0000000 + i, upload.getUint32LE(i));
    }
    bus.transferStoreQueue(0xe1060000);
    packet([0x80800008, 0xe0000000, copy, 0x0800c000]);
    for (final (i, xy) in [(0.0, 0.0), (32.0, 0.0), (0.0, 32.0)].indexed) {
      packet([
        i == 2 ? 0xf0000000 : 0xe0000000,
        bits(xy.$1),
        bits(xy.$2),
        bits(1),
        bits(xy.$1 / 32),
        bits(0),
        0xff808080,
        0
      ]);
    }
    packet([0]);
    expect((bus.gpu.vram.getUint32LE(object) >> 21) & 7, 3);
    expect(bus.read32(reg + 0x138), parameter + 84);
    render();
    expect(pixel(0, 0), 0xffff0000);
    expect(pixel(4, 0), 0xff00ff00);
    expect(bus.systemBus.normalStatus & 7, 7);
  });

  test('TA and CORE decode upper-half IEEE UV without treating it as binary16',
      () {
    init();
    texel(2, 0x001f);
    packet([0x80800009, 0xe0000000, copy, 0x0800c000]);
    final uv = (bits(1 / 8) & 0xffff0000) | (bits(0) >> 16);
    for (final (i, xy) in [(0.0, 0.0), (32.0, 0.0), (0.0, 32.0)].indexed) {
      packet([
        i == 2 ? 0xf0000000 : 0xe0000000,
        bits(xy.$1),
        bits(xy.$2),
        bits(1),
        uv,
        0,
        0xffffffff
      ]);
    }
    packet([0]);
    expect(bus.read32(reg + 0x138), parameter + 72);
    render();
    expect(pixel(1, 1), 0xff0000ff);
  });

  test(
      'floating textured vertices span two bursts without interpreting continuation words',
      () {
    init();
    texel(0, 0xffff);
    packet([0x8080001c, 0xe0000000, copy | (1 << 6), 0x0800c000]);
    for (final (i, xy) in [(0.0, 0.0), (32.0, 0.0), (0.0, 32.0)].indexed) {
      packet([
        i == 2 ? 0xf0000000 : 0xe0000000,
        bits(xy.$1),
        bits(xy.$2),
        bits(1),
        0,
        0,
        0,
        0
      ]);
      expect(bus.read32(reg + 0x138), parameter);
      packet([
        bits(1),
        bits(0.5),
        bits(0.25),
        bits(0),
        bits(0),
        bits(0),
        bits(0),
        bits(0.25)
      ]);
    }
    packet([0]);
    expect(bus.read32(reg + 0x138), parameter + 96);
    render();
    expect(pixel(1, 1), 0xff7f3f3f);
  });

  test('intensity offset headers span two bursts and preserve both face colors',
      () {
    init();
    texel(0, 0xffff);
    packet([0x8080002c, 0xe0000000, copy | (1 << 6), 0x0800c000]);
    packet([
      bits(1),
      bits(1),
      bits(0),
      bits(0),
      bits(0),
      bits(0),
      bits(1),
      bits(0)
    ]);
    for (final (i, xy) in [(0.0, 0.0), (32.0, 0.0), (0.0, 32.0)].indexed) {
      packet([
        i == 2 ? 0xf0000000 : 0xe0000000,
        bits(xy.$1),
        bits(xy.$2),
        bits(1),
        0,
        0,
        bits(0.5),
        bits(0.25)
      ]);
    }
    packet([0]);
    render();
    expect(pixel(1, 1), 0xff7f3f00);
  });

  test('affine bilinear texels modulated by a gray color', () {
    init();
    for (var i = 0; i < 64; i++) {
      texel(i, 0xf800);
    }
    packet([0x80800008, 0xe0000000, copy | 0x2040, 0x0800c000]);
    for (final (i, (x, y)) in [(0.0, 0.0), (32.0, 0.0), (0.0, 32.0)].indexed) {
      packet([
        i == 2 ? 0xf0000000 : 0xe0000000,
        bits(x),
        bits(y),
        bits(1),
        bits(x / 64),
        bits(y / 64),
        0xff808080
      ]);
    }
    packet([0]);
    render(twice: true);
    expect(pixel(4, 4), 0xff800000);
    expect(pixel(20, 2), 0xff800000);
  });

  test('perspective division uses reciprocal depth rather than affine UV', () {
    init();
    for (var i = 0; i < 64; i++) {
      texel(i, 0xf800);
    }
    texel(2, 0x07e0); // U=1,V=0, while the affine U at pixel (8,0) selects U=2.
    packet([0x80800008, 0xe0000000, copy, 0x0800c000]);
    packet(
        [0xe0000000, bits(0), bits(0), bits(1), bits(0), bits(0), 0xffffffff]);
    packet([
      0xe0000000,
      bits(32),
      bits(0),
      bits(0.5),
      bits(1),
      bits(0),
      0xffffffff
    ]);
    packet(
        [0xf0000000, bits(0), bits(32), bits(1), bits(0), bits(0), 0xffffffff]);
    packet([0]);
    render();
    expect(pixel(8, 0), 0xff00ff00);
  });

  test(
      'texture coordinate sampling can use integer positions independently of coverage',
      () {
    for (final half in [3, 7]) {
      bus = DcBus();
      bus.write32(reg + 8, 0);
      init();
      texel(0, 0xf800);
      texel(2, 0x07e0);
      packet([0x80800008, 0xe0000000, copy, 0x0800c000]);
      for (final (i, xy) in [(0.0, 0.0), (32.0, 0.0), (0.0, 32.0)].indexed) {
        packet([
          i == 2 ? 0xf0000000 : 0xe0000000,
          bits(xy.$1),
          bits(xy.$2),
          bits(1),
          bits((xy.$1 + 0.5) / 32),
          0,
          0xffffffff
        ]);
      }
      packet([0]);
      bus.write32(reg + 0x80, half);
      render();
      expect(pixel(3, 0), half == 7 ? 0xff00ff00 : 0xffff0000);
    }
  });

  test('a long-format vertex after End Of List is rejected at its first burst',
      () {
    init();
    packet([0x80800018, 0xe0000000, copy, 0x0800c000]);
    packet([0]);
    bus.write32(0xa05f6900, 0x80);
    expect(() => packet([0xe0000000, 0, 0, bits(1)]),
        throwsA(isA<DcUnsupported>()));
    expect(bus.systemBus.normalStatus & 0x80, 0);
    expect(bus.systemBus.errorStatus & 16, 16);
  });

  test(
      'reset discards a partial long packet and initialization rejects truncation',
      () {
    init();
    packet([0x8080002c, 0xe0000000, copy, 0x0800c000]);
    expect(() => bus.write32(reg + 0x144, 0x80000000),
        throwsA(isA<DcUnsupported>()));
    bus.write32(reg + 8, 1);
    bus.write32(reg + 8, 0);
    init();
    packet([0x80800000, 0xe0000000, copy]);
    packet([0]);
    expect(bus.systemBus.normalStatus & 0x80, 0x80);
  });
}
