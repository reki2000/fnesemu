import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/memory_card.dart';
import 'package:fnesemu_core/src/core/dc/memory_card_timer.dart';
import 'package:test/test.dart';

void main() {
  const hz = DcMemoryCardTimer.clocksPerSecond;
  for (final (year, month, day) in [
    (1900, 3, 1),
    (2000, 2, 29),
    (2004, 2, 29),
    (2100, 3, 1)
  ]) {
    test('Gregorian February transition for $year', () {
      final timer =
          DcMemoryCardTimer(initialTime: DateTime.utc(year, 2, 28, 23, 59, 59));
      timer.tickMasterClocks(hz - 1);
      expect(timer.time, DateTime.utc(year, 2, 28, 23, 59, 59));
      timer.tickMasterClocks(1);
      expect(timer.time, DateTime.utc(year, month, day));
    });
  }
  test('calendar crosses year and a complete 400-year Gregorian cycle', () {
    final timer =
        DcMemoryCardTimer(initialTime: DateTime.utc(1999, 12, 31, 23, 59, 59));
    timer.tickMasterClocks(hz);
    expect(timer.time, DateTime.utc(2000));
    // A Gregorian 400-year cycle contains exactly 146097 days.
    timer.tickMasterClocks(146097 * 86400 * hz);
    expect(timer.time, DateTime.utc(2400));
  });
  test('fractional seconds survive protocol reset and batch partitioning', () {
    final large = DcMemoryCardTimer(), small = DcMemoryCardTimer();
    large.tickMasterClocks(3 * hz + 17);
    for (final ticks in [17, hz - 1, 1, hz ~/ 2, hz ~/ 2, hz]) {
      small.tickMasterClocks(ticks);
      small.reset();
    }
    expect(small.time, large.time);
    large.tickMasterClocks(hz - 17);
    small.tickMasterClocks(hz - 17);
    expect(small.time, DateTime.utc(2000, 1, 1, 0, 0, 4));
    expect(small.time, large.time);
  });
  test(
      'year overflow and negative clocks stop without normalizing the calendar',
      () {
    final timer =
        DcMemoryCardTimer(initialTime: DateTime.utc(9999, 12, 31, 23, 59, 59));
    expect(() => timer.tickMasterClocks(hz), throwsA(isA<DcUnsupported>()));
    expect(timer.time.year, 9999);
    expect(() => timer.tickMasterClocks(-1), throwsArgumentError);
  });
  test(
      'invalid write is atomic and a valid write restarts the fractional second',
      () {
    final timer = DcMemoryCardTimer();
    timer.tickMasterClocks(hz - 1);
    final bad = Uint8List.fromList(
        [12, 1, 0, 4, 0, 0, 0, 8, 0, 0, 0, 0, 0xd0, 7, 13, 1, 0, 0, 0, 0]);
    expect(timer.command(12, bad).$1, 0xfc);
    timer.tickMasterClocks(1);
    expect(timer.time.second, 1);
    bad[14] = 12;
    bad[15] = 31;
    expect(timer.command(12, bad).$1, 7);
    timer.tickMasterClocks(hz - 1);
    expect(timer.time, DateTime.utc(2000, 12, 31));
    timer.tickMasterClocks(1);
    expect(timer.time.second, 1);
  });
  test(
      'attached memory card clock runs with host DMA disabled and through device kill',
      () {
    final dc = Dc(), memoryCard = DcMemoryCard();
    dc.attachMemoryCard(0, 0, memoryCard);
    dc.bus.tickMasterClocks(3 * hz);
    expect(memoryCard.timer.time.second, 3);
    memoryCard.exchange(Uint8List.fromList([1, 1, 0, 0]), 0);
    memoryCard.exchange(Uint8List.fromList([4, 1, 0, 0]), 0);
    dc.bus.tickMasterClocks(hz);
    expect(memoryCard.timer.time.second, 4);
    dc.reset();
    dc.bus.tickMasterClocks(hz);
    expect(memoryCard.timer.time.second, 5);
  });
  test('descriptor chain samples each RTC read at its own request boundary',
      () {
    final dc = Dc(), memoryCard = DcMemoryCard();
    dc.attachMemoryCard(0, 0, memoryCard);
    final bus = dc.bus;
    final parent = bus.maple.controllers[0]!;
    parent.exchange(Uint8List.fromList([1, 32, 0, 0]), 0);
    parent.exchange(Uint8List.fromList([1, 1, 0, 0]), 0);
    bus.tickMasterClocks(hz - 10000);
    bus.write32(0xffa00040, 0x8201);
    bus.write32(0xa05f6c8c, 0x6155407f);
    bus.write32(0xa05f6ce8, 0);
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
    expect(memoryCard.timer.time.second, 1);
  });
}
