import 'dart:math' as math;

/// Debug-only image work must leave time for emulation and input handling.
/// Fast captures run at most 10 Hz. Slow captures get four capture durations
/// of cooldown, keeping their average synchronous load below about 20%.
class VideoRefresh {
  static const minimumIntervalUs = 100000;
  final int Function() _now;
  int _nextCaptureUs = 0;

  VideoRefresh({int Function()? now}) : _now = now ?? _clock();
  static int Function() _clock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsedMicroseconds;
  }

  bool get ready => _now() >= _nextCaptureUs;

  void capture(void Function() render) {
    final start = _now();
    render();
    final end = _now();
    _nextCaptureUs = end + math.max(minimumIntervalUs, (end - start) * 4);
  }
}
