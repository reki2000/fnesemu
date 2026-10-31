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
  // Set once by the constructor. Plain fields avoid the late-initialization
  // check on every texel read.
  int width = 0, height = 0, stride = 0, format = 0, base = 0, selector = 0;
  int filterMode = 0;
  bool get trilinear => mipMapped && filterMode >= 2;
  bool superSample = false,
      twiddled = false,
      compressed = false,
      mipMapped = false,
      bilinear = false,
      clampU = false,
      clampV = false,
      flipU = false,
      flipV = false;
  int _maxLevel = 0;
  int get maxLevel => _maxLevel;
  double _adjust = 0;
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

  /// Bit `i` of the index moves to bit `2i`.
  static final _spread = Uint32List.fromList([
    for (var i = 0; i < 1024; i++)
      [for (var bit = 0; bit < 10; bit++) ((i >> bit) & 1) << (bit * 2)]
          .fold(0, (a, b) => a | b)
  ]);

  int _index(int x, int y, int levelWidth, int levelHeight) {
    if (!twiddled) return y * stride + x;
    // Interleave the low bits common to both sizes (V in even bits, U in odd
    // bits), then append the remaining bits of the longer side.
    final widthBits = levelWidth.bitLength - 1,
        heightBits = levelHeight.bitLength - 1;
    final bits = widthBits < heightBits ? widthBits : heightBits;
    if (bits < 0) return x | y;
    final mask = (1 << bits) - 1;
    return _spread[y & mask] |
        (_spread[x & mask] << 1) |
        (((x | y) >> bits) << (bits * 2));
  }

  int _byte(int address) {
    if (address < 0 || address >= memory.length) {
      throw const DcUnsupported('CORE texture read outside retail VRAM');
    }
    final offset =
        (address & 3) | ((address >> 1) & 0x3ffffc) | ((address & 4) << 20);
    return memory[offset];
  }

  @pragma('vm:prefer-inline')
  static int _coordinate(int value, int size, bool clamp, bool flip) {
    if (clamp) return value < 0 ? 0 : (value >= size ? size - 1 : value);
    if (size & (size - 1) == 0) {
      if (!flip) return value & (size - 1);
      value &= size * 2 - 1;
    } else {
      value %= flip ? size * 2 : size;
    }
    return value >= size ? size * 2 - value - 1 : value;
  }

  int _texel(int x, int y, int level, int bumpParameters) => _texelAt(
      _coordinate(x, width >> level, clampU, flipU),
      _coordinate(y, height >> level, clampV, flipV),
      level,
      bumpParameters);

  /// Decoded texels kept by the renderer for this texture's contents.
  DcTextureCache? cache;

  /// Reads a texel at coordinates already wrapped, clamped or mirrored.
  int _texelAt(int x, int y, int level, int bumpParameters) {
    final cache = this.cache;
    if (cache == null) return _decodeTexel(x, y, level, bumpParameters);
    final index = cache.levelOffsets[level] + y * (width >> level) + x;
    if (cache.stamps[index] == cache.generation) return cache.texels[index];
    final texel = _decodeTexel(x, y, level, bumpParameters);
    cache.texels[index] = texel;
    cache.stamps[index] = cache.generation;
    return texel;
  }

  /// Decodes every level-0 texel once per cache generation, so that
  /// [sampleBilinear] can skip the per-texel stamps.
  void decodeAll() {
    final cache = this.cache!;
    if (cache.complete == cache.generation) return;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        _texelAt(x, y, 0, 0);
      }
    }
    cache.complete = cache.generation;
  }

  int _decodeTexel(int x, int y, int level, int bumpParameters) {
    final w = width >> level, h = height >> level, exponent = _maxLevel - level;
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
    final level = mipMapped ? selectLevel(footprint) : 0;
    final w = width >> level, h = height >> level;
    final x = _position(u, w, clampU, flipU),
        y = _position(v, h, clampV, flipV);
    // Positions are nonnegative, so truncation is the floor.
    final left = x.toInt(), top = y.toInt();
    if (!bilinear) return _texel(left, top, level, parameters);
    final tx = x - left, ty = y - top;
    final x0 = _coordinate(left, w, clampU, flipU),
        x1 = _coordinate(left + 1, w, clampU, flipU),
        y0 = _coordinate(top, h, clampV, flipV),
        y1 = _coordinate(top + 1, h, clampV, flipV);
    final int c0, c1, c2, c3;
    final cache = this.cache;
    if (cache == null) {
      c0 = _decodeTexel(x0, y0, level, parameters);
      c1 = _decodeTexel(x1, y0, level, parameters);
      c2 = _decodeTexel(x0, y1, level, parameters);
      c3 = _decodeTexel(x1, y1, level, parameters);
    } else {
      // The cache lookup of [_texelAt], inlined for the four taps.
      final texels = cache.texels, stamps = cache.stamps;
      final generation = cache.generation;
      final row0 = cache.levelOffsets[level] + y0 * w,
          row1 = cache.levelOffsets[level] + y1 * w;
      c0 = stamps[row0 + x0] == generation
          ? texels[row0 + x0]
          : _texelAt(x0, y0, level, parameters);
      c1 = stamps[row0 + x1] == generation
          ? texels[row0 + x1]
          : _texelAt(x1, y0, level, parameters);
      c2 = stamps[row1 + x0] == generation
          ? texels[row1 + x0]
          : _texelAt(x0, y1, level, parameters);
      c3 = stamps[row1 + x1] == generation
          ? texels[row1 + x1]
          : _texelAt(x1, y1, level, parameters);
    }
    return _filter(c0, c1, c2, c3, tx, ty);
  }

  /// Whether [sampleBilinear] applies: a cached bilinear texture without
  /// MIP maps, bump mapping or supersampling.
  bool get plainBilinear =>
      bilinear && !mipMapped && format != 4 && !superSample && cache != null;

  /// [sample] of a [plainBilinear] texture.
  @pragma('vm:prefer-inline')
  @pragma('vm:unsafe:no-bounds-checks')
  int sampleBilinear(double u, double v) {
    final w = width, h = height;
    final cache = this.cache!;
    final su = u * w, sv = v * h;
    // NaN fails these tests and is rejected on the general path.
    if (su >= 0 && su < w - 1 && sv >= 0 && sv < h - 1) {
      // Both taps of each axis lie inside: no wrap, mirror or clamp.
      final left = su.toInt(), top = sv.toInt();
      final row0 = cache.levelOffsets[0] + top * w + left, row1 = row0 + w;
      final stamps = cache.stamps, generation = cache.generation;
      if (cache.complete == generation ||
          stamps[row0] == generation &&
              stamps[row0 + 1] == generation &&
              stamps[row1] == generation &&
              stamps[row1 + 1] == generation) {
        final texels = cache.texels;
        return _filter(texels[row0], texels[row0 + 1], texels[row1],
            texels[row1 + 1], su - left, sv - top);
      }
    }
    return _sampleBilinearSlow(u, v);
  }

  /// [sampleBilinear] at texel positions in 16.16 fixed point, or -1 when
  /// a tap needs wrapping or decoding.
  @pragma('vm:prefer-inline')
  @pragma('vm:unsafe:no-bounds-checks')
  int sampleBilinearFixed(int su, int sv) {
    final w = width, cache = this.cache!;
    if (su < 0 ||
        su >= (w - 1) << 16 ||
        sv < 0 ||
        sv >= (height - 1) << 16 ||
        cache.complete != cache.generation) {
      return -1;
    }
    final row0 = cache.levelOffsets[0] + (sv >> 16) * w + (su >> 16);
    final row1 = row0 + w, texels = cache.texels;
    return _blend4(
        texels[row0],
        texels[row0 + 1],
        texels[row1],
        texels[row1 + 1],
        ((su & 0xffff) + 128) >> 8,
        ((sv & 0xffff) + 128) >> 8);
  }

  int _sampleBilinearSlow(double u, double v) {
    if (!u.isFinite || !v.isFinite) {
      throw const DcUnsupported('CORE nonfinite texture coordinate');
    }
    final w = width, h = height;
    final cache = this.cache!;
    final texels = cache.texels, stamps = cache.stamps;
    final generation = cache.generation;
    final x = _position(u, w, clampU, flipU),
        y = _position(v, h, clampV, flipV);
    final left = x.toInt(), top = y.toInt();
    final x0 = _coordinate(left, w, clampU, flipU),
        x1 = _coordinate(left + 1, w, clampU, flipU),
        y0 = _coordinate(top, h, clampV, flipV),
        y1 = _coordinate(top + 1, h, clampV, flipV);
    final row0 = cache.levelOffsets[0] + y0 * w,
        row1 = cache.levelOffsets[0] + y1 * w;
    final c0 = stamps[row0 + x0] == generation
        ? texels[row0 + x0]
        : _texelAt(x0, y0, 0, 0);
    final c1 = stamps[row0 + x1] == generation
        ? texels[row0 + x1]
        : _texelAt(x1, y0, 0, 0);
    final c2 = stamps[row1 + x0] == generation
        ? texels[row1 + x0]
        : _texelAt(x0, y1, 0, 0);
    final c3 = stamps[row1 + x1] == generation
        ? texels[row1 + x1]
        : _texelAt(x1, y1, 0, 0);
    return _filter(c0, c1, c2, c3, x - left, y - top);
  }

  @pragma('vm:prefer-inline')
  static int _filter(int c0, int c1, int c2, int c3, double tx, double ty) {
    // Weights in 1/256 steps; the filter fraction precision is unverified.
    return _blend4(
        c0, c1, c2, c3, (tx * 256 + 0.5).toInt(), (ty * 256 + 0.5).toInt());
  }

  @pragma('vm:prefer-inline')
  static int _blend4(int c0, int c1, int c2, int c3, int fx, int fy) {
    // All four channels in 16-bit lanes: a horizontal then a vertical
    // blend, each lane staying below 2^16 before its rounding shift.
    const lanes = 0x00ff00ff00ff00ff, half = 0x0080008000800080;
    final gx = 256 - fx;
    final top = ((_lanes(c0) * gx + _lanes(c1) * fx + half) >>> 8) & lanes;
    final bottom = ((_lanes(c2) * gx + _lanes(c3) * fx + half) >>> 8) & lanes;
    final mixed = ((top * (256 - fy) + bottom * fy + half) >>> 8) & lanes;
    return (mixed & 0xff00ff) | ((mixed >>> 24) & 0xff00ff00);
  }

  /// The channels of a color at bits 0, 16, 32 and 48, in the order
  /// 0, 2, 1, 3.
  @pragma('vm:prefer-inline')
  static int _lanes(int c) => (c & 0xff00ff) | ((c & 0xff00ff00) << 24);

  @pragma('vm:prefer-inline')
  static double _position(double value, int size, bool clamp, bool flip) {
    value *= size;
    // In-range positions are their own wrap, mirror and clamp results.
    if (value >= 0 && value < size - 1) return value;
    if (!value.isFinite) {
      throw const DcUnsupported('CORE texture coordinate overflow');
    }
    if (clamp) {
      final last = (size - 1).toDouble();
      return value < 0 ? 0.0 : (value > last ? last : value);
    }
    return value % (flip ? size * 2 : size);
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

  @pragma('vm:prefer-inline')

  /// [shade] in mode 1, or mode 3 with an opaque color, where the color
  /// has the same [gray] value in each RGB channel. [alpha] is ORed into
  /// the texel.
  @pragma('vm:prefer-inline')
  static int shadeGray(int texel, int gray, int offset, int alpha) {
    const lanes = 0x00ff00ff00ff00ff;
    // div255 of each lane's product plus 127, exact for byte operands.
    final x = _lanes(texel) * gray + 0x007f007f007f007f;
    final m = ((x + ((x >>> 8) & lanes) + 0x0001000100010001) >>> 8) & lanes;
    var rgb = ((m & 0xff0000) << 4) | ((m >>> 22) & 0x3fc00) | (m & 255);
    rgb +=
        ((offset & 0xff0000) << 4) | ((offset & 0xff00) << 2) | (offset & 255);
    rgb |= ((rgb >> 8) & 0x100401) * 255;
    return ((texel | alpha) & 0xff000000) |
        ((rgb >> 4) & 0xff0000) |
        ((rgb >> 2) & 0xff00) |
        (rgb & 0xff);
  }

  @pragma('vm:prefer-inline')
  static int shade(int color, int texel, int offset, int tsp) {
    if (tsp & 0x80000 != 0) texel |= 0xff000000;
    final alpha = (texel >> 24) & 255, mode = (tsp >> 6) & 3;
    final tr = (texel >> 16) & 255, tg = (texel >> 8) & 255, tb = texel & 255;
    int r, g, b, a;
    if (mode == 0) {
      r = tr;
      g = tg;
      b = tb;
      a = alpha;
    } else {
      final cr = (color >> 16) & 255, cg = (color >> 8) & 255;
      final cb = color & 255, ca = (color >> 24) & 255;
      if (mode == 2) {
        final inverse = 255 - alpha;
        r = div255(tr * alpha + cr * inverse + 127);
        g = div255(tg * alpha + cg * inverse + 127);
        b = div255(tb * alpha + cb * inverse + 127);
        a = ca;
      } else {
        r = div255(cr * tr + 127);
        g = div255(cg * tg + 127);
        b = div255(cb * tb + 127);
        a = mode == 1 ? alpha : div255(ca * alpha + 127);
      }
    }
    // Add the offset in 10-bit lanes; a carry out of a lane saturates it.
    var lanes = ((r << 20) | (g << 10) | b) +
        (((offset & 0xff0000) << 4) |
            ((offset & 0xff00) << 2) |
            (offset & 255));
    lanes |= ((lanes >> 8) & 0x100401) * 255;
    return (a << 24) |
        ((lanes >> 4) & 0xff0000) |
        ((lanes >> 2) & 0xff00) |
        (lanes & 0xff);
  }
}

/// Texels of one texture decoded on first use. A texel is valid while its
/// stamp equals [generation], so invalidation is a counter increment.
class DcTextureCache {
  DcTextureCache(int size, this.levelOffsets)
      : texels = Uint32List(size),
        stamps = Uint32List(size);
  final Uint32List texels, stamps;
  final Int32List levelOffsets;
  int generation = 1;

  /// The generation in which every level-0 texel was decoded.
  int complete = 0;

  /// VRAM page clock and palette version when the contents were validated.
  int checked = 0, paletteVersion = -1;

  void invalidate() {
    if (++generation == 0xffffffff) {
      stamps.fillRange(0, stamps.length, 0);
      generation = 1;
      complete = 0;
    }
  }
}
