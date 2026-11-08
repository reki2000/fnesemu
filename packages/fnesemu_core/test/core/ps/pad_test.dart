import 'dart:async';
import 'package:fnesemu_core/app_api.dart';
import 'package:fnesemu_core/src/core/ps/pad.dart';
import 'package:test/test.dart';

/// Sends one transfer [tx] (address, command, then parameters) and returns the
/// bytes answered by the pad.
List<int> transfer(Pad pad, List<int> tx) =>
    [for (final b in tx) pad.notify(b).rxData];

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

  aggCase('digital pad answers a 2 byte poll', () {
    final pad = Pad();
    expect(
        transfer(pad, [0x01, 0x42, 0, 0, 0]), [0xff, 0x41, 0x5a, 0xff, 0xff]);
    expect(pad.padStep, Pad.waitAddr);
  });

  aggCase('configuration selects the analog mode and polls the sticks', () {
    final state = PadState()
      ..setAxis(0, PadAxis.leftX, -1)
      ..setAxis(0, PadAxis.leftY, 1)
      ..setAxis(0, PadAxis.rightX, 1)
      ..setAxis(0, PadAxis.rightY, 0);
    final pad = Pad()..source = state;
    transfer(pad, [0x01, 0x43, 0, 1, 0]);
    expect(pad.configMode, isTrue);
    expect(transfer(pad, [0x01, 0x44, 0, 1, 3, 0, 0, 0, 0]),
        [0xff, 0xf3, 0x5a, 0, 0, 0, 0, 0, 0]);
    expect(pad.analogMode, isTrue);
    transfer(pad, [0x01, 0x43, 0, 0, 0, 0, 0, 0, 0]);
    expect(pad.configMode, isFalse);
    expect(transfer(pad, [0x01, 0x42, 0, 0, 0, 0, 0, 0, 0]),
        [0xff, 0x73, 0x5a, 0xff, 0xff, 255, 0x80, 1, 255]);
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
