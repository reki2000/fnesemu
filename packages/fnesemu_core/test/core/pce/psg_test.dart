import 'dart:math';

import 'package:fnesemu_core/src/core/pce/component/bus.dart';
import 'package:fnesemu_core/src/core/pce/component/psg.dart';
import 'package:test/test.dart';

// the counter stepped once per clock, as the reference of the skipping synth
void _referenceStep(Wave w, List<int> out) {
  for (int i = 0; i < out.length; i += 2) {
    for (int k = 0; k < Psg.divider; k++) {
      w.counter = (w.counter - 1) & 0xfff;
      if (w.counter == 1) {
        w.counter = (w.freq + w.freqOffset).clamp(0, 0xfff);
        w.tableIndex = (w.tableIndex + 1) & 0x1f;
        final o = (w.table[w.tableIndex] - 16) * (w.volume + 1);
        w.currentL = o * (w.volumeL + 1) ~/ (32 * 16);
        w.currentR = o * (w.volumeR + 1) ~/ (32 * 16);
      }
    }
    out[i] += w.currentL;
    out[i + 1] += w.currentR;
  }
}

Wave _wave(int seed) {
  final r = Random(seed);
  final w = Wave()
    ..enabled = true
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
  test('psg wave matches stepping the counter', () {
    for (int seed = 0; seed < 200; seed++) {
      final a = _wave(seed);
      final b = _wave(seed);
      for (int run = 0; run < 20; run++) {
        final outA = List<int>.filled(56, 0);
        final outB = List<int>.filled(56, 0);
        _referenceStep(a, outA);
        b.synth(outB);
        expect(outB, outA, reason: 'seed $seed run $run');
        expect(b.counter, a.counter);
        expect(b.tableIndex, a.tableIndex);
        expect(b.noiseIndex, a.noiseIndex);
      }
    }
  });
  test('audio duration preserves fractional samples across updates', () {
    final psg = Psg(Bus());
    var frames = 0;
    for (var i = 0; i < 1000; i++) {
      frames += psg.exec(1362).length ~/ 2;
    }
    expect(frames, 1362000 ~/ (6 * Psg.divider));
    psg.reset();
    expect(psg.exec(6 * Psg.divider - 1), isEmpty);
    expect(psg.exec(1).length, 2);
  });
  for (final divisor in [1, 7, 31]) {
    test('noise clock uses a 64-clock prescaler with divisor $divisor', () {
      final wave = Wave()
        ..noiseFreq = divisor
        ..noiseCounter = 64 * divisor
        ..volume = 31
        ..volumeL = 15
        ..volumeR = 15;
      wave.synthNoise(List.filled((64 * divisor ~/ Psg.divider - 1) * 2, 0));
      expect(wave.noiseIndex, 0);
      wave.synthNoise(List.filled(2, 0));
      expect(wave.noiseIndex, 1);
      expect(wave.noiseCounter, 64 * divisor);
      wave.synthNoise(List.filled(64 * divisor ~/ Psg.divider * 2, 0));
      expect(wave.noiseIndex, 2);
    });
  }
  test('noise has both polarities and responds to the channel envelope', () {
    final wave = Wave()
      ..noiseFreq = 1
      ..volume = 31
      ..volumeL = 15
      ..volumeR = 15;
    final output = List.filled(2048, 0);
    wave.synthNoise(output);
    expect(output.any((v) => v < 0), isTrue);
    expect(output.any((v) => v > 0), isTrue);
    wave.volume = 0;
    final muted = List.filled(2048, 0);
    wave.synthNoise(muted);
    expect(muted.every((v) => v == 0), isTrue);
  });
}
