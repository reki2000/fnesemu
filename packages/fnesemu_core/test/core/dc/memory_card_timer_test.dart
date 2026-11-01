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

  test('host elapsed time spans years and a 400-year Gregorian cycle', () {
    var now = DateTime.utc(2000);
    final timer = DcMemoryCardTimer(
        clock: () => now,
        initialTime: DateTime.utc(1999, 12, 31, 23, 59, 59));
    now = now.add(const Duration(seconds: 1));
    expect(timer.time, DateTime.utc(2000));
    now = now.add(const Duration(days: 146097));
    expect(timer.time, DateTime.utc(2400));
  });

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
    expect(timer.time, DateTime.utc(2000, 12, 31));
    now = now.add(const Duration(milliseconds: 1));
    expect(timer.time.second, 1);
  });

  test('guest time offsets survive save/load and elapsed host time', () {
    var now = DateTime.utc(2026, 11, 1);
    final timer = DcMemoryCardTimer(clock: () => now);
    final write = Uint8List.fromList(
        [12, 1, 0, 4, 0, 0, 0, 8, 0, 0, 0, 0, 0xe8, 7, 2, 29, 12, 0, 0, 0]);
    expect(timer.command(12, write).$1, 7); // 2024-02-29
    final writer = StateWriter('timer', 1, 0);
    timer.saveState(writer);
    now = now.add(const Duration(hours: 2));
    final restored = DcMemoryCardTimer(clock: () => now);
    restored.loadState(StateReader(writer.take(), 'timer', 1, 0));
    expect(restored.time, DateTime.utc(2024, 2, 29, 14));
    restored.reset();
    expect(restored.time, DateTime.utc(2024, 2, 29, 14));
  });

  test('VMU is based on local calendar fields, not UTC timestamp', () {
    final now = DateTime(2026, 11, 1, 18, 30);
    final timer = DcMemoryCardTimer(clock: () => now);
    expect(timer.time, DateTime.utc(2026, 11, 1, 18, 30));
  });

  test('attached memory card RTC advances when host time changes', () {
    var now = DateTime.utc(2026);
    final dc = Dc(), memoryCard = DcMemoryCard();
    addTearDown(dc.dispose);
    memoryCard.timer.clock = () => now;
    dc.attachMemoryCard(0, 0, memoryCard);
    dc.bus.tickMasterClocks(100000);
    expect(memoryCard.timer.time.second, 0);
    now = now.add(const Duration(seconds: 3));
    expect(memoryCard.timer.time.second, 3);
    memoryCard.exchange(Uint8List.fromList([1, 1, 0, 0]), 0);
    memoryCard.exchange(Uint8List.fromList([4, 1, 0, 0]), 0);
    now = now.add(const Duration(seconds: 1));
    expect(memoryCard.timer.time.second, 4);
    dc.reset();
    now = now.add(const Duration(seconds: 1));
    expect(memoryCard.timer.time.second, 5);
  });

  test('descriptor chain samples each RTC read at its request boundary', () {
    final dc = Dc(), memoryCard = DcMemoryCard();
    addTearDown(dc.dispose);
    dc.attachMemoryCard(0, 0, memoryCard);
    var reads = 0;
    memoryCard.timer.clock =
        () => DateTime.utc(2026, 11, 1, 0, 0, reads++);
    final bus = dc.bus;
    final parent = bus.maple.controllers[0]!;
    parent.exchange(Uint8List.fromList([1, 32, 0, 0]), 0);
    parent.exchange(Uint8List.fromList([1, 1, 0, 0]), 0);
    bus.write32(0xffa00040, 0x8201);
    bus.write32(0xa05f6c8c, 0x6155407f);
    bus.write32(0xa05f6ce8, 1);
    bus.write32(0xa05f6c04, 0x0c010000);
    final bytes = ByteData.sublistView(bus.ram);
    final request = [11, 1, 0, 2, 0, 0, 0, 8, 0, 0, 0, 0];
    for (var i = 0; i < 2; i++) {
      final offset = 0x10000 + i * 20;
      bytes.setUint32(offset, i == 0 ? 2 : 0x80000002, Endian.little);
      bytes.setUint32(offset + 4, 0x0c020000 + i * 32, Endian.little);
      bus.ram.setRange(offset + 8, offset + 20, request);
    }
    bus.write32(0xa05f6c14, 1);
    bus.write32(0xa05f6c18, 1);
    bus.tickMasterClocks(100000);
    expect(bus.ram[0x2000e], 0);
    expect(bus.ram[0x2002e], 1);
    expect(reads, 2);
  });
}
