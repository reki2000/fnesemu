import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/gpu_texture.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  const reg = 0xa05f8000, copy = 0x20800000, adjustOne = 0x400;
  const offsets = [
    6,
    8,
    0x10,
    0x30,
    0xb0,
    0x2b0
  ]; // Manual page 148, RGB byte offsets.
  late DcBus bus;
  setUp(() {
    bus = DcBus();
    bus.write32(reg + 8, 0);
  });
  void word(int offset, int value) => bus.write16(0xa4060000 + offset, value);
  void byte(int offset, int value) {
    final address = 0xa4060000 + (offset & ~1), shift = (offset & 1) * 8;
    bus.write16(address,
        (bus.read16(address) & ~(255 << shift)) | ((value & 255) << shift));
  }

  void rgbLevel(int exponent, int color) {
    for (var i = 0; i < (1 << (2 * exponent)); i++) {
      word(offsets[exponent] + i * 2, color);
    }
  }

  DcGpuTexture texture({int tcw = 0x8800c000, int tsp = copy | adjustOne}) =>
      DcGpuTexture(bus.gpu.vram, tcw: tcw, tsp: tsp, palette: bus.gpu.palette);
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
      (0x124, 0x100000),
      (0x128, 0x200000),
      (0x12c, 0x10ffe0),
      (0x130, 0x20fffc),
      (0x140, 1),
      (0x164, 0x101000),
      (0x144, 0x80000000)
    ]) {
      bus.write32(reg + item.$1, item.$2);
    }
  }

  void render() {
    void put(int address, List<int> words) {
      for (final (i, value) in words.indexed) {
        bus.gpu.vram.setUint32LE(address + 4 * i, value);
      }
    }

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
    put(0x9000, [0x80000000, 0x100000, 0x80000000, 0x80000000, 0x80000000]);
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

  test('RGB mip levels use padded hardware offsets down to texel three at 1x1',
      () {
    rgbLevel(3, 0xf800);
    rgbLevel(2, 0x07e0);
    rgbLevel(1, 0x001f);
    rgbLevel(0, 0xffff);
    final view = texture();
    expect(view.sample(0, 0, footprint: 1), 0xffff0000);
    expect(view.sample(0, 0, footprint: 2), 0xff00ff00);
    expect(view.sample(0, 0, footprint: 4), 0xff0000ff);
    expect(view.sample(0, 0, footprint: 8), 0xffffffff);
    expect(view.sample(0.75, 0.75, footprint: 1e6), 0xffffffff);
  });

  test(
      'functional power-of-two footprints apply D-adjust and clamp the level range',
      () {
    final normal = texture(),
        half = texture(tsp: copy | 0x200),
        twice = texture(tsp: copy | 0x800);
    expect(normal.selectLevel(0), 0);
    expect(normal.selectLevel(1), 0);
    expect(normal.selectLevel(2), 1);
    expect(normal.selectLevel(4), 2);
    expect(half.selectLevel(2), 0);
    expect(twice.selectLevel(1), 1);
    expect(twice.selectLevel(100), 3);
    expect(normal.footprint(0.25, 0, 0, 0.5), 4);
  });

  test('MIP uses square U size regardless of the V-size field', () {
    final view = texture(tsp: copy | adjustOne | 7);
    expect((view.width, view.height), (8, 8));
    expect(view.selectLevel(8), 3);
  });

  test('4BPP and 8BPP mip offsets use nibble and byte units respectively', () {
    bus.write32(reg + 0x108, 3);
    for (final item in [
      (1, 0xffff0000),
      (2, 0xff00ff00),
      (3, 0xff0000ff),
      (4, 0xffffffff)
    ]) {
      bus.write32(0xa05f9000 + item.$1 * 4, item.$2);
    }
    // The 4BPP 1x1 level is at nibble 3, not byte 3 or the first nibble.
    byte(12, 1);
    byte(4, 2);
    byte(2, 4);
    byte(1, 0x30);
    final four = texture(tcw: 0xa800c000);
    expect(four.sample(0, 0, footprint: 1), 0xffff0000);
    expect(four.sample(0, 0, footprint: 2), 0xff00ff00);
    expect(four.sample(0, 0, footprint: 4), 0xffffffff);
    expect(four.sample(0, 0, footprint: 8), 0xff0000ff);
    byte(24, 1);
    byte(8, 2);
    byte(4, 4);
    byte(3, 3);
    final eight = texture(tcw: 0xb000c000);
    expect(eight.sample(0, 0, footprint: 1), 0xffff0000);
    expect(eight.sample(0, 0, footprint: 2), 0xff00ff00);
    expect(eight.sample(0, 0, footprint: 4), 0xffffffff);
    expect(eight.sample(0, 0, footprint: 8), 0xff0000ff);
  });

  test(
      'VQ mip index offsets stay after the codebook and 1x1 chooses texel three',
      () {
    for (var i = 0; i < 4; i++) {
      word(8 + i * 2, 0xf800);
      word(16 + i * 2, 0x07e0);
      word(24 + i * 2, 0x001f);
      word(32 + i * 2, 0xf800);
    }
    for (final (i, color) in [0xf800, 0x07e0, 0x001f, 0xffff].indexed) {
      word(56 + i * 2, color);
    }
    byte(0x800 + 0x16, 1);
    byte(0x800 + 6, 2);
    byte(0x800 + 2, 3);
    byte(0x800 + 1, 4);
    byte(0x800, 7);
    final view = texture(tcw: 0xc800c000, tsp: copy | adjustOne | 8);
    for (final item in [
      (1.0, 0xffff0000),
      (2.0, 0xff00ff00),
      (4.0, 0xff0000ff),
      (8.0, 0xffff0000),
      (16.0, 0xffffffff)
    ]) {
      expect(view.sample(0, 0, footprint: item.$1), item.$2);
    }
  });

  test(
      'bilinear filtering samples the selected resolution using its own dimensions',
      () {
    for (final (i, color) in [0xf800, 0x07e0, 0x001f, 0xffff].indexed) {
      word(0x10 + i * 2, color);
    }
    expect(
        texture(tsp: copy | adjustOne | 0x2000)
            .sample(1 / 8, 1 / 8, footprint: 2),
        0xff808080);
  });

  test('invalid adjust and nonfinite footprints stop explicitly', () {
    for (final tsp in [copy]) {
      expect(() => texture(tsp: tsp), throwsA(isA<DcUnsupported>()));
    }
    expect(() => texture().sample(0, 0, footprint: double.infinity),
        throwsA(isA<DcUnsupported>()));
    expect(() => texture().sample(0, 0, footprint: -1),
        throwsA(isA<DcUnsupported>()));
  });

  test(
      'CORE minification selects a smaller RGB level from perspective plane derivatives',
      () {
    init();
    rgbLevel(3, 0xf800);
    rgbLevel(2, 0x07e0);
    rgbLevel(1, 0x001f);
    rgbLevel(0, 0xffff);
    packet([0x80800008, 0xe0000000, copy | adjustOne, 0x8800c000]);
    for (final (i, xy) in [(0.0, 0.0), (2.0, 0.0), (0.0, 2.0)].indexed) {
      packet([
        i == 2 ? 0xf0000000 : 0xe0000000,
        bits(xy.$1),
        bits(xy.$2),
        bits(1),
        bits(xy.$1 / 2),
        bits(xy.$2 / 2),
        0xffffffff
      ]);
    }
    packet([0]);
    render();
    // Eight texels over two screen pixels yields D=4, selecting the 2x2 level.
    expect(bus.gpu.vram.getUint32LE(0x400000), 0xff0000ff);
    expect(bus.systemBus.normalStatus & 7, 7);
  });

  test(
      'CORE automatic LOD uses palette and VQ mip layouts through the same path',
      () {
    for (final compressed in [false, true]) {
      bus = DcBus();
      bus.write32(reg + 8, 0);
      init();
      if (compressed) {
        for (var i = 0; i < 4; i++) {
          word(7 * 8 + i * 2, 0x001f);
        }
        byte(0x801, 7); // Index offset 1 belongs to the VQ 2x2 level.
      } else {
        bus.write32(reg + 0x108, 3);
        bus.write32(0xa05f900c, 0xff0000ff);
        byte(2, 0x33); // Nibble offset 4 belongs to the 4BPP 2x2 level.
      }
      packet([
        0x80800008,
        0xe0000000,
        copy | adjustOne,
        compressed ? 0xc800c000 : 0xa800c000
      ]);
      for (final (i, xy) in [(0.0, 0.0), (2.0, 0.0), (0.0, 2.0)].indexed) {
        packet([
          i == 2 ? 0xf0000000 : 0xe0000000,
          bits(xy.$1),
          bits(xy.$2),
          bits(1),
          bits(xy.$1 / 2),
          bits(xy.$2 / 2),
          0xffffffff
        ]);
      }
      packet([0]);
      render();
      expect(bus.gpu.vram.getUint32LE(0x400000), 0xff0000ff);
      expect(bus.systemBus.normalStatus & 7, 7);
    }
  });

  test('Dcalc controls use screen-origin or original-first-vertex numerators',
      () {
    for (final precise in [false, true]) {
      bus = DcBus();
      bus.write32(reg + 8, 0);
      init();
      rgbLevel(5, 0xf800);
      rgbLevel(4, 0x07e0);
      packet([
        0x80800008,
        0xe0000000 | (precise ? 0x100000 : 0),
        copy | 0x610,
        0x8800c000
      ]);
      final data = [
        (8.0, 8.0, 1.0, 0.0),
        (24.0, 8.0, 0.5, 1.0),
        (8.0, 24.0, 0.25, 0.0)
      ];
      for (final (i, v) in data.indexed) {
        packet([
          i == 2 ? 0xf0000000 : 0xe0000000,
          bits(v.$1),
          bits(v.$2),
          bits(v.$3),
          bits(v.$4),
          0,
          0xffffffff
        ]);
      }
      packet([0]);
      render();
      // At (8.5,8.5), the manual's numerators give adjusted D about 2.23 or 1.62.
      expect(bus.gpu.vram.getUint32LE(0x400000 + (8 * 32 + 8) * 4),
          precise ? 0xffff0000 : 0xff00ff00);
    }
  });
}
