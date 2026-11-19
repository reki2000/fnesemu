import 'dart:math' as math;
import 'dart:typed_data';

import 'allegrex.dart';

/// The multimedia coprocessor: 128 single-precision registers arranged
/// as eight 4x4 matrices, vector operations of one to four lanes with
/// operand prefixes, matrix operations and a random generator.
///
/// A register operand is seven bits: bits 4-2 select the matrix, bits
/// 1-0 and 6-5 locate the anchor element, and bit 5 also selects the
/// orientation of a vector: clear enumerates a column (rows increase),
/// set enumerates a row (columns increase). Pairs start at element 0 or
/// 2 of their row or column, triples and quads at element 0.
///
/// The arithmetic follows the hardware float rules as far as the test
/// programs pin them down: denormal inputs and results are flushed to
/// zero, and the transcendental operations use double-precision
/// approximations whose results are rounded to single precision.
extension PspVfpuExec on Allegrex {
  static final _scratch = Float32List(1);
  static final _scratchBits = ByteData.view(_scratch.buffer);

  static int _bits(double value) {
    _scratch[0] = value;
    return _scratchBits.getUint32(0, Endian.little);
  }

  static double _floatOf(int bits) {
    _scratchBits.setUint32(0, bits & 0xffffffff, Endian.little);
    return _scratch[0];
  }

  /// Flushes a denormal to a signed zero; every other value passes.
  static double _clean(double value) {
    if (value == 0 || value.isNaN || value.isInfinite) return value;
    if (value.abs() < 1.1754943508222875e-38) {
      return value.isNegative ? -0.0 : 0.0;
    }
    return value;
  }

  /// Rounds a computed value to single precision.
  static double _round(double value) {
    _scratch[0] = value;
    return _clean(_scratch[0]);
  }

  static final _dbits = Float64List(1);
  static final _dbitsView = ByteData.view(_dbits.buffer);

  /// The stored bits of a computed value: the canonical NaN for a
  /// NaN result, with the sign the computation produced (recovered
  /// from the double's own sign bit, which the single-precision
  /// conversion would lose), else the rounded value's bits.
  static int _resultBits(double value) {
    if (value.isNaN) {
      _dbits[0] = value;
      final sign = _dbitsView.getUint64(0, Endian.little) >> 63;
      return 0x7f800001 | (sign << 31);
    }
    return _bits(_round(value));
  }

  /// The storage indices of a vector operand's lanes, in lane order.
  ///
  /// The operand names an anchor element by its matrix, its row (bits
  /// 6-5) and its column (bits 1-0); bit 5 also gives the direction,
  /// down a column when clear and along a row when set. A vector's
  /// bits 1-0 name the column it runs down, or the row it runs along.
  /// Bit 6 places its first lane: a pair starts at lane 0 or 2, a
  /// triple at lane 0 or 1, and a quad at lane 0.
  List<int> _elems(int operand, int count) {
    final matrix = (operand >> 2) & 7;
    final base = matrix * 16;
    final line = operand & 3;
    if (count == 1) {
      return [base + ((operand >> 5) & 3) * 4 + line];
    }
    final half = (operand >> 6) & 1;
    final start = count == 2 ? half * 2 : (count == 3 ? half : 0);
    if (operand & 0x20 == 0) {
      return [
        for (var i = 0; i < count; i++) base + (start + i) * 4 + line
      ];
    }
    return [
      for (var i = 0; i < count; i++) base + line * 4 + start + i
    ];
  }

  int _sizeOf(int w) =>
      ((w >> 15) & 1) * 2 + ((w >> 7) & 1) + 1;

  /// The constants a source prefix can substitute, indexed by the
  /// swizzle code plus four when the absolute-value bit is set.
  static const _prefixConstants = [
    0.0, 1.0, 2.0, 0.5, 3.0, 1 / 3, 0.25, 1 / 6,
  ];

  /// The named constants of the vcst operation, as float bit
  /// patterns, in selector order from 0x60: (unused), huge, sqrt(2),
  /// sqrt(1/2), 2/sqrt(pi), 2/pi, 1/pi, pi/4, pi/2, pi, e, log2(e),
  /// log10(e), ln(2), ln(10), 2pi, pi/6, log10(2), log2(10), sqrt(3)/2.
  static const _vcstBits = [
    0x00000000, 0x7f7fffff, 0x3fb504f3, 0x3f3504f3, 0x3f906ebb,
    0x3f22f983, 0x3ea2f983, 0x3f490fdb, 0x3fc90fdb, 0x40490fdb,
    0x402df854, 0x3fb8aa3b, 0x3ede5bd9, 0x3f317218, 0x40135d8e,
    0x40c90fdb, 0x3f060a92, 0x3e9a209b, 0x40549a78, 0x3f5db3d7,
  ];

  /// Pi over two at single precision, the scale of the trigonometric
  /// operations: their arguments are in quarter turns, and the
  /// multiplication behaves as if done with this constant, which the
  /// signed-zero results at whole turns pin down.
  static const _halfPi = 1.5707963705062866;

  /// Reads the four lanes of [operand]'s vector through a source
  /// prefix: swizzle or constant selection, absolute value, negation.
  /// The view covers the vector's own lanes (per [size]); positions
  /// past its end read as zero. Unless [raw] is set, denormal values
  /// are flushed to zero on the way in, as the arithmetic operations
  /// do.
  ///
  /// With [pipes] set (the computational operations), quirks of the
  /// prefix unit apply. A used lane before the last whose field
  /// names a register lane past the size makes that result lane come
  /// out as zero (both modes). With pipes == 2 (the reciprocal and
  /// transcendental operations and vdiv), the last lane is governed
  /// by the prefix's first field rather than its own: a constant
  /// there supplies the value, a swizzle of zero applies the field's
  /// absolute value and negation to the raw last lane, and any other
  /// swizzle makes the lane zero (as a value for the second source,
  /// as a written zero for the first).
  List<double> _readSource(int operand, int prefix,
      [int size = 4,
      bool raw = false,
      bool second = false,
      int pipes = 0]) {
    final lanes = _viewLanes(operand, size);
    final out = List<double>.filled(4, 0);
    double readLane(int at) => at < 0
        ? 0.0
        : (raw ? _floatOf(v[at]) : _clean(_floatOf(v[at])));
    if (pipes == 2) {
      // The reciprocal pipe reads its lanes before the last raw,
      // with no prefix at all; only the last lane interacts with
      // the prefix, through its first field (handled below).
      for (var i = 0; i < size - 1; i++) {
        out[i] = readLane(lanes[i]);
      }
      for (var i = size; i < 4; i++) {
        out[i] = readLane(lanes[i]);
      }
    }
    for (var i = 0; i < 4; i++) {
      if (pipes == 2 && i < size - 1) continue;
      final swizzle = (prefix >> (2 * i)) & 3;
      double value;
      if ((prefix >> (12 + i)) & 1 != 0) {
        // A constant selection is always in range.
        final abs = (prefix >> (8 + i)) & 1;
        value = _prefixConstants[swizzle + abs * 4];
      } else {
        if (pipes > 0 &&
            swizzle >= size &&
            (i < size - 1 || (pipes == 1 && i == size - 1))) {
          vfpuZeroLanes |= 1 << i;
        }
        value = readLane(lanes[swizzle]);
        if ((prefix >> (8 + i)) & 1 != 0) value = value.abs();
      }
      if ((prefix >> (16 + i)) & 1 != 0) value = -value;
      out[i] = value;
    }
    if (pipes == 2 && size >= 1) {
      final last = size - 1;
      if ((prefix >> 12) & 1 != 0) {
        // The first field's constant supplies the last lane too.
        final abs = (prefix >> 8) & 1;
        out[last] = _prefixConstants[(prefix & 3) + abs * 4];
      } else if ((prefix & 3) == 0) {
        var value = readLane(lanes[last]);
        if ((prefix >> 8) & 1 != 0) value = value.abs();
        if ((prefix >> 16) & 1 != 0) value = -value;
        out[last] = value;
      } else if (second) {
        out[last] = 0;
      } else {
        vfpuZeroLanes |= 1 << last;
        out[last] = 0;
      }
    }
    return out;
  }

  /// The four storage indices a source prefix sees for [operand]:
  /// the vector's own lanes (per [size]); the remaining positions of
  /// the view are not backed by the vector and read as zero (marked
  /// here with -1).
  List<int> _viewLanes(int operand, int size) {
    final vec = _elems(operand, size);
    final lanes = List<int>.filled(4, -1);
    for (var i = 0; i < size; i++) {
      lanes[i] = vec[i];
    }
    return lanes;
  }

  /// Writes [count] lanes of [values] to [operand] through the pending
  /// destination prefix (write mask and saturation), then consumes all
  /// pending prefixes.
  void _writeDest(int operand, int count, List<double> values) {
    final lanes = _elems(operand, count);
    for (var i = 0; i < count; i++) {
      if ((vpfxd >> (8 + i)) & 1 != 0) continue;
      if ((vfpuZeroLanes >> i) & 1 != 0) {
        v[lanes[i]] = 0;
        continue;
      }
      var value = values[i];
      final saturation = (vpfxd >> (2 * i)) & 3;
      if (!value.isNaN) {
        if (saturation == 1) {
          value = value.clamp(0.0, 1.0).toDouble();
        } else if (saturation == 3) {
          value = value.clamp(-1.0, 1.0).toDouble();
        }
      }
      v[lanes[i]] = _resultBits(value);
    }
    _consumePrefixes();
  }

  /// Writes the result of a reciprocal-pipe operation: the lanes
  /// before the last take no destination prefix at all, and the last
  /// lane takes the destination prefix's first field (its mask and
  /// its saturation). Consumes all pending prefixes.
  void _writeDestPipeB(int operand, int count, List<double> values) {
    final lanes = _elems(operand, count);
    for (var i = 0; i < count; i++) {
      if (i != count - 1) {
        v[lanes[i]] = _resultBits(values[i]);
        continue;
      }
      if ((vpfxd >> 8) & 1 != 0) continue;
      if ((vfpuZeroLanes >> i) & 1 != 0) {
        v[lanes[i]] = 0;
        continue;
      }
      var value = values[i];
      final saturation = vpfxd & 3;
      if (!value.isNaN) {
        if (saturation == 1) {
          value = value.clamp(0.0, 1.0).toDouble();
        } else if (saturation == 3) {
          value = value.clamp(-1.0, 1.0).toDouble();
        }
      }
      v[lanes[i]] = _resultBits(value);
    }
    _consumePrefixes();
  }

  /// Writes raw words to [count] lanes of [operand], honouring only the
  /// destination write mask, then consumes all pending prefixes.
  void _writeDestBits(int operand, int count, List<int> words) {
    final lanes = _elems(operand, count);
    for (var i = 0; i < count; i++) {
      if ((vpfxd >> (8 + i)) & 1 != 0) continue;
      if ((vfpuZeroLanes >> i) & 1 != 0) {
        v[lanes[i]] = 0;
        continue;
      }
      var word = words[i] & 0xffffffff;
      // The destination saturation applies to the result read as a
      // float, even when the operation produced raw words; a NaN
      // keeps its bits and denormals pass through.
      final saturation = (vpfxd >> (2 * i)) & 3;
      if (saturation == 1 || saturation == 3) {
        final value = _floatOf(word);
        if (!value.isNaN) {
          final clamped = saturation == 1
              ? value.clamp(0.0, 1.0)
              : value.clamp(-1.0, 1.0);
          word = _bits(clamped.toDouble());
        }
      }
      v[lanes[i]] = word;
    }
    _consumePrefixes();
  }

  void _consumePrefixes() {
    vpfxs = AllegrexState.pfxDefault;
    vpfxt = AllegrexState.pfxDefault;
    vpfxd = AllegrexState.pfxdDefault;
  }

  /// The register operand of a load or store: bits 4-0 ride in the rt
  /// field, bits 6-5 above the offset, whose low bits carry flags.
  /// The register operand of a load or store: bits 4-0 sit above the
  /// displacement and bits 6-5 in its low two bits, which the
  /// displacement itself does not use (it is a multiple of four).
  static int _loadReg(int w) =>
      (((w >> 16) & 0x1f) | ((w & 3) << 5)) & 0x7f;

  bool execVfpu(int w) {
    vfpuZeroLanes = 0;
    final op = w >>> 26;
    switch (op) {
      case 0x12:
        return _cop2(w);
      case 0x18:
      case 0x19:
      case 0x1b:
        return _arith(w);
      case 0x32:
      case 0x35:
      case 0x36:
      case 0x3a:
      case 0x3d:
      case 0x3e:
        return _loadStore(w);
      case 0x34:
        return _vfpu4(w);
      case 0x37:
        return _vfpu5(w);
      case 0x3c:
        return _vfpu6(w);
      case 0x3f:
        // VNOP (0xffff0000) and the synchronisation words are no-ops.
        return (w >>> 16) == 0xffff;
      default:
        return false;
    }
  }

  bool _loadStore(int w) {
    final op = w >>> 26;
    final base = r[(w >> 21) & 31];
    final operand = _loadReg(w);
    // The displacement is sixteen bits wide; its low two bits hold
    // the operand's top bits instead, so it is a multiple of four.
    final offset = ((w & 0xffff) & ~3).toSigned(16);
    final addr = base + offset;
    if (op == 0x32 || op == 0x3a) {
      // LV.S / SV.S: a single element.
      final at = _elems(operand, 1)[0];
      if (op == 0x32) {
        v[at] = mem.read32(addr);
      } else {
        mem.write32(addr, v[at]);
      }
      return true;
    }
    final lanes = _elems(operand, 4);
    switch (op) {
      case 0x36: // LV.Q
        for (var i = 0; i < 4; i++) {
          v[lanes[i]] = mem.read32(addr + 4 * i);
        }
        return true;
      case 0x3e: // SV.Q
        for (var i = 0; i < 4; i++) {
          mem.write32(addr + 4 * i, v[lanes[i]]);
        }
        return true;
      case 0x35: // LVL.Q / LVR.Q
      case 0x3d: // SVL.Q / SVR.Q
        final right = (w >> 1) & 1 != 0;
        final quarter = (addr >> 2) & 3;
        if (!right) {
          // The left form covers the words from the block start through
          // the addressed word, landing in the top of the register.
          final block = addr & ~15;
          for (var j = 0; j <= quarter; j++) {
            final lane = lanes[j + 3 - quarter];
            if (op == 0x35) {
              v[lane] = mem.read32(block + 4 * j);
            } else {
              mem.write32(block + 4 * j, v[lane]);
            }
          }
        } else {
          // The right form covers the words from the addressed word
          // through the block end, landing in the bottom of the register.
          for (var j = 0; j + quarter <= 3; j++) {
            final lane = lanes[j];
            if (op == 0x35) {
              v[lane] = mem.read32(addr + 4 * j);
            } else {
              mem.write32(addr + 4 * j, v[lane]);
            }
          }
        }
        return true;
      default:
        return false;
    }
  }

  /// The three-operand and compare operations of VFPU0, VFPU1 and
  /// VFPU3, selected by the major opcode, the function field at bits
  /// 25-23 and the minor opcode at bits 5-0.
  bool _arith(int w) {
    final op = w >>> 26;
    final func = (w >> 23) & 7;
    final vd = w & 0x7f, vs = (w >> 8) & 0x7f, vt = (w >> 16) & 0x7f;
    final n = _sizeOf(w);
    if (op == 0x1b && func == 0) {
      return _compare(w, vs, vt, n);
    }
    // The minor-opcode bits are the top of the destination operand, so
    // the operation is selected by the major opcode and function alone.
    final key = (op << 4) | func;
    // VDIV goes through the reciprocal pipe, with its last-lane
    // prefix behaviour; the rest of the arithmetic does not.
    final pipes = key == 0x187 ? 2 : 1;
    final a = _readSource(vs, vpfxs, n, false, false, pipes);
    // VSCL's second source is a single scalar, read with its own size.
    final b = _readSource(vt, vpfxt, key == 0x192 ? 1 : n, false, true, pipes);
    switch (key) {
      case 0x180: // VADD
        _writeDest(vd, n, [for (var i = 0; i < n; i++) a[i] + b[i]]);
        return true;
      case 0x181: // VSUB
        _writeDest(vd, n, [for (var i = 0; i < n; i++) a[i] - b[i]]);
        return true;
      case 0x187: // VDIV
        _writeDestPipeB(vd, n, [for (var i = 0; i < n; i++) a[i] / b[i]]);
        return true;
      case 0x190: // VMUL
        _writeDest(vd, n, [for (var i = 0; i < n; i++) a[i] * b[i]]);
        return true;
      case 0x192: // VSCL: the second source is a single scalar
        _writeDest(vd, n, [for (var i = 0; i < n; i++) a[i] * b[0]]);
        return true;
      case 0x191: // VDOT: the products of the whole prefix view,
        // whose lanes past the size read as zero (constants count)
        var sum = 0.0;
        for (var i = 0; i < 4; i++) {
          sum += a[i] * b[i];
        }
        _writeDest(vd, 1, [sum]);
        return true;
      case 0x194: // VHDP: the dot product with the last used lane's
        // product replaced by the second source's lane itself; the first
        // source's last lane is not read, so a NaN there does not matter
        var sum = 0.0;
        for (var i = 0; i < 4; i++) {
          sum += i == n - 1 ? b[i] : a[i] * b[i];
        }
        _writeDest(vd, 1, [sum]);
        return true;
      case 0x196: // VDET of a pair; a zero result is a positive zero
        final det = a[0] * b[1] - a[1] * b[0];
        _writeDest(vd, 1, [det == 0 ? 0.0 : det]);
        return true;
      case 0x195: // VCRS: the cyclic products of two triples, the
        // positive terms of a cross product
        _writeDest(vd, 3, [
          a[1] * b[2],
          a[2] * b[0],
          a[0] * b[1],
        ]);
        return true;
      case 0x1b2: // VMIN
      case 0x1b3: // VMAX: select an operand by the sort ordering
        // (denormals flushed, NaNs ordered as signed infinities),
        // keeping the winner's exact bits.
        final x = _readSourceBits(vs, vpfxs, n);
        final y = _readSourceBits(vt, vpfxt, n);
        _writeDestBits(vd, n, [
          for (var i = 0; i < n; i++)
            _select(key == 0x1b2, x[i], y[i]),
        ]);
        return true;
      case 0x1b5: // VSCMP: the three-way comparison of the lanes
        _writeDest(vd, n, [
          for (var i = 0; i < n; i++)
            a[i] > b[i] ? 1.0 : (a[i] < b[i] ? -1.0 : 0.0),
        ]);
        return true;
      case 0x1b6: // VSGE
        _writeDest(vd, n, [
          for (var i = 0; i < n; i++) a[i] >= b[i] ? 1.0 : 0.0,
        ]);
        return true;
      case 0x1b7: // VSLT
        _writeDest(vd, n, [
          for (var i = 0; i < n; i++) a[i] < b[i] ? 1.0 : 0.0,
        ]);
        return true;
      default:
        return false;
    }
  }

  /// VCMP: per-lane comparisons into the condition codes. Bits 0-3 are
  /// the lanes, bit 4 is "any", bit 5 is "all", bit 6 is "none".
  bool _compare(int w, int vs, int vt, int n) {
    final cond = w & 0x1f;
    final a = _readSource(vs, vpfxs, n);
    final b = _readSource(vt, vpfxt, n);
    var bits = 0;
    var any = false, all = true;
    for (var i = 0; i < n; i++) {
      final x = a[i], y = b[i];
      final result = switch (cond) {
        0 => false, // F
        1 => x == y, // EQ
        2 => x < y, // LT
        3 => x <= y, // LE
        4 => true, // TR
        5 => x != y, // NE
        6 => x >= y, // GE
        7 => x > y, // GT
        8 => x == 0, // EZ
        9 => x.isNaN, // EN
        10 => x.isInfinite, // EI
        11 => x.isNaN || x.isInfinite, // ES
        12 => x != 0, // NZ
        13 => !x.isNaN, // NN
        14 => !x.isInfinite, // NI
        15 => !x.isNaN && !x.isInfinite, // NS
        _ => false,
      };
      if (result) {
        bits |= 1 << i;
        any = true;
      } else {
        all = false;
      }
    }
    vcc = bits |
        (any ? 0x10 : 0) |
        (all ? 0x20 : 0) |
        (any ? 0 : 0x40);
    _consumePrefixes();
    return true;
  }

  /// VFPU5: the prefix instructions and the immediate moves.
  bool _vfpu5(int w) {
    final func = (w >> 23) & 7;
    switch (func) {
      case 0: // VPFXS
        vpfxs = w & 0xfffff;
        return true;
      case 2: // VPFXT
        vpfxt = w & 0xfffff;
        return true;
      case 4: // VPFXD
        vpfxd = w & 0xfffff;
        return true;
      case 6: // VIIM: the immediate becomes the register's raw bits
        final at = _elems((w >> 16) & 0x7f, 1)[0];
        v[at] = (w & 0xffff).toSigned(16) & 0xffffffff;
        return true;
      case 7: // VFIM: the immediate is a half-precision float
        final at = _elems((w >> 16) & 0x7f, 1)[0];
        v[at] = _halfBits(w & 0xffff);
        return true;
      default:
        return false;
    }
  }

  /// The single-precision bits a half-precision value converts to.
  static int _halfBits(int half) {
    final sign = (half >> 15) & 1;
    final exp = (half >> 10) & 0x1f;
    final mant = half & 0x3ff;
    if (exp == 0) {
      // Zero and denormal halves alike become a signed zero.
      return sign << 31;
    }
    if (exp == 31) {
      // A NaN half keeps its mantissa in place, unshifted.
      return (sign << 31) | 0x7f800000 | mant;
    }
    return (sign << 31) | ((exp - 15 + 127) << 23) | (mant << 13);
  }

  /// The half-precision bits of a single: the mantissa is truncated,
  /// values below the smallest normal half become a signed zero and
  /// values above the largest become infinity.
  static int _floatToHalf(int bits) {
    final sign = (bits >> 31) & 1;
    final exp = (bits >> 23) & 0xff;
    final mant = bits & 0x7fffff;
    if (exp == 0xff) {
      // Infinities keep no mantissa; a NaN keeps its low ten bits.
      return (sign << 15) | 0x7c00 | (mant & 0x3ff);
    }
    final e = exp - 127 + 15;
    if (e >= 31) return (sign << 15) | 0x7c00;
    if (e <= 0) return sign << 15;
    return (sign << 15) | (e << 10) | (mant >> 13);
  }

  /// COP2: moves between the integer core and the coprocessor, the
  /// control registers and the condition branches.
  bool _cop2(int w) {
    final rs = (w >> 21) & 31;
    final rt = (w >> 16) & 31;
    switch (rs) {
      case 0: // MFC2
        final reg = ((w >> 11) & 0x1f) | (((w >> 6) & 3) << 5);
        if (rt != 0) r[rt] = v[_elems(reg, 1)[0]].toSigned(32);
        return true;
      case 4: // MTC2
        final reg = ((w >> 11) & 0x1f) | (((w >> 6) & 3) << 5);
        v[_elems(reg, 1)[0]] = r[rt] & 0xffffffff;
        return true;
      case 2: // CFC2: register 31 reads the condition codes
        if (rt != 0) {
          r[rt] = ((w >> 11) & 31) == 31 ? vcc : 0;
        }
        return true;
      case 6: // CTC2
        if (((w >> 11) & 31) == 31) vcc = r[rt] & 0xff;
        return true;
      case 3: // MFVC
        if (rt != 0) r[rt] = _readControl(w & 0xff);
        return true;
      case 7: // MTVC
        _writeControl(w & 0xff, r[rt]);
        return true;
      case 8: // BVF / BVT / BVFL / BVTL
        final code = (w >> 18) & 7;
        final kind = (w >> 16) & 3;
        final taken = (kind & 1) == 0
            ? (vcc >> code) & 1 == 0
            : (vcc >> code) & 1 != 0;
        if (taken) {
          nextPc = pc + ((w & 0xffff).toSigned(16) << 2);
        } else if (kind >= 2) {
          pc = nextPc;
          nextPc = pc + 4;
        }
        return true;
      default:
        return false;
    }
  }

  /// Reads a control register: 0-127 are the register file itself,
  /// 128-130 the pending prefixes, 131 the condition codes and
  /// 136-143 the random generator's state registers.
  int _readControl(int index) {
    switch (index) {
      case 128:
        return vpfxs;
      case 129:
        return vpfxt;
      case 130:
        return vpfxd;
      case 131:
        return vcc;
      default:
        if (index >= 0 && index < 128) {
          return v[_elems(index, 1)[0]];
        }
        if (index >= 136 && index < 144) return rcx[index - 136];
        return 0;
    }
  }

  void _writeControl(int index, int value) {
    switch (index) {
      case 128:
        vpfxs = value & 0xfffff;
      case 129:
        vpfxt = value & 0xfffff;
      case 130:
        vpfxd = value & 0xfff;
      case 131:
        vcc = value & 0xff;
      default:
        if (index >= 0 && index < 128) {
          v[_elems(index, 1)[0]] = value & 0xffffffff;
        } else if (index >= 136 && index < 144) {
          // The random state registers hold a float in [1, 2): a
          // write keeps only the low twenty bits as its mantissa.
          rcx[index - 136] = 0x3f800000 | (value & 0x000fffff);
        }
    }
  }

  /// VFPU4: the one-source operations, selected by the rs field. With
  /// rs 0 the operation sits at bits 22-16; the float / integer
  /// conversions carry a scale at bits 20-16 instead.
  bool _vfpu4(int w) {
    final family = (w >> 23) & 7;
    final sel = (w >> 16) & 0x7f;
    final vd = w & 0x7f, vs = (w >> 8) & 0x7f;
    final n = _sizeOf(w);
    if (family == 4) {
      // VF2IN / VF2IZ / VF2IU / VF2ID by bits 22-21, with a scale.
      final scale = math.pow(2.0, (w >> 16) & 31).toDouble();
      final a = _readSource(vs, vpfxs, n);
      final mode = (w >> 21) & 3;
      _writeDestBits(vd, n, [
        for (var i = 0; i < n; i++) _floatToInt(a[i] * scale, mode),
      ]);
      return true;
    }
    if (family == 5) {
      final sub = (w >> 21) & 3;
      if (sub == 0) {
        // VI2F, with a scale.
        final scale = math.pow(2.0, -((w >> 16) & 31)).toDouble();
        final lanes = _elems(vs, n);
        _writeDest(vd, n, [
          for (var i = 0; i < n; i++)
            v[lanes[i]].toSigned(32) * scale,
        ]);
        return true;
      }
      if (sub == 1) {
        // VCMOVT (bit 19 clear) and VCMOVF (bit 19 set): copy when the
        // named condition code is set or clear. Code 6 tests each lane
        // against its own condition code bit; code 7 is unspecified.
        final code = (w >> 16) & 7;
        final want = (w >> 19) & 1 == 0 ? 1 : 0;
        bool moves(int lane) =>
            code < 6 && (vcc >> code) & 1 == want ||
            code == 6 && (vcc >> lane) & 1 == want;
        if (code == 6) {
          final a = _readSource(vs, vpfxs, n);
          final lanes = _elems(vd, n);
          _writeDest(vd, n, [
            for (var i = 0; i < n; i++)
              moves(i) ? a[i] : _floatOf(v[lanes[i]]),
          ]);
        } else if (moves(0)) {
          _writeDest(vd, n, _readSource(vs, vpfxs, n));
        } else {
          _consumePrefixes();
        }
        return true;
      }
      return false;
    }
    if (family != 0) return false;
    if (sel >= 0x60 && sel <= 0x73) {
      // VCST: a named constant into every lane.
      _writeDest(vd, n, [
        for (var i = 0; i < n; i++) _floatOf(_vcstBits[sel - 0x60]),
      ]);
      return true;
    }
    switch (sel) {
      case 0x03: // VIDT: the destination's line of the identity matrix.
        // Column c (or row r) of the identity has its one at row c (or
        // column r), so the one sits at the lane of that index, counted
        // from the vector's first lane; a single is one on the diagonal.
        final half = (vd >> 6) & 1;
        final start = n == 2 ? half * 2 : (n == 3 ? half : 0);
        final along = n == 1
            ? (((vd >> 5) & 3) == (vd & 3) ? 0 : -1)
            : (vd & 3) - start;
        _writeDest(vd, n, [
          for (var i = 0; i < n; i++) i == along ? 1.0 : 0.0,
        ]);
        return true;
      case 0x20: // VRNDS: seed the generator from the source register
        _seedRandom(v[_elems(vs, 1)[0]]);
        return true;
      case 0x21: // VRNDI: draw integers
        _writeDestBits(vd, n, [for (var i = 0; i < n; i++) _drawRandom()]);
        return true;
      case 0x22: // VRNDF1: draw floats in [1, 2)
        _writeDestBits(vd, n, [
          for (var i = 0; i < n; i++) 0x3f800000 | (_drawRandom() & 0x7fffff),
        ]);
        return true;
      case 0x23: // VRNDF2: draw floats in [2, 4)
        _writeDestBits(vd, n, [
          for (var i = 0; i < n; i++) 0x40000000 | (_drawRandom() & 0x7fffff),
        ]);
        return true;
      case 0x32: // VF2H: pack floats into half-precision lanes
        final a = _readSourceBits(vs, vpfxs, n);
        final out = List<int>.filled((n + 1) ~/ 2, 0);
        for (var i = 0; i < n; i++) {
          out[i >> 1] |= _floatToHalf(a[i]) << (16 * (i & 1));
        }
        _writeDestBits(vd, out.length, out);
        return true;
      case 0x33: // VH2F: expand half-precision lanes into floats; the
        // size field counts the source words, each holding two halves.
        final lanes = _elems(vs, n);
        final out = List<int>.filled(2 * n, 0);
        for (var i = 0; i < 2 * n; i++) {
          final word = v[lanes[i >> 1]];
          out[i] = _halfBits((word >> (16 * (i & 1))) & 0xffff);
        }
        _writeDestBits(vd, 2 * n, out);
        return true;
      case 0x38: // VUC2I
      case 0x39: // VC2I: expand the bytes of the source word into
        // lanes: the signed form puts each byte at the top of its
        // lane, the unsigned form scales it to just below 2^31.
        final a = _readSourceBits(vs, vpfxs, 1);
        final word = a[0];
        final out = List<int>.filled(4, 0);
        for (var i = 0; i < 4; i++) {
          final byte = (word >> (8 * i)) & 0xff;
          out[i] = sel == 0x39 ? byte << 24 : (byte * 0x01010101) >> 1;
        }
        _writeDestBits(vd, 4, out);
        return true;
      case 0x3a: // VUS2I
      case 0x3b: // VS2I: unpack the halfwords of the source words to
        // the top of their own lanes, the unsigned form one bit lower.
        final src = _readSourceBits(vs, vpfxs, n);
        final out = List<int>.filled(2 * n, 0);
        for (var i = 0; i < n; i++) {
          final word = src[i];
          out[2 * i] = (word & 0xffff) << (sel == 0x3a ? 15 : 16);
          out[2 * i + 1] =
              sel == 0x3a ? (word >> 16) << 15 : word & 0xffff0000;
        }
        _writeDestBits(vd, 2 * n, out);
        return true;
      case 0x3c: // VI2UC
      case 0x3d: // VI2C: pack the top byte of each integer lane,
        // the unsigned form dropping the sign and one more bit.
        final src = _readSourceBits(vs, vpfxs, n);
        var word = 0;
        for (var i = 0; i < n && i < 4; i++) {
          final value = src[i].toSigned(32);
          final byte = sel == 0x3c
              ? (value < 0 ? 0 : (value >> 23) & 0xff)
              : (value >> 24) & 0xff;
          word |= byte << (8 * i);
        }
        _writeDestBits(vd, 1, [word]);
        return true;
      case 0x3e: // VI2US
      case 0x3f: // VI2S: pack the integer lanes into halfwords,
        // dropping fifteen (unsigned) or sixteen (signed) low bits.
        final src = _readSourceBits(vs, vpfxs, n);
        final out = List<int>.filled((n + 1) ~/ 2, 0);
        for (var i = 0; i < n; i++) {
          final value = src[i].toSigned(32);
          final half = sel == 0x3e
              ? (value < 0 ? 0 : (value >> 15) & 0xffff)
              : (value >> 16) & 0xffff;
          out[i >> 1] |= half << (16 * (i & 1));
        }
        _writeDestBits(vd, out.length, out);
        return true;
      case 0x40: // VSRT1
      case 0x41: // VSRT2
      case 0x48: // VSRT3
      case 0x49: // VSRT4: the sorting steps; 3 and 4 run the first
        // two on the reversed vector and reverse the result.
        final lanes = _elems(vs, 4);
        final src = [for (var i = 0; i < 4; i++) v[lanes[i]]];
        final work = sel == 0x48 || sel == 0x49
            ? [src[3], src[2], src[1], src[0]]
            : src;
        final sorted = _sortStep(work, sel == 0x41 || sel == 0x49);
        _writeDestBits(vd, 4,
            sel == 0x48 || sel == 0x49 ? sorted.reversed.toList() : sorted);
        return true;
      case 0x42: // VBFY1
      case 0x43: // VBFY2: the butterfly sums and differences, across
        // the halves (1) or across the pairs (2).
        final a = _readSource(vs, vpfxs, n);
        _writeDest(
            vd,
            4,
            sel == 0x42
                ? [a[0] + a[1], a[0] - a[1], a[2] + a[3], a[2] - a[3]]
                : [a[0] + a[2], a[1] + a[3], a[0] - a[2], a[1] - a[3]]);
        return true;
      case 0x45: // VSOCP: each source lane becomes a pair holding
        // its saturated complement and itself.
        final a = _readSource(vs, vpfxs, n);
        final out = List<double>.filled(2 * n, 0);
        for (var i = 0; i < n; i++) {
          var t = a[i];
          if (!t.isNaN) {
            t = t < 0 ? 0.0 : (t > 1 ? 1.0 : (t == 0 ? 0.0 : t));
          }
          out[2 * i] = 1.0 - t;
          out[2 * i + 1] = t;
        }
        _writeDest(vd, 2 * n, out);
        return true;
      case 0x46: // VFAD: the sum of the whole prefix view, whose
        // lanes past the size read as zero (constants count)
        final a = _readSource(vs, vpfxs, n);
        var sum = 0.0;
        for (var i = 0; i < 4; i++) {
          sum += a[i];
        }
        _writeDest(vd, 1, [sum]);
        return true;
      case 0x50: // VMFVC: a control register into a vector register
        _writeDestBits(vd, 1, [_readControl((w >> 8) & 0xff)]);
        return true;
      case 0x51: // VMTVC: a vector register into a control register
        _writeControl(
            (w >> 8) & 0xff, v[_elems(vs, 1)[0]]);
        _consumePrefixes();
        return true;
      case 0x47: // VAVG: the view's sum over the operation's size
        final a = _readSource(vs, vpfxs, n);
        var sum = 0.0;
        for (var i = 0; i < 4; i++) {
          sum += a[i];
        }
        _writeDest(vd, 1, [sum / n]);
        return true;
      case 0x59: // VT4444
      case 0x5a: // VT5551
      case 0x5b: // VT5650: pack colour words into 16-bit pixels
        final lanes = _elems(vs, n);
        final out = List<int>.filled((n + 1) ~/ 2, 0);
        for (var i = 0; i < n; i++) {
          final pixel = _packColor(v[lanes[i]], sel);
          out[i >> 1] |= pixel << (16 * (i & 1));
        }
        _writeDestBits(vd, out.length, out);
        return true;
    }
    if (sel == 0x04 || sel == 0x05) {
      // VSAT0 / VSAT1 clamp without flushing denormals or disturbing
      // a NaN's payload, so they too run on the raw words.
      final bits = _readSourceBits(vs, vpfxs, n);
      _writeDestBits(vd, n, [
        for (var i = 0; i < n; i++) _satBits(bits[i], sel == 0x05),
      ]);
      return true;
    }
    if (sel <= 0x02) {
      // VMOV / VABS / VNEG move bits: they neither flush denormals
      // nor round, so they run on the raw words through the prefix.
      final bits = _readSourceBits(vs, vpfxs, n);
      _writeDestBits(vd, n, [
        for (var i = 0; i < n; i++)
          sel == 0x00
              ? bits[i]
              : (sel == 0x01
                  ? bits[i] & 0x7fffffff
                  : bits[i] ^ 0x80000000),
      ]);
      return true;
    }
    // The remaining rs-0 operations are the elementwise unary set.
    final a = _readSource(vs, vpfxs, n, false, false, 2);
    final result = switch (sel) {
      0x04 => [
          for (var i = 0; i < n; i++) a[i].clamp(0.0, 1.0).toDouble(),
        ], // VSAT0
      0x05 => [
          for (var i = 0; i < n; i++) a[i].clamp(-1.0, 1.0).toDouble(),
        ], // VSAT1
      0x06 => [for (var i = 0; i < n; i++) 0.0], // VZERO
      0x07 => [for (var i = 0; i < n; i++) 1.0], // VONE
      0x10 => [for (var i = 0; i < n; i++) 1.0 / a[i]], // VRCP
      0x11 => [
          for (var i = 0; i < n; i++) 1.0 / math.sqrt(a[i]),
        ], // VRSQ
      0x12 => [
          for (var i = 0; i < n; i++) math.sin(a[i] * _halfPi),
        ], // VSIN
      0x13 => [
          for (var i = 0; i < n; i++) math.cos(a[i] * _halfPi),
        ], // VCOS
      0x14 => [
          for (var i = 0; i < n; i++) math.pow(2.0, a[i]).toDouble(),
        ], // VEXP2
      0x15 => [
          for (var i = 0; i < n; i++) math.log(a[i]) / math.ln2,
        ], // VLOG2
      0x16 => [for (var i = 0; i < n; i++) math.sqrt(a[i])], // VSQRT
      0x17 => [
          for (var i = 0; i < n; i++) math.asin(a[i]) * 2 / math.pi,
        ], // VASIN
      0x18 => [for (var i = 0; i < n; i++) -1.0 / a[i]], // VNRCP
      0x1a => [
          for (var i = 0; i < n; i++) -math.sin(a[i] * _halfPi),
        ], // VNSIN
      0x1c => [
          for (var i = 0; i < n; i++) math.pow(2.0, -a[i]).toDouble(),
        ], // VREXP2
      0x44 => [for (var i = 0; i < n; i++) 1.0 - a[i]], // VOCP
      0x4a => [
          for (var i = 0; i < n; i++)
            a[i].isNaN ? a[i] : (a[i] > 0 ? 1.0 : (a[i] < 0 ? -1.0 : 0.0)),
        ], // VSGN
      _ => null,
    };
    if (result == null) return false;
    // The sign of a NaN result follows the operation, not the
    // (unreliable) sign of the computed double: the odd operations
    // (rcp, sin, asin) keep the input's sign, the negated ones
    // (nrcp, nsin) flip it, and the rest produce a positive NaN.
    final nanSign = switch (sel) {
      0x10 || 0x11 || 0x12 || 0x17 => 0, // keep
      0x18 || 0x1a => 1, // flip
      _ => 2, // positive
    };
    if (nanSign != 2 || sel == 0x10 || sel == 0x12 || sel == 0x17) {
      final srcBits = _readSourceBits(vs, vpfxs, n);
      for (var i = 0; i < n; i++) {
        if (result[i].isNaN) {
          final inputSign = (srcBits[i] >> 31) & 1;
          final sign =
              nanSign == 2 ? 0 : (nanSign == 1 ? inputSign ^ 1 : inputSign);
          result[i] = _floatOf(0x7f800001 | (sign << 31));
        }
      }
    } else {
      for (var i = 0; i < n; i++) {
        if (result[i].isNaN) result[i] = _floatOf(0x7f800001);
      }
    }
    if (sel == 0x16) {
      // VSQRT of a negative zero is a positive zero here.
      for (var i = 0; i < n; i++) {
        if (result[i] == 0) result[i] = 0.0;
      }
    }
    _writeDestPipeB(vd, n, result);
    return true;
  }

  /// The saturation of VSAT0 (to [0, 1]) and VSAT1 (to [-1, 1]) on a
  /// raw word: a NaN keeps its bits, a negative zero becomes a
  /// positive one only for VSAT0, and denormals pass through.
  static int _satBits(int bits, bool bipolar) {
    final value = _floatOf(bits);
    if (value.isNaN) return bits;
    if (bipolar) {
      if (value < -1) return 0xbf800000;
      if (value > 1) return 0x3f800000;
      return bits;
    }
    if (value == 0 || value < 0) return 0;
    if (value > 1) return 0x3f800000;
    return bits;
  }

  /// The ordering key of the sort and select operations: the value
  /// with denormals flushed to zero and a NaN ordered as an infinity
  /// of its own sign (taken from the bits, since a Dart double loses
  /// a NaN's sign).
  static double _sortKey(int bits) {
    final cleaned = _clean(_floatOf(bits));
    if (cleaned.isNaN) {
      return bits & 0x80000000 != 0
          ? double.negativeInfinity
          : double.infinity;
    }
    return cleaned;
  }

  /// The winner of a minimum (or maximum) between two raw words:
  /// the strictly smaller (larger) key wins. On a tie between a NaN
  /// and a non-NaN (an infinity of the NaN's sign), the minimum takes
  /// the non-NaN and the maximum the NaN; any other tie goes to the
  /// second word.
  static int _select(bool minimum, int x, int y) {
    final kx = _sortKey(x), ky = _sortKey(y);
    if (minimum ? kx < ky : kx > ky) return x;
    if (minimum ? kx > ky : kx < ky) return y;
    bool nan(int bits) =>
        (bits >> 23) & 0xff == 0xff && bits & 0x7fffff != 0;
    if (nan(x) != nan(y)) return minimum ? (nan(x) ? y : x) : (nan(x) ? x : y);
    return y;
  }

  /// Reads the four lanes of [operand]'s vector through a source
  /// prefix as raw bit patterns: swizzle or constant selection,
  /// absolute value and negation applied to the bits themselves, so
  /// NaN payloads and signs survive for the selecting operations.
  List<int> _readSourceBits(int operand, int prefix, [int size = 4]) {
    final lanes = _viewLanes(operand, size);
    final out = List<int>.filled(4, 0);
    for (var i = 0; i < 4; i++) {
      final swizzle = (prefix >> (2 * i)) & 3;
      int bits;
      if ((prefix >> (12 + i)) & 1 != 0) {
        final abs = (prefix >> (8 + i)) & 1;
        bits = _bits(_prefixConstants[swizzle + abs * 4]);
      } else {
        final at = lanes[swizzle];
        bits = at < 0 ? 0 : v[at];
        if ((prefix >> (8 + i)) & 1 != 0) bits &= 0x7fffffff;
      }
      if ((prefix >> (16 + i)) & 1 != 0) bits ^= 0x80000000;
      out[i] = bits;
    }
    return out;
  }

  /// One sorting step over four raw words: pairs (0, 1) and (2, 3),
  /// or the cross pairs (0, 3) and (1, 2) when [cross] is set. Each
  /// pair is ordered by [_sortKey]; a pair whose keys compare equal
  /// yields the first word twice.
  List<int> _sortStep(List<int> words, bool cross) {
    final out = List<int>.of(words);
    void order(int i, int j) {
      final kx = _sortKey(words[i]), ky = _sortKey(words[j]);
      out[i] = kx <= ky ? words[i] : words[j];
      out[j] = kx >= ky ? words[i] : words[j];
    }

    if (cross) {
      order(0, 3);
      order(1, 2);
    } else {
      order(0, 1);
      order(2, 3);
    }
    return out;
  }

  /// Seeds the random generator from a 32-bit value, spreading it
  /// over the eight state registers as floats in [1, 2).
  void _seedRandom(int seed) {
    for (var i = 0; i < 8; i++) {
      rcx[i] = 0x3f800000 | ((seed + i * 0x010101) & 0x000fffff);
    }
  }

  /// Draws the next value of the random generator.
  int _drawRandom() {
    var x = rcx[0] & 0x000fffff;
    x ^= (x << 13) & 0x000fffff;
    x ^= x >> 17;
    x ^= (x << 5) & 0x000fffff;
    rcx[0] = 0x3f800000 | x;
    return x;
  }

  /// Rounds to the nearest integer, ties to the even neighbour
  /// (Dart's roundToDouble rounds ties away from zero instead).
  static double _roundEven(double value) {
    final t = value.truncateToDouble();
    final diff = (value - t).abs();
    if (diff > 0.5) return value.roundToDouble();
    if (diff < 0.5) return t;
    return t % 2 == 0 ? t : t + (value > 0 ? 1 : -1);
  }

  /// Float to integer with the conversion's rounding mode: 0 rounds to
  /// nearest (ties to even), 1 truncates, 2 rounds up, 3 rounds down.
  /// The result saturates to the signed 32-bit range; a NaN of either
  /// sign becomes the largest integer.
  static int _floatToInt(double value, int mode) {
    if (value.isNaN) return 0x7fffffff;
    if (value >= 2147483648.0) return 0x7fffffff;
    if (value <= -2147483649.0) return -2147483648;
    final rounded = switch (mode) {
      0 => _roundEven(value),
      1 => value.truncateToDouble(),
      2 => value.ceilToDouble(),
      _ => value.floorToDouble(),
    };
    if (rounded >= 2147483648.0) return 0x7fffffff;
    if (rounded < -2147483648.0) return -2147483648;
    return rounded.toInt();
  }

  /// Packs one RGBA8888 word (red in the low byte) into a 16-bit pixel
  /// of the format [format] selects (0x59, 0x5a or 0x5b).
  static int _packColor(int word, int format) {
    final r = word & 0xff, g = (word >> 8) & 0xff;
    final b = (word >> 16) & 0xff, a = (word >> 24) & 0xff;
    switch (format) {
      case 0x59: // 4444
        return (r >> 4) |
            ((g >> 4) << 4) |
            ((b >> 4) << 8) |
            ((a >> 4) << 12);
      case 0x5a: // 5551
        return (r >> 3) |
            ((g >> 3) << 5) |
            ((b >> 3) << 10) |
            ((a >> 7) << 15);
      default: // 5650
        return (r >> 3) | ((g >> 2) << 5) | ((b >> 3) << 11);
    }
  }

  /// VFPU6: the matrix operations, the transform products and the
  /// cross product, selected by the function field and bits 22-16.
  bool _vfpu6(int w) {
    final func = (w >> 23) & 7;
    final sel = (w >> 16) & 0x7f;
    final vd = w & 0x7f, vs = (w >> 8) & 0x7f, vt = (w >> 16) & 0x7f;
    if (func == 7 && sel >= 0x20) {
      // VROT: fill the destination with the cosine and sine of the
      // source angle. The immediate names the cosine's lane and a
      // second lane; the sine fills that lane, or every other lane
      // when the two coincide, and its top bit negates the sine.
      final imm = sel & 0x1f;
      final angle = _clean(_floatOf(v[_elems(vs, 1)[0]]));
      final cosine = math.cos(angle * _halfPi);
      var sine = math.sin(angle * _halfPi);
      if (imm & 0x10 != 0) sine = -sine;
      final n = _sizeOf(w);
      final cosLane = imm & 3, sinLane = (imm >> 2) & 3;
      _writeDest(vd, n, [
        for (var i = 0; i < n; i++)
          i == cosLane
              ? cosine
              : (sinLane == cosLane || i == sinLane ? sine : 0.0),
      ]);
      return true;
    }
    if (func == 7) {
      switch (sel) {
        case 0: // VMMOV
          _writeMatrix(vd, [
            for (var r = 0; r < 4; r++)
              for (var c = 0; c < 4; c++) _matrixAt(vs, r, c),
          ]);
          return true;
        case 3: // VMIDT
          _writeMatrix(vd, [
            for (var r = 0; r < 4; r++)
              for (var c = 0; c < 4; c++) r == c ? 1.0 : 0.0,
          ]);
          return true;
        case 6: // VMZERO
          _writeMatrix(vd, List<double>.filled(16, 0));
          return true;
        case 7: // VMONE
          _writeMatrix(vd, List<double>.filled(16, 1));
          return true;
      }
      return false;
    }
    if (func == 0 || func == 4) {
      final n = _sizeOf(w);
      if (func == 0) {
        // VMMUL: the product of the two source matrices over the
        // size's submatrix, the first one read transposed, so a
        // transposed first operand gives the plain product. A game
        // composing a translation with a model matrix needs this order.
        // A zero result is a positive zero here.
        for (var r = 0; r < n; r++) {
          for (var c = 0; c < n; c++) {
            var sum = 0.0;
            for (var k = 0; k < n; k++) {
              sum += _matrixAt(vs, k, r) * _matrixAt(vt, k, c);
            }
            _writeMatrixElement(vd, r, c, sum == 0 ? 0.0 : sum);
          }
        }
      } else {
        // VMSCL: every element of the source matrix scaled by a
        // single, over the size's submatrix.
        final scalar = _clean(_floatOf(v[_elems(vt, 1)[0]]));
        for (var r = 0; r < n; r++) {
          for (var c = 0; c < n; c++) {
            _writeMatrixElement(vd, r, c, _matrixAt(vs, r, c) * scalar);
          }
        }
      }
      _consumePrefixes();
      return true;
    }
    if (func >= 1 && func <= 3) {
      // VTFM and VHTFM of size func + 1; the homogeneous form's size
      // field names one lane fewer and its last term is a constant one.
      // Lane i is the dot product of the vector with line i of the
      // matrix read transposed, as VMMUL reads its first source.
      final size = _sizeOf(w);
      final homogeneous = size == func;
      final count = func + 1;
      final a = _readSource(vt, vpfxt, size);
      final out = List<double>.filled(4, 0);
      for (var i = 0; i < count; i++) {
        var sum = 0.0;
        for (var j = 0; j < count; j++) {
          final term = homogeneous && j == count - 1 ? 1.0 : a[j];
          sum += _matrixAt(vs, j, i) * term;
        }
        out[i] = sum;
      }
      _writeDest(vd, count, out);
      return true;
    }
    if (func == 5 && _sizeOf(w) == 4) {
      // VQMUL: the quaternion product of two quads.
      final a = _readSource(vs, vpfxs, 4);
      final b = _readSource(vt, vpfxt, 4);
      double z(double x) => x == 0 ? 0.0 : x;
      _writeDest(vd, 4, [
        z(a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1]),
        z(a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0]),
        z(a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3]),
        z(a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2]),
      ]);
      return true;
    }
    if (func == 5) {
      // VCRSP: the cross product of two triples. The hardware forms
      // the components in reverse order, writing each before forming
      // the next, so a destination that overlaps a source feeds the
      // components still to come. Lanes beyond the size field read as
      // zero and are not written.
      final size = _sizeOf(w);
      final sLanes = _elems(vs, 3), tLanes = _elems(vt, 3);
      final dLanes = _elems(vd, 3);
      double s(int i) =>
          i < size ? _clean(_floatOf(v[sLanes[i]])) : 0.0;
      double t(int i) =>
          i < size ? _clean(_floatOf(v[tLanes[i]])) : 0.0;
      for (var lane = 2; lane >= 0; lane--) {
        final a = (lane + 1) % 3, b = (lane + 2) % 3;
        final value = s(a) * t(b) - s(b) * t(a);
        if (lane < size) {
          v[dLanes[lane]] = _resultBits(value == 0 ? 0.0 : value);
        }
      }
      _consumePrefixes();
      return true;
    }
    return false;
  }

  /// One element of a matrix operand, honouring its orientation bit.
  double _matrixAt(int operand, int row, int column) {
    final matrix = (operand >> 2) & 7;
    final at = (operand & 0x20) == 0
        ? matrix * 16 + row * 4 + column
        : matrix * 16 + column * 4 + row;
    return _clean(_floatOf(v[at]));
  }

  void _writeMatrix(int operand, List<double> elements) {
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 4; c++) {
        _writeMatrixElement(operand, r, c, elements[r * 4 + c]);
      }
    }
    _consumePrefixes();
  }

  void _writeMatrixElement(int operand, int r, int c, double value) {
    final matrix = (operand >> 2) & 7;
    final at = (operand & 0x20) == 0
        ? matrix * 16 + r * 4 + c
        : matrix * 16 + c * 4 + r;
    v[at] = _resultBits(value);
  }
}
