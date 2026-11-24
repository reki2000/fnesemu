import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:fnesemu_core/src/core/n64/graphics.dart';
import 'package:fnesemu_core/src/core/n64/n64.dart';
import 'package:fnesemu_core/src/core/n64/rdp_compute_shader.dart';
import 'package:gs_compute_check/sink.dart';
import 'package:test/test.dart';

void main() {
  final gpu = WgpuComputeSink.open();
  if (gpu == null) {
    test('N64 RDP compute rectangles', () {}, skip: 'no adapter');
    return;
  }
  tearDownAll(gpu.device.close);

  late N64 software, compute;
  late _ObservedSink sink;

  setUp(() {
    sink = _ObservedSink(gpu);
    software = N64(jit: false);
    compute = N64(jit: false)..computeSink = sink;
    for (final core in [software, compute]) {
      core.bus.ram.fillRange(0x1000, 0x2000, 0x71);
      core.graphics
        ..colorImage = 0x1001
        ..scLeft = 1
        ..scTop = 1
        ..scRight = 13
        ..scBottom = 11
        ..width = 17;
    }
  });

  tearDown(() {
    compute.dispose();
    software.dispose();
  });

  void checkRdram() => expect(
    compute.bus.ram.sublist(0x1000, 0x2000),
    orderedEquals(software.bus.ram.sublist(0x1000, 0x2000)),
  );

  test('fill cycles preserve scissor, pixel parity and zero writes', () {
    for (final size in [2, 3]) {
      for (final core in [software, compute]) {
        core.graphics
          ..colorSize = size
          ..otherHigh = 3 << 20
          ..rdp(0xf7000000, size == 2 ? 0xf8010000 : 0x11223344)
          ..rdp(0xf603c03c, 0);
      }
      checkRdram();
    }
    expect(sink.reads, 2);
  });

  test('RDP command submission waits only when its RDRAM range is used', () {
    const commands = 0x4000;
    final bus = compute.bus;
    final words = [0xef300000, 0, 0xf7000000, 0x12345678, 0xf603c03c, 0];
    for (var i = 0; i < words.length; i++) {
      bus.ramWrite(commands + i * 4, words[i], 4);
    }
    final at = 0x1001 + (2 * 17 + 2) * 2;
    void submit() {
      bus.write(0xa4100000, commands, 4);
      bus.write(0xa4100004, commands + words.length * 4, 4);
    }

    submit();
    expect(sink.prefetches, 1);
    expect(sink.reads, 0);
    expect(bus.read(0x80005000, 4), 0);
    expect(sink.reads, 0);
    expect(bus.read(0x80000000 + at, 2), 0x1234);
    expect(sink.reads, 1);

    submit();
    bus.write(0x80000000 + at, 0xabcd, 2);
    expect(sink.reads, 2);
    expect(bus.ramRead(at, 2), 0xabcd);
    expect(bus.ramRead(at + 2, 2), 0x5678);

    submit();
    bus.write(0xa4040000, 0, 4);
    bus.write(0xa4040004, at & ~7, 4);
    bus.write(0xa4040008, 7, 4);
    expect(sink.reads, 3);
    expect(ByteData.sublistView(bus.sp).getUint16(at & 7), 0x1234);
  });

  test('copy cycles match TMEM formats, flip and transparent texels', () {
    var draws = 0;
    for (final (format, size) in [
      (0, 2),
      (0, 3),
      (2, 0),
      (2, 1),
      (3, 0),
      (3, 1),
      (3, 2),
      (4, 0),
      (4, 1),
    ]) {
      for (final flip in [false, true]) {
        for (final targetSize in [2, 3]) {
          for (final blend in [false, true]) {
            for (final core in [software, compute]) {
              final g = core.graphics
                ..colorSize = targetSize
                ..otherLow = blend ? 1 << 14 : 0
                ..otherHigh = (2 << 20) | (flip ? 3 << 14 : 0);
              g.tiles[0]
                ..format = format
                ..size = size
                ..line = 7
                ..tmem = 511
                ..palette = 13
                ..sMask = flip ? 3 : 0
                ..sMode = 1
                ..tMode = 2
                ..bottom = 7.25;
              core.bus.ram.fillRange(0x1000, 0x2000, 0x71);
              for (var i = 0; i < g.tmem.length; i++) {
                g.tmem[i] = i.isEven ? i * 71 : (i * 37) ^ (i >> 4);
              }
              g.textureRect(0xe403803c, 0x1001, 0xff800000, 0x10000400, flip);
            }
            checkRdram();
            draws++;
          }
        }
      }
    }
    expect(sink.reads, draws);
  });

  void displayList(N64 core, List<int> words, {bool defer = false}) {
    const address = 0x4000;
    for (var i = 0; i < words.length; i++) {
      core.bus.ramWrite(address + 4 * i, words[i], 4);
    }
    core.graphics.displayList(address, defer: defer);
  }

  test('a GPU geometry block transforms, lights and clips loaded vertices', () {
    for (final core in [software, compute]) {
      final g = core.graphics
        ..gpuGeometry = true
        ..scale = Vec3(8, 8, 1)
        ..translate = Vec3(8, 8, 0)
        ..geometry = 1 << 17
        ..combine1 = (4 << 15) | (4 << 9);
      g.model[0] = g.model[5] = 0.5;
      g.lights[0]
        ..r = 128
        ..dz = 1;
      g.lights[1]
        ..r = 64
        ..g = 32
        ..b = 16;
      const address = 0x6800;
      const points = [(-4, 1), (1, 1), (-1, -1)];
      for (var i = 0; i < points.length; i++) {
        final at = address + i * 16;
        final (x, y) = points[i];
        core.bus.ramWrite(at, x, 2);
        core.bus.ramWrite(at + 2, y, 2);
        core.bus.ramWrite(at + 12, 0x00007fff, 4);
      }
      displayList(core, [
        0x04200000, address,
        for (var i = 0; i < 8; i++) ...[0xbf000000, 0x00000a14],
        0xb8000000, 0,
      ]);
      expect(g.vertices[0]!.clip.x, -2);
      expect(g.vertices[0]!.color.r, 192);
      expect(g.triangles, 16);
    }
    checkRdram();
    expect(sink.geometryReads, 1);
  });

  void backgroundTask(N64 core, List<int> words) {
    const microcode = 'RSP Gfx ucode S2DEX fifo 2.08';
    core.bus.ram.setAll(0x5000, microcode.codeUnits);
    for (var i = 0; i < words.length; i++) {
      core.bus.ramWrite(0x4000 + 4 * i, words[i], 4);
    }
    core.graphics.task(0x4000, words.length * 4, 0x5000, 0x800);
  }

  test('scaled S2DEX backgrounds wrap, flip and blend in the GPU tiles', () {
    for (final failRead in [false, true]) {
      sink.failRead = failRead;
      for (final core in [software, compute]) {
        final bus = core.bus;
        bus.ram.fillRange(0x1000, 0x2000, 0x71);
        const object = 0x6000, image = 0x6201;
        final fields = [80, 12, 1, 32, 40, 8, 0, 24];
        for (var i = 0; i < fields.length; i++) {
          bus.ramWrite(object + 2 * i, fields[i], 2);
        }
        bus.ramWrite(object + 16, image, 4);
        bus.ram[object + 23] = 2;
        bus.ramWrite(object + 26, 1, 2);
        bus.ramWrite(object + 28, 512, 2);
        bus.ramWrite(object + 30, 768, 2);
        const texels = [0xf801, 0x07c0, 0x003f, 0x07c1, 0xffc1, 0x07ff];
        for (var i = 0; i < texels.length; i++) {
          bus.ramWrite(image + 2 * i, texels[i], 2);
        }
        backgroundTask(core, [
          0xef000000,
          1 << 14,
          0xfc001000,
          (1 << 15) | (7 << 12) | (3 << 9),
          0xfa000000,
          0x00000080,
          0x09000000,
          object,
          0xdf000000,
          0,
        ]);
        expect(bus.ramRead(0x1001 + (17 + 1) * 2, 2), isNot(0x7171));
      }
      checkRdram();
    }
    expect(sink.reads, 2);
    expect(sink.combinerBatches, 2);
    expect(sink.shaderColorPixels, greaterThan(0));
  });

  test('S2DEX copy reads the earlier GPU fill through RDRAM', () {
    for (final core in [software, compute]) {
      final bus = core.bus;
      const object = 0x6000, image = 0x6203;
      final fields = [0, 68, 0, 16, 0, 20, 0, 16];
      for (var i = 0; i < fields.length; i++) {
        bus.ramWrite(object + 2 * i, fields[i], 2);
      }
      bus.ramWrite(object + 16, image, 4);
      bus.ram[object + 23] = 3;
      backgroundTask(core, [
        0xff180010,
        image,
        0xef300000,
        0,
        0xf7000000,
        0x0060a0ff,
        0xf6010010,
        0,
        0xff100010,
        0x1001,
        0xef200000,
        0,
        0x0a000000,
        object,
        0xdf000000,
        0,
      ]);
      expect(bus.ramRead(0x1001 + (17 + 1) * 2, 2), 0x0329);
    }
    checkRdram();
    expect(sink.reads, 2);
  });

  test('an S2DEX draw can read back its own previous pixel', () {
    for (final scenario in ['copy', 'one-cycle alpha', 'readback failure']) {
      sink.failRead = scenario == 'readback failure';
      for (final core in [software, compute]) {
        final bus = core.bus;
        const object = 0x6000;
        final image = 0x1001 + 17 * 2;
        // The first destination pixel overwrites the second source pixel.
        final fields = [0, 16, 4, 12, 0, 4, 4, 4];
        for (var i = 0; i < fields.length; i++) {
          bus.ramWrite(object + 2 * i, fields[i], 2);
        }
        bus.ramWrite(object + 16, image, 4);
        bus.ram[object + 23] = 2;
        bus.ramWrite(image, 0xf80107c1, 4);
        backgroundTask(core, [
          if (scenario == 'one-cycle alpha') ...[
            0xef000000, 0,
            0xfc000000, (1 << 15) | (3 << 9),
            0xfa000000, 1,
          ] else ...[
            0xef200000, 0,
          ],
          0x0a000000, object,
          0xdf000000, 0,
        ]);
        expect(bus.ramRead(image + 2, 4), 0xf801f801);
      }
      checkRdram();
    }
    expect(sink.reads, 3);
    expect(sink.aliasedPixels, 6);
  });

  test('overlapping RGBA32 source and RGBA16 output retain byte order', () {
    for (final core in [software, compute]) {
      final bus = core.bus;
      const object = 0x6000, image = 0x1103;
      final fields = [0, 8, 0, 8, 0, 4, 0, 4];
      for (var i = 0; i < fields.length; i++) {
        bus.ramWrite(object + 2 * i, fields[i], 2);
      }
      bus.ramWrite(object + 16, image, 4);
      bus.ram[object + 23] = 3;
      bus.ramWrite(image, 0x112233ff, 4);
      bus.ramWrite(image + 4, 0xaabbccff, 4);
      core.graphics
        ..colorImage = image + 4
        ..scLeft = 0
        ..scTop = 0;
      backgroundTask(core, [
        0xef200000, 0,
        0x0a000000, object,
        0xdf000000, 0,
      ]);
      expect(bus.ramRead(image + 4, 4), 0x110d1073);
    }
    checkRdram();
    expect(sink.reads, 1);
    expect(sink.aliasedPixels, 2);
  });

  test('S2DEX feedback preserves writes across GPU dispatches', () {
    const width = 72, height = 60;
    const object = 0x6000, image = 0x1101;
    final length = width * height * 2;
    for (final core in [software, compute]) {
      final bus = core.bus;
      final fields = [0, width * 4, 0, width * 4, 0, height * 4, 0, height * 4];
      for (var i = 0; i < fields.length; i++) {
        bus.ramWrite(object + 2 * i, fields[i], 2);
      }
      bus.ramWrite(object + 16, image, 4);
      bus.ram[object + 23] = 2;
      bus.ram.fillRange(image, image + length + 2, 0);
      bus.ramWrite(image, 0xf801, 2);
      core.graphics
        ..colorImage = image + 2
        ..width = width
        ..scLeft = 0
        ..scRight = width
        ..scTop = 0
        ..scBottom = height;
      backgroundTask(core, [
        0xef200000, 0,
        0x0a000000, object,
        0xdf000000, 0,
      ]);
      expect(bus.ramRead(image + length, 2), 0xf801);
    }
    expect(compute.bus.ram.sublist(image, image + length + 2),
        orderedEquals(software.bus.ram.sublist(image, image + length + 2)));
    expect(sink.reads, 1);
    expect(sink.aliasedDispatches, 2);
    expect(sink.aliasedPixels, width * height);
  });

  test('mixed rectangle batches preserve draw order and TMEM contents', () {
    for (final fail in [false, true]) {
      sink.failRead = fail;
      final readsBefore = sink.reads;
      for (final core in [software, compute]) {
        core.bus.ram.fillRange(0x1000, 0x2000, 0x71);
        core.bus.ramWrite(0x4100, 0x07c1, 2);
        core.graphics.tiles[0]
          ..size = 2
          ..line = 1;
        core.graphics.tmem[0] = 0xf8;
        core.graphics.tmem[1] = 1;
        displayList(core, [
          0xef300000,
          0,
          0xf7000000,
          0x11223344,
          0xf603c03c,
          0,
          0xef200000,
          0,
          0xe403803c,
          0,
          0,
          0,
          0,
          0,
          0xfd100000,
          0x4100,
          0xf3000000,
          0,
          0xe4028028,
          0x00008008,
          0,
          0,
          0,
          0,
          0xef300000,
          0,
          0xf7000000,
          0x55667788,
          0xf6004004,
          0,
          0xb8000000,
          0,
        ]);
      }
      checkRdram();
      expect(sink.reads - readsBefore, 1);
    }
  });

  test('tiles resolve overlapping writes across all draw mask words', () {
    for (final size in [2, 3]) {
      for (final core in [software, compute]) {
        core.bus.ram.fillRange(0x1000, 0x2000, 0x71);
        core.graphics.colorSize = size;
        displayList(core, [
          0xef300000,
          0,
          for (var i = 0; i < n64RdpMaxDraws - 1; i++) ...[
            0xf7000000,
            0xff001100 | i,
            i == 0 ? 0xf603c03c : 0xf6030030,
            i == 0 ? 0 : 0x020020,
          ],
          0xf7000000,
          0,
          0xf6008008,
          0x4004,
          0xb8000000,
          0,
        ]);
        final bytes = size == 2 ? 2 : 4;
        expect(core.bus.ramRead(0x1001 + 18 * bytes, bytes), 0);
        expect(core.bus.ramRead(0x1001 + 17 * bytes, 1), 0x71);
      }
      checkRdram();
    }
    expect(sink.tileDispatches, 2);
    expect(sink.reads, 2);
  });

  test('flat triangles share a batch with rectangles and replay in order', () {
    for (final fail in [false, true]) {
      sink.failRead = fail;
      final readsBefore = sink.reads;
      for (final core in [software, compute]) {
        final g = core.graphics
          ..scale = Vec3(8, 8, 1)
          ..translate = Vec3(8, 8, 0);
        g.vertices[0] = N64Vertex(
          Vec4(-0.75, 0.75, 0, 1),
          Rgba(255, 0, 0, 255),
          0,
          0,
        );
        g.vertices[1] = N64Vertex(
          Vec4(0.25, 0.75, 0, 1),
          Rgba(255, 0, 0, 255),
          0,
          0,
        );
        g.vertices[2] = N64Vertex(
          Vec4(-0.75, -0.25, 0, 1),
          Rgba(255, 0, 0, 255),
          0,
          0,
        );
        core.bus.ram.fillRange(0x1000, 0x2000, 0x71);
        displayList(core, [
          0xef300000,
          0,
          0xf7000000,
          0x11221122,
          0xf603c03c,
          0,
          0xef200000,
          0,
          0xbf000000,
          0x00000a14,
          0xef300000,
          0,
          0xf7000000,
          0x33443344,
          0xf6010010,
          0,
          0xb8000000,
          0,
        ]);
        expect(core.bus.ramRead(0x1001 + (5 * 17 + 4) * 2, 2), 0xffff);
        expect(core.bus.ramRead(0x1001 + (4 * 17 + 4) * 2, 2), 0x3344);
        expect(core.bus.ramRead(0x1001 + (9 * 17 + 9) * 2, 2), 0x1122);
      }
      checkRdram();
      expect(sink.reads - readsBefore, 1);
    }
  });

  test('triangle winding and edge ties match software', () {
    final shade = Rgba(255, 0, 0, 255);
    N64Vertex vertex(double x, double y) =>
        N64Vertex(Vec4(x, -y, 0, 1), shade, 0, 0);
    final a = vertex(2, 2), b = vertex(10, 10), c = vertex(10, 2);
    final fixed = [(a, b, c), (b, a, c), (a, c, vertex(3.25, 9))];
    for (final (first, second, third) in fixed) {
      for (final core in [software, compute]) {
        core.bus.ram.fillRange(0x1000, 0x2000, 0x71);
        core.graphics
          ..scale = Vec3(1, 1, 1)
          ..translate = Vec3(0, 0, 0)
          ..otherHigh = 2 << 20
          ..triangle(first, second, third);
      }
      checkRdram();
    }
    expect(sink.reads, fixed.length);

    for (final core in [software, compute]) {
      core.bus.ram.fillRange(0x1000, 0x2000, 0x71);
      core.graphics
        ..geometry = 1
        ..otherLow = 1 << 5
        ..triangle(a, b, c);
    }
    checkRdram();
    expect(sink.reads, fixed.length + 1);
    expect(compute.graphics.depth, orderedEquals(software.graphics.depth));
  });

  test('depth tests and writes use the latest exact depth in the tile', () {
    const r = 0xf800, b = 0x003e;
    final shade = Rgba(255, 255, 255, 255);
    for (final fail in [false, true]) {
      sink.failRead = fail;
      final priorReads = sink.reads, priorDispatches = sink.tileDispatches;
      for (final core in [software, compute]) {
        final g = core.graphics
          ..scale = Vec3(8, 8, 1)
          ..translate = Vec3(8, 8, 0)
          ..geometry = 1;
        final depth = g.depth;
        depth.fillRange(0, depth.length, double.infinity);
        depth[5 * 17 + 4] = -0.75;
        depth[6 * 17 + 4] = double.nan;
        core.bus.ram.fillRange(0x1000, 0x2000, 0x71);
        for (var i = 0; i < 3; i++) {
          final z = [0.0, 0.25, -0.25][i];
          final first = i * 3;
          g.vertices[first] = N64Vertex(
            Vec4(-0.75, 0.75, z - 0.25, 1),
            shade,
            0,
            0,
          );
          g.vertices[first + 1] = N64Vertex(
            Vec4(0.25, 0.75, z + 0.5, 1),
            shade,
            0,
            0,
          );
          g.vertices[first + 2] = N64Vertex(
            Vec4(-0.75, -0.25, z + 0.25, 1),
            shade,
            0,
            0,
          );
        }
        displayList(core, [
          0xfc000000,
          (3 << 15) | (3 << 9),
          0xef000000,
          0x30,
          0xfa000000,
          0xf80000ff,
          0xbf000000,
          0x000a14,
          0xfa000000,
          0x00f800ff,
          0xbf000000,
          0x1e2832,
          0xef000000,
          0x10,
          0xfa000000,
          0x0000f8ff,
          0xbf000000,
          0x3c4650,
          0xb8000000,
          0,
        ]);
        final a = 5 * 17 + 4, other = 6 * 17 + 4;
        expect(depth[a], -0.75);
        expect(depth[other], 0.265625);
        expect(core.bus.ramRead(0x1001 + 2 * a, 2), 0x7171);
        expect(core.bus.ramRead(0x1001 + 2 * other, 2) & (r | b), b);
      }
      checkRdram();
      expect(
        Uint32List.sublistView(compute.graphics.depth, 0, 17 * 11),
        orderedEquals(
          Uint32List.sublistView(software.graphics.depth, 0, 17 * 11),
        ),
      );
      expect(sink.reads - priorReads, 1);
      expect(sink.tileDispatches - priorDispatches, 1);
    }
  });

  test('depth tiles round trip the binary64 fraction words', () {
    final shade = Rgba(255, 255, 255, 255);
    final a = N64Vertex(Vec4(0, 0, 700.00390625, 1), shade, 0, 0);
    final b = N64Vertex(Vec4(256, 0, -700, 1), shade, 0, 0);
    final c = N64Vertex(Vec4(0, -32, 13.94921875, 1), shade, 0, 0);
    for (final core in [software, compute]) {
      core.graphics
        ..scale = Vec3(1, 1, 1)
        ..translate = Vec3(0, 0, 0)
        ..width = 256
        ..scRight = 256
        ..scBottom = 32
        ..otherHigh = 2 << 20
        ..geometry = 1
        ..otherLow = 1 << 5
        ..triangle(a, b, c);
    }
    final aWords = Uint32List.sublistView(software.graphics.depth, 0, 8192);
    final bWords = Uint32List.sublistView(compute.graphics.depth, 0, 8192);
    expect(
      [
        for (var i = 0; i < aWords.length; i += 2) aWords[i],
      ].any((word) => word != 0),
      isTrue,
    );
    expect(bWords, orderedEquals(aWords));
    expect(sink.tileDispatches, 1);
    expect(sink.reads, 1);
  });

  test(
    'textured triangles sample TMEM, blend and update the same depth tile',
    () {
      final a = N64Vertex(Vec4(2, -2, -0.25, 1), Rgba(), -2, -1);
      final b = N64Vertex(Vec4(10, -2, 0.25, 1), Rgba(), 6, -1);
      final c = N64Vertex(Vec4(2, -10, 0, 1), Rgba(), -2, 7);
      final bPerspective = N64Vertex(Vec4(20, -4, 0.5, 2), Rgba(), 6, -1);
      final cPerspective = N64Vertex(Vec4(8, -40, 0, 4), Rgba(), -2, 7);
      for (final (targetSize, cycle, fail) in [
        (2, 2, false),
        (3, 0, false),
        (2, 2, true),
      ]) {
        final priorReads = sink.reads, priorTiles = sink.tileDispatches;
        sink.failRead = fail;
        for (final core in [software, compute]) {
          final g = core.graphics
            ..scale = Vec3(1, 1, 1)
            ..translate = Vec3(0, 0, 0)
            ..colorSize = targetSize
            ..otherHigh = cycle << 20
            ..otherLow = (1 << 14) | 0x30
            ..combine1 = (1 << 15) | (1 << 9)
            ..geometry = 1
            ..textureOn = true;
          g.depth.fillRange(0, g.depth.length, double.infinity);
          core.bus.ram.fillRange(0x1000, 0x2000, 0x71);
          g.tiles[0]
            ..size = 3
            ..line = 2
            ..sMode = 1
            ..sMask = 2
            ..sShift = 1
            ..tMode = 2
            ..tMask = 0
            ..top = 0.25
            ..bottom = 3.25;
          for (var i = 0; i < 64; i += 4) {
            g.tmem.setRange(i, i + 4, [
              200 - i,
              4 * i,
              i * 3,
              i % 12 == 0 ? 0 : 127,
            ]);
          }
          g.triangle(
            a,
            cycle == 0 ? bPerspective : b,
            cycle == 0 ? cPerspective : c,
          );
          final painted = g.depth.take(17 * 11).where((z) => z.isFinite).length;
          expect(painted, allOf(greaterThan(0), lessThan(36)));
        }
        checkRdram();
        expect(
          Uint32List.sublistView(compute.graphics.depth, 0, 17 * 11),
          orderedEquals(
            Uint32List.sublistView(software.graphics.depth, 0, 17 * 11),
          ),
        );
        expect(sink.reads, priorReads + 1);
        expect(sink.tileDispatches, priorTiles + 1);
      }
    },
  );

  test('the GPU combines interpolated shade and texels through two cycles', () {
    const first = (1 << 20) | (4 << 15) | (7 << 12) | (7 << 9);
    const second = (8 << 5) | 31;
    const firstInputs = (15 << 28) | (7 << 15) | (7 << 12) | (1 << 9);
    const secondInputs = (15 << 24) | (7 << 21) | (7 << 18) | (7 << 3);
    for (final core in [software, compute]) {
      final g = core.graphics
        ..scale = Vec3(1, 1, 1)
        ..translate = Vec3(0, 0, 0)
        ..otherHigh = 1 << 20
        ..combine0 = first | second
        ..combine1 = firstInputs | secondInputs
        ..otherLow = 0x30
        ..geometry = 1
        ..textureOn = true;
      g.tiles[0].size = 3;
      g.tmem.setRange(0, 4, [96, 128, 192, 200]);
      g.triangle(
        N64Vertex(Vec4(2, -2, 0.25, 1), Rgba(64, 168, 224, 255), 0, 0),
        N64Vertex(Vec4(10, -2, 0.25, 1), Rgba(80, 168, 224, 255), 0, 0),
        N64Vertex(Vec4(2, -10, 0.25, 1), Rgba(64, 168, 224, 255), 0, 0),
      );
      expect(g.depth[3 * 17 + 4], 0.25);
      expect(core.bus.ramRead(0x1001 + (3 * 17 + 4) * 2, 2), 0x1aab);
    }
    checkRdram();
    expect(sink.combinerBatches, 1);
  });

  test('arbitrary projected triangles execute the fragment shader', () {
    const combine0 = (1 << 20) | (4 << 15) | (7 << 12) | (7 << 9);
    const combine1 = (15 << 28) | (7 << 15) | (7 << 12) | (1 << 9);
    for (final core in [software, compute]) {
      final g = core.graphics
        ..scale = Vec3(1, 1, 1)
        ..translate = Vec3(0, 0, 0)
        ..otherHigh = 0
        ..combine0 = combine0
        ..combine1 = combine1
        ..otherLow = 0x30
        ..geometry = 1
        ..textureOn = true;
      g.tiles[0]
        ..size = 3
        ..line = 2
        ..sMask = 2
        ..tMask = 2;
      for (var i = 0; i < 64; i += 4) {
        g.tmem.setRange(i, i + 4, [96 + i, 128 - i, 192 + i, 200]);
      }
      g.triangle(
        N64Vertex(
          Vec4(2.1, -2.2, -0.11, 1),
          Rgba(64, 168, 224, 255),
          -1.731,
          0.135,
        ),
        N64Vertex(
          Vec4(20.1, -4.1, 0.49, 2),
          Rgba(80, 168, 224, 255),
          6.794,
          -1.156,
        ),
        N64Vertex(
          Vec4(2.4, -10.1, 0.35, 1),
          Rgba(64, 168, 224, 255),
          0.371,
          6.139,
        ),
      );
      expect(g.depth[3 * 17 + 4].isFinite, isTrue);
    }
    checkRdram();
    final expectedDepth = software.graphics.depth;
    final renderedDepth = compute.graphics.depth;
    for (var i = 0; i < 17 * 11; i++) {
      final expected = expectedDepth[i];
      expect(renderedDepth[i], expected.isFinite ? closeTo(expected, 1e-6) : expected);
    }
    expect(sink.fragmentBatches, 1);
    expect(sink.compactDepthBatches, 1);
  });

  test('the fragment shader preserves shade above the byte range', () {
    const combine0 = (1 << 20) | (4 << 15) | (7 << 12) | (7 << 9);
    const combine1 = (15 << 28) | (7 << 15) | (7 << 12) | (1 << 9);
    for (final core in [software, compute]) {
      final g = core.graphics
        ..scale = Vec3(1, 1, 1)
        ..translate = Vec3(0, 0, 0)
        ..otherHigh = 0
        ..combine0 = combine0
        ..combine1 = combine1
        ..textureOn = true;
      g.tiles[0].size = 3;
      g.tmem.setRange(0, 4, [96, 128, 192, 200]);
      g.triangle(
        N64Vertex(Vec4(2.1, -2.2, 0.25, 1), Rgba(384, 168, 224, 255), 0, 0),
        N64Vertex(Vec4(10.1, -2.1, 0.25, 1), Rgba(400, 168, 224, 255), 0, 0),
        N64Vertex(Vec4(2.4, -10.1, 0.25, 1), Rgba(500, 168, 224, 255), 0, 0),
      );
      expect(core.bus.ramRead(0x1001 + (3 * 17 + 4) * 2, 2), 0x9aab);
    }
    checkRdram();
    expect(sink.fragmentBatches, 1);
  });

  test('GPU coverage includes shared edges and interpolates depth', () {
    final shade = Rgba();
    for (final core in [software, compute]) {
      final g = core.graphics
        ..scale = Vec3(1, 1, 1)
        ..translate = Vec3(0, 0, 0)
        ..otherHigh = 2 << 20
        ..geometry = 1
        ..otherLow = 0x30;
      g.triangle(
        N64Vertex(Vec4(2.125, -2.875, 1.2, 1), shade, 0, 0),
        N64Vertex(Vec4(10.125, -2.875, -1.08, 1), shade, 0, 0),
        N64Vertex(Vec4(2.125, -10.875, 1.4, 1), shade, 0, 0),
      );
    }
    checkRdram();
    final expectedDepth = software.graphics.depth;
    final renderedDepth = compute.graphics.depth;
    for (var i = 0; i < 17 * 11; i++) {
      final expected = expectedDepth[i];
      expect(renderedDepth[i], expected.isFinite ? closeTo(expected, 1e-6) : expected);
    }
    expect(sink.fragmentBatches, 1);
    expect(sink.shaderColorPixels, greaterThan(0));
  });

  test('GPU samples texture coordinate boundaries without depth or blending', () {
    final shade = Rgba();
    for (final core in [software, compute]) {
      final g = core.graphics
        ..scale = Vec3(1, 1, 1)
        ..translate = Vec3(0, 0, 0)
        ..otherHigh = 2 << 20
        ..textureOn = true;
      g.tiles[0]
        ..size = 3
        ..sMask = 2;
      for (var i = 0; i < 16; i += 4) {
        g.tmem.setRange(i, i + 4, [220 - i * 4, 15, 90, 255]);
      }
      g.triangle(
        N64Vertex(Vec4(2.125, -2.125, 0, 1), shade, 1.625, 0),
        N64Vertex(Vec4(10.125, -2.125, 0, 1), shade, 9.625, 0),
        N64Vertex(Vec4(2.125, -10.125, 0, 1), shade, 1.625, 0),
      );
    }
    checkRdram();
    expect(sink.fragmentBatches, 1);
  });

  test('decal triangles resolve depth ties on the GPU', () {
    final shade = Rgba(80, 168, 224, 255);
    for (final core in [software, compute]) {
      final g = core.graphics
        ..scale = Vec3(1, 1, 1)
        ..translate = Vec3(0, 0, 0)
        ..otherLow = (3 << 10) | 0x30
        ..combine1 = (4 << 15) | (4 << 9)
        ..geometry = 1;
      final depth = g.depth;
      depth[3 * 17 + 4] = 0.5;
      depth[3 * 17 + 5] = 1.25;
      g.triangle(
        N64Vertex(Vec4(2.1, -2.2, 0.25, 1), shade, 0, 0),
        N64Vertex(Vec4(10.1, -2.1, 0.25, 1), shade, 0, 0),
        N64Vertex(Vec4(2.4, -10.1, 0.25, 1), shade, 0, 0),
      );
      expect(core.bus.ramRead(0x1001 + (3 * 17 + 6) * 2, 2), 0x7171);
      expect(core.bus.ramRead(0x1001 + (3 * 17 + 4) * 2, 2), 0x5579);
    }
    checkRdram();
    expect(
      Uint32List.sublistView(compute.graphics.depth, 0, 17 * 11),
      orderedEquals(
        Uint32List.sublistView(software.graphics.depth, 0, 17 * 11),
      ),
    );
    expect(sink.fragmentBatches, 1);
    expect(sink.shaderColorPixels, 2);
  });

  test('one-cycle rectangles retain each draw’s combiner colors', () {
    for (final core in [software, compute]) {
      core.graphics.tiles[0].size = 3;
      displayList(core, [
        0xfc000000,
        (3 << 15) | (3 << 9),
        0xfa000000,
        0xf00000ff,
        0xe4030030,
        0,
        0,
        0,
        0,
        0,
        0xfa000000,
        0x00f000ff,
        0xe4018018,
        0,
        0,
        0,
        0,
        0,
        0xb8000000,
        0,
      ]);
      expect(core.bus.ramRead(0x1001 + (2 * 17 + 2) * 2, 2), 0x0781);
      expect(core.bus.ramRead(0x1001 + (8 * 17 + 8) * 2, 2), 0xf001);
    }
    checkRdram();
    expect(sink.combinerBatches, 1);
  });

  test('GPU combiner rounds colors on pixel boundaries', () {
    for (final core in [software, compute]) {
      final g = core.graphics
        ..scale = Vec3(1, 1, 1)
        ..translate = Vec3(0, 0, 0)
        ..colorSize = 3
        ..combine1 = (4 << 15) | (4 << 9);
      g.tiles[0].size = 3;
      for (final r in [101.5, 102.0]) {
        g.textureOn = r == 102.0;
        g.otherLow = r == 101.5 ? 1 << 14 : 0;
        final varying = r == 101.5;
        final a = Rgba(varying ? 101 : r, 60, 73, 255);
        final b = Rgba(varying ? 105 : r, 60, 73, 255);
        final c = Rgba(varying ? 97 : r, 60, 73, 255);
        g.triangle(
          N64Vertex(Vec4(2, -2, 0, 1), a, 0, 0),
          N64Vertex(Vec4(10, -2, 0, 1), b, 0, 0),
          N64Vertex(Vec4(2, -10, 0, 1), c, 0, 0),
        );
        expect(core.bus.ramRead(0x1001 + (3 * 17 + 4) * 4, 4), 0x663c49ff);
      }
    }
    checkRdram();
    expect(sink.combinerBatches, 2);
  });

  test('a texture load observes queued writes to overlapping RDRAM', () {
    for (final core in [software, compute]) {
      displayList(core, [
        0xef300000,
        0,
        0xf7000000,
        0x01234567,
        0xf603c03c,
        0,
        0xfd100000,
        0x1025,
        0xf3000000,
        0,
        0xf603c03c,
        0,
        0xb8000000,
        0,
      ]);
      expect(core.graphics.tmem.sublist(0, 2), [0x45, 0x67]);
    }
    checkRdram();
    expect(sink.reads, 2);
  });

  test('solid rectangles combine and blend with earlier fills on the GPU', () {
    for (final failRead in [false, true]) {
      sink.failRead = failRead;
      for (final core in [software, compute]) {
        displayList(core, [
          0xef300000,
          0,
          0xf7000000,
          0x001f001f,
          0xf603c03c,
          0,
          0xef000000,
          1 << 14,
          0xfc000000,
          (3 << 15) | (3 << 9),
          0xfa000000,
          0xff000080,
          0xf6020024,
          0x00800c,
          0xb8000000,
          0,
        ]);
        expect(core.bus.ramRead(0x1001 + (3 * 17 + 2) * 2, 2), 0x800f);
        expect(core.bus.ramRead(0x1001 + (2 * 17 + 2) * 2, 2), 0x001f);
      }
      checkRdram();
    }
    expect(sink.reads, 2);
    expect(sink.combinerBatches, 2);
    expect(sink.shaderColorPixels, greaterThan(0));
  });

  test('copy blends with RDRAM and a standalone clear updates guest depth', () {
    for (final core in [software, compute]) {
      core.graphics
        ..otherHigh = 2 << 20
        ..otherLow = 1 << 14
        ..tiles[0].size = 3;
      core.graphics
        ..tmem[0] = 255
        ..tmem[3] = 127
        ..textureRect(0xe403803c, 0, 0, 0, false)
        ..zImage = 0x1001
        ..otherHigh = 3 << 20
        ..depth[17] = 1
        ..rdp(0xf603c03c, 0);
      expect(core.graphics.depth[17], double.infinity);
    }
    checkRdram();
    expect(sink.reads, 1);
    expect(sink.tileDispatches, 1);
  });

  test('depth clears preserve draw order within a single tile batch', () {
    for (final scenario in ['middle', 'first and middle', 'last', 'readback failure']) {
      sink.failRead = scenario == 'readback failure';
      final readsBefore = sink.reads;
      for (final core in [software, compute]) {
        core.bus.ram.fillRange(0x1000, 0x2000, 0x71);
        final g = core.graphics
          ..scale = Vec3(8, 8, 1)
          ..translate = Vec3(8, 8, 0)
          ..colorImage = 0x1001
          ..zImage = 0x2000
          ..geometry = 1
          ..otherLow = 0x30
          ..combine1 = (4 << 15) | (4 << 9);
        g.depth.fillRange(0, g.depth.length, scenario == 'first and middle' ? -1 : 0);
        final red = Rgba(255, 0, 0, 255), green = Rgba(0, 255, 0, 255);
        final positions = [
          (-0.75, 0.75),
          (0.25, 0.75),
          (-0.75, -0.25),
          (-0.75, 0.75),
          (0.0, 0.75),
          (-0.75, 0.0),
        ];
        for (var i = 0; i < positions.length; i++) {
          final (x, y) = positions[i];
          g.vertices[i] =
              N64Vertex(Vec4(x, y, i < 3 ? -0.5 : 0.5, 1), i < 3 ? red : green, 0, 0);
        }
        displayList(core, [
          if (scenario == 'first and middle') ...[
            0xff100010, 0x2000,
            0xf6000000, 0,
            0xff100010, 0x1001,
          ],
          0xbf000000, 0x00000a14,
          0xff100010, 0x2000,
          0xf6000000, 0,
          0xff100010, 0x1001,
          0xbf000000, 0x001e2832,
          if (scenario == 'last') ...[
            0xff100010, 0x2000,
            0xf6000000, 0,
          ],
          0xb8000000, 0,
        ]);
        final greenPixel = 3 * 17 + 3, redPixel = 3 * 17 + 7;
        expect(core.bus.ramRead(0x1001 + greenPixel * 2, 2), 0x07c1);
        expect(core.bus.ramRead(0x1001 + redPixel * 2, 2), 0xf801,
            reason: '$scenario ${identical(core, compute) ? "GPU" : "CPU"}');
        expect(g.depth[greenPixel], scenario == 'last' ? double.infinity : 0.5);
        expect(g.depth[redPixel], double.infinity);
        expect(g.depth.last, double.infinity);
      }
      checkRdram();
      expect(
        Uint32List.sublistView(compute.graphics.depth, 0, 17 * 11),
        orderedEquals(Uint32List.sublistView(software.graphics.depth, 0, 17 * 11)),
      );
      expect(sink.reads - readsBefore, 1);
    }
  });

  test('the next draw reuses GPU depth after committing the earlier color', () {
    final g = compute.graphics
      ..scale = Vec3(8, 8, 1)
      ..translate = Vec3(8, 8, 0)
      ..zImage = 0x2000
      ..geometry = 1
      ..otherLow = 0x30
      ..combine1 = (4 << 15) | (4 << 9);
    final red = Rgba(255, 0, 0, 255), green = Rgba(0, 255, 0, 255);
    List<N64Vertex> vertices(double z, Rgba shade) => [
      N64Vertex(Vec4(-0.75, 0.75, z, 1), shade, 0, 0),
      N64Vertex(Vec4(0.25, 0.75, z, 1), shade, 0, 0),
      N64Vertex(Vec4(-0.75, -0.25, z, 1), shade, 0, 0),
    ];
    g.vertices.setRange(0, 3, vertices(0.25, red));
    displayList(compute, [
      0xff100010, 0x2000,
      0xf6000000, 0,
      0xff100010, 0x1001,
      0xbf000000, 0x00000a14,
      0xb8000000, 0,
    ]);
    final behind = vertices(0.75, green);
    g.triangle(behind[0], behind[1], behind[2]);
    final index = 3 * 17 + 3;
    expect(compute.bus.ramRead(0x1001 + index * 2, 2), 0xf801);
    expect(g.depth[index], 0.25);
    expect(sink.residentDepthBatches, 2);
    expect(sink.outputUploads, 0);
    expect(sink.reads, 2);
  });

  test('RDRAM reads leave cleared depth on the GPU until it is requested', () {
    final g = compute.graphics
      ..scale = Vec3(8, 8, 1)
      ..translate = Vec3(8, 8, 0)
      ..zImage = 0x2000
      ..geometry = 1
      ..otherLow = 0x30
      ..combine1 = (4 << 15) | (4 << 9);
    final shade = Rgba(255, 0, 0, 255);
    g.vertices.setRange(0, 3, [
      N64Vertex(Vec4(-0.75, 0.75, 0.25, 1), shade, 0, 0),
      N64Vertex(Vec4(0.25, 0.75, 0.25, 1), shade, 0, 0),
      N64Vertex(Vec4(-0.75, -0.25, 0.25, 1), shade, 0, 0),
    ]);
    for (final failRead in [false, true]) {
      sink.failRead = false;
      // Request depth mutably only once, after both GPU batches.
      displayList(compute, [
        0xff100010, 0x2000,
        0xf6000000, 0,
        0xff100010, 0x1001,
        0xbf000000, 0x00000a14,
        0xb8000000, 0,
      ], defer: true);
      final index = 3 * 17 + 3, at = 0x1001 + index * 2;
      final colorBytes = sink.colorReadBytes;
      expect(compute.bus.ramRead(at, 2), 0xf801);
      expect(sink.colorReadBytes - colorBytes, 8 * 8 * 4);
      final reads = sink.depthReads;
      compute.bus.ramWrite(at, 0x07c1, 2);
      g.syncCompute();
      expect(sink.depthReads, reads);
      sink.failRead = failRead;
      g.syncCompute(depth: true);
      expect(sink.depthReads, reads + 1);
      expect(compute.bus.ramRead(at, 2), 0x07c1);
    }
    expect(g.depth[3 * 17 + 3], 0.25);
    expect(sink.colorOnlyBatches, 2);
  });

  test('a failed partial read preserves guest writes to settled color tiles', () {
    final g = compute.graphics
      ..scale = Vec3(8, 8, 1)
      ..translate = Vec3(8, 8, 0)
      ..zImage = 0x2000
      ..geometry = 1
      ..otherLow = 0x30
      ..combine1 = (4 << 15) | (4 << 9);
    final shade = Rgba(255, 0, 0, 255);
    g.vertices.setRange(0, 3, [
      N64Vertex(Vec4(-0.75, 0.75, 0.25, 1), shade, 0, 0),
      N64Vertex(Vec4(0.5, 0.75, 0.25, 1), shade, 0, 0),
      N64Vertex(Vec4(-0.75, -0.5, 0.25, 1), shade, 0, 0),
    ]);
    displayList(compute, [
      0xff100010, 0x2000,
      0xf6000000, 0,
      0xff100010, 0x1001,
      0xbf000000, 0x00000a14,
      0xb8000000, 0,
    ], defer: true);
    final left = 0x1001 + (3 * 17 + 3) * 2;
    final right = 0x1001 + (3 * 17 + 8) * 2;
    expect(compute.bus.ramRead(left, 2), 0xf801);
    compute.bus.ramWrite(left, 0x07c1, 2);
    sink.failRead = true;
    expect(compute.bus.ramRead(right, 2), 0xf801);
    expect(compute.bus.ramRead(left, 2), 0x07c1);
    expect(g.depth[3 * 17 + 3], 0.25);
    expect(g.depth[3 * 17 + 8], 0.25);
  });

  test('depth tests upload existing depth and read back only color', () {
    final shade = Rgba(255, 0, 0, 255);
    for (final core in [software, compute]) {
      final g = core.graphics
        ..scale = Vec3(1, 1, 1)
        ..translate = Vec3(0, 0, 0)
        ..geometry = 1
        ..otherLow = 0x10
        ..combine1 = (4 << 15) | (4 << 9);
      final index = 3 * 17 + 3;
      g.depth[index] = 0.5;
      g.triangle(
        N64Vertex(Vec4(2.1, -2.1, 0.25, 1), shade, 0, 0),
        N64Vertex(Vec4(10.1, -2.1, 0.25, 1), shade, 0, 0),
        N64Vertex(Vec4(2.1, -10.1, 0.25, 1), shade, 0, 0),
      );
      expect(g.depth[index], 0.5);
      expect(core.bus.ramRead(0x1001 + index * 2, 2), 0xf801);
    }
    checkRdram();
    expect(sink.colorOnlyBatches, 1);
    expect(sink.outputUploads, 1);
  });

  test('the next batch blends with the color retained on the GPU', () {
    for (final core in [software, compute]) {
      displayList(core, [
        0xef000000, 1 << 14,
        0xfc000000, (3 << 15) | (3 << 9),
        0xfa000000, 0,
        for (var i = 0; i < n64RdpMaxDraws - 1; i++) ...[
          0xf6020024, 0x00800c,
        ],
        0xfa000000, 0xff000080,
        0xf6020024, 0x00800c,
        0xfa000000, 0x0000ff80,
        0xf6020024, 0x00800c,
        0xb8000000, 0,
      ]);
    }
    checkRdram();
    expect(sink.reads, 2);
    expect(sink.outputUploads, 1);
    expect(sink.cachedColorBatches, 1);
  });

  test('blended copies read the latest color in the tile', () {
    for (final size in [2, 3]) {
      for (final core in [software, compute]) {
        core.bus.ram.fillRange(0x1000, 0x2000, 0x71);
        final g = core.graphics..colorSize = size;
        g.tiles[0].size = 3;
        g.tmem.setRange(0, 4, [231, 18, 94, 127]);
        displayList(core, [
          0xef300000,
          0,
          0xf7000000,
          0x0600f8c2,
          0xf6020020,
          0,
          0xef200000,
          1 << 14,
          0xe402c02c,
          0,
          0,
          0,
          0,
          0,
          0xe4018018,
          0,
          0,
          0,
          0,
          0,
          0xb8000000,
          0,
        ]);
      }
      checkRdram();
    }
    expect(sink.tileDispatches, 2);
    expect(sink.reads, 2);
  });

  test('readback failure retries the draw in software', () {
    sink.failRead = true;
    for (final color in [0xf80107c1, 0x003f0000]) {
      for (final core in [software, compute]) {
        core.graphics
          ..otherHigh = 3 << 20
          ..rdp(0xf7000000, color)
          ..rdp(0xf603c03c, 0);
      }
      checkRdram();
      expect(sink.reads, 1);
    }
  });
}

class _ObservedSink implements ComputeSink {
  _ObservedSink(this.gpu);

  final WgpuComputeSink gpu;
  int reads = 0, tileDispatches = 0;
  int residentDepthBatches = 0, outputUploads = 0;
  int cachedColorBatches = 0;
  int compactDepthBatches = 0, colorOnlyBatches = 0;
  int prefetches = 0;
  int geometryReads = 0, depthReads = 0;
  int colorReadBytes = 0;
  int aliasedDispatches = 0, aliasedPixels = 0;
  int combinerBatches = 0, fragmentBatches = 0;
  bool failRead = false;
  int shaderColorPixels = 0;

  @override
  String get name => gpu.name;

  @override
  bool get waits => gpu.waits;

  @override
  ComputeProgram program(
    String wgsl,
    List<String> entries,
    List<ComputeBinding> bindings, {
    required int paramStride,
    required int maxDispatches,
  }) {
    return _ObservedProgram(
      this,
      gpu.program(
        wgsl,
        entries,
        bindings,
        paramStride: paramStride,
        maxDispatches: maxDispatches,
      ),
      entries.first == 'transformVertices',
    );
  }
}

class _ObservedProgram implements ComputeProgram {
  _ObservedProgram(this.sink, this.inner, this.geometry);

  final _ObservedSink sink;
  final ComputeProgram inner;
  final bool geometry;

  int _tileFlags = 0;
  int _depthWords = 0;
  bool _tiled = false, _aliased = false;

  @override
  void write(
    int binding,
    int byteOffset,
    Uint32List words, [
    int start = 0,
    int? end,
  ]) {
    if (binding == 3) {
      _tileFlags = words[0];
      _depthWords = (words[2] >> 2) & 3;
    }
    if (binding == 0 && byteOffset == n64RdpTileSeedOffset * 4) {
      sink.outputUploads++;
    }
    if (binding == 2 && end! <= 16 * n64RdpMaxDraws) {
      for (var p = 0; p < end; p += 16) {
        if (words[p + 11] == 5) {
          sink.fragmentBatches++;
          break;
        }
      }
    }
    inner.write(binding, byteOffset, words, start, end);
  }

  @override
  void run(
    Uint32List dispatches,
    int count,
    Uint32List params, {
    bool wait = true,
  }) {
    if (geometry) {
      inner.run(dispatches, count, params, wait: wait);
      return;
    }
    _tiled = dispatches[(count - 1) * 4] == 1;
    _aliased = dispatches[0] == 2;
    if (_aliased) sink.aliasedDispatches += count;
    if (_tiled) {
      sink.tileDispatches++;
      if ((_tileFlags & 4) != 0) sink.combinerBatches++;
      if ((_tileFlags & (1 << 16)) != 0) sink.residentDepthBatches++;
      if ((_tileFlags & (1 << 30)) != 0) sink.cachedColorBatches++;
      if (_depthWords == 1) sink.compactDepthBatches++;
      if (_depthWords == 0) sink.colorOnlyBatches++;
    }
    inner.run(dispatches, count, params, wait: wait);
  }

  @override
  void read(int binding, int byteOffset, Uint32List target) {
    if (geometry) {
      sink.geometryReads++;
      inner.read(binding, byteOffset, target);
      return;
    }
    if (binding == 4) sink.depthReads++;
    if (binding == 1) sink.colorReadBytes += target.lengthInBytes;
    sink.reads++;
    if (sink.failRead) {
      throw Exception('injected readback failure');
    }
    inner.read(binding, byteOffset, target);
    if (_aliased) sink.aliasedPixels += target[0];
    if (_tiled && (_tileFlags & 4) != 0) {
      final packed = (_tileFlags & (1 << 15)) != 0;
      final stride = (packed ? 1 : 2) + _depthWords;
      for (var i = packed ? 0 : 1; i < target.length; i += stride) {
        final flags = packed ? target[i] >>> 16 : target[i];
        if ((flags & 1) != 0) sink.shaderColorPixels++;
      }
    }
  }

  @override
  void dispose() => inner.dispose();

  @override
  Future<void>? get fetching => inner.fetching;

  @override
  void prefetch(int binding, int byteOffset, int bytes) {
    sink.prefetches++;
    inner.prefetch(binding, byteOffset, bytes);
  }
}
