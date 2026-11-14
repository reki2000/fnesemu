import '../dyn_table.dart';
import '../ir.dart';
import '../native_env.dart';
import 'allocation.dart';
import 'assembler.dart';

/// Translates [IrBlock]s to x86-64 code.
///
/// IR values use block-local registers, rematerialized constants or stack
/// slots. Pinned registers:
/// rbx = context, r12 = read page table, r13 = write page table,
/// r14 = link slots, r15 = dynamic jump table.
abstract final class X64Backend {
  static const maxValues = 4096;

  /// the Win64 shadow space below the value slots
  static const _shadow = 32;

  /// the v128 value slots, above the scalar slots and the scratch words,
  /// 16-byte aligned
  static const _vectorSlots = _shadow + 8 * maxValues + 32;

  /// the frame below the pushed registers, keeping rsp 16-byte aligned
  static const frame = _vectorSlots + 16 * maxValues + 8;

  static const dynEntries = DynTable.entries;
  static const dynEntryBits = DynTable.entryBits; // 16 bytes: pc, tag, entry

  static const _pinned = [R.rbx, R.rbp, R.r12, R.r13, R.r14, R.r15];
  static const _saved = [..._pinned, R.rsi, R.rdi];

  static Mem _scratch(int i) => Mem(R.rsp, disp: _shadow + 8 * (maxValues + i));
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
    // Win64 grows a stack only through its guard page, so each page of the
    // frame is touched in order there. The stacks of other hosts are
    // reserved in whole, and touching would only cost stores at each entry.
    if (win64) {
      for (int p = 4096; p <= frame; p += 4096) {
        a.movMR(Mem(R.rsp, disp: -p), R.rax);
      }
      a.movMR(Mem(R.rsp, disp: -frame), R.rax);
    }
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
  static List<int> compile(IrBlock block, int base, NativeEnv env) {
    if (block.insts.length > maxValues) {
      throw StateError('block too long: ${block.insts.length} values');
    }
    final a = Assembler();
    final insts = block.insts;
    final allocation = X64Allocation(block, win64: env.win64);
    final registers = allocation.registers;
    // The slots are numbered densely, scalars and vectors apart, so that a
    // block touches few cache lines of its frame.
    final slots = List<int>.filled(insts.length, 0);
    var scalarSlots = 0, vectorSlots = 0;
    for (var v = 0; v < insts.length; v++) {
      if (insts[v].op == IrOp.constant) continue;
      slots[v] =
          insts[v].type == IrType.v128 ? vectorSlots++ : scalarSlots++;
    }
    Mem slot(int v) => Mem(R.rsp, disp: _shadow + 8 * slots[v]);
    Mem vectorSlot(int v) =>
        Mem(R.rsp, disp: _vectorSlots + 16 * slots[v]);
    bool wide(int v) => insts[v].type == IrType.i64;
    bool vector(int v) => insts[v].type == IrType.v128;
    int? constant(int v) {
      final i = insts[v];
      if (i.op != IrOp.constant) return null;
      return wide(v) ? (i.imm & 0xffffffff) | (i.immHi << 32) : i.imm;
    }

    bool immediate(int c, bool w) => !w || c == c.toSigned(32);
    void load(int dst, int v) {
      final c = constant(v), reg = registers[v], w = wide(v);
      if (c != null) {
        w ? a.movRI64Short(dst, c) : a.movRI(dst, c);
      } else if (reg >= 0) {
        if (dst != reg) a.movRR(dst, reg, w: w);
      } else {
        a.movRM(dst, slot(v), w: w);
      }
    }

    void save(int v, int src) {
      if (allocation.lastUse[v] < 0) return;
      final reg = registers[v], w = wide(v);
      if (reg >= 0) {
        if (src != reg) a.movRR(reg, src, w: w);
      } else {
        a.movMR(slot(v), src, w: w);
      }
    }

    void aluValue(int op, int dst, int v, {bool w = false}) {
      final c = constant(v), reg = registers[v];
      if (c != null && immediate(c, w)) {
        a.aluRI(op, dst, c, w: w);
      } else if (c != null) {
        load(R.rcx, v);
        a.aluRR(op, dst, R.rcx, w: w);
      } else if (reg >= 0) {
        a.aluRR(op, dst, reg, w: w);
      } else {
        a.aluRM(op, dst, slot(v), w: w);
      }
    }

    void compareZero(int v) {
      final reg = registers[v], c = constant(v);
      if (c != null) {
        a.movRI(R.rdx, c);
        a.aluRI(Alu.cmp, R.rdx, 0);
      } else if (reg >= 0) {
        a.aluRI(Alu.cmp, reg, 0);
      } else {
        a.aluMI(Alu.cmp, slot(v), 0);
      }
    }

    final labels = <Label>[];
    Label label() {
      final l = Label();
      labels.add(l);
      return l;
    }

    // 16-byte constants after the code, aligned for SSE memory operands
    final pool = <String, (Label, List<int>)>{};
    Label words(List<int> w) =>
        (pool[w.join(',')] ??= (label(), [for (final x in w) x & 0xffffffff]))
            .$1;
    Label lanes32(int v) => words([v, v, v, v]);
    Label lanes64(int v) => words([v, v >> 32, v, v >> 32]);
    Label laneMask(int mask) =>
        words([for (var k = 0; k < 4; k++) mask & (1 << k) != 0 ? -1 : 0]);

    void vload(int x, int v) => a.movdquRM(x, vectorSlot(v));
    void vsave(int v, int x) {
      if (allocation.lastUse[v] >= 0) a.movdquMR(vectorSlot(v), x);
    }

    // SSE2 opcodes, all with the 0x66 prefix
    const pand = 0xdb, pandn = 0xdf, por = 0xeb, pxor = 0xef;
    const paddq = 0xd4, psubd = 0xfa, pcmpeqd = 0x76, pcmpgtd = 0x66;

    /// the [IrOp.vuMax] key of each lane of XMM [x] into [k], with the
    /// temporary [t]: the magnitude, negated for a sign, and 0 for an
    /// exponent 0
    void imageKey(int k, int x, int t) {
      a.movdqaRR(k, x);
      a.sseRL(0x66, pand, k, lanes32(0x7fffffff));
      a.movdqaRR(t, x);
      a.shiftDI(4, t, 31);
      a.sseRR(0x66, pxor, k, t);
      a.sseRR(0x66, psubd, k, t);
      a.movdqaRR(t, x);
      a.sseRL(0x66, pand, t, lanes32(0x7f800000));
      a.sseRL(0x66, pcmpeqd, t, lanes32(0));
      a.sseRR(0x66, pandn, t, k);
      a.movdqaRR(k, t);
    }

    /// the images of [encodeLanes] in order, to the slot of [v]
    void encodedImages(int v) {
      // the sign, the bits of a normal image, and the largest magnitude of
      // an overflow
      // an overflow, shifted down, is the largest magnitude; XMM2 to XMM5
      // keep the sign and the masks
      a.sseRL(0x66, pand, 2, lanes32(0x80000000));
      a.movdqaRR(1, 4);
      a.sseRR(0x66, por, 1, 5);
      a.sseRR(0x66, pandn, 1, 0);
      a.sseRR(0x66, por, 1, 2);
      a.movdqaRR(0, 5);
      a.shiftDI(2, 0, 1);
      a.sseRR(0x66, por, 1, 0);
      vsave(v, 1);
    }

    /// the vuEncode done with the vuFlags before it
    var fusedEncode = -1;

    /// The lanes of the [IrOp.vuEncode] of XMM0 (low) and XMM1 (high),
    /// in order or [reversed]: XMM0 the image bits below single precision
    /// shifted into place (unless [reversed]), XMM2 the high words, XMM3 the
    /// underflows, XMM4 the zeros and XMM5 the overflows; XMM1 is the
    /// magnitude of the high words.
    void encodeLanes({required bool reversed}) {
      a.movdqaRR(2, 0);
      a.shufps(2, 1, 0xdd);
      a.movdqaRR(3, 0);
      a.shufps(3, 1, 0x88);
      if (reversed) {
        a.pshufd(2, 2, 0x1b);
        a.pshufd(3, 3, 0x1b);
      } else {
        a.shiftQI(2, 0, 29);
        a.shiftQI(2, 1, 29);
        a.shufps(0, 1, 0x88);
        a.sseRL(0x66, psubd, 0, lanes32(896 << 23));
      }
      a.movdqaRR(1, 2);
      a.sseRL(0x66, pand, 1, lanes32(0x7fffffff));
      a.sseRR(0x66, por, 3, 1);
      a.sseRR(0x66, pxor, 4, 4);
      a.sseRR(0x66, pcmpeqd, 3, 4);
      a.movdqaRL(4, lanes32(897 << 20));
      a.sseRR(0x66, pcmpgtd, 4, 1);
      a.movdqaRR(5, 1);
      a.sseRL(0x66, pcmpgtd, 5, lanes32((1152 << 20) - 1));
      a.sseRR(0x66, pandn, 3, 4);
    }

    final fused = irFusedCompareConsumers(block, selects: true);
    // A single-use comparison can set the flags for its branch or select
    // directly instead of producing a boolean with SETcc/MOVZX followed by
    // CMP against zero. Sets the flags for [v] and returns the condition
    // code that holds when [v] is true. RAX is a scratch register.
    int condition(int v) {
      if (fused[v] >= 0) {
        final cmp = insts[v];
        final w = wide(cmp.a);
        // The operand's own register serves a comparison, which only reads.
        int operand(int x) {
          if (constant(x) == null && registers[x] >= 0) return registers[x];
          load(R.rax, x);
          return R.rax;
        }

        final ka = constant(cmp.a), kb = constant(cmp.b);
        if (cmp.op == IrOp.ltU &&
            ka != null &&
            kb == null &&
            !w &&
            !wide(cmp.b) &&
            immediate(ka, false)) {
          // K < x unsigned is x above K.
          a.aluRI(Alu.cmp, operand(cmp.b), ka);
          return Cc.a;
        }
        final test = cmp.op == IrOp.and;
        if (ka == null && kb != null && immediate(kb, w)) {
          final reg = operand(cmp.a);
          test
              ? a.testRI(reg, kb, w: w)
              : a.aluRI(Alu.cmp, reg, kb, w: w);
        } else if (ka == null && kb == null && registers[cmp.b] >= 0) {
          final reg = operand(cmp.a);
          test
              ? a.testRR(reg, registers[cmp.b], w: w)
              : a.aluRR(Alu.cmp, reg, registers[cmp.b], w: w);
        } else {
          load(R.rax, cmp.a);
          aluValue(test ? Alu.and : Alu.cmp, R.rax, cmp.b, w: w);
        }
        return switch (cmp.op) {
          IrOp.eq => Cc.e,
          IrOp.ne || IrOp.and => Cc.ne,
          IrOp.ltS => Cc.l,
          IrOp.ltU => Cc.b,
          _ => throw StateError('not a fused condition'),
        };
      }
      compareZero(v);
      return Cc.ne;
    }

    void jumpOnCondition(int v, Label target, {required bool whenTrue}) {
      final cc = condition(v);
      a.jcc(whenTrue ? cc : cc ^ 1, target);
    }

    final stubs = <void Function()>[];
    final exitStubs = <int, Label>{};
    final win64 = env.win64;
    final arg0 = win64 ? R.rcx : R.rdi;
    final arg1 = win64 ? R.rdx : R.rsi;
    final arg2 = win64 ? R.r8 : R.rdx;

    // jumps to the exit with eax = reason after setting the exit pc and tag
    late void Function(int, int) linkTo;
    void exitTo(
      int reason,
      int pc,
      int tag, {
      int refund = 0,
      List<(int, IrValue)> stores = const [],
      bool linked = false,
    }) {
      for (final (word, v) in stores) {
        if (vector(v.index)) {
          a.movdquRM(0, vectorSlot(v.index));
          a.movdquMR(_ctx(word), 0);
          continue;
        }
        load(R.rcx, v.index);
        a.movMR(_ctx(word), R.rcx, w: wide(v.index));
      }
      if (refund != 0) a.aluMI(Alu.add, _ctx(JitCtx.budget), refund);
      if (linked) {
        linkTo(pc, tag);
        return;
      }
      a.movMI(_ctx(JitCtx.exitPc), pc);
      a.movMI(_ctx(JitCtx.exitTag), tag);
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

    linkTo = (pc, tag) {
      final s = env.slotFor(pc, tag);
      final miss = stub(() => exitTo(JitReason.miss, pc, tag));
      a.movRM64(R.rax, Mem(R.r14, disp: 8 * s));
      a.testRR64(R.rax, R.rax);
      a.jcc(Cc.e, miss);
      a.jmpR(R.rax);
    };

    // Entry checks
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
        final value = g.endian == IrEndian.little
            ? g.value
            : ((g.value & 255) << 24) |
                ((g.value & 0xff00) << 8) |
                ((g.value >>> 8) & 0xff00) |
                (g.value >>> 24);
        a.aluMI(Alu.cmp, Mem(R.rax, disp: host - base), value);
        a.jcc(Cc.ne, invalid);
      }
    }
    if (env.blockEntryFn != 0) {
      a.movRI64(R.rax, env.blockEntryFn);
      a.callR(R.rax);
    }
    a.aluMI(Alu.sub, _ctx(JitCtx.budget), block.cost);

    // the page lookup of the address in eax: rdx = host page or 0,
    // ecx = offset in the page; eax keeps the address
    void lookup(int table) {
      a.movRR(R.rcx, R.rax);
      if (env.addrMask != 0xffffffff) a.aluRI(Alu.and, R.rcx, env.addrMask);
      a.movRR(R.rdx, R.rcx);
      a.shiftRI(Shift.shr, R.rdx, env.pageShift);
      a.movRM64(R.rdx, Mem(table, index: R.rdx, scale: 8));
    }

    // Like lookup, through the translation of inst for an address outside
    // the table's direct window, jumping to miss when its slot misses.
    void translatedLookup(IrInst inst, int table, Label miss) {
      final id = inst.translationTable;
      final t = env.translationTable(id);
      final done = label(), direct = label();
      final windowed = t.directEnd > t.directStart;
      if (windowed) {
        a.movRR(R.rcx, R.rax);
        if (t.directStart != 0) a.aluRI(Alu.sub, R.rcx, t.directStart);
        a.aluRI(Alu.cmp, R.rcx, t.directEnd - t.directStart);
        a.jcc(Cc.b, direct);
      }
      a.movRR(R.rcx, R.rax);
      a.shiftRI(Shift.shr, R.rcx, env.pageShift);
      final hash = t.slotHash(inst.translationKey) & (t.slots - 1);
      if (hash != 0) a.aluRI(Alu.xor, R.rcx, hash);
      a.aluRI(Alu.and, R.rcx, t.slots - 1);
      a.shiftRI(Shift.shl, R.rcx, 4);
      a.movRI64(R.rdx, env.translationAddress(id));
      a.aluRR(Alu.add, R.rdx, R.rcx, w: true);
      a.movRR(R.rcx, R.rax);
      a.aluRI(Alu.and, R.rcx, ~((1 << env.pageShift) - 1) & 0xffffffff);
      a.aluRI(Alu.or, R.rcx, inst.translationKey);
      a.aluRM(Alu.cmp, R.rcx, Mem(R.rdx));
      a.jcc(Cc.ne, miss);
      a.movRM64(R.rdx, Mem(R.rdx, disp: 8));
      a.movRR(R.rcx, R.rax);
      if (windowed) {
        a.jmp(done);
        a.bind(direct);
        lookup(table);
        a.testRR64(R.rdx, R.rdx);
        a.jcc(Cc.e, miss);
        a.bind(done);
      }
    }

    // leaves through e with the guest address in eax as the fault address
    Label unmappedExit(IrExit e) => stub(() {
      a.movMR(_ctx(JitCtx.faultAddr), R.rax);
      exitTo(
        e.reason,
        e.pc,
        e.tag,
        refund: e.refund(block.cost),
        stores: e.stores,
        linked: e.link,
      );
    });

    void swap(int reg, int size, IrEndian endian) {
      if (endian == IrEndian.little || size == 1) return;
      if (size == 2) {
        a.swap16(reg);
      } else {
        a.bswap(reg, w: size == 8);
      }
    }

    void finishLoad(IrInst inst) {
      swap(R.rax, inst.imm, inst.endian);
      final w = inst.type == IrType.i64, signed = inst.aux != 0;
      switch (inst.imm) {
        case 1:
          signed ? a.movsx8RR(R.rax, R.rax, w: w) : a.movzx8RR(R.rax, R.rax);
        case 2:
          signed ? a.movsx16RR(R.rax, R.rax, w: w) : a.movzx16RR(R.rax, R.rax);
        case 4:
          if (w && signed) a.movsxdRR(R.rax, R.rax);
      }
    }

    void readCallback(IrInst inst) {
      a.movMR(_scratch(0), R.rax);
      void part(int offset) {
        a.movRM(arg0, _scratch(0));
        if (offset != 0) a.aluRI(Alu.add, arg0, offset);
        a.movRI(arg1, inst.imm == 8 ? 4 : inst.imm);
        a.movRI(arg2, 0);
        a.movRI64(R.rax, env.readFn);
        a.callR(R.rax);
        a.movRR(R.rax, R.rax);
      }

      part(0);
      if (inst.imm == 8) {
        a.movMR(_scratch(1), R.rax, w: true);
        part(4);
        a.shiftRI(Shift.shl, R.rax, 32, w: true);
        a.aluRM(Alu.or, R.rax, _scratch(1), w: true);
      }
    }

    void writeCallback(IrInst inst) {
      a.movMR(_scratch(0), R.rax);
      load(R.rax, inst.b);
      swap(R.rax, inst.imm, inst.endian);
      a.movMR(_scratch(1), R.rax, w: true);
      void part(int offset) {
        a.movRM(arg0, _scratch(0));
        if (offset != 0) a.aluRI(Alu.add, arg0, offset);
        a.movRM(arg1, Mem(R.rsp, disp: _shadow + 8 * (maxValues + 1) + offset));
        a.movRI(arg2, inst.imm == 8 ? 4 : inst.imm);
        a.movRI64(R.rax, env.writeFn);
        a.callR(R.rax);
      }

      part(0);
      if (inst.imm == 8) part(4);
    }

    for (int i = 0; i < insts.length; i++) {
      final inst = insts[i];
      final w = inst.type == IrType.i64;
      void binary(void Function(int) op) {
        final dst = registers[i] >= 0 ? registers[i] : R.rax;
        load(dst, inst.a);
        op(dst);
        save(i, dst);
      }

      void compare(int cc) => binary((dst) {
            aluValue(Alu.cmp, dst, inst.b, w: wide(inst.a));
            a.setcc(cc, dst);
            a.movzx8RR(dst, dst);
          });

      void shift(int kind) => binary((dst) {
            final count = constant(inst.b);
            if (count != null) {
              a.shiftRI(kind, dst, count & (w ? 63 : 31), w: w);
            } else {
              load(R.rcx, inst.b);
              a.shiftRCl(kind, dst, w: w);
            }
          });

      void alu(int op) => binary((dst) => aluValue(op, dst, inst.b, w: w));

      switch (inst.op) {
        case IrOp.sext32:
          load(R.rax, inst.a);
          a.movsxdRR(R.rax, R.rax);
          save(i, R.rax);
        case IrOp.zext32 || IrOp.trunc32:
          // a 32-bit move clears the upper half
          final dst = registers[i] >= 0 ? registers[i] : R.rax;
          final c = constant(inst.a), reg = registers[inst.a];
          if (c != null) {
            a.movRI(dst, c & 0xffffffff);
          } else if (reg >= 0) {
            a.movRR(dst, reg);
          } else {
            a.movRM(dst, slot(inst.a));
          }
          save(i, dst);
        case IrOp.constant:
          break; // Constants are materialized at their uses.
        case IrOp.ctxLoad when inst.type == IrType.v128:
          a.movdquRM(0, _ctx(inst.imm));
          vsave(i, 0);
        case IrOp.ctxStore when inst.type == IrType.v128:
          vload(0, inst.a);
          a.movdquMR(_ctx(inst.imm), 0);
        case IrOp.vSplat:
          load(R.rax, inst.a);
          a.movdXR(0, R.rax);
          a.pshufd(0, 0, 0);
          vsave(i, 0);
        case IrOp.vExtract:
          final dst = registers[i] >= 0 ? registers[i] : R.rax;
          vload(0, inst.a);
          if (inst.imm != 0) a.pshufd(0, 0, inst.imm);
          a.movdRX(dst, 0);
          save(i, dst);
        case IrOp.vInsert:
          vload(0, inst.a);
          load(R.rax, inst.b);
          a.movdXR(1, R.rax);
          a.pshufd(1, 1, 0);
          final mask = laneMask(1 << inst.imm);
          a.sseRL(0x66, pand, 1, mask);
          a.movdqaRL(2, mask);
          a.sseRR(0x66, pandn, 2, 0);
          a.sseRR(0x66, por, 1, 2);
          vsave(i, 1);
        case IrOp.vShuffle:
          vload(0, inst.a);
          a.pshufd(0, 0, inst.imm);
          vsave(i, 0);
        case IrOp.vBlend:
          vload(0, inst.a);
          vload(1, inst.b);
          final mask = laneMask(inst.imm);
          a.sseRL(0x66, pand, 1, mask);
          a.movdqaRL(2, mask);
          a.sseRR(0x66, pandn, 2, 0);
          a.sseRR(0x66, por, 1, 2);
          vsave(i, 1);
        case IrOp.vuDecode:
          // each binary64 lane holds its image in both words, which puts
          // the sign at bit 63
          final h = inst.imm * 2;
          vload(0, inst.a);
          a.pshufd(0, 0, h | h << 2 | (h + 1) << 4 | (h + 1) << 6);
          a.movdqaRR(1, 0);
          a.sseRL(0x66, pand, 1, lanes64(0x7fffffff));
          a.shiftQI(6, 1, 29);
          a.sseRL(0x66, paddq, 1, lanes64(896 << 52));
          a.movdqaRR(2, 0);
          a.sseRL(0x66, pand, 2, lanes64(-0x8000000000000000));
          a.sseRR(0x66, por, 1, 2);
          a.movdqaRR(3, 0);
          a.sseRL(0x66, pand, 3, lanes64(0x7f800000));
          a.sseRR(0x66, pxor, 2, 2);
          a.sseRR(0x66, pcmpeqd, 3, 2);
          a.pshufd(3, 3, 0xa0);
          a.sseRR(0x66, pandn, 3, 1);
          vsave(i, 3);
        case IrOp.vFloatAdd || IrOp.vFloatSub || IrOp.vFloatMul:
          vload(0, inst.a);
          vload(1, inst.b);
          a.sseRR(
              0x66,
              switch (inst.op) {
                IrOp.vFloatAdd => 0x58,
                IrOp.vFloatSub => 0x5c,
                _ => 0x59,
              },
              0,
              1);
          vsave(i, 0);
        case IrOp.vuEncode:
          if (fusedEncode == i) break;
          vload(0, inst.a);
          vload(1, inst.b);
          encodeLanes(reversed: false);
          encodedImages(i);
        case IrOp.vuFlags:
          final dst = registers[i] >= 0 ? registers[i] : R.rax;
          vload(0, inst.a);
          vload(1, inst.b);
          // The encode of the same lanes that the translator puts next is
          // done here as well, from the same lanes, which are reversed for
          // the flags after it.
          final next = i + 1;
          final fuse = next < insts.length &&
              insts[next].op == IrOp.vuEncode &&
              insts[next].a == inst.a &&
              insts[next].b == inst.b;
          encodeLanes(reversed: !fuse);
          if (fuse) {
            encodedImages(next);
            fusedEncode = next;
            for (final x in const [2, 3, 4, 5]) {
              a.pshufd(x, x, 0x1b);
            }
          }
          a.movmskps(dst, 4);
          for (final (x, shift) in const [(2, 4), (3, 8), (5, 12)]) {
            a.movmskps(R.rcx, x);
            a.shiftRI(Shift.shl, R.rcx, shift);
            a.aluRR(Alu.or, dst, R.rcx);
          }
          save(i, dst);
        case IrOp.vuMax || IrOp.vuMin:
          vload(0, inst.a);
          vload(1, inst.b);
          imageKey(2, 0, 4);
          imageKey(3, 1, 4);
          // the lanes that take b
          final take = inst.op == IrOp.vuMax ? 3 : 2;
          a.sseRR(0x66, pcmpgtd, take, take == 3 ? 2 : 3);
          a.movdqaRR(4, take);
          a.sseRR(0x66, pand, 4, 1);
          a.sseRR(0x66, pandn, take, 0);
          a.sseRR(0x66, por, take, 4);
          vsave(i, take);
        case IrOp.vuClip:
          final dst = registers[i] >= 0 ? registers[i] : R.rax;
          vload(0, inst.a);
          vload(1, inst.b);
          a.pshufd(1, 1, 0xff);
          a.movdqaRR(2, 1);
          a.sseRL(0x66, pand, 2, lanes32(0x7fffffff));
          a.movdqaRR(3, 1);
          a.sseRL(0x66, pand, 3, lanes32(0x7f800000));
          a.sseRL(0x66, pcmpeqd, 3, lanes32(0));
          a.sseRR(0x66, pandn, 3, 2);
          imageKey(2, 0, 4);
          a.sseRR(0x66, pxor, 4, 4);
          a.sseRR(0x66, psubd, 4, 3);
          a.movdqaRR(5, 2);
          a.sseRR(0x66, pcmpgtd, 5, 3);
          a.sseRR(0x66, pcmpgtd, 4, 2);
          // above and below interleaved by lane
          a.movdqaRR(1, 5);
          a.sseRR(0x66, 0x62, 1, 4); // PUNPCKLDQ
          a.sseRR(0x66, 0x6a, 5, 4); // PUNPCKHDQ
          a.movmskps(dst, 1);
          a.movmskps(R.rcx, 5);
          a.aluRI(Alu.and, R.rcx, 3);
          a.shiftRI(Shift.shl, R.rcx, 4);
          a.aluRR(Alu.or, dst, R.rcx);
          save(i, dst);
        case IrOp.ctxLoad:
          final dst = registers[i] >= 0 ? registers[i] : R.rax;
          a.movRM(dst, _ctx(inst.imm), w: w);
          save(i, dst);
        case IrOp.ctxStore:
          final value = constant(inst.a), reg = registers[inst.a];
          if (value != null && !w) {
            a.movMI(_ctx(inst.imm), value);
          } else if (reg >= 0) {
            a.movMR(_ctx(inst.imm), reg, w: w);
          } else {
            load(R.rax, inst.a);
            a.movMR(_ctx(inst.imm), R.rax, w: w);
          }
        case IrOp.add:
          alu(Alu.add);
        case IrOp.sub:
          alu(Alu.sub);
        case IrOp.and:
          if (fused[i] < 0) alu(Alu.and);
        case IrOp.or:
          alu(Alu.or);
        case IrOp.xor:
          alu(Alu.xor);
        case IrOp.mul:
          binary((dst) {
            final c = constant(inst.b), reg = registers[inst.b];
            if (c != null && immediate(c, w)) {
              a.imulRI(dst, c, w: w);
            } else if (c != null) {
              load(R.rcx, inst.b);
              a.imulRR(dst, R.rcx, w: w);
            } else if (reg >= 0) {
              a.imulRR(dst, reg, w: w);
            } else {
              a.imulRM(dst, slot(inst.b), w: w);
            }
          });
        case IrOp.divS || IrOp.divU || IrOp.remS || IrOp.remU:
          final signed = inst.op == IrOp.divS || inst.op == IrOp.remS;
          final remainder = inst.op == IrOp.remS || inst.op == IrOp.remU;
          final zeroDivisor = label(), normal = label(), done = label();
          load(R.rcx, inst.b);
          load(R.rax, inst.a);
          a.aluRI(Alu.cmp, R.rcx, 0, w: w);
          a.jcc(Cc.e, zeroDivisor);
          if (signed) {
            // x86 IDIV also traps on MIN / -1. That guest-visible result
            // wraps to MIN with a zero remainder under our IR contract.
            a.aluRI(Alu.cmp, R.rcx, -1, w: w);
            a.jcc(Cc.ne, normal);
            if (w) {
              a.movRI64(R.rdx, -0x8000000000000000);
              a.aluRR(Alu.cmp, R.rax, R.rdx, w: true);
            } else {
              a.aluRI(Alu.cmp, R.rax, 0x80000000);
            }
            a.jcc(Cc.ne, normal);
            a.movRI(R.rdx, 0);
            a.jmp(done);
          }
          a.bind(normal);
          if (signed) {
            a.signExtendDiv(w: w);
          } else {
            a.movRI(R.rdx, 0);
          }
          a.divR(R.rcx, signed: signed, w: w);
          a.jmp(done);
          a.bind(zeroDivisor);
          a.movRI(R.rax, 0);
          a.movRI(R.rdx, 0);
          a.bind(done);
          save(i, remainder ? R.rdx : R.rax);
        case IrOp.mulHiS || IrOp.mulHiU:
          load(R.rax, inst.a);
          if (registers[inst.b] >= 0 || constant(inst.b) != null) {
            load(R.rcx, inst.b);
            inst.op == IrOp.mulHiS
                ? a.imul1R(R.rcx, w: w)
                : a.mul1R(R.rcx, w: w);
          } else {
            inst.op == IrOp.mulHiS
                ? a.imul1M(slot(inst.b), w: w)
                : a.mul1M(slot(inst.b), w: w);
          }
          save(i, R.rdx);
        case IrOp.shl:
          shift(Shift.shl);
        case IrOp.shrU:
          shift(Shift.shr);
        case IrOp.shrS:
          shift(Shift.sar);
        case IrOp.eq:
          if (fused[i] < 0) compare(Cc.e);
        case IrOp.ne:
          if (fused[i] < 0) compare(Cc.ne);
        case IrOp.ltS:
          if (fused[i] < 0) compare(Cc.l);
        case IrOp.ltU:
          if (fused[i] < 0) compare(Cc.b);
        case IrOp.select:
          // the loads after the comparison are MOVs, which keep the flags
          // The result register is none of the operands, which are still
          // live here.
          final cc = condition(inst.a);
          final dst = registers[i] >= 0 ? registers[i] : R.rax;
          load(dst, inst.b);
          final c = inst.c, reg = registers[c];
          if (constant(c) == null && reg >= 0) {
            a.cmovRR(cc ^ 1, dst, reg, w: w);
          } else if (constant(c) == null) {
            a.cmovRM(cc ^ 1, dst, slot(c), w: w);
          } else {
            load(R.rcx, c);
            a.cmovRR(cc ^ 1, dst, R.rcx, w: w);
          }
          save(i, dst);
        case IrOp.sext8:
          if (registers[inst.a] >= 0 || constant(inst.a) != null) {
            load(R.rax, inst.a);
            a.movsx8RR(R.rax, R.rax, w: w);
          } else {
            a.movsx8RM(R.rax, slot(inst.a), w: w);
          }
          save(i, R.rax);
        case IrOp.sext16:
          if (registers[inst.a] >= 0 || constant(inst.a) != null) {
            load(R.rax, inst.a);
            a.movsx16RR(R.rax, R.rax, w: w);
          } else {
            a.movsx16RM(R.rax, slot(inst.a), w: w);
          }
          save(i, R.rax);
        case IrOp.zext8:
          if (registers[inst.a] >= 0 || constant(inst.a) != null) {
            load(R.rax, inst.a);
            a.movzx8RR(R.rax, R.rax);
          } else {
            a.movzx8RM(R.rax, slot(inst.a));
          }
          save(i, R.rax);
        case IrOp.zext16:
          if (registers[inst.a] >= 0 || constant(inst.a) != null) {
            load(R.rax, inst.a);
            a.movzx16RR(R.rax, R.rax);
          } else {
            a.movzx16RM(R.rax, slot(inst.a));
          }
          save(i, R.rax);
        case IrOp.load:
          final done = label();
          final slow = inst.exit >= 0
              ? unmappedExit(block.exits[inst.exit])
              : stub(() {
                  readCallback(inst);
                  a.jmp(done);
                });
          load(R.rax, inst.a);
          final Mem m;
          final address = wide(inst.a) || inst.translation >= 0
              ? null
              : constant(inst.a);
          if (inst.translation >= 0) {
            translatedLookup(inst, R.r12, slow);
            a.aluRI(Alu.and, R.rcx, (1 << env.pageShift) - 1);
            m = Mem(R.rdx, index: R.rcx);
          } else if (address != null) {
            // The page and the offset are known when the code is generated.
            final mapped = address.toUnsigned(32) & env.addrMask;
            a.movRM64(R.rdx,
                Mem(R.r12, disp: 8 * (mapped >>> env.pageShift)));
            a.testRR64(R.rdx, R.rdx);
            a.jcc(Cc.e, slow);
            m = Mem(R.rdx, disp: mapped & ((1 << env.pageShift) - 1));
          } else {
            lookup(R.r12);
            a.testRR64(R.rdx, R.rdx);
            a.jcc(Cc.e, slow);
            a.aluRI(Alu.and, R.rcx, (1 << env.pageShift) - 1);
            m = Mem(R.rdx, index: R.rcx);
          }
          switch (inst.imm) {
            case 1:
              a.movzx8RM(R.rax, m);
            case 2:
              a.movzx16RM(R.rax, m);
            case 4:
              a.movRM(R.rax, m);
            case 8:
              a.movRM64(R.rax, m);
          }
          a.bind(done);
          finishLoad(inst);
          save(i, R.rax);
        case IrOp.store:
          final done = label();
          final slow = inst.exit >= 0
              ? unmappedExit(block.exits[inst.exit])
              : stub(() {
                  writeCallback(inst);
                  a.jmp(done);
                });
          load(R.rax, inst.a);
          final Mem m;
          final address = wide(inst.a) || inst.translation >= 0
              ? null
              : constant(inst.a);
          if (inst.translation >= 0) {
            translatedLookup(inst, R.r13, slow);
            a.aluRI(Alu.and, R.rcx, (1 << env.pageShift) - 1);
            m = Mem(R.rdx, index: R.rcx);
          } else if (address != null) {
            final mapped = address.toUnsigned(32) & env.addrMask;
            a.movRM64(R.rdx,
                Mem(R.r13, disp: 8 * (mapped >>> env.pageShift)));
            a.testRR64(R.rdx, R.rdx);
            a.jcc(Cc.e, slow);
            m = Mem(R.rdx, disp: mapped & ((1 << env.pageShift) - 1));
          } else {
            lookup(R.r13);
            a.testRR64(R.rdx, R.rdx);
            a.jcc(Cc.e, slow);
            a.aluRI(Alu.and, R.rcx, (1 << env.pageShift) - 1);
            m = Mem(R.rdx, index: R.rcx);
          }
          load(R.rax, inst.b);
          swap(R.rax, inst.imm, inst.endian);
          switch (inst.imm) {
            case 1:
              a.mov8MR(m, R.rax);
            case 2:
              a.mov16MR(m, R.rax);
            case 4:
              a.movMR(m, R.rax);
            case 8:
              a.movMR(m, R.rax, w: true);
          }
          a.bind(done);
        case IrOp.floatAdd || IrOp.floatSub || IrOp.floatMul || IrOp.floatDiv:
          load(R.rax, inst.a);
          load(R.rcx, inst.b);
          a.floatBinary(
            inst.op == IrOp.floatAdd
                ? 0x58
                : inst.op == IrOp.floatSub
                ? 0x5c
                : inst.op == IrOp.floatMul
                ? 0x59
                : 0x5e,
            wide: wide(i),
          );
          save(i, R.rax);
        case IrOp.floatSqrt:
          load(R.rax, inst.a);
          a.floatSqrt(wide: wide(i));
          save(i, R.rax);
        case IrOp.floatConvert:
          load(R.rax, inst.a);
          a.floatConvert(fromWide: wide(inst.a));
          save(i, R.rax);
        case IrOp.floatToInt:
          load(R.rax, inst.a);
          a.floatToInt(wide: wide(inst.a), truncate: inst.imm == 1);
          save(i, R.rax);
        case IrOp.call:
          load(arg0, inst.a);
          load(arg1, inst.b);
          load(arg2, inst.c);
          a.movRI64(R.rax, env.helperFn(inst.imm));
          a.callR(R.rax);
          save(i, R.rax);
        case IrOp.exitIf:
          final e = block.exits[inst.aux];
          // Conditions split from one exit share its stub.
          final l = exitStubs[inst.aux] ??= stub(
            () => exitTo(
              e.reason,
              e.pc,
              e.tag,
              refund: e.refund(block.cost),
              stores: e.stores,
              linked: e.link,
            ),
          );
          jumpOnCondition(inst.a, l, whenTrue: true);
        case IrOp.guardMapped:
          final l = unmappedExit(block.exits[inst.aux]);
          load(R.rax, inst.a);
          lookup(inst.imm != 0 ? R.r13 : R.r12);
          a.testRR64(R.rdx, R.rdx);
          a.jcc(Cc.e, l);
      }
    }

    // jumps to the block (pc, tag) through its link slot

    switch (block.term) {
      case IrJump(:final pc, :final tag):
        linkTo(pc, tag);
      case IrBranch t:
        final notTaken = label();
        jumpOnCondition(t.cond.index, notTaken, whenTrue: false);
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
        load(R.rax, v.index);
        a.movRR(R.rcx, R.rax);
        a.shiftRI(Shift.shr, R.rcx, DynTable.pcShift);
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
        exitTo(
          exit.reason,
          exit.pc,
          exit.tag,
          refund: exit.refund(block.cost),
          stores: exit.stores,
          linked: exit.link,
        );
    }

    for (var i = 0; i < stubs.length; i++) {
      stubs[i]();
    }
    if (pool.isNotEmpty) {
      while (a.offset & 15 != 0) {
        a.u8(0xcc);
      }
      for (final (l, w) in pool.values) {
        a.bind(l);
        for (final x in w) {
          a.u32(x);
        }
      }
    }
    a.link(labels);
    return a.bytes;
  }

  /// the dynamic table index of (pc, tag), as computed by the code above
  static int dynIndex(int pc, int tag) => DynTable.index(pc, tag);
}
