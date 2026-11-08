import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/render_frame.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

class _Frames implements RenderFrameSink {
  final frames = <RenderFrame>[];

  @override
  void submit(RenderFrame frame) => frames.add(frame);
}

void main() {
  const reg = 0xa05f8000;
  late DcBus bus;
  late _Frames host;

  int bits(double value) {
    final bytes = ByteData(4)..setFloat32(0, value, Endian.little);
    return bytes.getUint32(0, Endian.little);
  }

  void put(int address, List<int> words) {
    for (final (i, word) in words.indexed) {
      bus.gpu.vram.setUint32LE(address + i * 4, word);
    }
  }

  // An untextured red background and one region entry, written to a
  // 32-pixel wide framebuffer at 0x400000.
  void render({int pack = 6, int control = 0x80000000, int scale = 0x400}) {
    final words = <int>[0, 0, 0];
    for (var i = 0; i < 3; i++) {
      words.addAll([
        bits(i == 1 ? 32.0 : 0.0),
        bits(i == 2 ? 32.0 : 0.0),
        bits(1),
        0xffff0000
      ]);
    }
    put(0x8000, words);
    bus.write32(reg + 0x8c, (1 << 24) | 0x10000);
    bus.write32(reg + 0x88, bits(0));
    put(0x9000, [control, 0x80000000, 0x80000000, 0x80000000, 0x80000000]);
    for (final (offset, value) in [
      (0x2c, 0x9000),
      (0x48, pack),
      (0x4c, pack == 6 ? 16 : 8),
      (0x60, 0x400000),
      (0x68, 31 << 16),
      (0x6c, 31 << 16),
      (0xf4, scale),
    ]) {
      bus.write32(reg + offset, value);
    }
    bus.write32(reg + 0x14, 1);
  }

  Uint8List rgba(RenderFrame frame, List<int> color) => Uint8List.fromList([
        for (var i = 0; i < frame.width * frame.height; i++) ...color,
      ]);

  setUp(() {
    bus = DcBus();
    bus.write32(reg + 8, 0);
    bus.write32(reg + 0x80, 0);
    host = _Frames();
    bus.gpu.render.hostSink = host;
  });

  test('a render left to the host ends without writing VRAM', () {
    render();
    expect(host.frames, hasLength(1));
    expect(host.frames.single.width, 32);
    expect(bus.gpu.render.busy, isTrue);
    bus.tickMasterClocks(2);
    expect(bus.gpu.render.busy, isFalse);
    expect(bus.gpu.vram.getUint32LE(0x400000), 0);
  });

  test('the pixels of the host are written with the pack mode of the render',
      () {
    render(pack: 1);
    final frame = host.frames.single;
    bus.tickMasterClocks(2);
    // The next render changes the registers before the pixels come back.
    bus.write32(reg + 0x48, 6);
    frame.onDrawn!(rgba(frame, [0xff, 0x80, 0x08, 0xff]));
    final rgb565 = (0xff >> 3) << 11 | (0x80 >> 2) << 5 | (0x08 >> 3);
    expect(bus.gpu.vram.getUint16LE(0x400000), rgb565);
    expect(bus.gpu.vram.getUint16LE(0x400000 + 31 * 64 + 62), rgb565);
    expect(bus.gpu.render.read(0x48), 6);
  });

  test('a tile without write-out is not written', () {
    render(control: 0x90000000);
    final frame = host.frames.single;
    frame.onDrawn!(rgba(frame, [1, 2, 3, 255]));
    expect(bus.gpu.vram.getUint32LE(0x400000), 0);
  });

  test('pixels that come back after a reset are dropped', () {
    render();
    final frame = host.frames.single;
    bus.gpu.render.reset(registers: false);
    frame.onDrawn!(rgba(frame, [1, 2, 3, 255]));
    expect(bus.gpu.vram.getUint32LE(0x400000), 0);
  });

  test('a render through the scaler stays with the core renderer', () {
    render(scale: 0x800);
    expect(host.frames, isEmpty);
  });
}
