import 'package:fnesemu_core/src/internal/frame_pacer.dart';
import 'package:test/test.dart';

void main() {
  test('fractional microseconds accumulate without long-term drift', () {
    final pacer = FramePacer();
    const clocksPerFrame = 70224, clockHz = 4194304;
    for (var frame = 1; frame <= 10000; frame++) {
      expect(
          pacer.advance(
              clocksPerFrame: clocksPerFrame,
              clockHz: clockHz,
              minimumDeadlineUs: 0),
          frame * clocksPerFrame * 1000000 ~/ clockHz);
    }
  });

  test('changing the clock frequency preserves the elapsed fraction', () {
    final pacer = FramePacer();
    for (var pair = 1; pair <= 2100; pair++) {
      pacer.advance(clocksPerFrame: 1, clockHz: 3, minimumDeadlineUs: 0);
      expect(pacer.advance(clocksPerFrame: 1, clockHz: 7, minimumDeadlineUs: 0),
          pair * 10 * 1000000 ~/ 21);
    }
  });

  test('an overrun starts a fresh deadline after the required yield', () {
    final pacer = FramePacer();
    int advance(int minimum) => pacer.advance(
        clocksPerFrame: 1, clockHz: 3, minimumDeadlineUs: minimum);
    expect(advance(0), 333333);
    expect(advance(1000000), 1000000);
    expect(advance(0), 1333333);
    expect(advance(0), 1666666);
    expect(advance(0), 2000000);
  });
}
