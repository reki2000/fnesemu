import '../ir.dart';
import '../native_env.dart';
import 'assembler.dart';

/// AAPCS64 code generation, also used by the ARM64 desktop ABIs.
/// X19-X23 hold runtime pointers; X18 and SIMD registers are untouched.
/// SSA spill slots survive every helper and unmapped-memory callback.
abstract final class Arm64Backend {
  static const maxValues = 4096;
  static const frame = 16 + maxValues * 8;
  static const saved = [(19, 20), (21, 22), (23, 24), (29, 30)];

  static (List<int>, int) trampoline({
    required bool win64,
    required int ctx,
    required int readTable,
    required int writeTable,
    required int slots,
    required int dyn,
  }) {
    final a = Arm64Assembler()..emit(0xd503245f); // BTI c
    for (final (x, y) in saved) {
      a.pushPair(x, y);
    }
    a.immediate(29, 31, 0);
    // Probe each page before descending further, including on guarded stacks.
    for (var remaining = frame; remaining > 0;) {
      final count = remaining >= 4096 ? 4096 : remaining;
      a.immediate(
        31,
        31,
        count == 4096 ? 1 : count,
        sub: true,
        shifted: count == 4096,
      );
      a.memory(false, 31, 31, 0);
      remaining -= count;
    }
    for (final (r, value) in [
      (19, ctx),
      (20, readTable),
      (21, writeTable),
      (22, slots),
      (23, dyn),
    ]) {
      a.constant(r, value, wide: true);
    }
    a.emit(0xd61f0000); // BR x0
    final exit = a.offset;
    a.emit(0xd503249f); // BTI j
    a.memory(false, 0, 19, JitCtx.exitReason * 4, size: 4);
    a.immediate(31, 31, frame >>> 12, shifted: true);
    a.immediate(31, 31, frame & 4095);
    for (final (x, y) in saved.reversed) {
      a.popPair(x, y);
    }
    a.emit(0xd65f03c0); // RET
    return (a.bytes, exit);
  }

  static List<int> compile(IrBlock block, int base, NativeEnv env) {
    if (block.insts.length > maxValues) throw StateError('block too long');
    final a = Arm64Assembler()..emit(0xd503249f);
    final stubs = <void Function()>[];
    bool wide(int v) => block.insts[v].type == IrType.i64;
    void load(int reg, int value) {
      final i = block.insts[value];
      if (i.op == IrOp.constant) {
        a.constant(
          reg,
          wide(value) ? (i.imm & 0xffffffff) | (i.immHi << 32) : i.imm,
          wide: wide(value),
        );
      } else {
        a.memory(true, reg, 31, 16 + 8 * value, size: wide(value) ? 8 : 4);
      }
    }

    void save(int reg, int value) =>
        a.memory(false, reg, 31, 16 + 8 * value, size: wide(value) ? 8 : 4);
    void budget(int delta) {
      a.memory(true, 0, 19, 4 * JitCtx.budget, size: 4);
      a.constant(1, delta);
      a.alu(0x0b000000, 0, 0, 1);
      a.memory(false, 0, 19, 4 * JitCtx.budget, size: 4);
    }

    late void Function(int, int) link;
    void leave(
      int reason,
      int pc,
      int tag, {
      int refund = 0,
      bool linked = false,
      List<(int, IrValue)> stores = const [],
    }) {
      for (final (word, v) in stores) {
        load(0, v.index);
        a.memory(false, 0, 19, word * 4, size: wide(v.index) ? 8 : 4);
      }
      if (refund != 0) budget(refund);
      if (linked) {
        link(pc, tag);
        return;
      }
      a.constant(0, pc);
      a.memory(false, 0, 19, 4 * JitCtx.exitPc, size: 4);
      a.constant(0, tag);
      a.memory(false, 0, 19, 4 * JitCtx.exitTag, size: 4);
      a.constant(0, reason);
      a.jump(env.exitStub);
    }

    Arm64Label stub(void Function() emit) {
      final label = Arm64Label();
      stubs.add(() {
        a.bind(label);
        emit();
      });
      return label;
    }

    link = (pc, tag) {
      final miss = stub(() => leave(JitReason.miss, pc, tag));
      a.memory(true, 0, 22, env.slotFor(pc, tag) * 8);
      a.cmp(0, 31, wide: true);
      a.branch(miss, 0);
      a.emit(0xd61f0000);
    };

    final entryExit = stub(() => leave(JitReason.budget, block.pc, block.tag));
    a.memory(true, 0, 19, JitCtx.stop * 4, size: 4);
    a.cmp(0, 31);
    a.branch(entryExit, 1);
    a.memory(true, 0, 19, JitCtx.budget * 4, size: 4);
    a.cmp(0, 31);
    a.branch(entryExit, 13); // LE
    if (block.guards.isNotEmpty) {
      final invalid = stub(() => leave(JitReason.invalid, block.pc, block.tag));
      for (final g in block.guards) {
        final address = env.guardAddr(g.addr);
        if (address == null) continue;
        a.constant(0, address, wide: true);
        a.memory(true, 1, 0, 0, size: 4);
        if (g.endian == IrEndian.big) a.reverse(1, 4);
        a.constant(2, g.value);
        a.cmp(1, 2);
        a.branch(invalid, 1);
      }
    }
    if (env.blockEntryFn != 0) {
      a.constant(16, env.blockEntryFn, wide: true);
      a.emit(0xd63f0200); // BLR x16
    }
    budget(-block.cost);

    // X0 retains the guest address, X5 is the mapped host address or null.
    void lookup(bool write) {
      a.constant(3, env.addrMask);
      a.alu(0x0a000000, 3, 0, 3);
      a.constant(4, env.pageShift);
      a.alu(0x1ac02400, 4, 3, 4);
      a.constant(5, 3);
      a.alu(0x1ac02000, 4, 4, 5);
      a.alu(0x0b000000, 4, write ? 21 : 20, 4, wide: true);
      a.memory(true, 5, 4, 0);
      a.constant(4, (1 << env.pageShift) - 1);
      a.alu(0x0a000000, 3, 3, 4);
    }

    void swap(int reg, int size, IrEndian endian) {
      if (endian == IrEndian.big && size > 1) a.reverse(reg, size);
    }

    void finishLoad(IrInst i) {
      swap(0, i.imm, i.endian);
      if (i.imm < 8) {
        a.extend(
          0,
          0,
          i.imm * 8,
          signed: i.aux != 0,
          wide: i.type == IrType.i64,
        );
      }
    }

    Arm64Label unmapped(IrExit e) => stub(() {
      a.memory(false, 0, 19, 4 * JitCtx.faultAddr, size: 4);
      leave(
        e.reason,
        e.pc,
        e.tag,
        refund: e.refund(block.cost),
        stores: e.stores,
        linked: e.link,
      );
    });
    for (var v = 0; v < block.insts.length; v++) {
      final i = block.insts[v], w = wide(v);
      void binary(int op) {
        load(0, i.a);
        load(1, i.b);
        a.alu(op, 0, 0, 1, wide: w);
        save(0, v);
      }

      void compare(int cc) {
        load(0, i.a);
        load(1, i.b);
        a.cmp(0, 1, wide: wide(i.a));
        a.cset(0, cc);
        save(0, v);
      }

      switch (i.op) {
        case IrOp.constant:
          break;
        case IrOp.ctxLoad:
          a.memory(true, 0, 19, i.imm * 4, size: w ? 8 : 4);
          save(0, v);
        case IrOp.ctxStore:
          load(0, i.a);
          a.memory(false, 0, 19, i.imm * 4, size: w ? 8 : 4);
        case IrOp.add:
          binary(0x0b000000);
        case IrOp.sub:
          binary(0x4b000000);
        case IrOp.and:
          binary(0x0a000000);
        case IrOp.or:
          binary(0x2a000000);
        case IrOp.xor:
          binary(0x4a000000);
        case IrOp.mul:
          binary(0x1b007c00);
        case IrOp.shl:
          binary(0x1ac02000);
        case IrOp.shrU:
          binary(0x1ac02400);
        case IrOp.shrS:
          binary(0x1ac02800);
        case IrOp.mulHiS || IrOp.mulHiU:
          load(0, i.a);
          load(1, i.b);
          if (w) {
            a.alu(
              i.op == IrOp.mulHiS ? 0x1b407c00 : 0x1bc07c00,
              0,
              0,
              1,
              wide: true,
            );
          } else {
            a.alu(
              i.op == IrOp.mulHiS ? 0x1b207c00 : 0x1ba07c00,
              0,
              0,
              1,
              wide: true,
            );
            a.constant(1, 32);
            a.alu(0x1ac02400, 0, 0, 1, wide: true);
          }
          save(0, v);
        case IrOp.eq:
          compare(0);
        case IrOp.ne:
          compare(1);
        case IrOp.ltS:
          compare(11);
        case IrOp.ltU:
          compare(3);
        case IrOp.select:
          load(0, i.a);
          load(1, i.b);
          load(2, i.c);
          a.cmp(0, 31);
          a.select(0, 1, 2, 1, wide: w);
          save(0, v);
        case IrOp.sext8 ||
            IrOp.sext16 ||
            IrOp.zext8 ||
            IrOp.zext16 ||
            IrOp.sext32 ||
            IrOp.zext32 ||
            IrOp.trunc32:
          load(0, i.a);
          final bits = switch (i.op) {
            IrOp.sext8 || IrOp.zext8 => 8,
            IrOp.sext16 || IrOp.zext16 => 16,
            _ => 32,
          };
          a.extend(
            0,
            0,
            bits,
            wide: w,
            signed:
                i.op == IrOp.sext8 ||
                i.op == IrOp.sext16 ||
                i.op == IrOp.sext32,
          );
          save(0, v);
        case IrOp.load:
          final done = Arm64Label();
          final slow = i.exit >= 0
              ? unmapped(block.exits[i.exit])
              : stub(() {
                  a.memory(false, 0, 31, 0, size: 4);
                  void part(int offset) {
                    a.memory(true, 0, 31, 0, size: 4);
                    if (offset != 0) {
                      a.constant(1, offset);
                      a.alu(0x0b000000, 0, 0, 1);
                    }
                    a.constant(1, i.imm == 8 ? 4 : i.imm);
                    a.constant(2, 0);
                    a.call(env.readFn);
                    a.move(0, 0);
                  }

                  part(0);
                  if (i.imm == 8) {
                    a.memory(false, 0, 31, 8);
                    part(4);
                    a.constant(1, 32);
                    a.alu(0x1ac02000, 0, 0, 1, wide: true);
                    a.memory(true, 1, 31, 8);
                    a.alu(0x2a000000, 0, 0, 1, wide: true);
                  }
                  a.branch(done);
                });
          load(0, i.a);
          lookup(false);
          a.cmp(5, 31, wide: true);
          a.branch(slow, 0);
          a.alu(0x0b000000, 5, 5, 3, wide: true);
          a.memory(true, 0, 5, 0, size: i.imm);
          a.bind(done);
          finishLoad(i);
          save(0, v);
        case IrOp.store:
          final done = Arm64Label();
          final slow = i.exit >= 0
              ? unmapped(block.exits[i.exit])
              : stub(() {
                  a.memory(false, 0, 31, 0, size: 4);
                  load(0, i.b);
                  swap(0, i.imm, i.endian);
                  a.memory(false, 0, 31, 8);
                  void part(int offset) {
                    a.memory(true, 0, 31, 0, size: 4);
                    if (offset != 0) {
                      a.constant(1, offset);
                      a.alu(0x0b000000, 0, 0, 1);
                    }
                    a.memory(true, 1, 31, 8 + offset, size: 4);
                    a.constant(2, i.imm == 8 ? 4 : i.imm);
                    a.call(env.writeFn);
                  }

                  part(0);
                  if (i.imm == 8) part(4);
                  a.branch(done);
                });
          load(0, i.a);
          lookup(true);
          a.cmp(5, 31, wide: true);
          a.branch(slow, 0);
          a.alu(0x0b000000, 5, 5, 3, wide: true);
          load(0, i.b);
          swap(0, i.imm, i.endian);
          a.memory(false, 0, 5, 0, size: i.imm);
          a.bind(done);
        case IrOp.floatAdd || IrOp.floatSub || IrOp.floatMul:
          load(0, i.a);
          load(1, i.b);
          a.emit(w ? 0x9e670000 : 0x1e270000);
          a.emit(w ? 0x9e670021 : 0x1e270021);
          if (!w) {
            a.emit(0x1e22c000);
            a.emit(0x1e22c021);
          }
          a.emit(
            i.op == IrOp.floatAdd
                ? 0x1e612800
                : i.op == IrOp.floatSub
                ? 0x1e613800
                : 0x1e610800,
          );
          if (!w) a.emit(0x1e624000);
          a.emit(w ? 0x9e660000 : 0x1e260000);
          save(0, v);
        case IrOp.floatConvert:
          load(0, i.a);
          if (w) {
            a.emit(0x1e270000); // fmov s0, w0
            a.emit(0x1e22c000); // fcvt d0, s0
            a.emit(0x9e660000); // fmov x0, d0
          } else {
            a.emit(0x9e670000); // fmov d0, x0
            a.emit(0x1e624000); // fcvt s0, d0 (nearest under the default FPCR)
            a.emit(0x1e260000); // fmov w0, s0
          }
          save(0, v);
        case IrOp.floatToInt:
          load(0, i.a);
          if (wide(i.a)) {
            a.emit(0x9e670000); // fmov d0, x0
          } else {
            a.emit(0x1e270000); // fmov s0, w0
            a.emit(0x1e22c000); // fcvt d0, s0
          }
          a.emit(i.imm == 1 ? 0x1e780000 : 0x1e600000); // fcvtzs / fcvtns w0, d0
          save(0, v);
        case IrOp.call:
          load(0, i.a);
          load(1, i.b);
          load(2, i.c);
          a.call(env.helperFn(i.imm));
          save(0, v);
        case IrOp.exitIf:
          final e = block.exits[i.aux];
          final dest = stub(
            () => leave(
              e.reason,
              e.pc,
              e.tag,
              refund: e.refund(block.cost),
              stores: e.stores,
              linked: e.link,
            ),
          );
          load(0, i.a);
          a.cmp(0, 31);
          a.branch(dest, 1);
        case IrOp.guardMapped:
          load(0, i.a);
          lookup(i.imm != 0);
          a.cmp(5, 31, wide: true);
          a.branch(unmapped(block.exits[i.aux]), 0);
      }
    }

    switch (block.term) {
      case IrJump(:final pc, :final tag):
        link(pc, tag);
      case IrBranch t:
        final no = Arm64Label();
        load(0, t.cond.index);
        a.cmp(0, 31);
        a.branch(no, 0);
        link(t.pcTrue, t.tagTrue);
        a.bind(no);
        link(t.pcFalse, t.tagFalse);
      case IrJumpDyn t:
        final miss = stub(() {
          a.memory(false, 0, 19, 4 * JitCtx.exitPc, size: 4);
          a.constant(0, t.tag);
          a.memory(false, 0, 19, 4 * JitCtx.exitTag, size: 4);
          a.constant(0, JitReason.miss);
          a.jump(env.exitStub);
        });
        load(0, t.pc.index);
        a.constant(1, 2);
        a.alu(0x1ac02400, 1, 0, 1);
        a.constant(2, t.tag);
        a.alu(0x4a000000, 1, 1, 2);
        a.constant(2, 4095);
        a.alu(0x0a000000, 1, 1, 2);
        a.constant(2, 4);
        a.alu(0x1ac02000, 1, 1, 2);
        a.alu(0x0b000000, 1, 23, 1, wide: true);
        a.memory(true, 2, 1, 0, size: 4);
        a.cmp(0, 2);
        a.branch(miss, 1);
        a.memory(true, 2, 1, 4, size: 4);
        a.constant(3, t.tag);
        a.cmp(2, 3);
        a.branch(miss, 1);
        a.memory(true, 2, 1, 8);
        a.cmp(2, 31, wide: true);
        a.branch(miss, 0);
        a.emit(0xd61f0040);
      case IrExitTerm(:final exit):
        leave(
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
    return a.bytes;
  }
}
