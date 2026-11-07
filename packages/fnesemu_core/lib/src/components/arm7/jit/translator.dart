import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../../../util/int.dart';

/// Which instruction forms a core's ARM translator emits.
///
/// The DC policy is exactly the set the ARM7DI translator has always
/// supported over sound RAM: data processing with immediate or
/// immediately shifted operands, unconditional single transfers and
/// branches. The GBA policy adds the forms the TDMI interpreter
/// executes but the DI core prohibits or lacks: register-controlled
/// shifts, multiply, swap, halfword transfers and block transfers, with
/// the TDMI's lenient transfer rules. Both policies leave the rest to
/// the interpreter by ending the block before the instruction, so the
/// interpreter executes it with its exact state and cycle count.
///
/// Instructions charge their executed cycle counts even when their
/// condition fails, where the interpreter charges one cycle. That is
/// the ARM7DI translator's documented divergence, kept for both cores.
final class ArmTranslatorPolicy {
  const ArmTranslatorPolicy({
    required this.registerShift,
    required this.multiply,
    required this.swap,
    required this.halfTransfers,
    required this.blockTransfers,
    required this.lenientTransfers,
    required this.loadToPcCycles,
    required this.maxInstructionCycles,
    this.strictBlockTransfers = false,
    this.blockLoadToPcCycles = 0,
    this.statusTransfers = false,
  });

  /// Register-controlled operand2 shifts in data processing.
  final bool registerShift;

  /// Short and long multiply.
  final bool multiply;

  /// Single data swap (unconditional only, like transfers).
  final bool swap;

  /// Halfword and signed byte/halfword transfers.
  final bool halfTransfers;

  /// Block transfers (unconditional, without the S bit).
  final bool blockTransfers;

  /// The ARM7DI interpreter prohibits a block transfer based on PC, which
  /// stays interpreted, and charges [blockLoadToPcCycles] more cycles for a
  /// load that includes PC.
  final bool strictBlockTransfers;

  /// Extra cycles of a block load that includes PC.
  final int blockLoadToPcCycles;

  /// Unconditional MRS from the CPSR and MSR to the CPSR in the ARM7DI
  /// forms. An MSR that would change the mode leaves the block before it,
  /// and one that enables an interrupt leaves the block after it.
  final bool statusTransfers;

  /// Accepts the transfer forms the ARM7DI interpreter prohibits:
  /// writeback to PC, byte loads to PC, load/writeback overlap,
  /// register offsets the DI core traps, and post-indexed transfers
  /// with the W bit, which the TDMI interpreter treats as plain
  /// post-indexed transfers.
  final bool lenientTransfers;

  /// Cycles a single-transfer load to PC charges (5 on the DI core, 3
  /// on the TDMI core, matching their interpreters).
  final int loadToPcCycles;

  /// The most cycles one emitted instruction charges.
  final int maxInstructionCycles;

  /// The most cycles one block translated under this policy takes.
  int maxBlockCycles(int maxInstructions) =>
      maxInstructions * maxInstructionCycles;

  /// The ARM7DI policy (DC AICA sound CPU).
  static const dc = ArmTranslatorPolicy(
    registerShift: false,
    multiply: false,
    swap: false,
    halfTransfers: false,
    blockTransfers: true,
    strictBlockTransfers: true,
    blockLoadToPcCycles: 2,
    statusTransfers: true,
    lenientTransfers: false,
    loadToPcCycles: 5,
    // A block load of sixteen registers that includes PC takes 20.
    maxInstructionCycles: 20,
  );

  /// The ARM7TDMI policy (GBA).
  static const gba = ArmTranslatorPolicy(
    registerShift: true,
    multiply: true,
    swap: true,
    halfTransfers: true,
    blockTransfers: true,
    lenientTransfers: true,
    loadToPcCycles: 3,
    maxInstructionCycles: 18,
  );
}

/// ARM block translator shared by the DC and GBA cores.
///
/// Data processing, single transfers and branches follow the ARM7DI
/// translator's emission. The GBA policy's extra forms (see
/// [ArmTranslatorPolicy]) emit through the same value cache, snapshot
/// and flush machinery. The Thumb front-end runs only when a halfword
/// fetch is supplied (the GBA); it exits back to the interpreter for
/// SWI and BX, whose state change the interpreter performs exactly.
///
/// Registers live in the runtime context at [regs], the CPSR at
/// [cpsr]; compiled code and the interpreter share them through the
/// owning adapter.
final class ArmTranslator {
  static const regs = JitCtx.user;
  static const cpsr = regs + 16, ctxWords = cpsr + 1;
  static const interpret = JitReason.user;

  ArmTranslator({
    required this.fetch,
    required this.protect,
    required this.policy,
    this.fetchHalf,
    this.maxInstructions = 64,
  }) : assert(maxInstructions * policy.maxInstructionCycles <=
            policy.maxBlockCycles(maxInstructions));

  /// The instruction word at an ARM address, or null to end the block.
  final int? Function(int pc) fetch;

  /// The instruction halfword at a Thumb address, or null to end the
  /// block. Null on cores without Thumb state.
  final int? Function(int pc)? fetchHalf;

  /// Marks a translated instruction's page as code.
  final void Function(int) protect;

  final ArmTranslatorPolicy policy;
  final int maxInstructions;

  late IrBuilder b;
  final _values = <int, IrValue>{};
  int _spent = 0;

  IrValue c(int x) => b.c32(x & 0xffffffff);
  IrValue _get(int word) => _values[word] ??= b.ctxLoad(word);
  void _put(int word, IrValue value) => _values[word] = value;
  IrValue _r(int n, int at, {int ahead = 8}) =>
      n == 15 ? c(at + ahead) : _get(regs + n);
  IrExit _snapshot(int pc, {int tag = 0}) => IrExit(interpret, pc,
      tag: tag,
      spent: _spent,
      stores: [for (final e in _values.entries) (e.key, e.value)]);

  void _flush() {
    for (final e in _values.entries) {
      b.ctxStore(e.key, e.value);
    }
  }

  /// Translates the block at [pc]; [tag] 1 selects the Thumb front-end
  /// on cores that have one.
  IrBlock? translate(int pc, {int tag = 0}) {
    if (tag == 1 && fetchHalf != null) return _translateThumb(pc, tag);
    return _translateArm(pc, tag);
  }

  IrBlock? _translateArm(int pc, int tag) {
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
      // BX ends the block: its target's bit 0 picks the state the
      // interpreter continues in, which a compiled jump cannot express.
      if ((op & 0x0ffffff0) == 0x012fff10) break;
      final cost = _cost(op, condition);
      if (cost == null) break;
      b.guard(at, op);
      protect(at);
      final jump = _emit(op, at, condition);
      _spent += cost;
      if (jump != null) {
        _flush();
        return b.finish(IrJumpDyn(jump, tag: tag), cost: _spent);
      }
      at = (at + 4) & 0xffffffff;
    }
    if (_spent == 0) return null;
    _flush();
    return b.finish(IrExitTerm(IrExit(interpret, at, tag: tag)),
        cost: _spent);
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
  int? _cost(int op, int condition) {
    if (op & 0x0c000000 == 0) {
      // Data processing space, plus the multiply/swap/halfword space
      // inside its register form.
      if (op & 0x02000000 == 0 && (op & 0x90) == 0x90) {
        if ((op & 0x60) == 0) {
          if (op & 0x01000000 != 0) return policy.swap ? 4 : null;
          if (op & 0x00800000 != 0) {
            // A long multiply into PC reads its accumulate input from
            // the fetch pointer mid-block; leave it to the interpreter.
            if ((op >> 12) & 15 == 15 || (op >> 16) & 15 == 15) return null;
            return policy.multiply ? 5 : null;
          }
          return policy.multiply ? 4 : null;
        }
        return policy.halfTransfers ? (op & 0x100000 != 0 ? 3 : 2) : null;
      }
      if (_statusTransfer(op, condition)) return 1;
      if (!policy.registerShift && (op & 0x02000010) == 0x10) return null;
      final code = (op >> 21) & 15, rd = (op >> 12) & 15;
      final set = op & 0x100000 != 0, test = code >= 8 && code <= 11;
      if (test && (!set || rd == 15)) return null;
      if (!test && rd == 15 && set) return null;
      final regShift = (op & 0x02000010) == 0x10;
      return !test && rd == 15 ? 3 : (regShift ? 2 : 1);
    }
    if (op & 0x0c000000 == 0x04000000) {
      if (condition != 14) return null;
      if (!policy.lenientTransfers && (op & 0x02000010) == 0x02000010) {
        return null;
      }
      final rn = (op >> 16) & 15, rd = (op >> 12) & 15;
      final pre = op & 0x1000000 != 0, load = op & 0x100000 != 0;
      final byte = op & 0x400000 != 0;
      final back = !pre || op & 0x200000 != 0;
      // User-mode transfers (post-indexed with W) are left to the
      // interpreter on the DI core; the TDMI interpreter treats them
      // as plain post-indexed transfers.
      if (!policy.lenientTransfers && !pre && op & 0x200000 != 0) {
        return null;
      }
      if (!policy.lenientTransfers) {
        if (rn == 15 && back) return null;
        if (byte && rd == 15) return null;
        if (op & 0x2000000 != 0 && (op & 15 == 15 || (!pre && op & 15 == rn))) {
          return null;
        }
        if (load && back && rn == rd) return null;
      }
      return load ? (rd == 15 ? policy.loadToPcCycles : 3) : 2;
    }
    if (op & 0x0e000000 == 0x08000000) {
      if (!policy.blockTransfers) return null;
      if (condition != 14) return null;
      if (op & 0x400000 != 0) return null; // the S bit stays interpreted
      if (policy.strictBlockTransfers && (op >> 16) & 15 == 15) return null;
      var count = 0;
      for (var i = 0; i < 16; i++) {
        if (op & (1 << i) != 0) count++;
      }
      if (count == 0) return null;
      if (op & 0x100000 == 0) return count + 1;
      return count + 2 + (op & 0x8000 != 0 ? policy.blockLoadToPcCycles : 0);
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

  /// NZCV flags after an arithmetic operation on x and y (already
  /// complemented for subtractions) with the given carry in and out.
  IrValue _flagsArithmetic(
      IrValue flags, IrValue result, IrValue x, IrValue y, IrValue carry) {
    final overflow =
        b.shrU(b.and(b.xor(x, result), b.xor(y, result)), c(31));
    return b.or(
        b.and(flags, c(0x0fffffff)),
        b.or(
            b.or(b.and(result, c(0x80000000)),
                b.shl(b.eq(result, c(0)), c(30))),
            b.or(b.shl(carry, c(29)), b.shl(overflow, c(28)))));
  }

  /// NZC flags after a logical operation; V is preserved.
  IrValue _flagsLogical(IrValue flags, IrValue result, IrValue carry) {
    return b.or(
        b.and(flags, c(0x1fffffff)),
        b.or(
            b.or(b.and(result, c(0x80000000)),
                b.shl(b.eq(result, c(0)), c(30))),
            b.shl(carry, c(29))));
  }

  /// NZ flags after a multiply; C and V are preserved.
  IrValue _flagsMultiply(IrValue flags, IrValue result) {
    return b.or(
        b.and(flags, c(0x3fffffff)),
        b.or(b.and(result, c(0x80000000)),
            b.shl(b.eq(result, c(0)), c(30))));
  }

  /// Operand 2 and its shifter carry; the carry is built only if
  /// [carry]. Immediate and immediately shifted register forms.
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

  /// A barrel shift by a register-controlled amount (the low byte of
  /// [amountRaw]), with the register form's edge cases. The carry is
  /// built only if [carry].
  (IrValue, IrValue?) _shiftByRegister(
      int type, IrValue v, IrValue amountRaw, bool carry) {
    final amount = b.and(amountRaw, c(0xff));
    final oldCarry = _bit(_get(cpsr), 29);
    final isZero = b.eq(amount, c(0));
    final below32 = b.ltU(amount, c(32));
    IrValue value;
    IrValue? out;
    switch (type) {
      case 0: // LSL
        value = b.select(isZero, v, b.select(below32, b.shl(v, amount), c(0)));
        if (carry) {
          out = b.select(
              isZero,
              oldCarry,
              b.select(
                  below32,
                  b.and(b.shrU(v, b.sub(c(32), amount)), c(1)),
                  b.select(b.eq(amount, c(32)), _bit(v, 0), c(0))));
        }
      case 1: // LSR
        value = b.select(
            isZero, v, b.select(below32, b.shrU(v, amount), c(0)));
        if (carry) {
          out = b.select(
              isZero,
              oldCarry,
              b.select(
                  below32,
                  b.and(b.shrU(v, b.sub(amount, c(1))), c(1)),
                  b.select(b.eq(amount, c(32)), _bit(v, 31), c(0))));
        }
      case 2: // ASR
        final fill = b.select(_bit(v, 31), c(0xffffffff), c(0));
        value = b.select(
            isZero,
            v,
            b.select(below32, b.shrS(v, amount), fill));
        if (carry) {
          out = b.select(
              isZero,
              oldCarry,
              b.select(below32,
                  b.and(b.shrU(v, b.sub(amount, c(1))), c(1)), _bit(v, 31)));
        }
      default: // ROR
        final rot = b.and(amount, c(31));
        final rotated = b.or(b.shrU(v, rot), b.shl(v, b.sub(c(32), rot)));
        value = b.select(isZero, v, b.select(b.eq(rot, c(0)), v, rotated));
        if (carry) {
          out = b.select(
              isZero,
              oldCarry,
              b.select(
                  b.eq(rot, c(0)),
                  _bit(v, 31),
                  b.and(b.shrU(v, b.sub(rot, c(1))), c(1))));
        }
    }
    return (value, out);
  }

  /// Operand 2 in register-shifted form and its shifter carry.
  (IrValue, IrValue?) _operandRegShift(int op, int at, bool carry) {
    final rm = _r(op & 15, at, ahead: 12);
    final amount = _r((op >> 8) & 15, at);
    return _shiftByRegister((op >> 5) & 3, rm, amount, carry);
  }

  /// Emits a non-branch instruction; returns the jump target when it
  /// writes the PC.
  /// Whether [op] is a PSR transfer that the block emits.
  bool _statusTransfer(int op, int condition) {
    if (!policy.statusTransfers || condition != 14) return false;
    // MRS Rd, CPSR, with Rd other than PC.
    if (op & 0x0fff0fff == 0x010f0000) return (op >> 12) & 15 != 15;
    // MSR CPSR from a register other than PC, whole or flags only.
    if (op & 0x0ffefff0 == 0x0128f000) return op & 15 != 15;
    // MSR CPSR_flg from an immediate.
    return op & 0x0ffff000 == 0x0328f000;
  }

  /// MRS and MSR on the CPSR. The ARM7DI writes the flags, or with bit 16
  /// outside user mode also the control bits.
  void _emitStatus(int op, int at) {
    final flags = _get(cpsr);
    if (op & 0x00200000 == 0) {
      _put(regs + ((op >> 12) & 15), flags);
      return;
    }
    final IrValue value;
    if (op & 0x02000000 != 0) {
      final imm = op & 255, rot = ((op >> 8) & 15) * 2;
      value = c(rot == 0 ? imm : (imm >>> rot | imm << (32 - rot)));
    } else {
      value = _get(regs + (op & 15));
    }
    if (op & 0x10000 == 0) {
      _put(cpsr,
          b.or(b.and(flags, c(0x0fffffff)), b.and(value, c(0xf0000000))));
      return;
    }
    final user = b.eq(b.and(flags, c(0x1f)), c(0x10));
    final mask = b.select(user, c(0xf0000000), c(0xf00000df));
    final next = b.or(b.and(flags, b.xor(mask, c(0xffffffff))),
        b.and(value, mask));
    // A mode change switches register banks, which the interpreter does.
    b.exitIf(b.ne(b.and(b.xor(next, flags), c(0x1f)), c(0)), _snapshot(at));
    _put(cpsr, next);
    // Clearing I or F lets the interpreter take a pending interrupt.
    final enables = b.and(b.and(flags, b.xor(next, c(0xffffffff))), c(0xc0));
    b.exitIf(
        b.ne(enables, c(0)),
        IrExit(interpret, (at + 4) & 0xffffffff,
            spent: _spent + 1,
            stores: [for (final e in _values.entries) (e.key, e.value)]));
  }

  IrValue? _emit(int op, int at, int condition) {
    if (_statusTransfer(op, condition)) {
      _emitStatus(op, at);
      return null;
    }
    if (op & 0x0c000000 == 0x04000000) return _transfer(op, at);
    if (op & 0x0e000000 == 0x08000000) return _emitBlock(op, at);
    if (op & 0x02000000 == 0 && (op & 0x90) == 0x90) {
      if ((op & 0x60) == 0) {
        return op & 0x01000000 != 0
            ? _emitSwap(op, at, condition)
            : _emitMultiply(op, at, condition);
      }
      return _emitHalf(op, at);
    }
    return _emitDataProc(op, at, condition);
  }

  IrValue? _emitDataProc(int op, int at, int condition) {
    final passes = condition == 14 ? null : _condition(condition);
    final code = (op >> 21) & 15, rd = (op >> 12) & 15;
    final set = op & 0x100000 != 0, test = code >= 8 && code <= 11;
    final arithmetic = (0xcfc >> code) & 1 != 0;
    final regShift = (op & 0x02000010) == 0x10;
    final a = _r((op >> 16) & 15, at, ahead: regShift ? 12 : 8);
    final (operand, shifterCarry) = regShift
        ? _operandRegShift(op, at, set && !arithmetic)
        : _operand(op, at, set && !arithmetic);
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
        // x + y + 1 carries when the result does not exceed x; x + y
        // when the result is below x.
        final carry = code >= 5 && code <= 7
            ? b.select(carryIn, _not(b.ltU(x, result)), b.ltU(result, x))
            : add
                ? b.ltU(result, x)
                : _not(b.ltU(x, result));
        newFlags = _flagsArithmetic(flags, result, x, y, carry);
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
        newFlags = _flagsLogical(flags, result, shifterCarry!);
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

  /// A word load with the unaligned-rotate behaviour, as in
  /// [_transfer], for the forms that did not exist on the DI core.
  IrValue _loadWordRotated(IrValue address, IrExit exit) {
    final word = b.load(4, b.and(address, c(0xfffffffc)), unmapped: exit);
    final shift = b.shl(b.and(address, c(3)), c(3));
    final value = b.or(b.shrU(word, shift),
        b.shl(word, b.and(b.sub(c(32), shift), c(31))));
    return b.select(b.eq(shift, c(0)), word, value);
  }

  IrValue? _emitMultiply(int op, int at, int condition) {
    final passes = condition == 14 ? null : _condition(condition);
    final set = op & 0x100000 != 0;
    final flags = _get(cpsr);
    if (!op.bit23) {
      // Short multiply (MUL/MLA).
      final rd = (op >> 16) & 15, rn = (op >> 12) & 15;
      final a = _r(op & 15, at), multiplicand = _r((op >> 8) & 15, at);
      var result = b.mul(a, multiplicand);
      if (op & 0x200000 != 0) result = b.add(result, _r(rn, at));
      if (set) {
        final newFlags = _flagsMultiply(flags, result);
        _put(cpsr, passes == null ? newFlags : b.select(passes, newFlags, flags));
      }
      _put(regs + rd,
          passes == null ? result : b.select(passes, result, _get(regs + rd)));
      return null;
    }
    // Long multiply: the low half is a plain multiply, the high half
    // comes from the widening multiply operations.
    final rdHi = (op >> 16) & 15, rdLo = (op >> 12) & 15;
    final a = _r(op & 15, at), multiplicand = _r((op >> 8) & 15, at);
    var lo = b.mul(a, multiplicand);
    var hi = op.bit22 ? b.mulHiS(a, multiplicand) : b.mulHiU(a, multiplicand);
    if (op & 0x200000 != 0) {
      final oldLo = _get(regs + rdLo), oldHi = _get(regs + rdHi);
      final sumLo = b.add(lo, oldLo);
      hi = b.add(b.add(hi, oldHi), b.ltU(sumLo, lo));
      lo = sumLo;
    }
    if (set) {
      final newFlags = b.or(
          b.and(flags, c(0x3fffffff)),
          b.or(b.and(hi, c(0x80000000)),
              b.shl(b.and(b.eq(hi, c(0)), b.eq(lo, c(0))), c(30))));
      _put(cpsr, passes == null ? newFlags : b.select(passes, newFlags, flags));
    }
    _put(regs + rdLo,
        passes == null ? lo : b.select(passes, lo, _get(regs + rdLo)));
    _put(regs + rdHi,
        passes == null ? hi : b.select(passes, hi, _get(regs + rdHi)));
    return null;
  }

  IrValue? _emitSwap(int op, int at, int condition) {
    final rn = (op >> 16) & 15, rd = (op >> 12) & 15, rm = op & 15;
    final exit = _snapshot(at);
    final address = _r(rn, at);
    final byte = op & 0x400000 != 0;
    final value =
        byte ? b.load(1, address, unmapped: exit) : _loadWordRotated(address, exit);
    if (byte) {
      b.store(1, address, _r(rm, at), unmapped: exit);
    } else {
      b.store(4, b.and(address, c(0xfffffffc)), _r(rm, at),
          unmapped: exit);
    }
    _put(regs + rd, value);
    return null;
  }

  IrValue? _emitHalf(int op, int at) {
    final pre = op.bit24, up = op.bit23, wb = op.bit21, load = op.bit20;
    final rn = (op >> 16) & 15, rd = (op >> 12) & 15;
    final sh = (op >> 5) & 3; // 01=H 10=SB 11=SH (0 decodes as SH too)
    final exit = _snapshot(at);
    final offset = op.bit22
        ? c(((op >> 8) & 15) << 4 | (op & 15))
        : _r(op & 15, at);
    final base = _r(rn, at);
    final modified = up ? b.add(base, offset) : b.sub(base, offset);
    final address = pre ? modified : base;
    final back = !pre || wb;
    if (load) {
      IrValue value;
      if (sh == 1) {
        // LDRH: an odd address reads the aligned halfword rotated by 8.
        final raw = b.load(2, b.and(address, c(0xfffffffe)), unmapped: exit);
        final rotated = b.or(b.shrU(raw, c(8)), b.shl(raw, c(24)));
        value = b.select(b.and(address, c(1)), rotated, raw);
      } else if (sh == 2) {
        value = b.sext8(b.load(1, address, unmapped: exit));
      } else {
        // LDRSH: an odd address reads a signed byte instead.
        final asByte = b.sext8(b.load(1, address, unmapped: exit));
        final asHalf = b.sext16(
            b.load(2, b.and(address, c(0xfffffffe)), unmapped: exit));
        value = b.select(b.and(address, c(1)), asByte, asHalf);
      }
      if (back) _put(regs + rn, modified);
      if (rd == 15) return b.and(value, c(0xfffffffc));
      _put(regs + rd, value);
    } else {
      // STRH is the only store form; the interpreter stores the raw
      // register (r15 included) at the halfword-aligned address.
      b.store(2, b.and(address, c(0xfffffffe)), _r(rd, at, ahead: 12),
          unmapped: exit);
      if (back) _put(regs + rn, modified);
    }
    return null;
  }

  IrValue? _emitBlock(int op, int at) {
    final pre = op.bit24, up = op.bit23, wb = op.bit21, load = op.bit20;
    final rn = (op >> 16) & 15;
    final list = <int>[
      for (var i = 0; i < 16; i++)
        if (op & (1 << i) != 0) i,
    ];
    final count = list.length;
    // The exit snapshot precedes every effect of the block, so an
    // unmapped access leaves the whole transfer to the interpreter.
    final exit = _snapshot(at);
    final base = _r(rn, at);
    final writeback =
        up ? b.add(base, c(count * 4)) : b.sub(base, c(count * 4));
    final startOffset = up ? (pre ? 4 : 0) : (-count * 4 + (pre ? 0 : 4));
    var address =
        startOffset == 0 ? base : b.add(base, c(startOffset & 0xffffffff));
    IrValue? jump;
    if (load) {
      for (final index in list) {
        // The interpreter accesses each word at its aligned address.
        final value =
            b.load(4, b.and(address, c(0xfffffffc)), unmapped: exit);
        address = b.add(address, c(4));
        if (index == 15) {
          jump = b.and(value, c(0xfffffffc));
        } else {
          _put(regs + index, value);
        }
      }
      if (wb && !list.contains(rn)) _put(regs + rn, writeback);
    } else {
      var first = true;
      for (final index in list) {
        var value = index == 15 ? _r(15, at, ahead: 12) : _get(regs + index);
        if (wb && index == rn && !first) value = writeback;
        b.store(4, b.and(address, c(0xfffffffc)), value, unmapped: exit);
        address = b.add(address, c(4));
        first = false;
      }
      if (wb) _put(regs + rn, writeback);
    }
    return jump;
  }

  // --- Thumb front-end --------------------------------------------------------

  IrBlock? _translateThumb(int pc, int tag) {
    _values.clear();
    _spent = 0;
    b = IrBuilder(pc, tag: tag);
    final fetchHalf = this.fetchHalf!;
    var at = pc;
    for (var count = 0; count < maxInstructions; count++) {
      final op = fetchHalf(at);
      if (op == null) break;
      // A long branch is a pair of halfwords; translate it as one
      // unit when the second half follows, and as the LR setup alone
      // when it does not.
      if ((op & 0xf800) == 0xf000) {
        final nextHalf = fetchHalf(at + 2);
        if (nextHalf != null && (nextHalf & 0xf800) == 0xf800) {
          if (!_thumbGuard(at) || !_thumbGuard(at + 2)) break;
          protect(at);
          protect(at + 2);
          _thumbBlPair(at);
          _spent += 2;
          _flush();
          return b.finish(IrJump(_thumbBlTarget(op, nextHalf, at), tag: tag),
              cost: _spent);
        }
      }
      final cost = _thumbCost(op);
      if (cost == null) break;
      if (!_thumbGuard(at)) break;
      protect(at);
      final jump = _emitThumb(op, at);
      _spent += cost;
      if (jump != null) {
        if (jump is IrBlock) return jump;
        _flush();
        return b.finish(IrJumpDyn(jump as IrValue, tag: tag), cost: _spent);
      }
      at = (at + 2) & 0xffffffff;
    }
    if (_spent == 0) return null;
    _flush();
    return b.finish(IrExitTerm(IrExit(interpret, at, tag: tag)),
        cost: _spent);
  }

  /// Guards a Thumb instruction by the aligned word holding it.
  bool _thumbGuard(int at) {
    final word = fetch(at & ~3);
    if (word == null) return false;
    b.guard(at & ~3, word);
    return true;
  }

  int _thumbBlTarget(int high, int low, int at) =>
      (at + 4 +
              (((high & 0x7ff) ^ 0x400) - 0x400) * 4096 +
              (low & 0x7ff) * 2) &
          0xfffffffe;

  void _thumbBlPair(int at) {
    _put(regs + 14, c((at + 4) | 1));
  }

  /// Executed cycles of a supported Thumb instruction, or null.
  int? _thumbCost(int op) {
    final hi = op >> 13;
    switch (hi) {
      case 0:
      case 1:
        return 1;
      case 2:
        if (op.bit12) return 3; // load/store with register offset
        if (op.bit11) return 3; // PC-relative load
        if (op.bit10) {
          // Hi-register operations: BX leaves the block, a write to
          // PC charges the branch cost.
          final code = (op >> 8) & 3;
          if (code == 3) return null;
          final rd = (op & 7) | ((op >> 4) & 8);
          return rd == 15 ? 3 : 1;
        }
        return 1; // ALU
      case 3:
        return op.bit11 ? 3 : 2;
      case 4:
        return op.bit11 ? 3 : 2;
      case 5:
        if (!op.bit12) return 1; // load address
        if ((op & 0x0f00) == 0x0000) return 1; // add SP
        var count = 0;
        for (var i = 0; i < 8; i++) {
          if (op & (1 << i) != 0) count++;
        }
        if (op.bit11) return count + (op.bit8 ? 3 : 2); // POP
        return count + (op.bit8 ? 1 : 0) + 1; // PUSH
      case 6:
        if (!op.bit12) {
          var count = 0;
          for (var i = 0; i < 8; i++) {
            if (op & (1 << i) != 0) count++;
          }
          if (count == 0) return null; // the empty-list quirk stays interpreted
          return op.bit11 ? count + 2 : count + 1;
        }
        if ((op & 0x0f00) == 0x0f00) return null; // SWI
        return 3; // conditional branch (taken or not, as on the DI core)
      default: // 7
        // A BL half on its own costs one cycle; pairs are handled by
        // the caller in _translateThumb.
        if ((op & 0xf800) == 0xf000 || (op & 0xf800) == 0xf800) return 1;
        return 3; // unconditional branch
    }
  }

  /// Emits a Thumb instruction. Returns an [IrValue] jump target for a
  /// dynamic branch, a finished [IrBlock] for a static branch, or null.
  Object? _emitThumb(int op, int at) {
    final hi = op >> 13;
    switch (hi) {
      case 0:
        return (op & 0x1800) == 0x1800
            ? _thAddSub(op, at)
            : _thShift(op, at);
      case 1:
        return _thMovCmpImm(op, at);
      case 2:
        if (op.bit12) {
          return !op.bit9 ? _thLdStReg(op, at) : _thLdStSign(op, at);
        }
        if (op.bit11) return _thLdrPc(op, at);
        return !op.bit10 ? _thAlu(op, at) : _thHiReg(op, at);
      case 3:
        return _thLdStImm(op, at);
      case 4:
        return !op.bit12 ? _thLdStHalf(op, at) : _thLdStSp(op, at);
      case 5:
        if (!op.bit12) return _thLoadAddr(op, at);
        if ((op & 0x0f00) == 0x0000) return _thAddSp(op, at);
        return _thPushPop(op, at);
      case 6:
        if (!op.bit12) return _thBlock(op, at);
        return _thCondBranch(op, at);
      default:
        if ((op & 0xf800) == 0xf000) return _thBlHigh(op, at);
        if ((op & 0xf800) == 0xf800) return _thBlLow(op, at);
        return _thBranch(op, at);
    }
  }

  // A BL first half on its own: sets LR for the second half.
  Object? _thBlHigh(int op, int at) {
    final offset = (((op & 0x7ff) ^ 0x400) - 0x400) * 4096;
    _put(regs + 14, c(at + 4 + offset));
    return null;
  }

  // A BL second half on its own: branches through the prepared LR.
  Object? _thBlLow(int op, int at) {
    final target =
        b.and(b.add(_get(regs + 14), c((op & 0x7ff) * 2)), c(0xfffffffe));
    _put(regs + 14, c((at + 2) | 1));
    return target;
  }

  IrValue _thr(int n, int at) => n == 15 ? c(at + 4) : _get(regs + n);

  // Format 1: move shifted register.
  Object? _thShift(int op, int at) {
    final type = (op >> 11) & 3;
    final offset = (op >> 6) & 31;
    final res = _shiftConst(type, _get(regs + ((op >> 3) & 7)), offset);
    _put(regs + (op & 7), res.$1);
    _putCpsrThumb(_flagsLogical(_get(cpsr), res.$1, res.$2!));
    return null;
  }

  // Format 2: add/subtract.
  Object? _thAddSub(int op, int at) {
    final sub = op.bit9;
    final b = op.bit10 ? c((op >> 6) & 7) : _get(regs + ((op >> 6) & 7));
    final a = _get(regs + ((op >> 3) & 7));
    final (result, newFlags) = _thumbAddSub(a, b, sub, false);
    _put(regs + (op & 7), result);
    _putCpsrThumb(newFlags);
    return null;
  }

  // Format 3: move/compare/add/subtract immediate.
  Object? _thMovCmpImm(int op, int at) {
    final kind = (op >> 11) & 3;
    final rd = (op >> 8) & 7;
    final imm = c(op & 0xff);
    switch (kind) {
      case 0: // MOV
        _put(regs + rd, imm);
        _putCpsrThumb(b.or(b.and(_get(cpsr), c(0x3fffffff)),
            b.shl(b.eq(imm, c(0)), c(30))));
      case 1: // CMP
        _putCpsrThumb(_thumbAddSub(_get(regs + rd), imm, true, false).$2);
      case 2: // ADD
        final (result, newFlags) =
            _thumbAddSub(_get(regs + rd), imm, false, false);
        _put(regs + rd, result);
        _putCpsrThumb(newFlags);
      default: // SUB
        final (result, newFlags) =
            _thumbAddSub(_get(regs + rd), imm, true, false);
        _put(regs + rd, result);
        _putCpsrThumb(newFlags);
    }
    return null;
  }

  /// An add or subtract with the interpreter's flag results; returns
  /// the result and the new CPSR.
  (IrValue, IrValue) _thumbAddSub(
      IrValue a, IrValue rhs, bool sub, bool carryIn) {
    final flags = _get(cpsr);
    final y = sub ? b.xor(rhs, c(0xffffffff)) : rhs;
    final cin = sub
        ? (carryIn ? _bit(flags, 29) : c(1))
        : (carryIn ? _bit(flags, 29) : c(0));
    final result = b.add(b.add(a, y), cin);
    final carry = sub
        ? (carryIn
            ? b.select(cin, _not(b.ltU(a, result)), b.ltU(result, a))
            : _not(b.ltU(a, result)))
        : (carryIn
            ? b.select(cin, _not(b.ltU(a, result)), b.ltU(result, a))
            : b.ltU(result, a));
    return (result, _flagsArithmetic(flags, result, a, y, carry));
  }

  /// Sets the cached CPSR; Thumb flag updates never touch the mode or
  /// state bits in compiled code, so the cached value is what the
  /// interpreter continues with.
  void _putCpsrThumb(IrValue newFlags) => _put(cpsr, newFlags);

  /// A constant-amount barrel shift (Thumb format 1), returning the
  /// value and its carry-out.
  (IrValue, IrValue?) _shiftConst(int type, IrValue v, int amount) {
    switch (type) {
      case 0: // LSL
        if (amount == 0) return (v, _bit(_get(cpsr), 29));
        return (b.shl(v, c(amount)), _bit(v, 32 - amount));
      case 1: // LSR (#0 means #32)
        if (amount == 0) return (c(0), _bit(v, 31));
        return (b.shrU(v, c(amount)), _bit(v, amount - 1));
      case 2: // ASR (#0 means #32)
        if (amount == 0) return (b.shrS(v, c(31)), _bit(v, 31));
        return (b.shrS(v, c(amount)), _bit(v, amount - 1));
      default: // ROR does not occur in format 1
        return (v, _bit(_get(cpsr), 29));
    }
  }

  // Format 4: ALU operations.
  Object? _thAlu(int op, int at) {
    final code = (op >> 6) & 15;
    final rs = (op >> 3) & 7, rd = op & 7;
    final a = _get(regs + rd);
    final operand = _get(regs + rs);
    final flags = _get(cpsr);
    IrValue result;
    IrValue? arithFlags;
    IrValue? shiftCarry;
    var write = true;
    switch (code) {
      case 0x0:
        result = b.and(a, operand); // AND
      case 0x1:
        result = b.xor(a, operand); // EOR
      case 0x2:
        (result, shiftCarry) = _shiftByRegister(0, a, operand, true); // LSL
      case 0x3:
        (result, shiftCarry) = _shiftByRegister(1, a, operand, true); // LSR
      case 0x4:
        (result, shiftCarry) = _shiftByRegister(2, a, operand, true); // ASR
      case 0x5:
        (result, arithFlags) = _thumbAddSub(a, operand, false, true); // ADC
      case 0x6:
        (result, arithFlags) = _thumbAddSub(a, operand, true, true); // SBC
      case 0x7:
        (result, shiftCarry) = _shiftByRegister(3, a, operand, true); // ROR
      case 0x8:
        result = b.and(a, operand);
        write = false; // TST
      case 0x9:
        (result, arithFlags) = _thumbAddSub(c(0), operand, true, false); // NEG
      case 0xa:
        (result, arithFlags) = _thumbAddSub(a, operand, true, false);
        write = false; // CMP
      case 0xb:
        (result, arithFlags) = _thumbAddSub(a, operand, false, false);
        write = false; // CMN
      case 0xc:
        result = b.or(a, operand); // ORR
      case 0xd:
        result = b.mul(a, operand); // MUL
      case 0xe:
        result = b.and(a, b.xor(operand, c(0xffffffff))); // BIC
      default:
        result = b.xor(operand, c(0xffffffff)); // MVN
    }
    if (write) _put(regs + rd, result);
    if (arithFlags != null) {
      _putCpsrThumb(arithFlags);
    } else if (shiftCarry != null) {
      _putCpsrThumb(_flagsLogical(flags, result, shiftCarry));
    } else if (code == 0xd) {
      _putCpsrThumb(_flagsMultiply(flags, result));
    } else {
      _putCpsrThumb(b.or(
          b.and(flags, c(0x3fffffff)),
          b.or(b.and(result, c(0x80000000)),
              b.shl(b.eq(result, c(0)), c(30)))));
    }
    return null;
  }

  // Format 5: hi register operations (BX is left to the interpreter).
  Object? _thHiReg(int op, int at) {
    final code = (op >> 8) & 3;
    final rd = (op & 7) | ((op >> 4) & 8);
    final rs = ((op >> 3) & 7) | ((op >> 3) & 8);
    final a = _thr(rd, at);
    final operand = _thr(rs, at);
    switch (code) {
      case 0: // ADD (no flags)
        final res = b.add(a, operand);
        if (rd == 15) return b.and(res, c(0xfffffffe));
        _put(regs + rd, res);
      case 1: // CMP (flags only)
        _putCpsrThumb(_thumbAddSub(a, operand, true, false).$2);
      case 2: // MOV (no flags)
        if (rd == 15) return b.and(operand, c(0xfffffffe));
        _put(regs + rd, operand);
      default: // BX: _thumbCost rejects it
        return null;
    }
    return null;
  }

  // Format 6: PC-relative load.
  Object? _thLdrPc(int op, int at) {
    final address = c(((at + 4) & ~2) + (op & 0xff) * 4);
    final exit = _snapshot(at, tag: 1);
    _put(regs + ((op >> 8) & 7), b.load(4, address, unmapped: exit));
    return null;
  }

  // Format 7: load/store with register offset.
  Object? _thLdStReg(int op, int at) {
    final exit = _snapshot(at, tag: 1);
    final address =
        b.add(_get(regs + ((op >> 3) & 7)), _get(regs + ((op >> 6) & 7)));
    final rd = op & 7;
    if (op.bit11) {
      _put(regs + rd,
          op.bit10 ? b.load(1, address, unmapped: exit) : _loadWordRotated(address, exit));
      return null;
    }
    if (op.bit10) {
      b.store(1, address, _get(regs + rd), unmapped: exit);
    } else {
      b.store(4, b.and(address, c(0xfffffffc)), _get(regs + rd),
          unmapped: exit);
    }
    return null;
  }

  // Format 8: load/store sign-extended byte/halfword.
  Object? _thLdStSign(int op, int at) {
    final exit = _snapshot(at, tag: 1);
    final address =
        b.add(_get(regs + ((op >> 3) & 7)), _get(regs + ((op >> 6) & 7)));
    final rd = op & 7;
    final h = op.bit11, s = op.bit10;
    if (!s && !h) {
      b.store(2, b.and(address, c(0xfffffffe)), _get(regs + rd),
          unmapped: exit);
      return null;
    }
    if (!s && h) {
      final raw = b.load(2, b.and(address, c(0xfffffffe)), unmapped: exit);
      final rotated = b.or(b.shrU(raw, c(8)), b.shl(raw, c(24)));
      _put(regs + rd, b.select(b.and(address, c(1)), rotated, raw));
    } else if (s && !h) {
      _put(regs + rd, b.sext8(b.load(1, address, unmapped: exit)));
    } else {
      final asByte = b.sext8(b.load(1, address, unmapped: exit));
      final asHalf =
          b.sext16(b.load(2, b.and(address, c(0xfffffffe)), unmapped: exit));
      _put(regs + rd, b.select(b.and(address, c(1)), asByte, asHalf));
    }
    return null;
  }

  // Format 9: load/store with immediate offset.
  Object? _thLdStImm(int op, int at) {
    final exit = _snapshot(at, tag: 1);
    final byte = op.bit12;
    final offset = (op >> 6) & 31;
    final address = b.add(
        _get(regs + ((op >> 3) & 7)), c(byte ? offset : offset * 4));
    final rd = op & 7;
    if (op.bit11) {
      _put(regs + rd,
          byte ? b.load(1, address, unmapped: exit) : _loadWordRotated(address, exit));
      return null;
    }
    if (byte) {
      b.store(1, address, _get(regs + rd), unmapped: exit);
    } else {
      b.store(4, b.and(address, c(0xfffffffc)), _get(regs + rd),
          unmapped: exit);
    }
    return null;
  }

  // Format 10: load/store halfword.
  Object? _thLdStHalf(int op, int at) {
    final exit = _snapshot(at, tag: 1);
    final address =
        b.add(_get(regs + ((op >> 3) & 7)), c(((op >> 6) & 31) * 2));
    final rd = op & 7;
    if (op.bit11) {
      final raw = b.load(2, b.and(address, c(0xfffffffe)), unmapped: exit);
      final rotated = b.or(b.shrU(raw, c(8)), b.shl(raw, c(24)));
      _put(regs + rd, b.select(b.and(address, c(1)), rotated, raw));
    } else {
      b.store(2, b.and(address, c(0xfffffffe)), _get(regs + rd),
          unmapped: exit);
    }
    return null;
  }

  // Format 11: SP-relative load/store.
  Object? _thLdStSp(int op, int at) {
    final exit = _snapshot(at, tag: 1);
    final address = b.add(_get(regs + 13), c((op & 0xff) * 4));
    final rd = (op >> 8) & 7;
    if (op.bit11) {
      _put(regs + rd, _loadWordRotated(address, exit));
    } else {
      b.store(4, b.and(address, c(0xfffffffc)), _get(regs + rd),
          unmapped: exit);
    }
    return null;
  }

  // Format 12: load address.
  Object? _thLoadAddr(int op, int at) {
    final base = op.bit11 ? _get(regs + 13) : c((at + 4) & ~2);
    _put(regs + ((op >> 8) & 7), b.add(base, c((op & 0xff) * 4)));
    return null;
  }

  // Format 13: add offset to stack pointer.
  Object? _thAddSp(int op, int at) {
    final imm = (op & 0x7f) * 4;
    final sp = _get(regs + 13);
    _put(regs + 13, op.bit7 ? b.sub(sp, c(imm)) : b.add(sp, c(imm)));
    return null;
  }

  // Format 14: push/pop registers.
  Object? _thPushPop(int op, int at) {
    final load = op.bit11, pclr = op.bit8;
    final list = <int>[
      for (var i = 0; i < 8; i++)
        if (op & (1 << i) != 0) i,
    ];
    final exit = _snapshot(at, tag: 1);
    final sp = _get(regs + 13);
    if (load) {
      var address = sp;
      for (final r in list) {
        _put(regs + r,
            b.load(4, b.and(address, c(0xfffffffc)), unmapped: exit));
        address = b.add(address, c(4));
      }
      IrValue? jump;
      if (pclr) {
        final value =
            b.load(4, b.and(address, c(0xfffffffc)), unmapped: exit);
        address = b.add(address, c(4));
        jump = b.and(value, c(0xfffffffe));
      }
      _put(regs + 13, address);
      return jump;
    } else {
      final count = list.length + (pclr ? 1 : 0);
      var address = b.sub(sp, c(count * 4));
      _put(regs + 13, address);
      for (final r in list) {
        b.store(4, b.and(address, c(0xfffffffc)), _get(regs + r),
            unmapped: exit);
        address = b.add(address, c(4));
      }
      if (pclr) {
        b.store(4, b.and(address, c(0xfffffffc)), _get(regs + 14),
            unmapped: exit);
      }
      return null;
    }
  }

  // Format 15: multiple load/store.
  Object? _thBlock(int op, int at) {
    final load = op.bit11;
    final rb = (op >> 8) & 7;
    final list = <int>[
      for (var i = 0; i < 8; i++)
        if (op & (1 << i) != 0) i,
    ];
    final exit = _snapshot(at, tag: 1);
    var address = _get(regs + rb);
    final start = address;
    if (load) {
      for (final r in list) {
        _put(regs + r,
            b.load(4, b.and(address, c(0xfffffffc)), unmapped: exit));
        address = b.add(address, c(4));
      }
      if (!list.contains(rb)) _put(regs + rb, address);
    } else {
      final writeback = b.add(start, c(list.length * 4));
      var first = true;
      for (final r in list) {
        var value = _get(regs + r);
        if (r == rb && !first) value = writeback;
        b.store(4, b.and(address, c(0xfffffffc)), value, unmapped: exit);
        address = b.add(address, c(4));
        first = false;
      }
      _put(regs + rb, writeback);
    }
    return null;
  }

  // Format 16: conditional branch. Condition 14 branches always; the
  // interpreter sends it down the same path as an unconditional one.
  Object? _thCondBranch(int op, int at) {
    final cond = (op >> 8) & 15;
    final target =
        (at + 4 + (((op & 0xff) ^ 0x80) - 0x80) * 2) & 0xffffffff;
    _spent += 3;
    _flush();
    if (cond == 14) return b.finish(IrJump(target, tag: 1), cost: _spent);
    final passes = _condition(cond);
    final block = b.finish(
        IrBranch(passes, target, (at + 2) & 0xffffffff,
            tagTrue: 1, tagFalse: 1),
        cost: _spent);
    return block;
  }

  // Format 18: unconditional branch.
  Object? _thBranch(int op, int at) {
    final target =
        (at + 4 + (((op & 0x7ff) ^ 0x400) - 0x400) * 2) & 0xffffffff;
    _spent += 3;
    _flush();
    return b.finish(IrJump(target, tag: 1), cost: _spent);
  }
}
