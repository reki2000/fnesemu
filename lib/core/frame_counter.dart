class FrameCounter {
  late Duration? duration;

  FrameCounter({this.duration}) {
    startAt =
        DateTime.now().add(duration != null ? -duration! : -const Duration());
    prevStartAt = startAt;
  }

  int frames = 0;
  late DateTime startAt;

  int prevFrames = 0;
  late DateTime prevStartAt;

  count() => frames++;

  elapsedMilliseconds(DateTime now) {
    return now.difference(startAt).inMilliseconds.toDouble();
  }

  fps(DateTime now) {
    if (duration != null && now.difference(startAt) < duration!) {
      prevFrames = frames;
      prevStartAt = startAt;
      frames = 0;
      startAt = now;
    }
    return (frames + prevFrames) * 1000.0 / elapsedMilliseconds(now);
  }
}
