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

}
