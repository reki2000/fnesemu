import '../ir.dart';
import 'assembler.dart';

/// The addresses and tables a compiled block refers to.
abstract interface class X64Env {
  bool get win64;

  /// the mask applied to guest addresses before the page lookup
  int get addrMask;

  /// the shared exit code, see [X64Backend.exitStub]
  int get exitStub;

  /// native addresses of the read and write functions for unmapped pages
  int get readFn;
  int get writeFn;

  int helperFn(int id);

  /// the host address of a guest word mapped at compile time, or null
  int? guardAddr(int guestAddr);

  /// a link slot which will hold the entry of the block (pc, tag)
  int slotFor(int pc, int tag);
}

/// Translates [IrBlock]s to x86-64 code.
///
/// Every IR value has a 32-bit slot in the frame. Pinned registers:
/// rbx = context, r12 = read page table, r13 = write page table,
/// r14 = link slots, r15 = dynamic jump table.
abstract final class X64Backend {
  static const maxValues = 4096;

  /// the Win64 shadow space below the value slots
  static const _shadow = 32;

  /// the frame below the pushed registers, keeping rsp 16-byte aligned
  static const frame = _shadow + 4 * maxValues + 8;

  static const dynEntries = 4096;
  static const dynEntryBits = 4; // 16 bytes: pc, tag, entry

  static const _pinned = [R.rbx, R.rbp, R.r12, R.r13, R.r14, R.r15];
  static const _saved = [..._pinned, R.rsi, R.rdi];

  static Mem _slot(int v) => Mem(R.rsp, disp: _shadow + 4 * v);
  static Mem _ctx(int word) => Mem(R.rbx, disp: 4 * word);

  /// the trampoline `int enter(void* entry)` which sets up the pinned
  /// registers and jumps to a block, and at [exitOffset] the exit which
  /// returns the reason in eax to the caller
  static (List<int>, int exitOffset) trampoline(
      {required bool win64,
      required int ctx,
      required int readTable,
      required int writeTable,
      required int slots,
      required int dyn}) {
    final a = Assembler();
    for (final r in _saved) {
      a.push(r);
    }
    // touch each page of the frame in order, for hosts with stack guards
    for (int p = 4096; p <= frame; p += 4096) {
      a.movMR(Mem(R.rsp, disp: -p), R.rax);
    }
    a.movMR(Mem(R.rsp, disp: -frame), R.rax);
    a.aluRI(Alu.sub, R.rsp, frame, w: true);
    a.movRI64(R.rbx, ctx);
    a.movRI64(R.r12, readTable);
    a.movRI64(R.r13, writeTable);
    a.movRI64(R.r14, slots);
    a.movRI64(R.r15, dyn);
    a.jmpR(win64 ? R.rcx : R.rdi);

    final exitOffset = a.offset;
    a.movMR(_ctx(JitCtx.exitReason), R.rax);
    a.aluRI(Alu.add, R.rsp, frame, w: true);
    for (final r in _saved.reversed) {
      a.pop(r);
    }
    a.ret();
    return (a.bytes, exitOffset);
  }

  /// compiles [block] to be placed at the native address [base]
  static List<int> compile(IrBlock block, int base, X64Env env) {
    if (block.usesI64 || block.usesBigEndian) {
      throw UnsupportedError(
          'x64 backend currently emits i32 little-endian IR');
    }
    if (block.insts.length > maxValues) {
      throw StateError('block too long: ${block.insts.length} values');
    }
    final a = Assembler();
    final labels = <Label>[];
    Label label() {
      final l = Label();
      labels.add(l);
      return l;
    }

    final stubs = <void Function()>[];
    final win64 = env.win64;
    final arg0 = win64 ? R.rcx : R.rdi;
    final arg1 = win64 ? R.rdx : R.rsi;
    final arg2 = win64 ? R.r8 : R.rdx;

    // jumps to the exit with eax = reason after setting the exit pc and tag
    void exitTo(int reason, int pc, int tag, {int refund = 0}) {
      a.movMI(_ctx(JitCtx.exitPc), pc);
      a.movMI(_ctx(JitCtx.exitTag), tag);
      if (refund != 0) a.aluMI(Alu.add, _ctx(JitCtx.budget), refund);
      a.movRI(R.rax, reason);
      a.jmpAbs(env.exitStub, base);
    }

    Label stub(void Function() emit) {
      final l = label();
      stubs.add(() {
        a.bind(l);
        emit();
      });
      return l;
    }

    // entry checks
    final entryExit = stub(() => exitTo(JitReason.budget, block.pc, block.tag));
    a.aluMI(Alu.cmp, _ctx(JitCtx.stop), 0);
    a.jcc(Cc.ne, entryExit);
    a.aluMI(Alu.cmp, _ctx(JitCtx.budget), 0);
    a.jcc(Cc.le, entryExit);
    if (block.guards.isNotEmpty) {
      final invalid =
          stub(() => exitTo(JitReason.invalid, block.pc, block.tag));
      int? base;
      for (final g in block.guards) {
        final host = env.guardAddr(g.addr);
        if (host == null) continue;
        if (base == null || host - base >= 0x7ffffff0 || host < base) {
          base = host;
          a.movRI64(R.rax, base);
        }
        a.aluMI(Alu.cmp, Mem(R.rax, disp: host - base), g.value);
        a.jcc(Cc.ne, invalid);
      }
    }
    a.aluMI(Alu.sub, _ctx(JitCtx.budget), block.cost);

    // the page lookup of the address in eax: rdx = host page or 0,
    // ecx = offset in the page; eax keeps the address
    void lookup(int table) {
      a.movRR(R.rcx, R.rax);
      if (env.addrMask != 0xffffffff) a.aluRI(Alu.and, R.rcx, env.addrMask);
      a.movRR(R.rdx, R.rcx);
      a.shiftRI(Shift.shr, R.rdx, 12);
      a.movRM64(R.rdx, Mem(table, index: R.rdx, scale: 8));
    }

    void extend(int size, bool signed) {
      if (size == 1) {
        signed ? a.movsx8RR(R.rax, R.rax) : a.movzx8RR(R.rax, R.rax);
      } else if (size == 2) {
        signed ? a.movsx16RR(R.rax, R.rax) : a.movzx16RR(R.rax, R.rax);
      }
    }

    final insts = block.insts;
    for (int i = 0; i < insts.length; i++) {
      final inst = insts[i];
      final out = _slot(i);
      void binary(void Function() op) {
        a.movRM(R.rax, _slot(inst.a));
        op();
        a.movMR(out, R.rax);
      }

      void compare(int cc) => binary(() {
            a.aluRM(Alu.cmp, R.rax, _slot(inst.b));
            a.setcc(cc, R.rax);
            a.movzx8RR(R.rax, R.rax);
          });

      void shift(int kind) => binary(() {
            a.movRM(R.rcx, _slot(inst.b));
            a.shiftRCl(kind, R.rax);
          });

      void alu(int op) => binary(() => a.aluRM(op, R.rax, _slot(inst.b)));

      switch (inst.op) {
        case IrOp.sext32 || IrOp.zext32 || IrOp.trunc32:
          throw UnsupportedError('x64 i64 emission is not implemented');
        case IrOp.constant:
          a.movMI(out, inst.imm);
        case IrOp.ctxLoad:
          a.movRM(R.rax, _ctx(inst.imm));
          a.movMR(out, R.rax);
        case IrOp.ctxStore:
          a.movRM(R.rax, _slot(inst.a));
          a.movMR(_ctx(inst.imm), R.rax);
        case IrOp.add:
          alu(Alu.add);
        case IrOp.sub:
          alu(Alu.sub);
        case IrOp.and:
          alu(Alu.and);
        case IrOp.or:
          alu(Alu.or);
        case IrOp.xor:
          alu(Alu.xor);
        case IrOp.mul:
          binary(() => a.imulRM(R.rax, _slot(inst.b)));
        case IrOp.mulHiS || IrOp.mulHiU:
          a.movRM(R.rax, _slot(inst.a));
          inst.op == IrOp.mulHiS
              ? a.imul1M(_slot(inst.b))
              : a.mul1M(_slot(inst.b));
          a.movMR(out, R.rdx);
        case IrOp.shl:
          shift(Shift.shl);
        case IrOp.shrU:
          shift(Shift.shr);
        case IrOp.shrS:
          shift(Shift.sar);
        case IrOp.eq:
          compare(Cc.e);
        case IrOp.ne:
          compare(Cc.ne);
        case IrOp.ltS:
          compare(Cc.l);
        case IrOp.ltU:
          compare(Cc.b);
        case IrOp.select:
          a.movRM(R.rax, _slot(inst.b));
          a.movRM(R.rcx, _slot(inst.c));
          a.aluMI(Alu.cmp, _slot(inst.a), 0);
          a.cmovRR(Cc.e, R.rax, R.rcx);
          a.movMR(out, R.rax);
        case IrOp.sext8:
          a.movsx8RM(R.rax, _slot(inst.a));
          a.movMR(out, R.rax);
        case IrOp.sext16:
          a.movsx16RM(R.rax, _slot(inst.a));
          a.movMR(out, R.rax);
        case IrOp.zext8:
          a.movzx8RM(R.rax, _slot(inst.a));
          a.movMR(out, R.rax);
        case IrOp.zext16:
          a.movzx16RM(R.rax, _slot(inst.a));
          a.movMR(out, R.rax);
        case IrOp.load:
          final size = inst.imm, signed = inst.aux != 0;
          final done = label();
          final slow = stub(() {
            a.movRR(arg0, R.rax);
            a.movRI(arg1, size);
            a.movRI(arg2, 0);
            a.movRI64(R.rax, env.readFn);
            a.callR(R.rax);
            extend(size, signed);
            a.jmp(done);
          });
          a.movRM(R.rax, _slot(inst.a));
          lookup(R.r12);
          a.testRR64(R.rdx, R.rdx);
          a.jcc(Cc.e, slow);
          a.aluRI(Alu.and, R.rcx, 0xfff);
          final m = Mem(R.rdx, index: R.rcx);
          switch ((size, signed)) {
            case (1, false):
              a.movzx8RM(R.rax, m);
            case (1, true):
              a.movsx8RM(R.rax, m);
            case (2, false):
              a.movzx16RM(R.rax, m);
            case (2, true):
              a.movsx16RM(R.rax, m);
            default:
              a.movRM(R.rax, m);
          }
          a.bind(done);
          a.movMR(out, R.rax);
        case IrOp.store:
          final size = inst.imm;
          final done = label();
          final slow = stub(() {
            a.movRR(arg0, R.rax);
            a.movRM(arg1, _slot(inst.b));
            a.movRI(arg2, size);
            a.movRI64(R.rax, env.writeFn);
            a.callR(R.rax);
            a.jmp(done);
          });
          a.movRM(R.rax, _slot(inst.a));
          lookup(R.r13);
          a.testRR64(R.rdx, R.rdx);
          a.jcc(Cc.e, slow);
          a.aluRI(Alu.and, R.rcx, 0xfff);
          a.movRM(R.r8, _slot(inst.b));
          final m = Mem(R.rdx, index: R.rcx);
          switch (size) {
            case 1:
              a.mov8MR(m, R.r8);
            case 2:
              a.mov16MR(m, R.r8);
            default:
              a.movMR(m, R.r8);
          }
          a.bind(done);
        case IrOp.call:
          a.movRM(arg0, _slot(inst.a));
          a.movRM(arg1, _slot(inst.b));
          a.movRM(arg2, _slot(inst.c));
          a.movRI64(R.rax, env.helperFn(inst.imm));
          a.callR(R.rax);
          a.movMR(out, R.rax);
        case IrOp.exitIf:
          final e = block.exits[inst.aux];
          final l = stub(() =>
              exitTo(e.reason, e.pc, e.tag, refund: e.refund(block.cost)));
          a.aluMI(Alu.cmp, _slot(inst.a), 0);
          a.jcc(Cc.ne, l);
        case IrOp.guardMapped:
          final e = block.exits[inst.aux];
          final l = stub(() =>
              exitTo(e.reason, e.pc, e.tag, refund: e.refund(block.cost)));
          a.movRM(R.rax, _slot(inst.a));
          lookup(inst.imm != 0 ? R.r13 : R.r12);
          a.testRR64(R.rdx, R.rdx);
          a.jcc(Cc.e, l);
      }
    }

    // jumps to the block (pc, tag) through its link slot
    void linkTo(int pc, int tag) {
      final s = env.slotFor(pc, tag);
      final miss = stub(() => exitTo(JitReason.miss, pc, tag));
      a.movRM64(R.rax, Mem(R.r14, disp: 8 * s));
      a.testRR64(R.rax, R.rax);
      a.jcc(Cc.e, miss);
      a.jmpR(R.rax);
    }

    switch (block.term) {
      case IrJump(:final pc, :final tag):
        linkTo(pc, tag);
      case IrBranch t:
        final notTaken = label();
        a.aluMI(Alu.cmp, _slot(t.cond.index), 0);
        a.jcc(Cc.e, notTaken);
        linkTo(t.pcTrue, t.tagTrue);
        a.bind(notTaken);
        linkTo(t.pcFalse, t.tagFalse);
      case IrJumpDyn(pc: final v, :final tag):
        final miss = stub(() {
          a.movMR(_ctx(JitCtx.exitPc), R.rax);
          a.movMI(_ctx(JitCtx.exitTag), tag);
          a.movRI(R.rax, JitReason.miss);
          a.jmpAbs(env.exitStub, base);
        });
        a.movRM(R.rax, _slot(v.index));
        a.movRR(R.rcx, R.rax);
        a.shiftRI(Shift.shr, R.rcx, 2);
        if (tag != 0) a.aluRI(Alu.xor, R.rcx, tag);
        a.aluRI(Alu.and, R.rcx, dynEntries - 1);
        a.shiftRI(Shift.shl, R.rcx, dynEntryBits);
        a.aluRM(Alu.cmp, R.rax, Mem(R.r15, index: R.rcx));
        a.jcc(Cc.ne, miss);
        a.aluMI(Alu.cmp, Mem(R.r15, index: R.rcx, disp: 4), tag);
        a.jcc(Cc.ne, miss);
        a.movRM64(R.rdx, Mem(R.r15, index: R.rcx, disp: 8));
        a.testRR64(R.rdx, R.rdx);
        a.jcc(Cc.e, miss);
        a.jmpR(R.rdx);
      case IrExitTerm(:final exit):
        exitTo(exit.reason, exit.pc, exit.tag, refund: exit.refund(block.cost));
    }

    for (final s in stubs) {
      s();
    }
    a.link(labels);
    return a.bytes;
  }

  /// the dynamic table index of (pc, tag), as computed by the code above
  static int dynIndex(int pc, int tag) => ((pc >>> 2) ^ tag) & (dynEntries - 1);
}
