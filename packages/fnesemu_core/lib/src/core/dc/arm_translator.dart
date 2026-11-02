import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

/// ARM7DI blocks over sound RAM: data processing with immediate shifts,
/// single word and byte transfers and branches. Any other instruction, a
/// conditional transfer and an access outside mapped RAM leave the block
/// before their effects so that the interpreter executes them. Interrupts
/// are taken by the interpreter before a run, since the interrupt line only
/// changes between runs.
///
/// Instructions charge their executed cycle counts even when their
/// condition fails, where the interpreter charges one cycle.
final class DcArmTranslator {
  static const regs = JitCtx.user;
  static const cpsr = regs + 16, ctxWords = cpsr + 1;
  static const interpret = JitReason.user;

  /// The most cycles one block takes: [maxInstructions] loads into the PC.
  static const maxBlockCycles = 64 * 5;

  DcArmTranslator(
      {required this.fetch, required this.protect, this.maxInstructions = 64})
      : assert(maxInstructions * 5 <= maxBlockCycles);

  final int? Function(int pc) fetch;
  final void Function(int) protect;
  final int maxInstructions;

  late IrBuilder b;
  final _values = <int, IrValue>{};
  int _spent = 0;

  IrValue c(int x) => b.c32(x & 0xffffffff);
  IrValue _get(int word) => _values[word] ??= b.ctxLoad(word);
  void _put(int word, IrValue value) => _values[word] = value;
  IrValue _r(int n, int at, {int ahead = 8}) =>
      n == 15 ? c(at + ahead) : _get(regs + n);
  IrExit _snapshot(int pc) => IrExit(interpret, pc,
      spent: _spent,
      stores: [for (final e in _values.entries) (e.key, e.value)]);

  void _flush() {
    for (final e in _values.entries) {
      b.ctxStore(e.key, e.value);
    }
  }

  IrBlock? translate(int pc, int tag) {
    _values.clear();
    _spent = 0;
    b = IrBuilder(pc, tag: tag);
    var at = pc;
    for (var count = 0; count < maxInstructions; count++) {
      final op = fetch(at);
      if (op == null) break;
      final condition = op >>> 28;
      if (condition == 15) break;
      if (op & 0x0e000000 == 0x0a000000) {
        b.guard(at, op);
        protect(at);
        return _branch(op, at, condition);
      }
      final cost = _cost(op, condition);
      if (cost == null) break;
      b.guard(at, op);
      protect(at);
      final jump = _emit(op, at, condition);
      _spent += cost;
      if (jump != null) {
        _flush();
        return b.finish(IrJumpDyn(jump), cost: _spent);
      }
      at = (at + 4) & 0xffffffff;
    }
    if (_spent == 0) return null;
    _flush();
    return b.finish(IrExitTerm(IrExit(interpret, at)), cost: _spent);
  }

  IrBlock _branch(int op, int at, int condition) {
    final target =
        (at + 8 + (((op & 0xffffff) ^ 0x800000) - 0x800000) * 4) & 0xffffffff;
    final passes = condition == 14 ? null : _condition(condition);
    if (op & 0x01000000 != 0) {
      final link = c(at + 4);
      _put(regs + 14,
          passes == null ? link : b.select(passes, link, _get(regs + 14)));
    }
    _spent += 3;
    _flush();
    final next = (at + 4) & 0xffffffff;
    return b.finish(
        passes == null ? IrJump(target) : IrBranch(passes, target, next),
        cost: _spent);
  }

  /// Executed cycles of a supported instruction, or null.
  static int? _cost(int op, int condition) {
    if (op & 0x0c000000 == 0) {
      // Data processing with an immediate or an immediately shifted register.
      if (op & 0x02000090 == 0x90) return null;
      if (op & 0x02000010 == 0x10) return null;
      final code = (op >> 21) & 15, rd = (op >> 12) & 15;
      final set = op & 0x100000 != 0, test = code >= 8 && code <= 11;
      if (test && (!set || rd == 15)) return null;
      if (!test && rd == 15 && set) return null;
      return !test && rd == 15 ? 3 : 1;
    }
    if (op & 0x0c000000 == 0x04000000) {
      if (condition != 14) return null;
      if (op & 0x02000010 == 0x02000010) return null;
      final rn = (op >> 16) & 15, rd = (op >> 12) & 15;
      final pre = op & 0x1000000 != 0, load = op & 0x100000 != 0;
      final byte = op & 0x400000 != 0;
      final back = !pre || op & 0x200000 != 0;
      // User-mode transfers (post-indexed with W) are left to the interpreter.
      if (!pre && op & 0x200000 != 0) return null;
      if (rn == 15 && back) return null;
      if (byte && rd == 15) return null;
      if (op & 0x2000000 != 0 && (op & 15 == 15 || (!pre && op & 15 == rn))) {
        return null;
      }
      if (load && back && rn == rd) return null;
      return load ? (rd == 15 ? 5 : 3) : 2;
    }
    return null;
  }

  IrValue _bit(IrValue flags, int shift) =>
      b.and(b.shrU(flags, c(shift)), c(1));
  IrValue _not(IrValue x) => b.xor(x, c(1));

  IrValue _condition(int condition) {
    final flags = _get(cpsr);
    final n = _bit(flags, 31), z = _bit(flags, 30);
    final cy = _bit(flags, 29), v = _bit(flags, 28);
    return switch (condition) {
      0 => z,
      1 => _not(z),
      2 => cy,
      3 => _not(cy),
      4 => n,
      5 => _not(n),
      6 => v,
      7 => _not(v),
      8 => b.and(cy, _not(z)),
      9 => b.or(_not(cy), z),
      10 => b.eq(n, v),
      11 => b.ne(n, v),
      12 => b.and(_not(z), b.eq(n, v)),
      _ => b.or(z, b.ne(n, v)),
    };
  }

  IrValue _ror(IrValue x, int n) =>
      n == 0 ? x : b.or(b.shrU(x, c(n)), b.shl(x, c(32 - n)));

  /// Operand 2 and its shifter carry; the carry is built only if [carry].
  (IrValue, IrValue?) _operand(int op, int at, bool carry) {
    if (op & 0x02000000 != 0) {
      final rotate = ((op >> 8) & 15) * 2;
      final value =
          ((op & 255) >>> rotate | (op & 255) << (32 - rotate)) & 0xffffffff;
      return (
        c(value),
        !carry
            ? null
            : rotate == 0
                ? _bit(_get(cpsr), 29)
                : c(value >>> 31)
      );
    }
    final rm = _r(op & 15, at);
    final type = (op >> 5) & 3, amount = (op >> 7) & 31;
    IrValue? out;
    switch (type) {
      case 0:
        if (amount == 0) return (rm, carry ? _bit(_get(cpsr), 29) : null);
        if (carry) out = _bit(rm, 32 - amount);
        return (b.shl(rm, c(amount)), out);
      case 1:
        if (amount == 0) return (c(0), carry ? _bit(rm, 31) : null);
        if (carry) out = _bit(rm, amount - 1);
        return (b.shrU(rm, c(amount)), out);
      case 2:
        // ASR #0 encodes ASR #32.
        if (amount == 0) {
          return (b.shrS(rm, c(31)), carry ? _bit(rm, 31) : null);
        }
        if (carry) out = _bit(rm, amount - 1);
        return (b.shrS(rm, c(amount)), out);
      default:
        if (amount == 0) {
          final value =
              b.or(b.shl(_bit(_get(cpsr), 29), c(31)), b.shrU(rm, c(1)));
          return (value, carry ? b.and(rm, c(1)) : null);
        }
        final value = _ror(rm, amount);
        return (value, carry ? _bit(value, 31) : null);
    }
  }

  /// Emits a non-branch instruction; returns the jump target when it
  /// writes the PC.
  IrValue? _emit(int op, int at, int condition) {
    final passes = condition == 14 ? null : _condition(condition);
    if (op & 0x0c000000 == 0x04000000) return _transfer(op, at);
    final code = (op >> 21) & 15, rd = (op >> 12) & 15;
    final set = op & 0x100000 != 0, test = code >= 8 && code <= 11;
    final arithmetic = (0xcfc >> code) & 1 != 0;
    final a = _r((op >> 16) & 15, at);
    final (operand, shifterCarry) = _operand(op, at, set && !arithmetic);
    final flags = _get(cpsr);
    IrValue result, newFlags = flags;
    if (arithmetic) {
      final reverse = code == 3 || code == 7;
      final x = reverse ? operand : a, other = reverse ? a : operand;
      final add = code == 4 || code == 5 || code == 11;
      final y = add ? other : b.xor(other, c(0xffffffff));
      final carryIn = code >= 5 && code <= 7
          ? _bit(flags, 29)
          : add
              ? c(0)
              : c(1);
      result = b.add(b.add(x, y), carryIn);
      if (set) {
        // x + y + 1 carries when the result does not exceed x; x + y when
        // the result is below x.
        final carry = code >= 5 && code <= 7
            ? b.select(carryIn, _not(b.ltU(x, result)), b.ltU(result, x))
            : add
                ? b.ltU(result, x)
                : _not(b.ltU(x, result));
        final overflow =
            b.shrU(b.and(b.xor(x, result), b.xor(y, result)), c(31));
        newFlags = b.or(
            b.and(flags, c(0x0fffffff)),
            b.or(
                b.or(b.and(result, c(0x80000000)),
                    b.shl(b.eq(result, c(0)), c(30))),
                b.or(b.shl(carry, c(29)), b.shl(overflow, c(28)))));
      }
    } else {
      result = switch (code) {
        0 || 8 => b.and(a, operand),
        1 || 9 => b.xor(a, operand),
        12 => b.or(a, operand),
        13 => operand,
        14 => b.and(a, b.xor(operand, c(0xffffffff))),
        _ => b.xor(operand, c(0xffffffff)),
      };
      if (set) {
        newFlags = b.or(
            b.and(flags, c(0x1fffffff)),
            b.or(
                b.or(b.and(result, c(0x80000000)),
                    b.shl(b.eq(result, c(0)), c(30))),
                b.shl(shifterCarry!, c(29))));
      }
    }
    if (set) {
      _put(cpsr, passes == null ? newFlags : b.select(passes, newFlags, flags));
    }
    if (test) return null;
    if (rd == 15) {
      final target = b.and(result, c(0xfffffffc));
      return passes == null ? target : b.select(passes, target, c(at + 4));
    }
    _put(regs + rd,
        passes == null ? result : b.select(passes, result, _get(regs + rd)));
    return null;
  }

  IrValue? _transfer(int op, int at) {
    final rn = (op >> 16) & 15, rd = (op >> 12) & 15;
    final pre = op & 0x1000000 != 0, up = op & 0x800000 != 0;
    final load = op & 0x100000 != 0, byte = op & 0x400000 != 0;
    final back = !pre || op & 0x200000 != 0;
    final exit = _snapshot(at);
    final base = _r(rn, at);
    IrValue offset;
    if (op & 0x2000000 != 0) {
      offset = _operand(op & ~0x02000000 & ~0x10, at, false).$1;
    } else {
      offset = c(op & 0xfff);
    }
    final modified = up ? b.add(base, offset) : b.sub(base, offset);
    final address = pre ? modified : base;
    if (load) {
      IrValue value;
      if (byte) {
        value = b.load(1, address, unmapped: exit);
      } else {
        final word = b.load(4, b.and(address, c(0xfffffffc)), unmapped: exit);
        // An unaligned word rotates right by the byte offset.
        final shift = b.shl(b.and(address, c(3)), c(3));
        value = b.or(b.shrU(word, shift),
            b.shl(word, b.and(b.sub(c(32), shift), c(31))));
        value = b.select(b.eq(shift, c(0)), word, value);
      }
      if (back) _put(regs + rn, modified);
      if (rd == 15) return b.and(value, c(0xfffffffc));
      _put(regs + rd, value);
    } else {
      final value = _r(rd, at, ahead: 12);
      if (byte) {
        b.store(1, address, value, unmapped: exit);
      } else {
        b.store(4, b.and(address, c(0xfffffffc)), value, unmapped: exit);
      }
      if (back) _put(regs + rn, modified);
    }
    return null;
  }
}
