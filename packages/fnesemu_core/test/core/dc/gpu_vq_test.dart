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
