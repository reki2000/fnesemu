// FLAC frames, written from the FLAC format specification. CHD stores the
// frames of CD audio (16-bit stereo) without the stream header.
import 'dart:typed_data';

/// reads bits from the most significant bit of each byte
class _Bits {
  final Uint8List data;
  int pos = 0; // in bits

  _Bits(this.data);

  int bit() {
    final byte = pos >> 3;
    if (byte >= data.length) throw const FormatException('flac: truncated');
    final b = (data[byte] >> (7 - (pos & 7))) & 1;
    pos++;
    return b;
  }

  /// [n] bits (0..32) as an unsigned value
  int read(int n) {
    var v = 0;
    while (n > 0) {
      final byte = pos >> 3;
      if (byte >= data.length) throw const FormatException('flac: truncated');
      final avail = 8 - (pos & 7);
      final take = n < avail ? n : avail;
      v = (v << take) | ((data[byte] >> (avail - take)) & ((1 << take) - 1));
      pos += take;
      n -= take;
    }
    return v;
  }

  /// [n] bits as a two's complement value
  int signed(int n) {
    if (n == 0) return 0;
    final v = read(n);
    return v >= (1 << (n - 1)) ? v - (1 << n) : v;
  }

  /// the number of 0 bits before a 1 bit
  int unary() {
    var n = 0;
    while (true) {
      final byte = pos >> 3;
      if (byte >= data.length) throw const FormatException('flac: truncated');
      final rest = data[byte] & (0xff >> (pos & 7));
      if (rest == 0) {
        n += 8 - (pos & 7);
        pos = (byte + 1) << 3;
        continue;
      }
      final lead = 7 - (rest.bitLength - 1) - (pos & 7);
      n += lead;
      pos += lead + 1;
      return n;
    }
  }

  void alignToByte() => pos = (pos + 7) & ~7;
}

/// decodes FLAC frames of 16-bit stereo audio
class FlacDecoder {
  /// decodes the frames at the start of [src] until [samples] samples per
  /// channel are decoded. returns the interleaved samples as big-endian
  /// 16-bit values (the byte order of CD audio in CHD), and the number of
  /// bytes of [src] the frames used.
  static (Uint8List, int) decodeStereo16(Uint8List src, int samples) {
    final out = Uint8List(samples * 4);
    final bits = _Bits(src);
    var done = 0;
    while (done < samples) {
      final (left, right) = _frame(bits);
      final n = left.length;
      if (done + n > samples) {
        throw const FormatException('flac: too many samples');
      }
      for (int i = 0; i < n; i++) {
        final o = (done + i) * 4;
        final l = left[i], r = right[i];
        out[o] = (l >> 8) & 0xff;
        out[o + 1] = l & 0xff;
        out[o + 2] = (r >> 8) & 0xff;
        out[o + 3] = r & 0xff;
      }
      done += n;
    }
    return (out, bits.pos >> 3);
  }

  static const _blockSizes = [
    0, 192, 576, 1152, 2304, 4608, -8, -16, //
    256, 512, 1024, 2048, 4096, 8192, 16384, 32768,
  ];

  static (Int32List, Int32List) _frame(_Bits bits) {
    if (bits.read(14) != 0x3ffe) {
      throw const FormatException('flac: no frame sync');
    }
    bits.read(2); // reserved, blocking strategy
    final blockCode = bits.read(4);
    final rateCode = bits.read(4);
    final channelCode = bits.read(4);
    final sizeCode = bits.read(3);
    bits.read(1);
    _skipCodedNumber(bits);
    var blockSize = _blockSizes[blockCode];
    if (blockSize == -8) blockSize = bits.read(8) + 1;
    if (blockSize == -16) blockSize = bits.read(16) + 1;
    if (blockSize <= 0) throw const FormatException('flac: bad block size');
    if (rateCode == 12) bits.read(8);
    if (rateCode == 13 || rateCode == 14) bits.read(16);
    bits.read(8); // header CRC-8

    final sampleBits = switch (sizeCode) {
      0 || 4 => 16, // 0: the stream's, 16 bits for CD audio
      1 => 8,
      2 => 12,
      5 => 20,
      6 => 24,
      7 => 32,
      _ => throw const FormatException('flac: bad sample size'),
    };
    if (channelCode != 1 && channelCode < 8 || channelCode > 10) {
      throw const FormatException('flac: not stereo');
    }

    // the side channel has one more bit
    final ch0 =
        _subframe(bits, blockSize, sampleBits + (channelCode == 9 ? 1 : 0));
    final ch1 = _subframe(bits, blockSize,
        sampleBits + (channelCode == 8 || channelCode == 10 ? 1 : 0));
    bits.alignToByte();
    bits.read(16); // frame CRC-16

    switch (channelCode) {
      case 8: // left, side
        for (int i = 0; i < blockSize; i++) {
          ch1[i] = ch0[i] - ch1[i];
        }
      case 9: // side, right
        for (int i = 0; i < blockSize; i++) {
          ch0[i] = ch0[i] + ch1[i];
        }
      case 10: // mid, side
        for (int i = 0; i < blockSize; i++) {
          final side = ch1[i];
          final mid = (ch0[i] << 1) | (side & 1);
          ch0[i] = (mid + side) >> 1;
          ch1[i] = (mid - side) >> 1;
        }
    }
    return (ch0, ch1);
  }

  /// the frame or sample number, coded like UTF-8
  static void _skipCodedNumber(_Bits bits) {
    final first = bits.read(8);
    var extra = 0;
    for (int mask = 0x80; mask != 0 && first & mask != 0; mask >>= 1) {
      extra++;
    }
    if (extra == 1 || extra > 7) {
      throw const FormatException('flac: bad frame number');
    }
    for (int i = 1; i < extra; i++) {
      bits.read(8);
    }
  }

  static Int32List _subframe(_Bits bits, int n, int sampleBits) {
    bits.read(1); // padding
    final type = bits.read(6);
    var wasted = 0;
    if (bits.bit() == 1) wasted = bits.unary() + 1;
    final bps = sampleBits - wasted;
    final s = Int32List(n);

    if (type == 0) {
      final v = bits.signed(bps);
      for (int i = 0; i < n; i++) {
        s[i] = v;
      }
    } else if (type == 1) {
      for (int i = 0; i < n; i++) {
        s[i] = bits.signed(bps);
      }
    } else if (type >= 8 && type <= 12) {
      final order = type - 8;
      for (int i = 0; i < order; i++) {
        s[i] = bits.signed(bps);
      }
      _residual(bits, s, order);
      _fixed(s, order);
    } else if (type >= 32) {
      final order = type - 31;
      for (int i = 0; i < order; i++) {
        s[i] = bits.signed(bps);
      }
      final precision = bits.read(4) + 1;
      if (precision == 16) throw const FormatException('flac: bad precision');
      final shift = bits.signed(5);
      if (shift < 0) throw const FormatException('flac: negative shift');
      final coefs = Int32List(order);
      for (int i = 0; i < order; i++) {
        coefs[i] = bits.signed(precision);
      }
      _residual(bits, s, order);
      for (int i = order; i < n; i++) {
        var sum = 0;
        for (int j = 0; j < order; j++) {
          sum += coefs[j] * s[i - 1 - j];
        }
        s[i] += sum >> shift;
      }
    } else {
      throw FormatException('flac: reserved subframe type $type');
    }

    if (wasted > 0) {
      for (int i = 0; i < n; i++) {
        s[i] <<= wasted;
      }
    }
    return s;
  }

  /// adds the fixed polynomial prediction to the residuals in [s]
  static void _fixed(Int32List s, int order) {
    final n = s.length;
    switch (order) {
      case 1:
        for (int i = 1; i < n; i++) {
          s[i] += s[i - 1];
        }
      case 2:
        for (int i = 2; i < n; i++) {
          s[i] += 2 * s[i - 1] - s[i - 2];
        }
      case 3:
        for (int i = 3; i < n; i++) {
          s[i] += 3 * s[i - 1] - 3 * s[i - 2] + s[i - 3];
        }
      case 4:
        for (int i = 4; i < n; i++) {
          s[i] += 4 * s[i - 1] - 6 * s[i - 2] + 4 * s[i - 3] - s[i - 4];
        }
    }
  }

  /// reads the Rice coded residuals into [s] after the [order] warm-up
  /// samples
  static void _residual(_Bits bits, Int32List s, int order) {
    final method = bits.read(2);
    if (method > 1) throw const FormatException('flac: bad residual coding');
    final paramBits = method == 0 ? 4 : 5;
    final escape = method == 0 ? 15 : 31;
    final partitionOrder = bits.read(4);
    final partitions = 1 << partitionOrder;
    final perPartition = s.length >> partitionOrder;
    var i = order;
    for (int p = 0; p < partitions; p++) {
      final count = p == 0 ? perPartition - order : perPartition;
      final param = bits.read(paramBits);
      if (param == escape) {
        final width = bits.read(5);
        for (int k = 0; k < count; k++) {
          s[i++] = bits.signed(width);
        }
      } else {
        for (int k = 0; k < count; k++) {
          final u = (bits.unary() << param) | bits.read(param);
          s[i++] = (u >> 1) ^ -(u & 1);
        }
      }
    }
  }
}
