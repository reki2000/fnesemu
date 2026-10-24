import 'package:fnesemu_core/src/internal/frame_counter.dart';
import 'package:test/test.dart';

void main() {
  final start = DateTime.utc(2026, 1, 1);

  test('emits only after the measurement interval', () {
    final counter = FrameCounter(
        duration: const Duration(milliseconds: 500), startAt: start);
    for (var i = 0; i < 29; i++) {
      counter.count();
    }
    expect(counter.fps(start.add(const Duration(milliseconds: 499))), isNull);
    counter.count();
    expect(counter.fps(start.add(const Duration(milliseconds: 500))), 60);
  });

  test('samples the latest interval instead of a lifetime average', () {
    final counter = FrameCounter(
        duration: const Duration(milliseconds: 500), startAt: start);
    for (var i = 0; i < 10; i++) {
      counter.count();
    }
    expect(counter.fps(start.add(const Duration(milliseconds: 500))), 20);

    for (var i = 0; i < 20; i++) {
      counter.count();
    }
    expect(counter.fps(start.add(const Duration(milliseconds: 999))), isNull);
    expect(counter.fps(start.add(const Duration(seconds: 1))), 40);
  });

  test('uses actual elapsed time when an interval runs late', () {
    final counter = FrameCounter(
        duration: const Duration(milliseconds: 500), startAt: start);
    for (var i = 0; i < 24; i++) {
      counter.count();
    }
    expect(counter.fps(start.add(const Duration(milliseconds: 600))), 40);

    for (var i = 0; i < 15; i++) {
      counter.count();
    }
    expect(counter.fps(start.add(const Duration(milliseconds: 1350))), 20);
  });

  test('does not divide by zero at startup', () {
    final counter = FrameCounter(startAt: start);
    counter.count();
    expect(counter.fps(start), isNull);
    expect(counter.fps(start.add(const Duration(milliseconds: 500))), 2);
  });
}
