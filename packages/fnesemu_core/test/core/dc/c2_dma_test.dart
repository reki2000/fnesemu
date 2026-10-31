import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:test/test.dart';

void main() {
  test('TA software reset retains list configuration for the next frame', () {
    final bus = DcBus();
    final ta = bus.gpu.ta;
    for (final (offset, value) in [
      (0x124, 0x1000),
      (0x128, 0x3000),
      (0x12c, 0x2000),
      (0x130, 0x4000),
      (0x13c, 0x10001),
      (0x140, 1),
      (0x164, 0x1800)
    ]) {
      ta.write(offset, value);
    }
    bus.gpu.write(8, 4, 1);
    bus.gpu.write(8, 4, 0);
    expect(ta.globalClip, 0x10001);
    expect(ta.allocation, 1);
    expect(ta.objectBase, 0x1000);
    expect(ta.parameterBase, 0x3000);
    ta.write(0x144, 0x80000000);
    expect(ta.currentParameter, 0x3000);
    expect(ta.nextObject, 0x1800);
    bus.gpu.reset();
    expect(ta.globalClip, 0);
    expect(ta.allocation, 0);
  });

  test('conversion-only TA input retains geometry outside the tile clip', () {
    final bus = DcBus();
    final ta = bus.gpu.ta;
    ta.write(0x128, 0x20000);
    ta.write(0x130, 0x2fffc);
    ta.write(0x144, 0x80000000);
    void packet(List<int> words) {
      final data = ByteData(32);
      for (var i = 0; i < words.length; i++) {
        data.setUint32(i * 4, words[i], Endian.little);
      }
      ta.accept(data.buffer.asUint8List());
    }

    int bits(double value) => (ByteData(4)..setFloat32(0, value, Endian.little))
        .getUint32(0, Endian.little);
    packet([0x80800000, 0xe0000000, 0x20800000, 0]);
    for (final (i, point)
        in [(64.0, 64.0), (95.0, 64.0), (64.0, 95.0)].indexed) {
      packet([
        i == 2 ? 0xf0000000 : 0xe0000000,
        bits(point.$1),
        bits(point.$2),
        bits(1),
        0,
        0,
        0xffff0000,
        0
      ]);
    }
    expect(ta.currentParameter, 0x20000 + 60);
    expect(ByteData.sublistView(bus.gpu.vram).getUint32(0x2000c, Endian.little),
        bits(64));
    expect(bus.systemBus.errorStatus, 0);
  });

  test('channel-2 DREQ sends actual TA packets and completes both controllers',
      () {
    final bus = DcBus();
    bus.gpu.write(8, 4, 0);
    final ta = bus.gpu.ta;
    ta.write(0x128, 0x20000);
    ta.write(0x130, 0x2fffc);
    ta.write(0x144, 0x80000000);
    final memory = ByteData.sublistView(bus.ram);
    memory.setUint32(0x2000, 0x80000000, Endian.little);
    bus.write32(0xffa00020, 0x0c002000);
    bus.write32(0xffa00028, 2);
    bus.write32(0xffa0002c, 0x12c1);
    bus.write32(0xffa00040, 0x8201);
    bus.write32(0xa05f6800, 0x10000000);
    bus.write32(0xa05f6804, 64);
    bus.write32(0xa05f6808, 1);
    bus.tickMasterClocks(2);
    expect(bus.read32(0xa05f6808), 1);
    expect(bus.read32(0xa05f6804), 32);
    expect(bus.read32(0xffa00028), 1);
    expect(bus.systemBus.normalStatus & (1 << 19), 0);
    bus.tickMasterClocks(2);
    expect(bus.read32(0xa05f6808), 0);
    expect(bus.read32(0xa05f6804), 0);
    expect(bus.read32(0xffa00028), 0);
    expect(bus.read32(0xffa00020), 0x0c002040);
    expect(bus.read32(0xffa0002c) & 2, 2);
    expect(bus.systemBus.normalStatus & ((1 << 19) | (1 << 7)),
        (1 << 19) | (1 << 7));
  });

  test('TA initialization makes an allocated but unused object list empty', () {
    final bus = DcBus();
    final ta = bus.gpu.ta;
    ta.write(0x124, 0x1000);
    ta.write(0x12c, 0x2000);
    ta.write(0x128, 0x3000);
    ta.write(0x130, 0x4000);
    ta.write(0x140, 1);
    ta.write(0x164, 0x1800);
    ta.write(0x144, 0x80000000);
    expect(ByteData.sublistView(bus.gpu.vram).getUint32(0x1000, Endian.little),
        0xf0000000);
    expect(ta.currentParameter, 0x3000);
    expect(bus.systemBus.normalStatus, 0);
  });
}
