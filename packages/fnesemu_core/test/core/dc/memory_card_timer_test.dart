import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/memory_card.dart';
import 'package:fnesemu_core/src/core/dc/memory_card_timer.dart';
import 'package:fnesemu_core/src/state.dart';
import 'package:test/test.dart';

void main() {
  const hz = DcMemoryCardTimer.clocksPerSecond;

  for (final (year, month, day) in [
    (1900, 3, 1),
    (2000, 2, 29),
    (2004, 2, 29),
    (2100, 3, 1)
  ]) {
    test('host calendar crosses Gregorian February for $year', () {
      var now = DateTime.utc(2026);
      final timer = DcMemoryCardTimer(
          clock: () => now,
          initialTime: DateTime.utc(year, 2, 28, 23, 59, 59));
      // Device cycles alone must not advance the battery-backed clock.
      timer.tickMasterClocks(hz * 2);
      expect(timer.time, DateTime.utc(year, 2, 28, 23, 59, 59));
      now = now.add(const Duration(seconds: 1));
      expect(timer.time, DateTime.utc(year, month, day));
    });
  }


  test('host RTC continues while emulation is idle and after protocol reset', () {
    var now = DateTime.utc(2026, 11, 1, 12, 34, 56);
    final timer = DcMemoryCardTimer(clock: () => now);
    expect(timer.time, DateTime.utc(2026, 11, 1, 12, 34, 56));
    timer.tickMasterClocks(hz * 10);
    expect(timer.time, DateTime.utc(2026, 11, 1, 12, 34, 56));
    timer.reset();
    now = now.add(const Duration(seconds: 4));
    expect(timer.time, DateTime.utc(2026, 11, 1, 12, 35));
  });

  test('invalid writes are atomic and valid writes reset the fraction', () {
    var now = DateTime.utc(2026, 1, 1);
    final timer = DcMemoryCardTimer(
        clock: () => now, initialTime: DateTime.utc(2000));
    now = now.add(const Duration(milliseconds: 999));
    final bad = Uint8List.fromList(
        [12, 1, 0, 4, 0, 0, 0, 8, 0, 0, 0, 0, 0xd0, 7, 13, 1, 0, 0, 0, 0]);
    expect(timer.command(12, bad).$1, 0xfc);
    now = now.add(const Duration(milliseconds: 1));
    expect(timer.time.second, 1);
    bad[14] = 12;
    bad[15] = 31;
    expect(timer.command(12, bad).$1, 7);
    now = now.add(const Duration(milliseconds: 999));
    expect(timer.time.year, 2000);
    expect(timer.time.month, 12);
    expect(timer.time.day, 31);
    expect(timer.time.second, 0);
    now = now.add(const Duration(milliseconds: 1));
    expect(timer.time.second, 1);
  });




}
