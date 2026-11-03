import 'dart:async';
import 'package:fnesemu_core/src/core/ps/bus.dart';
import 'package:fnesemu_core/src/core/ps/gpu/gpu.dart';
import 'package:test/test.dart';

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

  for (final mode in [0, 1, 2, 3, 0x40]) {
    for (final interlaced in [false, true]) {
      aggCase('display mode $mode keeps 4:3 aspect (480i: $interlaced)', () {
        final gpu = Gpu(Bus());
        gpu.writeGp1(0x08000000 | mode | (interlaced ? 0x24 : 0));
        final image = gpu.imageBuffer;
        expect(image.width, mode == 0x40 ? 368 : [256, 320, 512, 640][mode]);
        expect(image.height, interlaced ? 480 : 240);
        expect(image.buffer.length, image.width * image.height);
        expect(image.displayWidth / (image.displayHeight ?? image.height),
            closeTo(4 / 3, 1e-10));
      });
    }
  }


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
