part of 'sh4.dart';

/// Additional integer instructions kept separate from exception dispatch.
extension _Sh4Integer on Sh4 {
  bool _integerOp(int op, int n, int m) {
    if (_systemOp(op, n)) return true;
    final a = r[n], b = r[m];
    switch (op & 0xf00f) {
      case 0x300e: // ADDC.
        final sum = a + b + (t ? 1 : 0);
        r[n] = sum.mask32;
        t = sum > 0xffffffff;
      case 0x300f: // ADDV.
        final sum = a.rel32 + b.rel32;
        r[n] = sum.mask32;
        t = sum < -0x80000000 || sum > 0x7fffffff;
      case 0x300a: // SUBC.
        final difference = a - b - (t ? 1 : 0);
        r[n] = difference.mask32;
        t = difference < 0;
      case 0x300b: // SUBV.
        final difference = a.rel32 - b.rel32;
        r[n] = difference.mask32;
        t = difference < -0x80000000 || difference > 0x7fffffff;
      case 0x3004: // DIV1.
        final mode = sr.bit9;
        final subtract = sr.bit8 == mode;
        final shifted = ((a << 1) | (t ? 1 : 0)).mask32;
        final result = subtract ? shifted - b : shifted + b;
        final wrapped = result < 0 || result > 0xffffffff;
        final quotientSign = (a.bit31 != wrapped) != mode;
        r[n] = result.mask32;
        _sr = _sr.setBit(8, quotientSign);
        t = quotientSign == mode;
      case 0x600a: // NEGC.
        final difference = -b - (t ? 1 : 0);
        r[n] = difference.mask32;
        t = difference < 0;
      case 0x200c: // CMP/STR: any corresponding pair of bytes is equal.
        final difference = a ^ b;
        t = [0, 8, 16, 24].any((shift) => (difference >> shift) & 255 == 0);
      case 0x6008: // SWAP.B.
        r[n] = (b & 0xffff0000) | ((b & 255) << 8) | ((b >> 8) & 255);
      case 0x6009: // SWAP.W.
        r[n] = ((b << 16) | (b >> 16)).mask32;
      case 0x200d: // XTRCT.
        r[n] = ((b << 16) | (a >> 16)).mask32;
      case 0x400c: // SHAD.
      case 0x400d: // SHLD.
        if (!b.bit31) {
          r[n] = (a << (b & 31)).mask32;
        } else {
          final count = 32 - (b & 31);
          // Handle 32 explicitly: JavaScript shifts mask their count to 5 bits.
          r[n] = count == 32
              ? (op & 15 == 12 && a.bit31 ? 0xffffffff : 0)
              : (op & 15 == 12 ? a.rel32 >> count : a >> count).mask32;
        }
      case 0x0007: // MUL.L.
      case 0x3005: // DMULU.L.
      case 0x300d: // DMULS.L.
        final (high, low) = _product32(a, b, signed: op & 15 == 13);
        macl = low;
        if (op & 0xf00f != 0x0007) {
          mach = high;
        }
      case 0x000f: // MAC.L.
        _accumulate(n, m, 4);
      case 0x400f: // MAC.W.
        _accumulate(n, m, 2);
      case 0x200e: // MULU.W.
        macl = ((a & 65535) * (b & 65535)).mask32;
      case 0x200f: // MULS.W.
        macl = (a.rel16 * b.rel16).mask32;
      case 0x2007: // DIV0S.
        _sr = _sr.setBit(8, a.bit31).setBit(9, b.bit31);
        t = a.bit31 != b.bit31;
      case 0x0004:
      case 0x0005:
      case 0x0006:
        final size = 1 << ((op & 15) - 4);
        _write((r[0] + a).mask32, size, b);
      case 0x000c:
      case 0x000d:
      case 0x000e:
        final size = 1 << ((op & 15) - 12);
        r[n] = _read((r[0] + b).mask32, size).rel(size);
      default:
        return _singleRegisterOp(op, n) || _extraMemoryOp(op);
    }
    return true;
  }

  (int, int) _product32(int a, int b, {required bool signed}) {
    // Four 16-bit products remain exact on both the VM and JavaScript.
    final low = (a & 65535) * (b & 65535);
    final ab = (a >> 16) * (b & 65535);
    final ba = (b >> 16) * (a & 65535);
    final middle = (low >> 16) + (ab & 65535) + (ba & 65535);
    var high = (a >> 16) * (b >> 16) + (ab >> 16) + (ba >> 16) + (middle >> 16);
    if (signed) {
      if (a.bit31) high -= b;
      if (b.bit31) high -= a;
    }
    return (high.mask32, (((middle & 65535) << 16) | (low & 65535)).mask32);
  }

  void _accumulate(int n, int m, int size) {
    final firstAddress = r[n];
    final secondAddress = n == m ? (firstAddress + size).mask32 : r[m];
    // Read Rn first; commit both postincrements only after both transfers succeed.
    final a = _read(firstAddress, size);
    final b = _read(secondAddress, size);
    final (productHigh, productLow) = size == 4
        ? _product32(a, b, signed: true)
        : (
            (a.rel16 * b.rel16 < 0 ? 0xffffffff : 0),
            (a.rel16 * b.rel16).mask32
          );
    final lowSum = macl + productLow;
    var nextLow = lowSum.mask32;
    var nextHigh = (mach + productHigh + (lowSum > 0xffffffff ? 1 : 0)).mask32;
    if (sr.bit1 && size == 2) {
      final sum = macl.rel32 + a.rel16 * b.rel16;
      final overflow = sum < -0x80000000 || sum > 0x7fffffff;
      if (overflow && mach > 1) {
        // ADE-602-156D specifies setting MACH bit 0; ADCS 7182230F specifies replacing MACH with 1.
        throw const DcUnsupported(
            'MAC.W saturation MACH overflow needs hardware validation');
      }
      nextLow = sum.clamp(-0x80000000, 0x7fffffff).mask32;
      nextHigh = overflow ? 1 : mach;
    } else if (sr.bit1) {
      if (mach != mach.rel16.mask32) {
        throw const DcUnsupported(
            'MAC.L saturation accumulator needs hardware validation');
      }
      final highSum =
          mach.rel16 + productHigh.rel32 + (lowSum > 0xffffffff ? 1 : 0);
      if (highSum < -0x8000) {
        nextHigh = 0xffff8000;
        nextLow = 0;
      } else if (highSum > 0x7fff) {
        nextHigh = 0x7fff;
        nextLow = 0xffffffff;
      } else {
        nextHigh = highSum.mask32;
      }
      final preservedHigh = (mach & 0xffff0000) | (nextHigh & 0xffff);
      if (preservedHigh != nextHigh) {
        // The two hardware manuals disagree on MACH's upper 16 result bits.
        throw const DcUnsupported(
            'MAC.L saturation MACH result needs hardware validation');
      }
    }
    // With aliased registers, both sequential operands advance the same pointer.
    if (n == m) {
      r[n] = (secondAddress + size).mask32;
    } else {
      r[n] = (firstAddress + size).mask32;
      r[m] = (secondAddress + size).mask32;
    }
    mach = nextHigh;
    macl = nextLow;
  }

  bool _singleRegisterOp(int op, int n) {
    final value = r[n];
    switch (op & 0xf0ff) {
      case 0x4000: // SHLL.
      case 0x4020: // SHAL.
        r[n] = (value << 1).mask32;
        t = value.bit31;
      case 0x4001: // SHLR.
        r[n] = value >> 1;
        t = value.bit0;
      case 0x4021: // SHAR.
        r[n] = (value.rel32 >> 1).mask32;
        t = value.bit0;
      case 0x4004: // ROTL.
      case 0x4024: // ROTCL.
        final input = op & 0x20 != 0 ? t : value.bit31;
        r[n] = ((value << 1) | (input ? 1 : 0)).mask32;
        t = value.bit31;
      case 0x4005: // ROTR.
      case 0x4025: // ROTCR.
        final input = op & 0x20 != 0 ? t : value.bit0;
        r[n] = (value >> 1) | (input ? 0x80000000 : 0);
        t = value.bit0;
      case 0x4008:
      case 0x4018:
      case 0x4028:
      case 0x4009:
      case 0x4019:
      case 0x4029:
        final count = switch ((op >> 4) & 3) { 0 => 2, 1 => 8, _ => 16 };
        r[n] = op.bit0 ? value >> count : (value << count).mask32;
      case 0x4011: // CMP/PZ.
        t = value.rel32 >= 0;
      case 0x4015: // CMP/PL.
        t = value.rel32 > 0;
      case 0x401b: // TAS.B.
        final byte = _read(value, 1);
        _write(value, 1, byte | 0x80);
        t = byte == 0;
      default:
        switch (op) {
          case 0x0028:
            mach = macl = 0; // CLRMAC.
          case 0x0048:
            _sr &= ~2; // CLRS.
          case 0x0058:
            _sr |= 2; // SETS.
          case 0x0019:
            _sr &= ~0x301; // DIV0U.
          default:
            return false;
        }
    }
    return true;
  }

  bool _systemOp(int op, int n) {
    final selector = (op >> 4) & 15;
    if (selector > 2) return false;
    final code = op & 0xf00f;
    if (code != 0x000a && code != 0x400a && code != 0x4002 && code != 0x4006) {
      return false;
    }
    final load = code == 0x400a || code == 0x4006;
    final memory = code == 0x4002 || code == 0x4006;
    if (load) {
      final value = memory ? _read(r[n], 4) : r[n];
      if (memory) r[n] = (r[n] + 4).mask32;
      switch (selector) {
        case 0:
          mach = value;
        case 1:
          macl = value;
        case 2:
          pr = value;
      }
    } else {
      final value = switch (selector) { 0 => mach, 1 => macl, _ => pr };
      if (memory) {
        final address = (r[n] - 4).mask32;
        _write(address, 4, value);
        r[n] = address;
      } else {
        r[n] = value;
      }
    }
    return true;
  }

  bool _extraMemoryOp(int op) {
    final high = op >> 8;
    if (high == 0x80 || high == 0x81 || high == 0x84 || high == 0x85) {
      final size = 1 << (high & 1);
      final address = (r[(op >> 4) & 15] + (op & 15) * size).mask32;
      if (high & 4 == 0) {
        _write(address, size, r[0]);
      } else {
        r[0] = _read(address, size).rel(size);
      }
      return true;
    }
    if ([0xc0, 0xc1, 0xc2, 0xc4, 0xc5, 0xc6].contains(high)) {
      final size = 1 << (high & 3);
      final address = (gbr + (op & 255) * size).mask32;
      if (high & 4 == 0) {
        _write(address, size, r[0]);
      } else {
        r[0] = _read(address, size).rel(size);
      }
      return true;
    }
    if (high >= 0xcc && high <= 0xcf) {
      final address = (gbr + r[0]).mask32;
      final value = _read(address, 1), immediate = op & 255;
      switch (high) {
        case 0xcc:
          t = value & immediate == 0;
        case 0xcd:
          _write(address, 1, value & immediate);
        case 0xce:
          _write(address, 1, value ^ immediate);
        case 0xcf:
          _write(address, 1, value | immediate);
      }
      return true;
    }
    return false;
  }
}
