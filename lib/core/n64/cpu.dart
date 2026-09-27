import 'bus.dart';
import 'fpu.dart';
import 'registers.dart';

/// Experimental VR4300 integer interpreter. BigInt preserves 64 bits on Web.
/// Unsupported operations stop explicitly instead of behaving as NOPs.
class Vr4300 {
  final N64Bus bus;
  final fpu = N64Fpu();
  bool _delay = false;
  int? _idleAddress;
  bool get idleLoop =>
      !_delay &&
      pc == _idleAddress &&
      !bus.interruptPending &&
      !_timerIrq &&
      count != cop0[11];
  void idle(int cycles) {
    final untilCompare = ((cop0[11] - count) & 0xffffffff) * 2;
    clocks += untilCompare > 0 && untilCompare < cycles ? untilCompare : cycles;
  }

  bool _ll = false;
  int _countOffset = 0;
  bool _timerIrq = false;
  final r = N64Registers();
  final cop0 = List<int>.filled(32, 0);
  int pc = 0, nextPc = 4, clocks = 0;
  BigInt hi = BigInt.zero, lo = BigInt.zero;
  String? stopReason;

  Vr4300(this.bus);

  void reset(int entry) {
    r.fillRange(0, 32, BigInt.zero);
    cop0.fillRange(0, 32, 0);
    hi = lo = BigInt.zero;
    pc = entry;
    nextPc = (entry + 4) & 0xffffffff;
    clocks = 0;
    stopReason = null;
    _idleAddress = null;
    fpu.reset();
    _delay = _ll = _timerIrq = false;
    _countOffset = 0;
    fpu.wide = true;
    cop0[12] = 0x34000000;
    cop0[16] = 0x7006e463;
    cop0[15] = 0x00000b22;
    r[29] = BigInt.from(0x807ffff0).toSigned(32);
  }

  void put(int index, BigInt value) {
    if (index != 0) r[index] = value;
  }

  void word(int index, BigInt value) => put(index, value.toSigned(32));
  int lowWord(int index) => r.word(index);
  void putWord(int index, int value) {
    r.setWord(index, value);
  }

  bool equal(int s, int t) =>
      r.isWord(s) && r.isWord(t) ? lowWord(s) == lowWord(t) : r[s] == r[t];
  bool negative(int s) => r.isWord(s) ? lowWord(s) < 0 : r[s].isNegative;
  bool nonpositive(int s) =>
      r.isWord(s) ? lowWord(s) <= 0 : r[s] <= BigInt.zero;
  bool lessSigned(int s, int t) =>
      r.isWord(s) && r.isWord(t) ? lowWord(s) < lowWord(t) : r[s] < r[t];
  bool lessUnsigned(int s, int t) => r.isWord(s) && r.isWord(t)
      ? (lowWord(s) & 0xffffffff) < (lowWord(t) & 0xffffffff)
      : r[s].toUnsigned(64) < r[t].toUnsigned(64);
  int addWord(int s, int value, {bool subtract = false}) {
    final result = subtract ? lowWord(s) - value : lowWord(s) + value;
    if (result < -2147483648 || result > 2147483647) {
      throw const CpuFault(12);
    }
    return result;
  }

  void logic(int d, int s, int t, int fn) {
    if (r.isWord(s) && r.isWord(t)) {
      final a = lowWord(s), b = lowWord(t);
      putWord(d,
          switch (fn) { 36 => a & b, 37 => a | b, 38 => a ^ b, _ => ~(a | b) });
    } else {
      final a = r[s], b = r[t];
      put(d,
          switch (fn) { 36 => a & b, 37 => a | b, 38 => a ^ b, _ => ~(a | b) });
    }
  }

  int address(BigInt value) => value.toUnsigned(32).toInt();
  int signed16(int value) => (value & 0xffff).toSigned(16);

  void aligned(int address, int size) {
    if (address % size != 0) throw UnsupportedError('Unaligned N64 access');
  }

  void exception(int code, int at, bool delay, {int? badAddress}) {
    cop0[13] = (cop0[13] & 0xff00) | (code << 2);
    if ((cop0[12] & 2) == 0) {
      cop0[14] = delay ? (at - 4) & 0xffffffff : at;
      if (delay) cop0[13] |= 0x80000000;
    }
    if (badAddress != null) cop0[8] = badAddress;
    cop0[12] |= 2;
    pc = (cop0[12] & 0x400000) != 0 ? 0xbfc00380 : 0x80000180;
    nextPc = (pc + 4) & 0xffffffff;
    _delay = false;
    _ll = false;
  }

  int get count => (clocks ~/ 2 + _countOffset) & 0xffffffff;
  void step() {
    if (stopReason != null) return;
    if (count == cop0[11] && clocks > 0) _timerIrq = true;
    cop0[13] = (cop0[13] & ~0x8400) |
        (bus.interruptPending ? 0x400 : 0) |
        (_timerIrq ? 0x8000 : 0);
    if ((cop0[12] & 7) == 1 && (cop0[12] & cop0[13] & 0xff00) != 0 && !_delay) {
      exception(0, pc, false);
      clocks++;
      return;
    }
    final at = pc;
    final delay = _delay;
    _delay = false;
    try {
      aligned(pc, 4);
      final op = bus.read(pc, 4);
      pc = nextPc;
      nextPc = (nextPc + 4) & 0xffffffff;
      if (op == 0) {
        clocks++;
        return;
      }
      final code = op >> 26;
      if ((op == 0x1000ffff ||
              (code == 2 &&
                  (((at + 4) & 0xf0000000) | ((op & 0x3ffffff) << 2)) == at)) &&
          bus.read((at + 4) & 0xffffffff, 4) == 0) {
        _idleAddress = at;
      }
      final s = (op >> 21) & 31, t = (op >> 16) & 31;
      final d = (op >> 11) & 31, shift = (op >> 6) & 31;
      final immediate = signed16(op);
      late final a = (lowWord(s) + immediate) & 0xffffffff;
      void branch(bool condition, {bool likely = false}) {
        _delay = true;
        if (condition) {
          nextPc = (at + 4 + immediate * 4) & 0xffffffff;
        } else if (likely) {
          _delay = false;
          pc = nextPc;
          nextPc = (nextPc + 4) & 0xffffffff;
        }
      }

      void unsupported() => throw UnsupportedError(
            'VR4300 instruction 0x${op.toRadixString(16).padLeft(8, '0')}',
          );
      BigInt load(int size, bool signed) {
        aligned(a, size);
        if (size <= 4) {
          final value = bus.read(a, size);
          return BigInt.from(signed ? value.toSigned(size * 8) : value);
        }
        final value = (BigInt.from(bus.read(a, 4)) << 32) |
            BigInt.from(bus.read(a + 4, 4));
        return signed ? value.toSigned(64) : value;
      }

      void loadWord(int size, bool signed) {
        aligned(a, size);
        final value = bus.read(a, size);
        putWord(t, signed ? value.toSigned(size * 8) : value);
      }

      void store(int size) {
        aligned(a, size);
        if (size <= 4) {
          bus.write(a, lowWord(t), size);
        } else {
          bus.write(a, (r[t].toUnsigned(64) >> 32).toInt(), 4);
          bus.write(a + 4, lowWord(t), 4);
        }
      }

      BigInt add(BigInt x, BigInt y, int bits, bool trap,
          {bool subtract = false}) {
        final result = subtract
            ? x.toSigned(bits) - y.toSigned(bits)
            : x.toSigned(bits) + y.toSigned(bits);
        if (trap && result != result.toSigned(bits)) {
          throw const CpuFault(12);
        }
        return result.toSigned(bits);
      }

      if ((code == 17 ||
              code == 49 ||
              code == 53 ||
              code == 57 ||
              code == 61) &&
          (cop0[12] & 0x20000000) == 0) {
        throw const CpuFault(11);
      }
      switch (code) {
        case 0:
          switch (op & 63) {
            case 0:
              putWord(d, lowWord(t) << shift);
            case 2:
              putWord(d, (lowWord(t) & 0xffffffff) >> shift);
            case 3:
              putWord(d, lowWord(t) >> shift);
            case 4:
              putWord(d, lowWord(t) << (lowWord(s) & 31));
            case 6:
              putWord(d, (lowWord(t) & 0xffffffff) >> (lowWord(s) & 31));
            case 7:
              putWord(d, lowWord(t) >> (lowWord(s) & 31));
            case 8:
              _delay = true;
              nextPc = lowWord(s) & 0xffffffff;
            case 9:
              _delay = true;
              final target = lowWord(s) & 0xffffffff;
              putWord(d, (at + 8) & 0xffffffff);
              nextPc = target;
            case 12:
              throw const CpuFault(8);
            case 13:
              throw const CpuFault(9);
            case 15:
              break; // SYNC
            case 16:
              put(d, hi);
            case 17:
              hi = r[s];
            case 18:
              put(d, lo);
            case 19:
              lo = r[s];
            case 20:
              put(d, r[t] << (r[s].toInt() & 63));
            case 22:
              put(d, r[t].toUnsigned(64) >> (r[s].toInt() & 63));
            case 23:
              put(d, r[t] >> (r[s].toInt() & 63));
            case 24:
            case 25:
              final unsigned = (op & 63) == 25;
              final x = unsigned ? r[s].toUnsigned(32) : r[s].toSigned(32);
              final y = unsigned ? r[t].toUnsigned(32) : r[t].toSigned(32);
              final product = x * y;
              lo = product.toSigned(32);
              hi = (product >> 32).toSigned(32);
            case 26:
            case 27:
              final unsigned = (op & 63) == 27;
              final x = unsigned ? r[s].toUnsigned(32) : r[s].toSigned(32);
              final y = unsigned ? r[t].toUnsigned(32) : r[t].toSigned(32);
              if (y == BigInt.zero) {
                lo =
                    unsigned || x >= BigInt.zero ? BigInt.from(-1) : BigInt.one;
                hi = x.toSigned(32);
              } else {
                lo = (x ~/ y).toSigned(32);
                hi = x.remainder(y).toSigned(32);
              }
            case 28:
            case 29:
              final unsigned = (op & 63) == 29;
              final x = unsigned ? r[s].toUnsigned(64) : r[s];
              final y = unsigned ? r[t].toUnsigned(64) : r[t];
              final product = x * y;
              lo = product.toSigned(64);
              hi = (product >> 64).toSigned(64);
            case 30:
            case 31:
              final unsigned = (op & 63) == 31;
              final x = unsigned ? r[s].toUnsigned(64) : r[s];
              final y = unsigned ? r[t].toUnsigned(64) : r[t];
              lo = (y == BigInt.zero
                      ? (unsigned || x >= BigInt.zero
                          ? BigInt.from(-1)
                          : BigInt.one)
                      : x ~/ y)
                  .toSigned(64);
              hi = (y == BigInt.zero ? x : x.remainder(y)).toSigned(64);
            case 32:
              putWord(d, addWord(s, lowWord(t)));
            case 33:
              putWord(d, lowWord(s) + lowWord(t));
            case 34:
              putWord(d, addWord(s, lowWord(t), subtract: true));
            case 35:
              putWord(d, lowWord(s) - lowWord(t));
            case 36:
              logic(d, s, t, 36);
            case 37:
              logic(d, s, t, 37);
            case 38:
              logic(d, s, t, 38);
            case 39:
              logic(d, s, t, 39);
            case 42:
              putWord(d, lessSigned(s, t) ? 1 : 0);
            case 43:
              putWord(d, lessUnsigned(s, t) ? 1 : 0);
            case 44:
              put(d, add(r[s], r[t], 64, true));
            case 45:
              put(d, r[s] + r[t]);
            case 46:
              put(d, add(r[s], r[t], 64, true, subtract: true));
            case 47:
              put(d, r[s] - r[t]);
            case 56:
              put(d, r[t] << shift);
            case 58:
              put(d, r[t].toUnsigned(64) >> shift);
            case 59:
              put(d, r[t] >> shift);
            case 60:
              put(d, r[t] << (shift + 32));
            case 62:
              put(d, r[t].toUnsigned(64) >> (shift + 32));
            case 63:
              put(d, r[t] >> (shift + 32));
            default:
              unsupported();
          }
        case 1:
          if (!const [0, 1, 2, 3, 16, 17, 18, 19].contains(t)) {
            unsupported();
            break;
          }
          if (t >= 16) putWord(31, (at + 8) & 0xffffffff);
          branch(
            (t & 1) == 0 ? negative(s) : !negative(s),
            likely: (t & 2) != 0,
          );
        case 2:
        case 3:
          _delay = true;
          if (code == 3) {
            putWord(31, (at + 8) & 0xffffffff);
          }
          nextPc = ((at + 4) & 0xf0000000) | ((op & 0x3ffffff) << 2);
        case 4:
          branch(equal(s, t));
        case 5:
          branch(!equal(s, t));
        case 6:
          branch(nonpositive(s));
        case 7:
          branch(!nonpositive(s));
        case 8:
          putWord(t, addWord(s, immediate));
        case 9:
          putWord(t, lowWord(s) + immediate);
        case 10:
          putWord(
              t,
              (r.isWord(s)
                      ? lowWord(s) < immediate
                      : r[s] < BigInt.from(immediate))
                  ? 1
                  : 0);
        case 11:
          putWord(
              t,
              (r.isWord(s)
                      ? (lowWord(s) & 0xffffffff) < (immediate & 0xffffffff)
                      : r[s].toUnsigned(64) <
                          BigInt.from(immediate).toUnsigned(64))
                  ? 1
                  : 0);
        case 12:
          putWord(t, lowWord(s) & (op & 0xffff));
        case 13:
          if (r.isWord(s)) {
            putWord(t, lowWord(s) | (op & 0xffff));
          } else {
            put(t, r[s] | BigInt.from(op & 0xffff));
          }
        case 14:
          if (r.isWord(s)) {
            putWord(t, lowWord(s) ^ (op & 0xffff));
          } else {
            put(t, r[s] ^ BigInt.from(op & 0xffff));
          }
        case 15:
          putWord(t, (op & 0xffff) << 16);
        case 16:
          if (s == 0 || s == 1) {
            putWord(t, d == 9 ? count : cop0[d]);
          } else if (s == 4 || s == 5) {
            final v = lowWord(t) & 0xffffffff;
            if (d == 9) _countOffset = v - clocks ~/ 2;
            if (d == 11) _timerIrq = false;
            if (d == 13) {
              cop0[d] = (cop0[d] & ~0x300) | (v & 0x300);
            } else {
              cop0[d] = v;
            }
            fpu.wide = (cop0[12] & 0x4000000) != 0;
          } else if (s == 16) {
            switch (op & 63) {
              case 24:
                pc = (cop0[12] & 4) != 0 ? cop0[30] : cop0[14];
                cop0[12] &= (cop0[12] & 4) != 0 ? ~4 : ~2;
                nextPc = (pc + 4) & 0xffffffff;
                _delay = false;
                _ll = false;
              case 2:
                bus.writeTlb(cop0[0] & 31, cop0);
              case 6:
                bus.writeTlb(
                    (clocks % (32 - (cop0[6] & 31))) + (cop0[6] & 31), cop0);
              case 8:
                cop0[0] = bus.probeTlb(cop0[10]);
              case 1:
                bus.readTlb(cop0[0] & 31, cop0);
              default:
                unsupported();
            }
          } else {
            unsupported();
          }
        case 17:
          final fs = d, fd = shift;
          switch (s) {
            case 0:
              putWord(t, fpu.word(fs));
            case 1:
              put(t, fpu.long(fs));
            case 2:
              putWord(t, fs == 31 ? fpu.control : 0x511);
            case 4:
              fpu.setWord(fs, lowWord(t));
            case 5:
              fpu.setLong(fs, r[t]);
            case 6:
              if (fs == 31) fpu.control = lowWord(t) & 0xffffffff;
            case 8:
              branch((t & 1) != 0 ? fpu.condition : !fpu.condition,
                  likely: (t & 2) != 0);
            default:
              fpu.execute(s, t, fs, fd, op & 63);
          }
        case 26:
        case 27:
        case 34:
        case 38:
          final size = code == 26 || code == 27 ? 8 : 4;
          final offset = a % size;
          final left = code == 26 || code == 34;
          final base = a - offset;
          final bytes = List<int>.generate(
              size,
              (i) => ((r[t].toUnsigned(size * 8) >> ((size - 1 - i) * 8)) &
                      BigInt.from(255))
                  .toInt());
          if (left) {
            for (var i = offset; i < size; i++) {
              bytes[i - offset] = bus.read8(base + i);
            }
          } else {
            for (var i = 0; i <= offset; i++) {
              bytes[size - 1 - offset + i] = bus.read8(base + i);
            }
          }
          var value = BigInt.zero;
          for (final b in bytes) {
            value = (value << 8) | BigInt.from(b);
          }
          if (size == 4) {
            word(t, value);
          } else {
            put(t, value);
          }
        case 20:
          branch(equal(s, t), likely: true);
        case 21:
          branch(!equal(s, t), likely: true);
        case 22:
          branch(nonpositive(s), likely: true);
        case 23:
          branch(!nonpositive(s), likely: true);
        case 24:
          put(t, add(r[s], BigInt.from(immediate), 64, true));
        case 25:
          put(t, r[s] + BigInt.from(immediate));
        case 32:
          loadWord(1, true);
        case 33:
          loadWord(2, true);
        case 35:
          loadWord(4, true);
        case 36:
          loadWord(1, false);
        case 37:
          loadWord(2, false);
        case 39:
          aligned(a, 4);
          final value = bus.read(a, 4);
          if (value < 0x80000000) {
            putWord(t, value);
          } else {
            put(t, BigInt.from(value));
          }
        case 42:
        case 46:
        case 44:
        case 45:
          final size = code == 44 || code == 45 ? 8 : 4;
          final offset = a % size;
          final left = code == 42 || code == 44;
          final base = a - offset;
          for (var i = left ? offset : 0; i < (left ? size : offset + 1); i++) {
            final index = left ? i - offset : size - 1 - offset + i;
            bus.write8(
                base + i,
                ((r[t].toUnsigned(size * 8) >> ((size - 1 - index) * 8)) &
                        BigInt.from(255))
                    .toInt());
          }
        case 48:
          loadWord(4, true);
          _ll = true;
        case 52:
          put(t, load(8, true));
          _ll = true;
        case 56:
        case 60:
          if (_ll) store(code == 56 ? 4 : 8);
          putWord(t, _ll ? 1 : 0);
          _ll = false;
        case 49:
          aligned(a, 4);
          fpu.setWord(t, bus.read(a, 4));
        case 53:
          fpu.setLong(t, load(8, false));
        case 57:
          aligned(a, 4);
          bus.write(a, fpu.word(t), 4);
        case 61:
          aligned(a, 8);
          for (var i = 0; i < 8; i++) {
            bus.write8(a + i,
                ((fpu.long(t) >> ((7 - i) * 8)) & BigInt.from(255)).toInt());
          }
        case 40:
          store(1);
        case 41:
          store(2);
        case 43:
          store(4);
        case 47:
          break; // CACHE: bus has no caches.
        case 55:
          put(t, load(8, true));
        case 63:
          store(8);
        default:
          unsupported();
      }
      clocks += 1; // Instruction timing is approximate.
    } on CpuFault catch (fault) {
      exception(fault.code, at, delay);
      if (fault.code == 11) cop0[13] |= 0x10000000;
      clocks++;
    } on N64AddressFault catch (fault) {
      exception(fault.write ? 3 : 2, at, delay, badAddress: fault.address);
      clocks++;
    } on UnsupportedError catch (error) {
      pc = at;
      stopReason = error.toString();
    } on StateError catch (error) {
      pc = at;
      stopReason = error.toString();
    }
  }
}

class CpuFault implements Exception {
  final int code;
  const CpuFault(this.code);
}
