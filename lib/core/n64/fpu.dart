import 'dart:math' as math;
import 'dart:typed_data';
import 'package:fnesemu/util/int.dart';

/// COP1 register file and scalar IEEE-754 operations. No host-native code.
class N64Fpu {
  final data = ByteData(32 * 8);
  bool wide = false;
  int control = 0;
  bool get condition => control.bit23;
  int offset(int r) => wide ? r * 8 : r * 4;
  int word(int r) => data.getUint32(offset(r), Endian.little);
  void setWord(int r, int v) => data.setUint32(offset(r), v, Endian.little);
  BigInt long(int r) =>
      BigInt.from(data.getUint32(offset(r), Endian.little)) |
      (BigInt.from(data.getUint32(offset(r) + 4, Endian.little)) << 32);
  void setLong(int r, BigInt v) {
    data.setUint32(offset(r), v.toUnsigned(32).toInt(), Endian.little);
    data.setUint32(
        offset(r) + 4, (v.toUnsigned(64) >> 32).toInt(), Endian.little);
  }

  double value(int r, int fmt) => fmt == 16
      ? data.getFloat32(offset(r), Endian.little)
      : data.getFloat64(offset(r), Endian.little);
  void setValue(int r, int fmt, double v) {
    if (fmt == 16) {
      data.setFloat32(offset(r), v, Endian.little);
    } else {
      data.setFloat64(offset(r), v, Endian.little);
    }
  }

  void reset() {
    data.buffer.asUint8List().fillRange(0, data.lengthInBytes, 0);
    control = 0;
    wide = false;
  }

  int rounded(double v, int mode) {
    if (!v.isFinite) return -2147483648;
    switch (mode) {
      case 1:
        return v.truncate();
      case 2:
        return v.ceil();
      case 3:
        return v.floor();
      default:
        final floor = v.floor(), fraction = v - v.floor();
        return fraction == 0.5 ? (floor.isEven ? floor : floor + 1) : v.round();
    }
  }

  void execute(int fmt, int ft, int fs, int fd, int fn) {
    if (fmt != 16 && fmt != 17 && fmt != 20 && fmt != 21) {
      throw UnsupportedError('COP1 format $fmt');
    }
    final a = fmt == 20
        ? word(fs).toSigned(32).toDouble()
        : fmt == 21
            ? long(fs).toSigned(64).toDouble()
            : value(fs, fmt);
    final b = fmt < 20 ? value(ft, fmt) : 0.0;
    if (fn >= 48) {
      final unordered = a.isNaN || b.isNaN;
      final test =
          (fn.bit0 && unordered) || (fn.bit1 && a == b) || (fn.bit2 && a < b);
      control = (control & ~0x800000) | (test ? 0x800000 : 0);
      return;
    }
    switch (fn) {
      case 0:
        setValue(fd, fmt, a + b);
      case 1:
        setValue(fd, fmt, a - b);
      case 2:
        setValue(fd, fmt, a * b);
      case 3:
        setValue(fd, fmt, a / b);
      case 4:
        setValue(fd, fmt, math.sqrt(a));
      case 5:
        setValue(fd, fmt, a.abs());
      case 6:
        if (fmt == 16) {
          setWord(fd, word(fs));
        } else {
          setLong(fd, long(fs));
        }
      case 7:
        setValue(fd, fmt, -a);
      case 8:
        setLong(fd, BigInt.from(rounded(a, 0)));
      case 9:
        setLong(fd, BigInt.from(rounded(a, 1)));
      case 10:
        setLong(fd, BigInt.from(rounded(a, 2)));
      case 11:
        setLong(fd, BigInt.from(rounded(a, 3)));
      case 12:
        setWord(fd, rounded(a, 0));
      case 13:
        setWord(fd, rounded(a, 1));
      case 14:
        setWord(fd, rounded(a, 2));
      case 15:
        setWord(fd, rounded(a, 3));
      case 32:
        setValue(fd, 16, a);
      case 33:
        setValue(fd, 17, a);
      case 36:
        setWord(fd, rounded(a, control.mask2));
      case 37:
        setLong(fd, BigInt.from(rounded(a, control & 3)));
      default:
        throw UnsupportedError('COP1 function $fn');
    }
  }
}
