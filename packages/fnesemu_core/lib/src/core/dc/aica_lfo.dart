import 'dart:math' as math;

import '../../state.dart';

/// Sample-domain LFO model, System Architecture section 8.1.1.5 and AICA Specification.
/// Frequencies are the published rounded values; divider/phase/noise matching is pending.
class DcAicaLfo {
  DcAicaLfo({this.seed = 0x6d2b79f5});
  final int seed;
  static const _denominator = 44100 * 100;
  static const _frequency = [
    17,
    19,
    23,
    27,
    34,
    39,
    45,
    55,
    68,
    78,
    92,
    110,
    139,
    160,
    187,
    227,
    287,
    331,
    392,
    479,
    615,
    718,
    860,
    1080,
    1440,
    1720,
    2150,
    2870,
    4310,
    5740,
    8610,
    17230
  ];
  static const _amplitudeDb = [0.0, 0.4, 0.8, 1.5, 3.0, 6.0, 12.0, 24.0];
  int _phase = 0, _clock = 0;
  int get phaseCode => (_phase * 256) ~/ _denominator;

  void reset() {
    _phase = _clock = 0;
  }

  void saveState(StateWriter writer) {
    writer.section('dc.aica.lfo');
    writer.int64(seed);
    writer.int32(_phase);
    writer.int64(_clock);
  }

  void loadState(StateReader reader) {
    reader.section('dc.aica.lfo');
    final savedSeed = reader.int64();
    final phase = reader.int32(), clock = reader.int64();
    if (savedSeed != seed || phase < 0 || phase >= _denominator || clock < 0) {
      throw const StateMismatch('AICA LFO state');
    }
    _phase = phase;
    _clock = clock;
  }

  void _synchronize(int clock, int control) {
    if (clock < _clock) throw ArgumentError('LFO sample clock moved backwards');
    if (control & 0x8000 != 0) {
      _phase = 0;
    } else {
      // Reduce elapsed time first so products remain exact in browser integer arithmetic.
      final elapsed = (clock - _clock) % _denominator;
      _phase =
          (_phase + elapsed * _frequency[(control >> 10) & 31]) % _denominator;
    }
    _clock = clock;
  }

  void write(int clock, int previous, int control) {
    _synchronize(clock, previous);
    if (control & 0x8000 != 0) _phase = 0;
  }

  int _noise(int clock) {
    // Counter-based deterministic stand-in, not a measured hardware RNG polynomial.
    // Both small-constant products fit exactly below 2^53 on browser runtimes.
    var value = ((clock & 0xffffffff) ^ seed) & 0xffffffff;
    value = ((value ^ (value >> 16)) * 40503) & 0xffffffff;
    value = ((value ^ (value >> 13)) * 34717) & 0xffffffff;
    value ^= value >> 16;
    return (value >> 24) & 255;
  }

  (int, int) sample(int clock, int control) {
    _synchronize(clock, control);
    final phase = phaseCode;
    final amplitudeWave = (control >> 3) & 3, pitchWave = (control >> 8) & 3;
    final noise = amplitudeWave == 3 || pitchWave == 3 ? _noise(clock) : 0;
    final amplitude = switch (amplitudeWave) {
      0 => phase,
      1 => phase < 128 ? 0 : 255,
      2 => (phase < 128 ? phase * 2 : (256 - phase) * 2).clamp(0, 255),
      _ => noise,
    };
    final pitch = switch (pitchWave) {
      0 => phase - 128,
      1 => phase < 128 ? 127 : -128,
      2 => (phase < 64
              ? phase * 2
              : phase < 192
                  ? 256 - phase * 2
                  : phase * 2 - 512)
          .clamp(-128, 127),
      _ => noise.toSigned(8),
    };
    return (amplitude, pitch);
  }

  static double amplitudeGain(int depth, int code) => depth == 0
      ? 1.0
      : math.pow(10, -_amplitudeDb[depth] * code / (255 * 20)).toDouble();

  /// FNS-domain truncation reproduces the rounded cent endpoints in Table 8-9.
  /// Intermediate pitch arithmetic and internal truncation boundaries remain unmeasured.
  static int pitchStep(int pitchRegister, int depth, int code) {
    var number = 1024 + (pitchRegister & 1023);
    if (depth != 0) number += (number * code) >> (17 - depth);
    final octave = (((pitchRegister >> 11) & 15) ^ 8) - 8;
    return number << (octave + 8);
  }
}
