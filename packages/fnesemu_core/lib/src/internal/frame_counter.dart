class FrameCounter {
  final Duration? duration;
  DateTime _startAt;
  int _frames = 0;

  FrameCounter({this.duration, DateTime? startAt})
      : _startAt = startAt ?? DateTime.now();

  void count() => _frames++;

  // Only publish completed measurement windows.
  double? fps(DateTime now) {
    final elapsedUs = now.difference(_startAt).inMicroseconds;
    if (elapsedUs <= 0 ||
        (duration != null && elapsedUs < duration!.inMicroseconds)) {
      return null;
    }

    final fps = _frames * Duration.microsecondsPerSecond / elapsedUs;
    _frames = 0;
    _startAt = now;
    return fps;
  }
}
