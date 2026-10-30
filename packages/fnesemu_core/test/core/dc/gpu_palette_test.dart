import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/gpu_texture.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  const reg = 0xa05f8000, ram = 0xa05f9000, copy = 0x20800000;
  late DcBus bus;
  setUp(() {
    bus = DcBus();
    bus.write32(reg + 8, 0);
  });
  void entry(int index, int value) => bus.write32(ram + 4 * index, value);
  void indices(List<int> bytes, {int offset = 0}) {
    for (var i = 0; i < bytes.length; i += 2) {
      bus.write16(0xa4060000 + offset + i, bytes[i] | (bytes[i + 1] << 8));
    }
  }

  DcGpuTexture texture({int tcw = 0x2800c000, int tsp = copy}) =>
      DcGpuTexture(bus.gpu.vram, tcw: tcw, tsp: tsp, palette: bus.gpu.palette);
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

  test('palette RAM aliases, boundaries, access widths and format masks', () {
    expect(bus.read32(reg + 0x108), 0);
    for (final address in [0x005f9000, 0x025f9000, 0x805f9000, 0xa25f9000]) {
      bus.write32(address, 0x1234ffff);
      expect(bus.read32(ram), 0xffff);
    }
    bus.write32(reg + 0x108, 0xffffffff);
    expect(bus.read32(reg + 0x108), 3);
    entry(1023, 0x89abcdef);
    expect(bus.read32(ram + 4092), 0x89abcdef);
    expect(() => bus.read16(ram), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write8(ram, 1), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read32(ram + 1), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read32(ram + 4096), throwsA(isA<DcUnsupported>()));
  });

  test('all four palette color formats expand documented channels', () {
    for (final item in [
      (0, 0xfc00, 0xffff0000),
      (1, 0x07e0, 0xff00ff00),
      (2, 0x8a4f, 0x88aa44ff),
      (3, 0x89abcdef, 0x89abcdef)
    ]) {
      bus.write32(reg + 0x108, item.$1);
      entry(0, item.$2);
      expect(bus.gpu.palette.color(0), item.$3);
    }
  });

  test(
      '4BPP uses low nibble first and all six selector bits including scan overlap',
      () {
    bus.write32(reg + 0x108, 3);
    entry(1009, 0xff112233);
    entry(1010, 0xff445566);
    entry(1011, 0xff778899);
    entry(1012, 0xffaabbcc);
    indices([0x21, 0x43]);
    final view = texture(tcw: 0x2800c000 | (63 << 21));
    expect(view.sample(0, 0), 0xff112233);
    expect(view.sample(0, 1 / 8), 0xff445566);
    expect(view.sample(1 / 8, 0), 0xff778899);
    expect(view.sample(1 / 8, 1 / 8), 0xffaabbcc);
  });

  test('8BPP uses only the upper two selector bits and ignores the lower four',
      () {
    bus.write32(reg + 0x108, 3);
    entry(768 + 128, 0xff123456);
    entry(1023, 0xffabcdef);
    indices([128, 255]);
    final full = texture(tcw: 0x3000c000 | (63 << 21));
    final high = texture(tcw: 0x3000c000 | (3 << 25));
    expect(full.sample(0, 0), 0xff123456);
    expect(full.sample(0, 1 / 8), 0xffabcdef);
    expect(high.sample(0, 0), full.sample(0, 0));
    expect(high.sample(0, 1 / 8), full.sample(0, 1 / 8));
  });

  test(
      'rectangular palette addressing keeps leftover U or V bits above Morton bits',
      () {
    entry(3, 0xfc00);
    indices([3, 0], offset: 64);
    expect(texture(tcw: 0x3000c000, tsp: copy | 8).sample(0.5, 0), 0xffff0000);
    expect(texture(tcw: 0x3000c000, tsp: copy | 1).sample(0, 0.5), 0xffff0000);
    indices([3, 0], offset: 32);
    expect(texture(tsp: copy | 8).sample(0.5, 0), 0xffff0000);
  });

  test(
      'bilinear filtering combines palette colors rather than interpolating indices',
      () {
    bus.write32(reg + 0x108, 3);
    entry(0, 0xffff0000);
    entry(1, 0xff00ff00);
    entry(128, 0xff0000ff);
    entry(255, 0xffffffff);
    indices([0, 1, 128, 255]);
    expect(texture(tcw: 0x3000c000, tsp: copy | 0x2000).sample(1 / 16, 1 / 16),
        0xff808080);
  });

  test(
      'mode changes and writes remain visible to existing functional texture views',
      () {
    bus.write32(reg + 0x108, 3);
    indices([0, 0]);
    entry(0, 0xff112233);
    final view = texture();
    expect(view.sample(0, 0), 0xff112233);
    entry(0, 0xff445566);
    expect(view.sample(0, 0), 0xff445566);
    bus.write32(reg + 0x108, 1);
    entry(0, 0x001f);
    expect(view.sample(0, 0), 0xff0000ff);
  });

  test('soft resets retain palette while power reset clears synthetic RAM', () {
    bus.write32(reg + 0x108, 3);
    entry(1023, 0x89abcdef);
    bus.write32(reg + 8, 3);
    expect(bus.read32(reg + 0x108), 3);
    expect(bus.read32(ram + 4092), 0x89abcdef);
    bus.gpu.reset();
    expect(bus.read32(reg + 0x108), 0);
    expect(bus.read32(ram + 4092), 0x89abcdef);
    bus.gpu.reset(clearMemory: true);
    expect(bus.read32(ram + 4092), 0);
  });

  test('TA and CORE fetch live palette colors for an indexed texture', () {
    bus.write32(reg + 0x108, 3);
    entry(33, 0xffff0000);
    indices([0x11, 0x11]);
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
    packet([0x80800008, 0xe0000000, copy, 0x2800c000 | (2 << 21)]);
    for (final (i, xy) in [(0.0, 0.0), (32.0, 0.0), (0.0, 32.0)].indexed) {
      packet([
        i == 2 ? 0xf0000000 : 0xe0000000,
        bits(xy.$1),
        bits(xy.$2),
        bits(1),
        0,
        0,
        0xffffffff
      ]);
    }
    packet([0]);
    void put(int address, List<int> words) {
      for (final (i, word) in words.indexed) {
        bus.gpu.vram.setUint32LE(address + i * 4, word);
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
    entry(33,
        0xff00ff00); // A CPU update before the tile is fetched replaces red with green.
    bus.tickMasterClocks(2);
    expect(bus.gpu.vram.getUint32LE(0x400000 + 132), 0xff00ff00);
    expect(bus.systemBus.normalStatus & 7, 7);
  });
}
