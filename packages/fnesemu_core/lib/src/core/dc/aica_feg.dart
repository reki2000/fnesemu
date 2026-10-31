import 'dart:math' as math;

import '../../state.dart';

/// Functional linear cutoff envelope from System Architecture Table 8-14.
/// Hardware stepping and the conflicting standalone AICA timings are unverified.
class DcAicaFeg {
  int state = 3;
  double level = 0;

  void reset() {
    state = 3;
    level = 0;
  }

  void saveState(StateWriter writer) {
    writer.section('dc.aica.feg');
    writer.int32(state);
    writer.float64(level);
  }

  void loadState(StateReader reader) {
    reader.section('dc.aica.feg');
    final stage = reader.int32(), cutoff = reader.float64();
    if (stage < 0 ||
        stage > 3 ||
        !cutoff.isFinite ||
        cutoff < 0 ||
        cutoff > 8191) {
      throw const StateMismatch('AICA filter envelope state');
    }
    state = stage;
    level = cutoff;
  }

  void start(int initial) {
    state = 0;
    level = initial.toDouble();
  }

  void release(int initial) {
    state = 3;
    level = initial.toDouble();
  }

  /// One 44.1 kHz edge; equal targets complete one stage per edge.
  void advance(List<int> regs) {
    final target = regs[12 + state];
    if (level != target) {
      final rate = switch (state) {
        0 => (regs[16] >> 8) & 31,
        1 => regs[16] & 31,
        2 => (regs[17] >> 8) & 31,
        _ => regs[17] & 31,
      };
      final krs = (regs[5] >> 10) & 15;
      final octave = (((regs[6] >> 11) & 15) ^ 8) - 8;
      final effective = (rate * 2 +
              (krs == 15 ? 0 : 2 * (krs + octave) + ((regs[6] >> 9) & 1)))
          .clamp(0, 63);
      final time = _milliseconds[effective];
      final delta = (0x1ff8 - 8) * 1000 / (time * 44100);
      level = level < target
          ? math.min(target.toDouble(), level + delta)
          : math.max(target.toDouble(), level - delta);
    }
    if (level == target && state < 2) state++;
  }

  static const _milliseconds = <double>[
    double.infinity, double.infinity, 472800, 405200, 354400, 283600,
    236400, 202800, 177200, 142000, 118400, 101200, 88800, 70800,
    59200, 50800, 44400, 35600, 29600, 25200, 22000, 17600, 14800,
    12800, 11200, 8800, 7200, 6400, 5600, 4400, 3680, 3160,
    2760, 2200, 1840, 1560, 1360, 1080, 920, 800, 680, 560, 440,
    392, 340, 272, 228, 196, 172,
    // Provisional interpolation: printed rate 49 conflicts with its neighbors.
    154,
    136, 100, 88, 72, 56, 48, 44, 34, 28, 24, 22, 17, 14, 12,
  ];
}
