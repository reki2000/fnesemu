import 'dart:math';

import 'package:fnesemu/core/ps/bus.dart';
import 'package:fnesemu/core/ps/gpu/gpu.dart';
import 'package:test/test.dart';

void main() {
  test('renderTexturedGouraudPolygon handles 2000 randomized calls', () {
    final bus = Bus();
    final gpu = Gpu(bus);
    final random = Random(0);

    gpu.drawingX1 = 0;
    gpu.drawingY1 = 0;
    gpu.drawingX2 = 1023;
    gpu.drawingY2 = 511;
    gpu.drawingOffsetX = 0;
    gpu.drawingOffsetY = 0;

    for (int index = 0; index < gpu.frameBuffer16.length; index++) {
      gpu.frameBuffer16[index] = random.nextInt(0x10000);
    }

    int makeVertex() {
      final x = random.nextInt(1024);
      final y = random.nextInt(512);
      return x | (y << 16);
    }

    int makeColor() => random.nextInt(0x1000000);

    int makeTexcoord() {
      final u = random.nextInt(256);
      final v = random.nextInt(256);
      return u | (v << 8);
    }

    int makeClut(int page) {
      final clutMode = (page >> 7) & 0x03;
      final maxClutX = switch (clutMode) {
        1 => 49,
        _ => 64,
      };
      final x = random.nextInt(maxClutX);
      final y = random.nextInt(512);
      return x | (y << 6);
    }

    int makePage(int textureDepth) {
      final baseX = random.nextInt(16);
      final baseY = random.nextInt(2);
      final semiTransparency = random.nextInt(4);
      return (baseX << 4) |
          baseY |
          (semiTransparency << 5) |
          (textureDepth << 7);
    }

    final stopwatch = Stopwatch()..start();

    expect(
      () {
        for (int i = 0; i < 2000; i++) {
          final textureDepth = random.nextInt(3);
          final page = makePage(textureDepth);
          final cmd = makeColor() |
              (random.nextBool() ? (1 << 24) : 0) |
              (random.nextBool() ? (1 << 25) : 0) |
              (random.nextBool() ? (1 << 28) : 0);

          gpu.renderTexturedGouraudPolygon(
            cmd,
            makeClut(page),
            page,
            makeColor(),
            makeVertex(),
            makeTexcoord(),
            makeColor(),
            makeVertex(),
            makeTexcoord(),
            makeColor(),
            makeVertex(),
            makeTexcoord(),
          );
        }
      },
      returnsNormally,
    );

    stopwatch.stop();
    print(
        'renderTexturedGouraudPolygon: 10000 calls in ${stopwatch.elapsedMilliseconds} ms');
  });
}
