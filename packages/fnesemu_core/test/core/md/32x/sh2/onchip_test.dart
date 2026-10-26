import 'dart:math';

import 'package:fnesemu_core/src/core/md/32x/sh2/onchip.dart';
import 'package:test/test.dart';

void main() {
  test('the free running timer counts the same in one tick or in single ticks',
      () {
    final random = Random(7);
    for (var round = 0; round < 300; round++) {
      final fast = Sh2OnChip(true), slow = Sh2OnChip(true);
      final tcr = random.nextInt(3), clear = random.nextInt(2);
      final frc = random.nextBool() ? random.nextInt(0x10000) : 0xfff0;
      final ocra = random.nextBool() ? random.nextInt(0x10000) : frc + 40;
      final ocrb = random.nextBool() ? random.nextInt(0x10000) : frc;
      for (final c in [fast, slow]) {
        c.tcr = tcr;
        c.ftcsr = clear;
        c.frc = frc;
        c.ocra = ocra & 0xffff;
        c.ocrb = ocrb & 0xffff;
      }
      for (var step = 0; step < 6; step++) {
        final clocks = random.nextInt(40000);
        fast.tick(clocks);
        for (var i = 0; i < clocks; i++) {
          slow.tick(1);
        }
        expect(fast.frc, slow.frc, reason: 'round $round step $step');
        expect(fast.ftcsr, slow.ftcsr, reason: 'round $round step $step');
      }
    }
  });
}
