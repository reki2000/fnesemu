import 'dart:math' as math;
import 'dart:typed_data';

/// The 8x8 inverse DCT of ISO/IEC 13818-2 Annex A, computed in double
/// precision. The result is rounded and saturated to -256..255.
class Idct {
  // _basis[x * 8 + u] = C(u) / 2 * cos((2x + 1) u pi / 16)
  static final _basis = Float64List.fromList([
    for (var x = 0; x < 8; x++)
      for (var u = 0; u < 8; u++)
        (u == 0 ? math.sqrt1_2 : 1.0) /
            2 *
            math.cos((2 * x + 1) * u * math.pi / 16),
  ]);

  final _tmp = Float64List(64);

  /// transforms the coefficients in [block] (row-major) in place
  void transform(Int32List block) {
    var acOnly = true;
    for (var i = 1; i < 64; i++) {
      if (block[i] != 0) {
        acOnly = false;
        break;
      }
    }
    if (acOnly) {
      // only the DC coefficient: a flat block of F / 8
      final v = _clip((block[0] / 8).round());
      block.fillRange(0, 64, v);
      return;
    }
    final b = _basis, t = _tmp;
    // rows: t[v * 8 + x] = sum_u F[v][u] * basis[x][u]
    for (var v = 0; v < 8; v++) {
      final row = v * 8;
      for (var x = 0; x < 8; x++) {
        var s = 0.0;
        final bx = x * 8;
        for (var u = 0; u < 8; u++) {
          final f = block[row + u];
          if (f != 0) s += f * b[bx + u];
        }
        t[row + x] = s;
      }
    }
    // columns: f[y][x] = sum_v t[v][x] * basis[y][v]
    for (var x = 0; x < 8; x++) {
      for (var y = 0; y < 8; y++) {
        var s = 0.0;
        final by = y * 8;
        for (var v = 0; v < 8; v++) {
          s += t[v * 8 + x] * b[by + v];
        }
        block[y * 8 + x] = _clip(s.round());
      }
    }
  }

  static int _clip(int v) => v < -256 ? -256 : (v > 255 ? 255 : v);
}
