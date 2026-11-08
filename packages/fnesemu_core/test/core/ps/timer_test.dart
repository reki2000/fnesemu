import 'dart:async';
import 'dart:math';

import 'package:fnesemu_core/src/core/ps/bus.dart';
import 'package:fnesemu_core/src/core/ps/timer.dart';
import 'package:test/test.dart';

class _Bus extends Bus {
  final requests = <int>[];

  @override
  void setIrq(int no) => requests.add(no);
}

class _CaseSkip implements Exception {
  const _CaseSkip();
}

void main() {
  // Aggregated cases: the per-case tests of this file are collected
  // in this table and executed by the aggregated test(s) at the end of
  // main; every case name stays visible here and in the run output.
  final aggCases = <(String, FutureOr<void> Function())>[];
  final aggTeardowns = <void Function()>[];
  void aggCase(String name, FutureOr<void> Function() body) =>
      aggCases.add((name, body));
  Future<void> runAggCases(
      Iterable<(String, FutureOr<void> Function())> cases) async {
    for (final (name, body) in cases) {
      print('case: $name');
      try {
        await body();
      } on _CaseSkip {
        print('skipped: $name');
      } finally {
        for (final teardown in aggTeardowns) {
          teardown();
        }
        aggTeardowns.clear();
      }
    }
  }

  aggCase('all target crossings preserve IRQ toggle parity', () {
    for (final batch in [100, 200, 300, 600]) {
      final bus = _Bus();
      final timer = Timer(0, bus)
        ..target = 149
        ..mode_ = 0xd8;
      for (int elapsed = 0; elapsed < 600; elapsed += batch) {
        timer.clock(batch);
      }
      expect(timer.counter, 0);
      expect(timer.intRequested, false);
      expect(bus.requests.length, 2);
    }
  });

  aggCase('timer IRQ counts and state do not depend on update batch size', () {
    final random = Random(53);
    for (final irqBits in [0, 0x10, 0x20, 0x30]) {
      for (final reset in [false, true]) {
        for (final toggle in [false, true]) {
          for (final repeat in [false, true]) {
            for (final target in [0, 1, 149, 0xfffe, 0xffff]) {
              for (final counter in [0, target, 0xfffd, 0xffff]) {
                final buses = [_Bus(), _Bus()];
                final timers = [
                  for (final bus in buses)
                    Timer(0, bus)
                      ..mode_ = irqBits |
                          (reset ? 8 : 0) |
                          (repeat ? 0x40 : 0) |
                          (toggle ? 0x80 : 0)
                      ..target = target
                      ..counter = counter
                ];
                const total = 0x20001;
                for (int n = 0; n < total; n++) {
                  timers[0].clock(1);
                }
                for (int left = total; left > 0;) {
                  final n = min(left, random.nextInt(700) + 1);
                  timers[1].clock(n);
                  left -= n;
                }
                final label =
                    '$irqBits/$reset/$toggle/$repeat/$target/$counter';
                expect(timers[1].counter, timers[0].counter, reason: label);
                expect(timers[1].mode, timers[0].mode, reason: label);
                expect(buses[1].requests.length, buses[0].requests.length,
                    reason: label);
              }
            }
          }
        }
      }
    }
  });

  const chunkCount = 1;
  final chunkSize = (aggCases.length + chunkCount - 1) ~/ chunkCount;
  for (var part = 0; part < chunkCount; part++) {
    final partCases =
        aggCases.skip(part * chunkSize).take(chunkSize).toList();
    if (partCases.isEmpty) continue;
    test('aggregated cases ${part + 1} of $chunkCount', () async {
      await runAggCases(partCases);
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}
