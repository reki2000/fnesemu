import 'dart:math' as math;

import 'fault.dart';

/// Provisional two-pole response, not a recovered AICA fixed-point filter.
/// Cutoff anchors approximate the standalone AICA manual's page-13 graph.
/// Biquad equations follow https://www.w3.org/TR/audio-eq-cookbook/#formulae.
class DcAicaFilter {
  double z1 = 0, z2 = 0;
  int _cutoff = -1, _resonance = -1;
  double _b0 = 0, _b1 = 0, _b2 = 0, _a1 = 0, _a2 = 0;

  void reset() {
    z1 = z2 = 0;
    _cutoff = _resonance = -1;
  }

  static const _anchors = <(int, double)>[
    (0x0600, 1),
    (0x0d00, 10),
    (0x1400, 100),
    (0x1a00, 1000),
    (0x1f00, 10000),
    (0x1ff8, 18000),
  ];

  /// Log-frequency interpolation of approximate graph readings, not register decoding.
  static double frequency(int code) {
    if (code <= _anchors.first.$1) return _anchors.first.$2;
    for (var i = 1; i < _anchors.length; i++) {
      final low = _anchors[i - 1], high = _anchors[i];
      if (code <= high.$1) {
        final fraction = (code - low.$1) / (high.$1 - low.$1);
        return low.$2 * math.pow(high.$2 / low.$2, fraction);
      }
    }
    return _anchors.last.$2;
  }

  double process(double input, double level, int resonance) {
    final cutoff = level.round().clamp(0, 8191);
    // Preserve bring-up for reserved low FLV settings; their hardware behavior is unknown.
    // Both manuals' documented through settings use Q=4 and a maximum FLV.
    if (cutoff < 8 || (cutoff >= 0x1ff8 && resonance == 4)) {
      z1 = z2 = 0;
      return input;
    }
    if (cutoff != _cutoff || resonance != _resonance) {
      final omega = 2 * math.pi * frequency(cutoff) / 44100;
      // The documented resonance dB setting is provisionally treated as biquad Q.
      final q = math.pow(10, (0.75 * resonance - 3) / 20);
      final cosine = math.cos(omega), alpha = math.sin(omega) / (2 * q);
      final denominator = 1 + alpha;
      _b0 = (1 - cosine) / (2 * denominator);
      _b1 = (1 - cosine) / denominator;
      _b2 = _b0;
      _a1 = -2 * cosine / denominator;
      _a2 = (1 - alpha) / denominator;
      _cutoff = cutoff;
      _resonance = resonance;
    }
    final output = _b0 * input + z1;
    z1 = _b1 * input - _a1 * output + z2;
    z2 = _b2 * input - _a2 * output;
    if (!output.isFinite || !z1.isFinite || !z2.isFinite) {
      throw const DcUnsupported('AICA provisional filter became nonfinite');
    }
    return output;
  }
}
