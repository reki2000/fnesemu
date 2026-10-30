part of 'sh4.dart';

extension _Sh4Fpu on Sh4 {
  DcFloat get _floatFormat =>
      fpscr.bit19 ? DcFloat.doublePrecision : DcFloat.single;

  void _doubleRegister(int register) {
    if (register.isOdd) _illegal();
  }

  BigInt _floatingBits(int register, {bool? wide}) {
    if (!(wide ?? fpscr.bit19)) return BigInt.from(fr[register]);
    _doubleRegister(register);
    return (BigInt.from(fr[register]) << 32) | BigInt.from(fr[register + 1]);
  }

  void _setFloatingBits(int register, BigInt bits, {bool? wide}) {
    if (!(wide ?? fpscr.bit19)) {
      fr[register] = bits.toUnsigned(32).toInt();
    } else {
      _doubleRegister(register);
      fr[register] = (bits >> 32).toUnsigned(32).toInt();
      fr[register + 1] = bits.toUnsigned(32).toInt();
    }
  }

  BigInt _finishFloat(DcFloatResult result, {int possible = 7}) {
    final enables = (fpscr >> 7) & 31;
    // Exception status cannot change FR or select another register bank.
    _fpscr = ((fpscr & ~0x3f000) |
            (result.flags << 12) |
            ((result.flags & 31) << 2)) &
        0x003fffff;
    if (result.flags & DcFloat.error != 0 ||
        result.flags & enables != 0 ||
        (result.normal && enables & possible != 0)) {
      throw const DcCpuException(0x120);
    }
    return result.bits;
  }

  bool _fpuOp(int op, int n, int m) {
    final code = op & 0xf0ff;
    final system = switch (code) {
      0x005a ||
      0x006a ||
      0x405a ||
      0x406a ||
      0x4056 ||
      0x4066 ||
      0x4052 ||
      0x4062 =>
        true,
      _ => false,
    };
    if (!system && op >> 12 != 15) return false;
    if (sr.bit15) throw DcCpuException(inDelaySlot ? 0x820 : 0x800);
    if (system) {
      final status = op & 0xf0 == 0x60;
      final load = op >> 12 == 4 && (op & 15 == 10 || op & 15 == 6);
      final memory = op & 15 == 2 || op & 15 == 6;
      if (load) {
        final value = memory ? _read(r[n], 4) : r[n];
        if (memory) r[n] = (r[n] + 4).mask32;
        if (status) {
          fpscr = value;
        } else {
          fpul = value;
        }
      } else {
        final value = status ? fpscr : fpul;
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
    final low = op & 15;
    if (low >= 6 && low <= 12) {
      _floatingMove(op, n, m);
      return true;
    }
    if (op == 0xfbfd || op == 0xf3fd) {
      if (fpscr.bit19) _illegal();
      fpscr ^= op == 0xfbfd ? 0x200000 : 0x100000;
      return true;
    }
    if (code == 0xf00d || code == 0xf01d) {
      if (code == 0xf00d) {
        fr[n] = fpul;
      } else {
        fpul = fr[n];
      }
      return true;
    }
    if (code == 0xf08d || code == 0xf09d) {
      if (fpscr.bit19) _illegal();
      fr[n] = code == 0xf08d ? 0 : 0x3f800000;
      return true;
    }
    if (code == 0xf04d || code == 0xf05d) {
      if (fpscr.bit19) _doubleRegister(n);
      fr[n] = code == 0xf04d ? fr[n] ^ 0x80000000 : fr[n] & 0x7fffffff;
      return true;
    }
    if (fpscr & 3 > 1 || (fpscr.bit19 && fpscr.bit20)) {
      throw const DcUnsupported('reserved FPSCR arithmetic mode');
    }
    final format = _floatFormat;
    if (code == 0xf0ed || op & 0xf3ff == 0xf1fd) {
      if (fpscr.bit19) _illegal();
      final destination = (op >> 10 & 3) * 4;
      final vector = [
        for (var i = 0; i < 4; i++) BigInt.from(fr[destination + i])
      ];
      if (code == 0xf0ed) {
        final source = (op >> 8 & 3) * 4;
        final result = DcFloat.single.innerProduct(vector,
            [for (var i = 0; i < 4; i++) BigInt.from(fr[source + i])], fpscr);
        fr[destination + 3] = _finishFloat(result).toInt();
      } else {
        final results = [
          for (var row = 0; row < 4; row++)
            DcFloat.single.innerProduct(
                vector,
                [
                  for (var column = 0; column < 4; column++)
                    BigInt.from(xf[row + 4 * column])
                ],
                fpscr)
        ];
        final flags = results.fold(0, (flags, result) => flags | result.flags);
        _finishFloat(DcFloatResult(BigInt.zero, flags, normal: true),
            possible: 23);
        for (var i = 0; i < 4; i++) {
          fr[destination + i] = results[i].bits.toInt();
        }
      }
      return true;
    }
    if (op & 0xf1ff == 0xf0fd) {
      if (fpscr.bit19) _illegal();
      final phase = fpul & 0xffff;
      final angle = phase * math.pi / 32768;
      final scratch = ByteData(4);
      // Quadrant endpoints avoid host transcendental residuals around zero.
      final sine = phase % 0x4000 == 0
          ? [0.0, 1.0, 0.0, -1.0][phase ~/ 0x4000]
          : math.sin(angle);
      final cosine = phase % 0x4000 == 0
          ? [1.0, 0.0, -1.0, 0.0][phase ~/ 0x4000]
          : math.cos(angle);
      _finishFloat(DcFloatResult(BigInt.zero, DcFloat.inexact, normal: true),
          possible: 1);
      scratch.setFloat32(0, sine);
      fr[n] = scratch.getUint32(0);
      scratch.setFloat32(0, cosine);
      fr[n + 1] = scratch.getUint32(0);
      return true;
    }
    if (low <= 5) {
      final a = _floatingBits(n), b = _floatingBits(m);
      if (low == 4 || low == 5) {
        t = _finishFloat(format.compare(a, b, fpscr, greater: low == 5),
                possible: 0) !=
            BigInt.zero;
      } else {
        final operation = ['add', 'sub', 'mul', 'div'][low];
        _setFloatingBits(
            n, _finishFloat(format.binary(operation, a, b, fpscr)));
      }
      return true;
    }
    if (low == 14) {
      if (fpscr.bit19) _illegal();
      final result = DcFloat.single.multiplyAdd(
          BigInt.from(fr[0]), BigInt.from(fr[m]), BigInt.from(fr[n]), fpscr);
      _setFloatingBits(n, _finishFloat(result));
      return true;
    }
    switch (code) {
      case 0xf02d: // FLOAT.
        if (fpscr.bit19) _doubleRegister(n);
        _setFloatingBits(
            n,
            _finishFloat(format.fromInteger(fpul.rel32, fpscr),
                possible: fpscr.bit19 ? 0 : 1));
      case 0xf03d: // FTRC.
        fpul =
            _finishFloat(format.toInteger(_floatingBits(n), fpscr), possible: 0)
                .toInt();
      case 0xf06d: // FSQRT.
        _setFloatingBits(
            n,
            _finishFloat(format.squareRoot(_floatingBits(n), fpscr),
                possible: 1));
      case 0xf07d: // SH7091 reciprocal square-root approximation.
        if (fpscr.bit19) _illegal();
        fr[n] = _finishFloat(
                DcFloat.single.reciprocalRoot(BigInt.from(fr[n]), fpscr),
                possible: 1)
            .toInt();
      case 0xf0ad: // FCNVSD.
        if (!fpscr.bit19) _illegal();
        _doubleRegister(n);
        _setFloatingBits(
            n,
            _finishFloat(
                DcFloat.doublePrecision
                    .convert(DcFloat.single, BigInt.from(fpul), fpscr),
                possible: 0));
      case 0xf0bd: // FCNVDS.
        if (!fpscr.bit19) _illegal();
        fpul = _finishFloat(DcFloat.single
                .convert(DcFloat.doublePrecision, _floatingBits(n), fpscr))
            .toInt();
      default:
        throw DcUnsupported('FPU instruction ${op.x4} at ${pc.x8}');
    }
    return true;
  }

  void _floatingMove(int op, int n, int m) {
    final size = fpscr.bit20 ? 8 : 4;
    final low = op & 15;
    if (low == 12) {
      if (size == 4) {
        fr[n] = fr[m];
      } else {
        final source = m.isOdd ? xf : fr, destination = n.isOdd ? xf : fr;
        final first = source[m & ~1], second = source[(m & ~1) + 1];
        destination[n & ~1] = first;
        destination[(n & ~1) + 1] = second;
      }
      return;
    }
    final load = low == 6 || low == 8 || low == 9;
    final register = load ? n : m;
    final registers = size == 8 && register.isOdd ? xf : fr;
    final index = size == 8 ? register & ~1 : register;
    final address = (load
            ? (low == 6 ? r[0] + r[m] : r[m])
            : (low == 7 ? r[0] + r[n] : r[n] - (low == 11 ? size : 0)))
        .mask32;
    _checkAccess(address, size, !load);
    if (load) {
      if (size == 4) {
        registers[index] = _read(address, 4);
      } else {
        final (first, second) =
            bus.cpuReadPair(address, privileged: privileged);
        // SH-4 quadword transfers do not swap the two words in little-endian mode.
        registers[index] = first;
        registers[index + 1] = second;
      }
      if (low == 9) r[m] = (address + size).mask32;
    } else {
      if (size == 4) {
        _write(address, 4, registers[index]);
      } else {
        bus.cpuWritePair(address, registers[index], registers[index + 1],
            privileged: privileged);
      }
      if (low == 11) r[n] = address;
    }
  }
}
