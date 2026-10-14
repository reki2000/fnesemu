import 'package:fnesemu_core/src/internal/video_refresh.dart';
import 'package:test/test.dart';

void main() {
  test('fast snapshots have a 100 ms cooldown', () {
    var now = 0;
    final refresh = VideoRefresh(now: () => now);
    expect(refresh.ready, true);
    refresh.capture(() => now += 1000);
    now = 100999;
    expect(refresh.ready, false);
    now = 101000;
    expect(refresh.ready, true);
  });
  test('slow snapshots leave four capture durations for other work', () {
    var now = 0;
    final refresh = VideoRefresh(now: () => now);
    refresh.capture(() => now += 150000);
    now = 749999;
    expect(refresh.ready, false);
    now = 750000;
    expect(refresh.ready, true);
  });
}
