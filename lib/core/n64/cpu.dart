import 'package:fnesemu/util/int.dart';

import 'bus.dart';
import 'fpu.dart';
import 'registers.dart';

/// Experimental VR4300 integer interpreter. 64-bit registers are plain ints
/// (native and wasm ints are 64-bit and wrap modulo 2^64).
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
    final untilCompare = (cop0[11] - count).mask32 * 2;
    clocks += untilCompare > 0 && untilCompare < cycles ? untilCompare : cycles;
  }

  bool _ll = false;
  int _countOffset = 0;
  bool _timerIrq = false;
  final r = N64Registers();
  final cop0 = List<int>.filled(32, 0);
  int pc = 0, nextPc = 4, clocks = 0;
  int hi = 0, lo = 0;
  String? stopReason;

  Vr4300(this.bus);

  void reset(int entry) {
    r.fillRange(0, 32, 0);
    cop0.fillRange(0, 32, 0);
    hi = lo = 0;
    pc = entry;
    nextPc = (entry + 4).mask32;
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
    r[29] = 0x807ffff0.toSigned(32);
  }

  void put(int index, int value) => r[index] = value;
  int lowWord(int index) => r.word(index);
  void putWord(int index, int value) => r.setWord(index, value);

  bool equal(int s, int t) => r[s] == r[t];
  bool negative(int s) => r[s] < 0;
  bool nonpositive(int s) => r[s] <= 0;
  bool lessSigned(int s, int t) => r[s] < r[t];
  bool lessUnsigned(int s, int t) => ltu(r[s], r[t]);
  int addWord(int s, int value, {bool subtract = false}) {
    final result = subtract ? lowWord(s) - value : lowWord(s) + value;
    if (result < -2147483648 || result > 2147483647) {
      throw const CpuFault(12);
    }
    return result;
  }

  void logic(int d, int s, int t, int fn) {
    final a = r[s], b = r[t];
    put(d,
        switch (fn) { 36 => a & b, 37 => a | b, 38 => a ^ b, _ => ~(a | b) });
  }

  int address(int value) => value.mask32;
  int signed16(int value) => value.mask16.toSigned(16);

  void aligned(int address, int size) {
    if (address % size != 0) throw UnsupportedError('Unaligned N64 access');
  }

  void exception(int code, int at, bool delay, {int? badAddress}) {
    cop0[13] = cop0[13] & 0xff00 | code.shl2;
    if (!cop0[12].bit1) {
      cop0[14] = delay ? (at - 4).mask32 : at;
      if (delay) cop0[13] |= 0x80000000;
    }
    if (badAddress != null) cop0[8] = badAddress;
    cop0[12] |= 2;
    pc = cop0[12].bit22 ? 0xbfc00380 : 0x80000180;
    nextPc = (pc + 4).mask32;
    _delay = false;
    _ll = false;
  }

  int get count => (clocks ~/ 2 + _countOffset).mask32;
  void step() {
    if (stopReason != null) return;
    if (count == cop0[11] && clocks > 0) _timerIrq = true;
    cop0[13] = (cop0[13] & ~0x8400) |
        (bus.interruptPending ? 0x400 : 0) |
        (_timerIrq ? 0x8000 : 0);
    if (cop0[12].mask3 == 1 && cop0[12] & cop0[13] & 0xff00 != 0 && !_delay) {
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
      nextPc = (nextPc + 4).mask32;
      if (op == 0) {
        clocks++;
        return;
      }
      final code = op.shr26;
      if ((op == 0x1000ffff ||
              (code == 2 &&
                  (((at + 4) & 0xf0000000) | op.mask26.shl2) == at)) &&
          bus.read((at + 4).mask32, 4) == 0) {
        _idleAddress = at;
      }
      final s = op.shr21.mask5, t = op.shr16.mask5;
      final d = op.shr11.mask5, shift = op.shr6.mask5;
      final immediate = signed16(op);
      late final a = (lowWord(s) + immediate).mask32;
      void branch(bool condition, {bool likely = false}) {
        _delay = true;
        if (condition) {
          nextPc = (at + 4 + immediate * 4).mask32;
        } else if (likely) {
          _delay = false;
          pc = nextPc;
          nextPc = (nextPc + 4).mask32;
        }
      }

      void unsupported() => throw UnsupportedError(
            'VR4300 instruction 0x${op.x8}',
          );
      int load64() {
        aligned(a, 8);
        return bus.read(a, 4) << 32 | bus.read(a + 4, 4);
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
          bus.write(a, r[t] >>> 32, 4);
          bus.write(a + 4, lowWord(t), 4);
        }
      }

      /// 64-bit add/sub trapping on signed overflow (DADD/DADDI/DSUB)
      int add(int x, int y, {bool subtract = false}) {
        final result = subtract ? x - y : x + y;
        final overflow =
            subtract ? (x ^ y) & (x ^ result) : (x ^ result) & (y ^ result);
        if (overflow < 0) throw const CpuFault(12);
        return result;
      }

      if ((code == 17 ||
              code == 49 ||
              code == 53 ||
              code == 57 ||
              code == 61) &&
          !cop0[12].bit29) {
        throw const CpuFault(11);
      }
      switch (code) {
        case 0:
          switch (op.mask6) {
            case 0:
              putWord(d, lowWord(t).shl(shift));
            case 2:
              putWord(d, lowWord(t).mask32.shr(shift));
            case 3:
              putWord(d, lowWord(t).shr(shift));
            case 4:
              putWord(d, lowWord(t).shl(lowWord(s).mask5));
            case 6:
              putWord(d, lowWord(t).mask32.shr(lowWord(s).mask5));
            case 7:
              putWord(d, lowWord(t).shr(lowWord(s).mask5));
            case 8:
              _delay = true;
              nextPc = lowWord(s).mask32;
            case 9:
              _delay = true;
              final target = lowWord(s).mask32;
              putWord(d, (at + 8).mask32);
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
              put(d, r[t] << r[s].mask6);
            case 22:
              put(d, r[t] >>> r[s].mask6);
            case 23:
              put(d, r[t] >> r[s].mask6);
            case 24:
            case 25:
              final unsigned = op.mask6 == 25;
              final x = unsigned ? r[s].mask32 : lowWord(s);
              final y = unsigned ? r[t].mask32 : lowWord(t);
              final product = x * y; // wraps modulo 2^64: low 64 bits exact
              lo = product.toSigned(32);
              hi = (product >> 32).toSigned(32);
            case 26:
            case 27:
              final unsigned = op.mask6 == 27;
              final x = unsigned ? r[s].mask32 : lowWord(s);
              final y = unsigned ? r[t].mask32 : lowWord(t);
              if (y == 0) {
                lo = unsigned || x >= 0 ? -1 : 1;
                hi = x.toSigned(32);
              } else {
                lo = (x ~/ y).toSigned(32);
                hi = x.remainder(y).toSigned(32);
              }
            case 28:
            case 29:
              final x = r[s], y = r[t];
              lo = x * y;
              hi = op.mask6 == 29 ? mulHiUnsigned(x, y) : mulHiSigned(x, y);
            case 30:
              final x = r[s], y = r[t];
              if (y == 0) {
                lo = x >= 0 ? -1 : 1;
                hi = x;
              } else if (y == -1) {
                lo = -x; // wraps for the minimum value like the hardware
                hi = 0;
              } else {
                lo = x ~/ y;
                hi = x.remainder(y);
              }
            case 31:
              final x = r[s], y = r[t];
              if (y == 0) {
                lo = -1;
                hi = x;
              } else {
                final (q, rem) = divUnsigned(x, y);
                lo = q;
                hi = rem;
              }
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
              put(d, add(r[s], r[t]));
            case 45:
              put(d, r[s] + r[t]);
            case 46:
              put(d, add(r[s], r[t], subtract: true));
            case 47:
              put(d, r[s] - r[t]);
            case 56:
              put(d, r[t] << shift);
            case 58:
              put(d, r[t] >>> shift);
            case 59:
              put(d, r[t] >> shift);
            case 60:
              put(d, r[t] << (shift + 32));
            case 62:
              put(d, r[t] >>> (shift + 32));
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
          if (t >= 16) putWord(31, (at + 8).mask32);
          branch(
            !t.bit0 ? negative(s) : !negative(s),
            likely: t.bit1,
          );
        case 2:
        case 3:
          _delay = true;
          if (code == 3) {
            putWord(31, (at + 8).mask32);
          }
          nextPc = (at + 4) & 0xf0000000 | op.mask26.shl2;
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
          putWord(t, r[s] < immediate ? 1 : 0);
        case 11:
          putWord(t, ltu(r[s], immediate) ? 1 : 0);
        case 12:
          put(t, r[s] & op.mask16);
        case 13:
          put(t, r[s] | op.mask16);
        case 14:
          put(t, r[s] ^ op.mask16);
        case 15:
          putWord(t, op.mask16.shl16);
        case 16:
          if (s == 0 || s == 1) {
            putWord(t, d == 9 ? count : cop0[d]);
          } else if (s == 4 || s == 5) {
            final v = lowWord(t).mask32;
            if (d == 9) _countOffset = v - clocks ~/ 2;
            if (d == 11) _timerIrq = false;
            if (d == 13) {
              cop0[d] = (cop0[d] & ~0x300) | (v & 0x300);
            } else {
              cop0[d] = v;
            }
            fpu.wide = cop0[12].bit26;
          } else if (s == 16) {
            switch (op.mask6) {
              case 24:
                pc = cop0[12].bit2 ? cop0[30] : cop0[14];
                cop0[12] &= cop0[12].bit2 ? ~4 : ~2;
                nextPc = (pc + 4).mask32;
                _delay = false;
                _ll = false;
              case 2:
                bus.writeTlb(cop0[0].mask5, cop0);
              case 6:
                bus.writeTlb(
                    (clocks % (32 - cop0[6].mask5)) + cop0[6].mask5, cop0);
              case 8:
                cop0[0] = bus.probeTlb(cop0[10]);
              case 1:
                bus.readTlb(cop0[0].mask5, cop0);
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
              if (fs == 31) fpu.control = lowWord(t).mask32;
            case 8:
              branch(t.bit0 ? fpu.condition : !fpu.condition, likely: t.bit1);
            default:
              fpu.execute(s, t, fs, fd, op.mask6);
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
              size, (i) => (r[t] >>> (size - 1 - i) * 8).mask8);
          if (left) {
            for (var i = offset; i < size; i++) {
              bytes[i - offset] = bus.read8(base + i);
            }
          } else {
            for (var i = 0; i <= offset; i++) {
              bytes[size - 1 - offset + i] = bus.read8(base + i);
            }
          }
          var value = 0;
          for (final b in bytes) {
            value = value.shl8 | b;
          }
          if (size == 4) {
            putWord(t, value);
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
          put(t, add(r[s], immediate));
        case 25:
          put(t, r[s] + immediate);
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
          put(t, bus.read(a, 4).mask32);
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
            bus.write8(base + i, (r[t] >>> (size - 1 - index) * 8).mask8);
          }
        case 48:
          loadWord(4, true);
          _ll = true;
        case 52:
          put(t, load64());
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
          fpu.setLong(t, load64());
        case 57:
          aligned(a, 4);
          bus.write(a, fpu.word(t), 4);
        case 61:
          aligned(a, 8);
          for (var i = 0; i < 8; i++) {
            bus.write8(a + i, (fpu.long(t) >>> (7 - i) * 8).mask8);
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
          put(t, load64());
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

/// unsigned 64-bit less-than
bool ltu(int a, int b) => (a ^ _signBit) < (b ^ _signBit);
const _signBit = 1 << 63;

/// high 64 bits of the unsigned 128-bit product of [x] and [y]
int mulHiUnsigned(int x, int y) {
  final xl = x.mask32, xh = x >>> 32, yl = y.mask32, yh = y >>> 32;
  final t = xh * yl + (xl * yl >>> 32);
  final u = xl * yh + t.mask32;
  return xh * yh + (t >>> 32) + (u >>> 32);
}

/// high 64 bits of the signed 128-bit product of [x] and [y]
int mulHiSigned(int x, int y) =>
    mulHiUnsigned(x, y) - (x < 0 ? y : 0) - (y < 0 ? x : 0);

/// unsigned 64-bit division; [y] must not be zero. Returns (quotient, remainder).
(int, int) divUnsigned(int x, int y) {
  if (x >= 0 && y > 0) return (x ~/ y, x.remainder(y));
  if (y < 0) return ltu(x, y) ? (0, x) : (1, x - y);
  var q = (x >>> 1) ~/ y << 1;
  var rem = x - q * y;
  if (!ltu(rem, y)) {
    q++;
    rem -= y;
  }
  return (q, rem);
}

class CpuFault implements Exception {
  final int code;
  const CpuFault(this.code);
}
