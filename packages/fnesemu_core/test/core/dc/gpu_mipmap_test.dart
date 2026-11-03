import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
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
      (0x20, 0x200000),
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

}
