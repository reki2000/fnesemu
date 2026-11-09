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

  // An untextured red background and the region entries of [tiles] by
  // [tiles] tiles, written to a framebuffer at 0x400000 that is 32 pixels
  // wide for one tile.
  void render(
      {int pack = 6,
      int control = 0x80000000,
      int scale = 0x400,
      int isp = 0,
      List<int> colors = const [0xffff0000, 0xffff0000, 0xffff0000],
      List<int> lists = const [0x80000000, 0x80000000],
      int tiles = 1}) {
    final words = <int>[isp, 0, 0];
    for (var i = 0; i < 3; i++) {
      words.addAll([
        bits(i == 1 ? 32.0 : 0.0),
        bits(i == 2 ? 32.0 : 0.0),
        bits(1),
        colors[i]
      ]);
    }
    put(0x8000, words);
    bus.write32(reg + 0x8c, (1 << 24) | 0x10000);
    bus.write32(reg + 0x88, bits(0));
    final entries = [...lists, for (var i = lists.length; i < 4; i++) 0x80000000];
    put(0x9000, [
      for (var y = 0; y < tiles; y++)
        for (var x = 0; x < tiles; x++) ...[
          (control & ~0x80000000) |
              x << 2 |
              y << 8 |
              (x == tiles - 1 && y == tiles - 1 ? control & 0x80000000 : 0),
          ...entries
        ]
    ]);
    for (final (offset, value) in [
      (0x2c, 0x9000),
      (0x48, pack),
      (0x4c, pack == 6 ? 16 : 8),
      (0x60, 0x400000),
      (0x68, (tiles * 32 - 1) << 16),
      (0x6c, (tiles * 32 - 1) << 16),
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

  // The red channels of the background triangles at their vertices.
  List<(double, double, int)> backgroundReds(RenderFrame frame) {
    final batch = frame.batches.first;
    const n = RenderFrame.vertexFloats;
    return [
      for (var i = batch.first * 3; i < (batch.first + batch.count) * 3; i++)
        (
          frame.vertices[i * n],
          frame.vertices[i * n + 1],
          (frame.vertices[i * n + 5] * 255).round()
        )
    ];
  }

  test('a Gouraud background covers the frame with its plane', () {
    render(
        isp: 0x00800000, colors: [0xff100000, 0xff100000, 0xff900000]);
    final reds = backgroundReds(host.frames.single);
    expect(reds, hasLength(6));
    for (final (_, y, red) in reds) {
      expect(red, 0x10 + (y / 32 * 0x80).round());
    }
  });

  test('a background plane is cut where its colors leave the range', () {
    // Red reaches 0x180 at the far corner and is clamped beyond 0xff.
    render(
        isp: 0x00800000, colors: [0xff000000, 0xffc00000, 0xffc00000]);
    final reds = backgroundReds(host.frames.single);
    expect(reds.length, greaterThan(6));
    for (final (x, y, red) in reds) {
      final plane = ((x + y) / 32 * 0xc0).round();
      expect(red, plane > 255 ? 255 : plane);
    }
  });

  test('the core renderer extends a Gouraud background past its triangle',
      () {
    bus.gpu.render.hostSink = null;
    render(
        isp: 0x00800000, colors: [0xff100000, 0xff100000, 0xff900000]);
    bus.tickMasterClocks(100000);
    // The far corner lies outside the triangle; red follows the plane.
    final pixel = bus.gpu.vram.getUint32LE(0x400000 + 31 * 128 + 31 * 4);
    expect((pixel >> 16) & 255, closeTo(0x10 + 0x80 * 31 / 32, 1));
  });

  // A shadowed opaque triangle and one volume that ends with an inside
  // last polygon, with the shadow intensity 0x80.
  void renderShadow() {
    bus.write32(reg + 0x74, 0x100 | 0x80);
    final triangle = <int>[0xc0000000, 0x20000000, 0];
    for (final (x, y) in [(0.0, 0.0), (32.0, 0.0), (0.0, 32.0)]) {
      triangle.addAll([bits(x), bits(y), bits(2), 0xff804020]);
    }
    put(0xa000, triangle);
    put(0xb000, [0x81000000 | 0xa000 >> 2, 0xf0000000]);
    final volume = <int>[0x20000000, 0, 0];
    for (final (x, y) in [(4.0, 4.0), (20.0, 4.0), (4.0, 20.0)]) {
      volume.addAll([bits(x), bits(y), bits(3)]);
    }
    put(0xc000, volume);
    put(0xd000, [0x80000000 | 0xc000 >> 2, 0xf0000000]);
    render(lists: [0xb000, 0xd000]);
  }

  test('modifier volumes come after the opaque pass with their group', () {
    renderShadow();
    final batches = host.frames.single.batches;
    expect([for (final b in batches) b.pass], [
      RenderBatch.opaque,
      RenderBatch.volume,
      RenderBatch.insideOpaque,
    ]);
    final volume = batches[1];
    expect(volume.count, 1);
    expect(volume.volumeInstruction, 1);
    expect(volume.volumeLayer, 0);
    expect(volume.volumeGroupEnds, isTrue);
  });

  test('a shadowed triangle is replaced inside volumes by scaled colors', () {
    renderShadow();
    final frame = host.frames.single;
    final inside = frame.batches[2];
    expect(inside.depthCompare, 2);
    expect(inside.depthWrite, isFalse);
    const n = RenderFrame.vertexFloats;
    final first = inside.first * 3 * n;
    expect((frame.vertices[first + 5] * 255).round(), 0x40);
    expect((frame.vertices[first + 6] * 255).round(), 0x20);
    expect((frame.vertices[first + 8] * 255).round(), 0xff);
  });

  test('volumes that overlap take separate layers of one group', () {
    // Each volume is one inside last polygon.
    final last = <int>[0x20000000, 0, 0];
    for (final (x, y) in [(4.0, 4.0), (20.0, 4.0), (4.0, 20.0)]) {
      last.addAll([bits(x), bits(y), bits(3)]);
    }
    final apart = [0x20000000, 0, 0];
    for (final (x, y) in [(24.0, 24.0), (31.0, 24.0), (24.0, 31.0)]) {
      apart.addAll([bits(x), bits(y), bits(3)]);
    }
    // Two volumes on the same place, then one apart from both.
    put(0xc000, [...last, ...last, ...apart]);
    put(0xd000, [0x80000000 | 2 << 25 | 0xc000 >> 2, 0xf0000000]);
    render(lists: [0x80000000, 0xd000]);
    final volumes = [
      for (final b in host.frames.single.batches)
        if (b.pass == RenderBatch.volume) b
    ];
    expect([for (final b in volumes) (b.volumeLayer, b.count)], [(0, 2), (1, 1)]);
    expect([for (final b in volumes) b.volumeGroupEnds], [false, true]);
  });

  test('a small triangle behind a large tilted one is drawn first', () {
    // A large translucent triangle whose depth grows to the right, and a
    // small one just behind it on the right side. The mean depth of the
    // small one is nearer than the mean depth of the large one.
    double plane(double x) => 1 + x / 96;
    final words = <int>[];
    for (final (red, vertices) in [
      (0xff, [(0.0, 0.0, 1.0), (96.0, 0.0, 2.0), (0.0, 96.0, 1.0)]),
      (
        0x10,
        [
          for (final (x, y) in [(70.0, 5.0), (80.0, 5.0), (70.0, 15.0)])
            (x, y, plane(x) - 0.01)
        ]
      ),
    ]) {
      words.addAll([0xc0000000, 0x94000000, 0]);
      for (final (x, y, z) in vertices) {
        words.addAll([bits(x), bits(y), bits(z), 0x80000000 | red << 16]);
      }
    }
    put(0xa000, words);
    put(0xb000, [0x80000000 | 1 << 25 | 0xa000 >> 2, 0xf0000000]);
    render(lists: [0x80000000, 0x80000000, 0xb000], tiles: 3);
    final frame = host.frames.single;
    const n = RenderFrame.vertexFloats;
    final reds = [
      for (final b in frame.batches)
        if (b.pass == RenderBatch.translucent)
          for (var t = b.first; t < b.first + b.count; t++)
            (frame.vertices[t * 3 * n + 5] * 255).round()
    ];
    expect(reds, [0x10, 0xff]);
  });

  test('a render through the scaler stays with the core renderer', () {
    render(scale: 0x800);
    expect(host.frames, isEmpty);
  });
}
