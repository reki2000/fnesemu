import 'dart:math';

import 'package:fnesemu_core/src/core/dc/bsc.dart';
import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:test/test.dart';

void main() {
  test(
      'refresh counters require the documented key including RFCR upper six bits',
      () {
    final bsc = DcBsc();
    for (final offset in [28, 32, 36, 40]) {
      bsc.write(offset, 2, 0x1234);
      expect(bsc.read(offset, 2), 0);
    }
    bsc.write(32, 2, 0xa5ab);
    bsc.write(36, 2, 0xa5cd);
    bsc.write(40, 2, 0xa7ff);
    expect(bsc.read(32, 2), 0xab);
    expect(bsc.read(36, 2), 0xcd);
    expect(bsc.read(40, 2), 1023);
  });

  test(
      'all refresh divider settings produce the first match on the correct edge',
      () {
    const divisors = [4, 16, 64, 256, 1024, 2048, 4096];
    for (var setting = 1; setting <= 7; setting++) {
      final bsc = DcBsc();
      bsc.write(28, 2, 0xa500 | (setting << 3));
      bsc.write(36, 2, 0xa503);
      bsc.tickBusClocks(divisors[setting - 1] * 3 - 1);
      expect(bsc.read(40, 2), 0);
      bsc.tickBusClocks(1);
      expect(bsc.read(32, 2), 0);
      expect(bsc.read(40, 2), 1);
      expect(bsc.read(28, 2) & 0x80, 0x80);
    }
  });




  test('batched counter matches agree with independent per-clock stepping', () {
    final bsc = DcBsc(), random = Random(13);
    bsc.write(28, 2, 0xa518);
    bsc.write(32, 2, 0xa5fa);
    bsc.write(36, 2, 0xa507);
    var count = 250, refresh = 0, phase = 0;
    for (var trial = 0; trial < 100; trial++) {
      final clocks = random.nextInt(10000);
      for (var i = 0; i < clocks; i++) {
        phase++;
        if (phase != 64) continue;
        phase = 0;
        count = (count + 1) % 256;
        if (count == 7) {
          count = 0;
          refresh = (refresh + 1) % 1024;
        }
      }
      bsc.tickBusClocks(clocks);
      expect(bsc.read(32, 2), count);
      expect(bsc.read(40, 2), refresh);
    }
  });



}
