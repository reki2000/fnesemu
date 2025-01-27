import 'vdp_renderer.dart';
import 'vdp.dart';
import 'dart:core';

void main() {
  final vdp = Vdp();
  vdp.reset();

  int sum = 0;
  int max = 0;
  int min = 1 << 62;
  const measureCount = 10;

  void exec() {
    for (var i = 0; i < 262 * 10; i++) {
      vdp.renderLine();
    }
  }

  exec(); // warm up

  for (var i = 0; i < measureCount; i++) {
    final startedAt = DateTime.now();

    exec();

    final elapsed = DateTime.now().difference(startedAt).inMicroseconds;
    sum += elapsed;
    max = (elapsed > max) ? elapsed : max;
    min = (elapsed < min) ? elapsed : min;
  }

  print('elapsed: ${sum ~/ measureCount} us (max: $max, min: $min)');
}
