import 'dart:math';

import 'package:fnesemu/core/ps/bus.dart';
import 'package:fnesemu/core/ps/gpu/gpu.dart';
import 'package:fnesemu/util/int.dart';
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
      return x | y.shl16;
    }

    int makeColor() => random.nextInt(0x1000000);

    int makeTexcoord() {
      final u = random.nextInt(256);
      final v = random.nextInt(256);
      return u | v.shl8;
    }

    final stopwatch = Stopwatch()..start();

    expect(
      () {
        for (int i = 0; i < 2000; i++) {
          final cmd = makeColor() |
              (random.nextBool() ? 1.shl24 : 0) |
              (random.nextBool() ? 1.shl25 : 0) |
              (random.nextBool() ? 1.shl28 : 0);

          gpu.renderTexturedGouraudPolygon4([
            cmd,
            makeColor(),
            makeVertex(),
            makeTexcoord(),
            makeColor(),
            makeVertex(),
            makeTexcoord(),
            makeColor(),
            makeVertex(),
            makeTexcoord(),
          ]);
        }
      },
      returnsNormally,
    );

    stopwatch.stop();
    print(
        'renderTexturedGouraudPolygon: 10000 calls in ${stopwatch.elapsedMilliseconds} ms');
  });
}
