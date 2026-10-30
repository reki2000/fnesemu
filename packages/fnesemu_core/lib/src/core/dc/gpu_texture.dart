import 'dart:math' as math;
import 'dart:typed_data';

import 'fault.dart';
import 'gpu_math.dart';
import 'gpu_palette.dart';

/// RGB/palette/YUV/bump texture view, including square RGB and non-MIP palette VQ blocks, from System Architecture §§3.6.2–3.6.3, 3.7.9.
/// Filter weights and arithmetic rounding are functional pending hardware measurements.
class DcGpuTexture {
  DcGpuTexture(this.memory,
      {required int tcw, required int tsp, int control = 0, this.palette}) {
    width = 8 << ((tsp >> 3) & 7);
    format = (tcw >> 27) & 7;
    final indexed = format == 5 || format == 6;
    twiddled = indexed || tcw & 0x04000000 == 0;
    mipMapped = twiddled && tcw & 0x80000000 != 0;
    height = mipMapped ? width : 8 << (tsp & 7);
    _maxLevel = width.bitLength - 1;
    _adjust = ((tsp >> 8) & 15) / 4;
    if (mipMapped && _adjust == 0) {
      throw const DcUnsupported('CORE MIP D-adjust zero is prohibited');
    }
    selector = format == 5 ? ((tcw >> 21) & 63) * 16 : ((tcw >> 25) & 3) * 256;
    if (indexed && palette == null) {
      throw const DcUnsupported('CORE palette RAM is not connected');
    }
    base = (tcw & 0x1fffff) * 8;
    compressed = tcw & 0x40000000 != 0;
    if (compressed &&
        (!twiddled || width != height || format == 3 || format == 4)) {
      throw const DcUnsupported(
          'CORE VQ requires a square twiddled RGB or palette texture');
    }
    if (compressed && indexed && mipMapped) {
      throw const DcUnsupported(
          'CORE palette VQ MIP index/texel layout is unverified');
    }
    if (compressed && control & 0x30000 != 0) {
      throw const DcUnsupported(
          'CORE VQ big-endian index/codebook wiring is unverified');
    }
    if (format == 4 && !twiddled) {
      throw const DcUnsupported(
          'CORE non-twiddled bump texture hangs the hardware (erratum 26)');
    }
    if (control & 0x1f00 != 0) {
      throw const DcUnsupported(
          'CORE alternate texture bank position is pending');
    }
    stride = !twiddled && tcw & 0x02000000 != 0 ? (control & 31) * 32 : width;
    if (stride == 0 || stride > width) {
      throw const DcUnsupported('CORE invalid texture stride');
    }
    superSample = tsp & 0x1000 != 0;
    clampU = tsp & 0x10000 != 0;
    clampV = tsp & 0x8000 != 0;
    flipU = tsp & 0x40000 != 0;
    flipV = tsp & 0x20000 != 0;
    // Trilinear passes without an effective MIP flag are documented point samples.
    filterMode = (tsp >> 13) & 3;
    bilinear = filterMode == 1 || trilinear;
  }
  final Uint8List memory;
  final DcGpuPalette? palette;
  late final int width, height, stride, format, base, selector, filterMode;
  bool get trilinear => mipMapped && filterMode >= 2;
  late final bool superSample,
      twiddled,
      compressed,
      mipMapped,
      bilinear,
      clampU,
      clampV,
      flipU,
      flipV;
  late final int _maxLevel;
  late final double _adjust;
  static const _rgbOffsets = [
    6,
    8,
    0x10,
    0x30,
    0xb0,
    0x2b0,
    0xab0,
    0x2ab0,
    0xaab0,
    0x2aab0,
    0xaaab0
  ];
  static const _paletteOffsets = [
    3,
    4,
    8,
    0x18,
    0x58,
    0x158,
    0x558,
    0x1558,
    0x5558,
    0x15558,
    0x55558
  ];
  static const _vqOffsets = [
    0,
    1,
    2,
    6,
    0x16,
    0x56,
    0x156,
    0x556,
    0x1556,
    0x5556,
    0x15556
  ];

  /// Functional binary-footprint model; the manual's D encoding needs physical validation.
  (int, double) _resolution(double footprint) {
    if (!footprint.isFinite || footprint < 0) {
      throw const DcUnsupported('CORE invalid MIP footprint');
    }
    if (!mipMapped) return (0, 0);
    var value = footprint * _adjust, level = 0;
    if (value >= width) return (_maxLevel, 0);
    while (value >= 2 && level < _maxLevel) {
      value /= 2;
      level++;
    }
    // Interpolate across each binary interval, keeping both pass boundaries continuous.
    // This normalized-mantissa policy is inferred, not a measured hardware D decoder.
    return (level, level == _maxLevel ? 0 : (value - 1).clamp(0.0, 1.0));
  }

  int selectLevel(double footprint) {
    final (level, _) = _resolution(footprint);
    final selected =
        trilinear && filterMode == 3 ? math.min(level + 1, _maxLevel) : level;
    return superSample ? math.max(0, selected - 1) : selected;
  }

  double passWeight(double footprint) {
    if (!trilinear) return 1;
    final (_, fraction) = _resolution(footprint);
    return filterMode == 2 ? 1 - fraction : fraction;
  }

  /// The trilinear multiplier follows shading/clamp/fog and precedes alpha blending.
  int applyPassWeight(int color, double footprint) {
    final weight = passWeight(footprint);
    if (weight == 1) return color;
    var output = 0;
    for (var shift = 0; shift < 32; shift += 8) {
      output |= roundByte(((color >> shift) & 255) * weight) << shift;
    }
    return output & 0xffffffff;
  }

  double footprint(double duDx, double dvDx, double duDy, double dvDy) =>
      math.sqrt(math.max(math.pow(duDx * width, 2) + math.pow(dvDx * height, 2),
          math.pow(duDy * width, 2) + math.pow(dvDy * height, 2)));

  int _index(int x, int y, int levelWidth, int levelHeight) {
    var index = y * stride + x;
    if (twiddled) {
      index = 0;
      var u = x, v = y, w = levelWidth, h = levelHeight, place = 1;
      while (w > 1 && h > 1) {
        index |= (v & 1) * place;
        place *= 2;
        index |= (u & 1) * place;
        place *= 2;
        u >>= 1;
        v >>= 1;
        w >>= 1;
        h >>= 1;
      }
      index |= (u | v) * place;
    }
    return index;
  }

  int _byte(int address) {
    if (address < 0 || address >= memory.length) {
      throw const DcUnsupported('CORE texture read outside retail VRAM');
    }
    final offset =
        (address & 3) | ((address >> 1) & 0x3ffffc) | ((address & 4) << 20);
    return memory[offset];
  }

  int _coordinate(int value, int size, bool clamp, bool flip) {
    if (clamp) return value.clamp(0, size - 1);
    value %= flip ? size * 2 : size;
    return value >= size ? size * 2 - value - 1 : value;
  }

  int _texel(int x, int y, int level, int bumpParameters) {
    final w = width >> level, h = height >> level, exponent = _maxLevel - level;
    x = _coordinate(x, w, clampU, flipU);
    y = _coordinate(y, h, clampV, flipV);
    final index = _index(x, y, w, h);
    final paletteOffset = mipMapped ? _paletteOffsets[exponent] : 0;
    if (compressed && (format == 5 || format == 6)) {
      // Partition the documented Morton texel stream into 64-bit book elements.
      // 4bpp uses 4x4 blocks; 8bpp uses 2x4 blocks (V0,U0,V1).
      final bits = format == 5 ? 4 : 3;
      final code = _byte(base + 0x800 + (index >> bits));
      final local = index & ((1 << bits) - 1);
      final value = _byte(base + code * 8 + (format == 5 ? local ~/ 2 : local));
      final entry = format == 5 ? (value >> ((local & 1) * 4)) & 15 : value;
      return palette!.color(selector + entry);
    }
    if (format == 5) {
      final nibble = index + paletteOffset;
      final packed = _byte(base + nibble ~/ 2);
      return palette!.color(selector + ((packed >> ((nibble & 1) * 4)) & 15));
    }
    if (format == 6) {
      return palette!.color(selector + _byte(base + paletteOffset + index));
    }
    if (format == 3) {
      if (mipMapped && w == 1) {
        final address = base + _rgbOffsets[0];
        return DcGpuPalette.decode(
            _byte(address) | (_byte(address + 1) << 8), 1,
            repeat: true);
      }
      final first = base + (mipMapped ? _rgbOffsets[exponent] : 0);
      final left = first + _index(x & ~1, y, w, h) * 2;
      final right = first + _index((x & ~1) + 1, y, w, h) * 2;
      return yuvColor(
          _byte((x.isOdd ? right : left) + 1), _byte(left), _byte(right));
    }
    // Low Morton bits select one texel inside the 2x2 codebook element.
    // The remaining bits address the half-width/half-height index image.
    final address = compressed
        ? base +
            _byte(base +
                    0x800 +
                    (mipMapped ? _vqOffsets[exponent] : 0) +
                    (index >> 2)) *
                8 +
            (mipMapped && w == 1 ? 3 : index & 3) * 2
        : base + (mipMapped ? _rgbOffsets[exponent] : 0) + index * 2;
    final value = _byte(address) | (_byte(address + 1) << 8);
    if (format == 4) return bumpColor(value, bumpParameters);
    return DcGpuPalette.decode(value, format == 7 ? 0 : format,
        repeat: twiddled);
  }

  /// Extra UVs correspond to screen offsets (0.5,0), (0,0.5), (0.5,0.5).
  int sample(double u, double v,
      {double footprint = 1,
      int? bumpParameters,
      List<(double, double)>? extraSamples}) {
    if (!superSample) {
      return _sample(u, v,
          footprint: footprint, bumpParameters: bumpParameters);
    }
    if (extraSamples == null || extraSamples.length != 3) {
      throw const DcUnsupported(
          'CORE supersampling requires three additional screen-space UVs');
    }
    final colors = [
      _sample(u, v, footprint: footprint, bumpParameters: bumpParameters),
      for (final (su, sv) in extraSamples)
        _sample(su, sv, footprint: footprint, bumpParameters: bumpParameters)
    ];
    var result = 0;
    for (var shift = 0; shift < 32; shift += 8) {
      var sum = 0;
      for (final color in colors) {
        sum += (color >> shift) & 255;
      }
      result |= ((sum + 2) ~/ 4) << shift;
    }
    return result & 0xffffffff;
  }

  int _sample(double u, double v,
      {required double footprint, int? bumpParameters}) {
    if (format == 4 && bumpParameters == null) {
      throw const DcUnsupported('CORE bump sample requires K1K2K3Q parameters');
    }
    final parameters = bumpParameters ?? 0;
    if (!u.isFinite || !v.isFinite) {
      throw const DcUnsupported('CORE nonfinite texture coordinate');
    }
    double position(double value, int size, bool clamp, bool flip) {
      value *= size;
      if (!value.isFinite) {
        throw const DcUnsupported('CORE texture coordinate overflow');
      }
      return clamp
          ? value.clamp(0.0, (size - 1).toDouble())
          : value % (flip ? size * 2 : size);
    }

    final level = mipMapped ? selectLevel(footprint) : 0;
    final x = position(u, width >> level, clampU, flipU),
        y = position(v, height >> level, clampV, flipV);
    final left = x.floor(), top = y.floor();
    if (!bilinear) return _texel(left, top, level, parameters);
    final tx = x - left, ty = y - top;
    final colors = [
      _texel(left, top, level, parameters),
      _texel(left + 1, top, level, parameters),
      _texel(left, top + 1, level, parameters),
      _texel(left + 1, top + 1, level, parameters)
    ];
    final weights = [
      (1 - tx) * (1 - ty),
      tx * (1 - ty),
      (1 - tx) * ty,
      tx * ty
    ];
    var color = 0;
    for (var shift = 0; shift < 32; shift += 8) {
      var channel = 0.0;
      for (var i = 0; i < 4; i++) {
        channel += ((colors[i] >> shift) & 255) * weights[i];
      }
      color |= roundByte(channel) << shift;
    }
    return color & 0xffffffff;
  }

  /// System Architecture sections 3.4.7.3.1 and 3.6.1.3, with host-double trig/rounding.
  static int bumpColor(int sr, int parameters) {
    int endpoint(int value) => value == 255 ? 256 : value;
    final s = endpoint((sr >> 8) & 255) * math.pi / 512;
    final r = endpoint(sr & 255) * (2 * math.pi / 256);
    final q = endpoint(parameters & 255) * (2 * math.pi / 256);
    final k1 = (parameters >> 24) & 255;
    final k2 = (parameters >> 16) & 255;
    final k3 = (parameters >> 8) & 255;
    final alpha = (k1 + k2 * math.sin(s) + k3 * math.cos(s) * math.cos(r - q))
        .round()
        .clamp(0, 255);
    return ((alpha << 24) | 0x00ffffff) & 0xffffffff;
  }

  /// The original CORE coefficients use full-range Y and unsigned chroma centered at 128.
  static int yuvColor(int y, int u, int v) {
    final du = u - 128, dv = v - 128;
    final r = ((y * 8 + 11 * dv) ~/ 8).clamp(0, 255);
    final g = ((y * 32 - 11 * du - 22 * dv) ~/ 32).clamp(0, 255);
    final b = ((y * 32 + 55 * du) ~/ 32).clamp(0, 255);
    return (0xff000000 | (r << 16) | (g << 8) | b) & 0xffffffff;
  }

  static int shade(int color, int texel, int offset, int tsp) {
    if (tsp & 0x80000 != 0) texel |= 0xff000000;
    final alpha = texel >> 24, mode = (tsp >> 6) & 3;
    var output = 0;
    for (var shift = 0; shift < 24; shift += 8) {
      final col = (color >> shift) & 255, tex = (texel >> shift) & 255;
      final channel = switch (mode) {
        0 => tex,
        1 || 3 => (col * tex + 127) ~/ 255,
        _ => (tex * alpha + col * (255 - alpha) + 127) ~/ 255,
      };
      output |= (channel + ((offset >> shift) & 255)).clamp(0, 255) << shift;
    }
    final a = switch (mode) {
      0 || 1 => alpha,
      2 => color >> 24,
      _ => ((color >> 24) * alpha + 127) ~/ 255,
    };
    return (output | (a << 24)) & 0xffffffff;
  }
}
