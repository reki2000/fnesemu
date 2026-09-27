import 'bus.dart';

/// Experimental VR4300 integer interpreter. BigInt preserves 64 bits on Web.
/// Unsupported operations stop explicitly instead of behaving as NOPs.
class Vr4300 {
  final N64Bus bus;
  final r = List<BigInt>.filled(32, BigInt.zero);
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
    cop0[15] = 0x00000b22;
    r[29] = BigInt.from(0x807ffff0).toSigned(32);
  }

  void put(int index, BigInt value) {
    if (index != 0) r[index] = value.toSigned(64);
  }

  void word(int index, BigInt value) => put(index, value.toSigned(32));
  int address(BigInt value) => value.toUnsigned(32).toInt();
  int signed16(int value) => (value & 0xffff).toSigned(16);

  void aligned(int address, int size) {
    if (address % size != 0) throw UnsupportedError('Unaligned N64 access');
  }

  void step() {
    if (stopReason != null) return;
    final at = pc;
    try {
      aligned(pc, 4);
      final op = bus.read(pc, 4);
      pc = nextPc;
      nextPc = (nextPc + 4) & 0xffffffff;
      final code = op >> 26;
      final s = (op >> 21) & 31, t = (op >> 16) & 31;
      final d = (op >> 11) & 31, shift = (op >> 6) & 31;
      final immediate = signed16(op);
      final a = address(r[s] + BigInt.from(immediate));
      void branch(bool condition, {bool likely = false}) {
        if (condition) {
          nextPc = (at + 4 + immediate * 4) & 0xffffffff;
        } else if (likely) {
          pc = nextPc;
          nextPc = (nextPc + 4) & 0xffffffff;
        }
      }

      void unsupported() => throw UnsupportedError(
            'VR4300 instruction 0x${op.toRadixString(16).padLeft(8, '0')}',
          );
      BigInt load(int size, bool signed) {
        aligned(a, size);
        var value = BigInt.zero;
        for (var i = 0; i < size; i++) {
          value = (value << 8) | BigInt.from(bus.read8(a + i));
        }
        return signed ? value.toSigned(size * 8) : value;
      }

      void store(int size) {
        aligned(a, size);
        if (size <= 4) {
          bus.write(a, r[t].toUnsigned(size * 8).toInt(), size);
        } else {
          for (var i = 0; i < size; i++) {
            bus.write8(
              a + i,
              ((r[t].toUnsigned(64) >> ((size - 1 - i) * 8)) & BigInt.from(255))
                  .toInt(),
            );
          }
        }
      }

      BigInt add(BigInt x, BigInt y, int bits, bool trap,
          {bool subtract = false}) {
        final result = subtract
            ? x.toSigned(bits) - y.toSigned(bits)
            : x.toSigned(bits) + y.toSigned(bits);
        if (trap && result != result.toSigned(bits)) {
          throw UnsupportedError('VR4300 arithmetic overflow exception');
        }
        return result.toSigned(bits);
      }

      switch (code) {
        case 0:
          switch (op & 63) {
            case 0:
              word(d, r[t].toUnsigned(32) << shift);
            case 2:
              word(d, r[t].toUnsigned(32) >> shift);
            case 3:
              word(d, r[t].toSigned(32) >> shift);
            case 4:
              word(d, r[t].toUnsigned(32) << (r[s].toInt() & 31));
            case 6:
              word(d, r[t].toUnsigned(32) >> (r[s].toInt() & 31));
            case 7:
              word(d, r[t].toSigned(32) >> (r[s].toInt() & 31));
            case 8:
              nextPc = address(r[s]);
            case 9:
              final target = address(r[s]);
              put(d, BigInt.from((at + 8) & 0xffffffff).toSigned(32));
              nextPc = target;
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
            case 32:
              word(d, add(r[s], r[t], 32, true));
            case 33:
              word(d, r[s] + r[t]);
            case 34:
              word(d, add(r[s], r[t], 32, true, subtract: true));
            case 35:
              word(d, r[s] - r[t]);
            case 36:
              put(d, r[s] & r[t]);
            case 37:
              put(d, r[s] | r[t]);
            case 38:
              put(d, r[s] ^ r[t]);
            case 39:
              put(d, ~(r[s] | r[t]));
            case 42:
              put(d, r[s] < r[t] ? BigInt.one : BigInt.zero);
            case 43:
              put(
                d,
                r[s].toUnsigned(64) < r[t].toUnsigned(64)
                    ? BigInt.one
                    : BigInt.zero,
              );
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
          if (![0, 1, 2, 3, 16, 17, 18, 19].contains(t)) {
            unsupported();
            break;
          }
          if (t >= 16) put(31, BigInt.from((at + 8) & 0xffffffff).toSigned(32));
          branch(
            (t & 1) == 0 ? r[s] < BigInt.zero : r[s] >= BigInt.zero,
            likely: (t & 2) != 0,
          );
        case 2:
        case 3:
          if (code == 3)
            put(31, BigInt.from((at + 8) & 0xffffffff).toSigned(32));
          nextPc = ((at + 4) & 0xf0000000) | ((op & 0x3ffffff) << 2);
        case 4:
          branch(r[s] == r[t]);
        case 5:
          branch(r[s] != r[t]);
        case 6:
          branch(r[s] <= BigInt.zero);
        case 7:
          branch(r[s] > BigInt.zero);
        case 8:
          word(t, add(r[s], BigInt.from(immediate), 32, true));
        case 9:
          word(t, r[s] + BigInt.from(immediate));
        case 10:
          put(t, r[s] < BigInt.from(immediate) ? BigInt.one : BigInt.zero);
        case 11:
          put(
            t,
            r[s].toUnsigned(64) < BigInt.from(immediate).toUnsigned(64)
                ? BigInt.one
                : BigInt.zero,
          );
        case 12:
          put(t, r[s] & BigInt.from(op & 0xffff));
        case 13:
          put(t, r[s] | BigInt.from(op & 0xffff));
        case 14:
          put(t, r[s] ^ BigInt.from(op & 0xffff));
        case 15:
          word(t, BigInt.from(op & 0xffff) << 16);
        case 16:
          if (s == 0) {
            word(t, BigInt.from(d == 9 ? clocks ~/ 2 : cop0[d]));
          } else if (s == 4 && ![12, 13].contains(d)) {
            cop0[d] = address(r[t]);
          } else {
            unsupported();
          }
        case 20:
          branch(r[s] == r[t], likely: true);
        case 21:
          branch(r[s] != r[t], likely: true);
        case 22:
          branch(r[s] <= BigInt.zero, likely: true);
        case 23:
          branch(r[s] > BigInt.zero, likely: true);
        case 24:
          put(t, add(r[s], BigInt.from(immediate), 64, true));
        case 25:
          put(t, r[s] + BigInt.from(immediate));
        case 32:
          put(t, load(1, true));
        case 33:
          put(t, load(2, true));
        case 35:
          put(t, load(4, true));
        case 36:
          put(t, load(1, false));
        case 37:
          put(t, load(2, false));
        case 39:
          put(t, load(4, false));
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
    } on UnsupportedError catch (error) {
      pc = at;
      stopReason = error.toString();
    } on StateError catch (error) {
      pc = at;
      stopReason = error.toString();
    }
  }
}
