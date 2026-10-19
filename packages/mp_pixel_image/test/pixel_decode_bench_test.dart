@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mp_pixel_image/mp_pixel_image.dart';

({double mean, int p50, int p95, int max}) _stats(List<int> input) {
  final values = [...input]..sort();
  final mean = values.reduce((a, b) => a + b) / values.length;
  return (
    mean: mean,
    p50: values[(values.length * 0.5).floor()],
    p95: values[((values.length * 0.95).ceil() - 1).clamp(0, values.length - 1)],
    max: values.last
  );
}

Future<({int scheduleUs, int completeUs})> _decode(
    Uint32List pixels, int width, int height) async {
  final done = Completer<(ui.Image, int)>();
  final watch = Stopwatch()..start();
  decodePixelImage(pixels, width, height,
      (image) => done.complete((image, watch.elapsedMicroseconds)));
  final scheduleUs = watch.elapsedMicroseconds;
  final (image, completeUs) =
      await done.future.timeout(const Duration(seconds: 10));
  image.dispose();
  return (scheduleUs: scheduleUs, completeUs: completeUs);
}

void main() {
  testWidgets('measure raw RGBA upload cost in Flutter tester', (tester) async {
    await tester.runAsync(() async {
      for (final (width, height, samples) in [
        (256, 240, 80),
        (320, 240, 80),
        (640, 480, 60),
      ]) {
        final pixels = Uint32List(width * height)
          ..fillRange(0, width * height, 0xff112233);
        for (var i = 0; i < 15; i++) {
          await _decode(pixels, width, height);
        }
        final schedule = <int>[], complete = <int>[];
        for (var i = 0; i < samples; i++) {
          pixels[0] ^= 0x00010101;
          final timing = await _decode(pixels, width, height);
          schedule.add(timing.scheduleUs);
          complete.add(timing.completeUs);
        }
        final a = _stats(schedule), b = _stats(complete);
        // The runner is flutter_tester (debug), not a release-mode GPU app.
        print('PIXEL_BENCH size=${width}x$height samples=$samples '
            'schedule_us_mean=${a.mean.toStringAsFixed(1)} '
            'schedule_us_p50=${a.p50} schedule_us_p95=${a.p95} '
            'schedule_us_max=${a.max} '
            'complete_us_mean=${b.mean.toStringAsFixed(1)} '
            'complete_us_p50=${b.p50} complete_us_p95=${b.p95} '
            'complete_us_max=${b.max}');
      }
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
