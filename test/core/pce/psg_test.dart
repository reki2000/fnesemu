import 'dart:math';

import 'package:fnesemu/core/pce/component/psg.dart';
import 'package:test/test.dart';

// the counter stepped once per clock, as the reference of the skipping synth
void _referenceStep(Wave w, List<int> out, {required bool noise}) {
  for (int i = 0; i < out.length; i += 2) {
    for (int k = 0; k < Psg.divider; k++) {
      w.counter = (w.counter - 1) & 0xfff;
      if (w.counter == 1) {
        if (noise) {
          w.counter = w.noiseFreq;
          w.noiseIndex = (w.noiseIndex + 1) & 0x3f;
          if (w.noiseIndex == 0 || w.noiseIndex == 0x10) {
            final o = (w.random.nextDouble() > 0.5) ? 31 : 0;
            w.currentL = o * (w.volumeL + 1) ~/ 32;
            w.currentR = o * (w.volumeR + 1) ~/ 32;
          }
        } else {
          w.counter = (w.freq + w.freqOffset).clamp(0, 0xfff);
          w.tableIndex = (w.tableIndex + 1) & 0x1f;
          final o = (w.table[w.tableIndex] - 16) * (w.volume + 1);
          w.currentL = o * (w.volumeL + 1) ~/ (32 * 16);
          w.currentR = o * (w.volumeR + 1) ~/ (32 * 16);
        }
      }
    }
    out[i] += w.currentL;
    out[i + 1] += w.currentR;
  }
}

Wave _wave(int seed, bool noise) {
  final r = Random(seed);
  final w = Wave()
    ..enabled = true
    ..noise = noise
    ..freq = [0, 1, 2, 3, 7, 8, 9, 100, 0xfff][r.nextInt(9)]
    ..freqOffset = r.nextInt(64) - 32
    ..noiseFreq = r.nextInt(0x20)
    ..counter = r.nextInt(0x1000)
    ..volume = r.nextInt(0x20)
    ..volumeL = r.nextInt(0x10)
    ..volumeR = r.nextInt(0x10);
  for (int i = 0; i < 32; i++) {
    w.table[i] = r.nextInt(32);
  }
  return w;
}

void main() {
  for (final noise in [false, true]) {
    test('psg ${noise ? 'noise' : 'wave'} matches stepping the counter', () {
      for (int seed = 0; seed < 200; seed++) {
        final a = _wave(seed, noise);
        final b = _wave(seed, noise);
        for (int run = 0; run < 20; run++) {
          final outA = List<int>.filled(56, 0);
          final outB = List<int>.filled(56, 0);
          _referenceStep(a, outA, noise: noise);
          b.synth(outB);
          expect(outB, outA, reason: 'seed $seed run $run');
          expect(b.counter, a.counter);
          expect(b.tableIndex, a.tableIndex);
          expect(b.noiseIndex, a.noiseIndex);
        }
      }
    });
  }
}
