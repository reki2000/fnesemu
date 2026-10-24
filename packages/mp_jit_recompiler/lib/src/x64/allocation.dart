import '../ir.dart';
import 'assembler.dart';

/// Block-local linear scan over registers reserved from emitter temporaries.
/// Values spanning a possible host call stay in their stack slots. Side exits
/// use the allocation at their branch point, before any later register reuse.
final class X64Allocation {
  final List<int> registers;
  final List<int> lastUse;

  X64Allocation(IrBlock block, {bool win64 = false})
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
      final call = inst.op == IrOp.call ||
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
    const pool = [R.r9, R.r10, R.r11, R.r8, R.rbp, R.rsi, R.rdi];
    final active = <int>[];
    for (int i = 0; i < n; i++) {
      for (var j = active.length - 1; j >= 0; j--) {
        if (lastUse[active[j]] < i) active.removeAt(j);
      }
      var occupied = 0;
      for (final v in active) occupied |= 1 << registers[v];
      final end = lastUse[i];
      if (end <= i ||
          block.insts[i].op == IrOp.constant ||
          !irHasResult(block.insts[i].op) ||
          calls[end] != calls[i + 1]) {
        continue;
      }
      // SysV argument setup writes RDI and RSI before later arguments load.
      bool allowed(int r) =>
          win64 ||
          (r != R.rsi && r != R.rdi) ||
          end >= n ||
          calls[end + 1] == calls[end];
      var reg = -1;
      final operand = block.insts[i].a;
      if (operand >= 0 &&
          lastUse[operand] == i &&
          registers[operand] >= 0 &&
          allowed(registers[operand]) &&
          const {
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
            IrOp.ltU
          }.contains(block.insts[i].op)) {
        reg = registers[operand];
        active.remove(operand);
      }
      for (final r in pool) {
        if (reg >= 0) break;
        if (allowed(r) && (occupied & (1 << r)) == 0) {
          reg = r;
          break;
        }
      }
      if (reg < 0) {
        var victim = -1;
        for (final v in active) {
          if (allowed(registers[v]) &&
              (victim < 0 || lastUse[v] > lastUse[victim])) victim = v;
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
}
