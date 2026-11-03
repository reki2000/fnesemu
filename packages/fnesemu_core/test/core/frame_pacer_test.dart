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

}
