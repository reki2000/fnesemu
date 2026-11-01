import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/gpu_texture.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  const reg = 0xa05f8000, copy = 0x20800000;
  late DcBus bus;
  setUp(() {
    bus = DcBus();
    bus.write32(reg + 8, 0);
  });
  void book(int code, List<int> values) {
    for (final (i, value) in values.indexed) {
      bus.write16(0xa4060000 + code * 8 + i * 2, value);
    }
  }

  void index(int offset, int value) {
    final address = 0xa4060800 + (offset & ~1),
        old = bus.read16(0xa4060800 + (offset & ~1));
    final shift = (offset & 1) * 8;
    bus.write16(address, (old & ~(255 << shift)) | (value << shift));
  }

  DcGpuTexture texture(
          {int tcw = 0x4800c000, int tsp = copy, int control = 0}) =>
      DcGpuTexture(bus.gpu.vram,
          tcw: tcw, tsp: tsp, control: control, palette: bus.gpu.palette);

  test('VQ codes expand four RGB texels in reverse-N order', () {
    book(7, [0xf800, 0x07e0, 0x001f, 0xffff]);
    index(0, 7);
    final view = texture();
    expect(view.sample(0, 0), 0xffff0000);
    expect(view.sample(0, 1 / 8), 0xff00ff00);
    expect(view.sample(1 / 8, 0), 0xff0000ff);
    expect(view.sample(1 / 8, 1 / 8), 0xffffffff);
  });

  test('the index image starts exactly 2048 bytes after the codebook', () {
    book(0, List.filled(4, 0x001f));
    book(255, List.filled(4, 0xf800));
    index(0, 255);
    expect(texture().sample(0, 0), 0xffff0000);
    expect(texture().sample(2 / 8, 0), 0xff0000ff);
  });

  test('half-size index coordinates use Morton order for adjacent blocks', () {
    book(1, List.filled(4, 0xf800));
    book(2, List.filled(4, 0x07e0));
    book(3, List.filled(4, 0x001f));
    book(4, List.filled(4, 0xffff));
    index(0, 1);
    index(1, 2);
    index(2, 3);
    index(3, 4);
    final view = texture();
    expect(view.sample(0, 0), 0xffff0000);
    expect(view.sample(0, 2 / 8), 0xff00ff00);
    expect(view.sample(2 / 8, 0), 0xff0000ff);
    expect(view.sample(2 / 8, 2 / 8), 0xffffffff);
  });

  test('RGB1555 and RGB4444 VQ preserve expanded alpha and component bits', () {
    book(1, [0x8a4f, 0, 0, 0]);
    index(0, 1);
    expect(texture(tcw: 0x5000c000).sample(0, 0), 0x88aa44ff);
    book(1, [0xfc00, 0, 0, 0]);
    expect(texture(tcw: 0x4000c000).sample(0, 0), 0xffff0000);
    expect(texture(tcw: 0x7800c000).sample(0, 0), 0xffff0000);
  });

  test('bilinear interpolation crosses codebook blocks using decoded colors',
      () {
    book(0, List.filled(4, 0xf800));
    book(1, List.filled(4, 0x001f));
    index(2, 1);
    expect(texture(tsp: copy | 0x2000).sample(1.5 / 8, 0), 0xff800080);
  });

  test('address wrapping and clamp apply before choosing an index block', () {
    book(0, List.filled(4, 0xf800));
    book(1, List.filled(4, 0x001f));
    index(10, 1);
    expect(texture().sample(-1 / 8, 0),
        0xff0000ff); // Block U=3 has Morton index 10.
    expect(texture(tsp: copy | 0x10000).sample(-1 / 8, 0), 0xffff0000);
    expect(texture(tsp: copy | 0x40000).sample(-1 / 8, 0), 0xffff0000);
  });

  test(
      'small codebooks use high code indices without changing the fixed index offset',
      () {
    // The documented reduced-book scheme references only the final eight elements.
    book(248, List.filled(4, 0x07e0));
    index(0, 248);
    final view = texture();
    expect(view.sample(0, 0), 0xff00ff00);
    book(248, List.filled(4, 0xf800));
    expect(view.sample(0, 0),
        0xffff0000); // No functional codebook cache hides CPU writes.
  });

  group('non-MIP palette VQ', () {
    void palette(int index, int value) =>
        bus.write32(reg + 0x1000 + index * 4, value);
    void prepare() {
      bus.write32(reg + 0x108, 3);
      for (var i = 0; i < 1024; i++) {
        palette(i, 0xff000000 | i);
      }
    }

    setUp(prepare);
    test('4bpp codebook elements contain sixteen reverse-N palette indices',
        () {
      book(7, [0x3210, 0x7654, 0xba98, 0xfedc]);
      index(0, 7);
      final view = texture(tcw: 0x6800c000);
      const grid = [
        [0, 2, 8, 10],
        [1, 3, 9, 11],
        [4, 6, 12, 14],
        [5, 7, 13, 15]
      ];
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          expect(view.sample(x / 8, y / 8), 0xff000000 | grid[y][x]);
        }
      }
    });
    test('8bpp codebook elements contain eight indices in a 2x4 block', () {
      book(255, [0x0100, 0x0302, 0x0504, 0x0706]);
      index(0, 255);
      final view = texture(tcw: 0x7000c000);
      const grid = [
        [0, 2],
        [1, 3],
        [4, 6],
        [5, 7]
      ];
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 2; x++) {
          expect(view.sample(x / 8, y / 8), 0xff000000 | grid[y][x]);
        }
      }
    });
    test('4bpp blocks use independent high codes after the fixed 2 KiB book',
        () {
      for (var i = 0; i < 4; i++) {
        book(248 + i, List.filled(4, (i + 1) * 0x1111));
        index(i, 248 + i);
      }
      final view = texture(tcw: 0x6800c000);
      expect(view.sample(0, 0), 0xff000001);
      expect(view.sample(0, 4 / 8), 0xff000002);
      expect(view.sample(4 / 8, 0), 0xff000003);
      expect(view.sample(4 / 8, 4 / 8), 0xff000004);
    });
    test('8bpp partitions the Morton stream across 2x4 block boundaries', () {
      for (var i = 0; i < 8; i++) {
        book(32 + i, List.filled(4, (i + 1) * 0x101));
        index(i, 32 + i);
      }
      final view = texture(tcw: 0x7000c000);
      const grid = [
        [0, 1, 4, 5],
        [2, 3, 6, 7]
      ];
      for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 4; x++) {
          expect(view.sample(x * 2 / 8, y * 4 / 8), 0xff000001 + grid[y][x]);
        }
      }
    });
    test('palette selectors apply after decompressing the codebook entry', () {
      book(0, List.filled(4, 0xffff));
      expect(texture(tcw: 0x6800c000 | (63 << 21)).sample(0, 0), 0xff0003ff);
      expect(texture(tcw: 0x7000c000 | (3 << 25)).sample(0, 0), 0xff0003ff);
    });
    test(
        'all palette color formats preserve their existing expansion and alpha',
        () {
      book(0, List.filled(4, 0x1111));
      const choices = [
        (0, 0xfc00, 0xffff0000),
        (1, 0x7e0, 0xff00ff00),
        (2, 0x8a4f, 0x88aa44ff),
        (3, 0x12345678, 0x12345678)
      ];
      for (final choice in choices) {
        bus.write32(reg + 0x108, choice.$1);
        palette(1, choice.$2);
        expect(texture(tcw: 0x6800c000).sample(0, 0), choice.$3);
      }
    });
    test('bilinear filtering crosses palette VQ blocks after color lookup', () {
      palette(0, 0xffff0000);
      palette(1, 0xff0000ff);
      book(1, List.filled(4, 0x1111));
      index(2, 1);
      expect(texture(tcw: 0x6800c000, tsp: copy | 0x2000).sample(3.5 / 8, 0),
          0xff800080);
    });
    test('wrap mirror and clamp resolve coordinates before block lookup', () {
      book(1, List.filled(4, 0x1111));
      index(2, 1);
      expect(texture(tcw: 0x6800c000).sample(-1 / 8, 0), 0xff000001);
      expect(texture(tcw: 0x6800c000, tsp: copy | 0x40000).sample(-1 / 8, 0),
          0xff000000);
      expect(texture(tcw: 0x6800c000, tsp: copy | 0x10000).sample(-1 / 8, 0),
          0xff000000);
    });
    test(
        'CPU codebook and palette writes are visible to the functional sampler',
        () {
      final view = texture(tcw: 0x6800c000);
      expect(view.sample(0, 0), 0xff000000);
      book(0, List.filled(4, 0x1111));
      expect(view.sample(0, 0), 0xff000001);
      palette(1, 0x80abcdef);
      expect(view.sample(0, 0), 0x80abcdef);
    });
  });

  for (final format in [1, 5, 6]) {
    test('TA and CORE render VQ format $format through its normal control word',
        () {
      if (format == 1) {
        book(9, [0xf800, 0x07e0, 0x001f, 0xffff]);
      } else {
        bus.write32(reg + 0x108, 3);
        for (final (i, color)
            in [0xffff0000, 0xff00ff00, 0xff0000ff, 0xffffffff].indexed) {
          bus.write32(reg + 0x1000 + (i + 1) * 4, color);
        }
        book(9, format == 5 ? [0x4321, 0, 0, 0] : [0x0201, 0x0403, 0, 0]);
      }
      index(0, 9);
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
      packet([0x80800008, 0xe0000000, copy, 0x4000c000 | (format << 27)]);
      for (final (i, xy) in [(0.0, 0.0), (32.0, 0.0), (0.0, 32.0)].indexed) {
        packet([
          i == 2 ? 0xf0000000 : 0xe0000000,
          bits(xy.$1),
          bits(xy.$2),
          bits(1),
          bits(xy.$1 / 32),
          bits(xy.$2 / 32),
          0xffffffff
        ]);
      }
      packet([0]);
      void put(int address, List<int> words) {
        for (final (i, word) in words.indexed) {
          bus.gpu.vram.setUint32LE(address + 4 * i, word);
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
      expect(bus.gpu.vram.getUint32LE(0x400000), 0xffff0000);
      expect(bus.gpu.vram.getUint32LE(0x400000 + 4 * 4), 0xff0000ff);
      expect(bus.gpu.vram.getUint32LE(0x400000 + 4 * 32 * 4), 0xff00ff00);
      expect(bus.systemBus.normalStatus & 7, 7);
    });
  }
}
