import '../ir.dart';

/// Block-local linear scan for the ARM64 backend, over registers that the
/// emitter never uses as temporaries. X24-X28 are callee-saved, so a value
/// keeps one of them across helper calls; X8-X15 hold only values whose
/// lifetime has no call. The other values stay in their stack slots. Side
/// exits use the allocation at their branch point, before any later reuse.
final class Arm64Allocation {
  /// the callee-saved registers, which the trampoline saves
  static const preserved = [24, 25, 26, 27, 28];

  /// the caller-saved registers that the emitter leaves alone
  static const scratch = [8, 9, 10, 11, 12, 13, 14, 15];

  final List<int> registers;
  final List<int> lastUse;

  Arm64Allocation(IrBlock block, List<int> fused)
    : registers = List<int>.filled(block.insts.length, -1),
      lastUse = List<int>.filled(block.insts.length, -1) {
    final n = block.insts.length;
    final calls = List<int>.filled(n + 1, 0);
    void use(int value, int at) {
      if (value >= 0 && at > lastUse[value]) lastUse[value] = at;
    }

    void exitUses(IrExit e, int at) {
      for (final (_, v) in e.stores) {
        use(v.index, at);
      }
    }

    for (int i = 0; i < n; i++) {
      final inst = block.insts[i];
      use(inst.a, i);
      use(inst.b, i);
      use(inst.c, i);
      if (inst.exit >= 0) exitUses(block.exits[inst.exit], i);
      if (inst.op == IrOp.exitIf || inst.op == IrOp.guardMapped) {
        exitUses(block.exits[inst.aux], i);
      }
      // a load or a store without an exit calls the host on a miss
      final call =
          inst.op == IrOp.call ||
          ((inst.op == IrOp.load || inst.op == IrOp.store) && inst.exit < 0);
      calls[i + 1] = calls[i] + (call ? 1 : 0);
    }
    switch (block.term) {
      case IrBranch t:
        use(t.cond.index, n);
      case IrJumpDyn t:
        use(t.pc.index, n);
      case IrExitTerm t:
        exitUses(t.exit, n);
      default:
        break;
    }
    // A fused comparison is emitted at its consumer, so its operands live
    // until then.
    for (var i = 0; i < n; i++) {
      if (fused[i] < 0) continue;
      use(block.insts[i].a, fused[i]);
      use(block.insts[i].b, fused[i]);
    }
    final active = <int>[];
    for (int i = 0; i < n; i++) {
      for (var j = active.length - 1; j >= 0; j--) {
        if (lastUse[active[j]] < i) active.removeAt(j);
      }
      final inst = block.insts[i];
      final end = lastUse[i];
      if (end <= i ||
          inst.type == IrType.v128 ||
          inst.op == IrOp.constant ||
          !irHasResult(inst.op) ||
          fused[i] >= 0) {
        continue;
      }
      // the value lives from after i to its last use, which reads it before
      // a call at that instruction
      final crossesCall = calls[end] != calls[i + 1];
      var occupied = 0;
      for (final v in active) {
        occupied |= 1 << registers[v];
      }
      var reg = -1;
      // An operand that dies here gives its register, as the emitter reads
      // the operands of these operations before it writes the result.
      final operand = inst.a;
      if (operand >= 0 &&
          lastUse[operand] == i &&
          registers[operand] >= 0 &&
          (!crossesCall || preserved.contains(registers[operand])) &&
          _reusing.contains(inst.op)) {
        reg = registers[operand];
        active.remove(operand);
      }
      if (reg < 0 && !crossesCall) {
        for (final r in scratch) {
          if (occupied & (1 << r) == 0) {
            reg = r;
            break;
          }
        }
      }
      if (reg < 0) {
        for (final r in preserved) {
          if (occupied & (1 << r) == 0) {
            reg = r;
            break;
          }
        }
      }
      if (reg < 0) {
        // take the register of the value that lives longest, if it lives
        // longer than this one
        var victim = -1;
        for (final v in active) {
          if ((!crossesCall || preserved.contains(registers[v])) &&
              (victim < 0 || lastUse[v] > lastUse[victim])) {
            victim = v;
          }
        }
        if (victim < 0 || lastUse[victim] <= end) continue;
        reg = registers[victim];
        registers[victim] = -1;
        active.remove(victim);
      }
      registers[i] = reg;
      active.add(i);
    }
  }

  static const _reusing = {
    IrOp.add,
    IrOp.sub,
    IrOp.mul,
    IrOp.and,
    IrOp.or,
    IrOp.xor,
    IrOp.shl,
    IrOp.shrU,
    IrOp.shrS,
    IrOp.eq,
    IrOp.ne,
    IrOp.ltS,
    IrOp.ltU,
    IrOp.sext8,
    IrOp.sext16,
    IrOp.zext8,
    IrOp.zext16,
    IrOp.sext32,
    IrOp.zext32,
    IrOp.trunc32,
  };
}
