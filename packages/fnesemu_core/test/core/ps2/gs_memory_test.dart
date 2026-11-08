import 'dart:async';
import 'package:fnesemu_core/src/core/ps2/gs/gs_memory.dart';
import 'package:test/test.dart';

// page size in pixels (width, height) and units per page
const _pages = {
  GsPsm.ct32: (64, 32, 2048),
  GsPsm.ct24: (64, 32, 2048),
  GsPsm.z32: (64, 32, 2048),
  GsPsm.t8h: (64, 32, 2048),
  GsPsm.t4hl: (64, 32, 2048),
  GsPsm.ct16: (64, 64, 4096),
  GsPsm.ct16s: (64, 64, 4096),
  GsPsm.z16: (64, 64, 4096),
  GsPsm.z16s: (64, 64, 4096),
  GsPsm.t8: (128, 64, 8192),
  GsPsm.t4: (128, 128, 16384),
};

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

  for (final entry in _pages.entries) {
    aggCase('psm 0x${entry.key.toRadixString(16)}: a page maps one to one', () {
      final (w, h, units) = entry.value;
      final seen = <int>{};
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = GsMemory.unitIndex(entry.key, 0, 2, x, y);
          expect(i, inInclusiveRange(0, units - 1), reason: '($x,$y)');
          expect(seen.add(i), isTrue, reason: '($x,$y) collides');
        }
      }
      expect(seen.length, units);
    });
  }

  // The 8-bit and 4-bit pixels of a page, written as 32-bit pixels: the
  // position of each one follows the published texture conversion code.
  aggCase('PSMT8 and PSMT4 pixels sit in the bytes of PSMCT32 pixels', () {
    for (var y = 0; y < 128; y++) {
      final swap = ((y + 2) >> 2) & 1 == 0 ? 0 : 4;
      final row = (((y & ~3) >> 1) + (y & 1)) & 7;
      for (var x = 0; x < 128; x++) {
        if (y < 64) {
          final cx = (x & ~15) ~/ 2 + ((x + swap) & 7);
          final cy = (y & ~15) ~/ 2 + row;
          final byte = ((y >> 1) & 1) + ((x >> 2) & 2);
          expect(GsMemory.unitIndex(GsPsm.t8, 0, 2, x, y),
              GsMemory.unitIndex(GsPsm.ct32, 0, 1, cx, cy) * 4 + byte);
        }
        final cx = (y & ~15) ~/ 2 + ((x + swap) & 7);
        final cy = (x & ~31) ~/ 4 + row;
        final byte = (x >> 3) & 3;
        expect(
            GsMemory.unitIndex(GsPsm.t4, 0, 2, x, y),
            (GsMemory.unitIndex(GsPsm.ct32, 0, 1, cx, cy) * 4 + byte) * 2 +
                ((y >> 1) & 1));
      }
    }
  });

  aggCase('pages follow the buffer width', () {
    // PSMCT32: the second page of a row is 2048 words after the first
    expect(GsMemory.unitIndex(GsPsm.ct32, 0, 2, 64, 0), 2048);
    expect(GsMemory.unitIndex(GsPsm.ct32, 0, 2, 0, 32), 4096);
    expect(GsMemory.unitIndex(GsPsm.ct32, 4, 1, 0, 0), 256);
  });

  aggCase('PSMCT32 block and column order', () {
    // block 1 is the second block of the first block row
    expect(GsMemory.unitIndex(GsPsm.ct32, 0, 1, 8, 0), 64);
    expect(GsMemory.unitIndex(GsPsm.ct32, 0, 1, 16, 0), 4 * 64);
    expect(GsMemory.unitIndex(GsPsm.ct32, 0, 1, 0, 8), 2 * 64);
    // inside a block: 8x2 columns of 16 words
    expect(GsMemory.unitIndex(GsPsm.ct32, 0, 1, 1, 0), 1);
    expect(GsMemory.unitIndex(GsPsm.ct32, 0, 1, 0, 1), 2);
    expect(GsMemory.unitIndex(GsPsm.ct32, 0, 1, 0, 2), 16);
  });

  aggCase('Z formats use the opposite block quadrant', () {
    expect(GsMemory.unitIndex(GsPsm.z32, 0, 1, 0, 0), 24 * 64);
    expect(GsMemory.unitIndex(GsPsm.z16, 0, 1, 0, 0), 24 * 64 * 2);
  });

  aggCase('pixels round trip in every format', () {
    final mem = GsMemory();
    for (final psm in _pages.keys) {
      final max = (1 << GsPsm.pixelBits(psm)) - 1;
      for (var i = 0; i < 40; i++) {
        final x = (i * 37) % 120, y = (i * 53) % 90;
        final v = (i * 0x9e3779b1 + 5) & max;
        mem.write(psm, 3, 2, x, y, v);
        expect(mem.read(psm, 3, 2, x, y), v, reason: 'psm $psm ($x,$y)');
      }
    }
  });

  aggCase('the 8H and 4H formats share the upper bits of a PSMCT32 word', () {
    final mem = GsMemory();
    mem.write(GsPsm.ct32, 0, 1, 5, 3, 0x11223344);
    mem.write(GsPsm.t8h, 0, 1, 5, 3, 0xab);
    expect(mem.read(GsPsm.ct32, 0, 1, 5, 3), 0xab223344);
    mem.write(GsPsm.t4hh, 0, 1, 5, 3, 0x7);
    mem.write(GsPsm.t4hl, 0, 1, 5, 3, 0x9);
    expect(mem.read(GsPsm.ct32, 0, 1, 5, 3), 0x79223344);
    expect(mem.read(GsPsm.t4hl, 0, 1, 5, 3), 9);
    mem.write(GsPsm.ct24, 0, 1, 5, 3, 0xffffff);
    expect(mem.read(GsPsm.ct32, 0, 1, 5, 3), 0x79ffffff);
  });


  const chunkCount = 2;
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
