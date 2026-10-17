import 'dart:typed_data';

import 'ir.dart';
import 'runtime.dart';

/// The reference implementation of [JitRuntime], which interprets the IR.
/// The native backends must behave the same.
final class IrInterpreterRuntime extends JitRuntime {
  @override
  final Uint32List ctx;
  final _helpers = <JitHelper>[];
  final _blocks = <(int, int), IrBlock>{};

  IrInterpreterRuntime(int ctxWords, super.addrMask, super.read, super.write)
      : ctx = Uint32List(ctxWords);

  @override
  Uint8List alloc(int size) => Uint8List(size);

  @override
  int addHelper(JitHelper f) {
    _helpers.add(f);
    return _helpers.length - 1;
  }

  @override
  bool contains(int pc, int tag) => _blocks.containsKey((pc, tag));

  @override
  void install(IrBlock block) => _blocks[(block.pc, block.tag)] = block;

  @override
  void invalidate(int pc, int tag) => _blocks.remove((pc, tag));

  @override
  void clear() => _blocks.clear();

  @override
  void dispose() => clear();

  int _exit(int reason, int pc, int tag) {
    ctx[JitCtx.exitReason] = reason;
    ctx[JitCtx.exitPc] = pc;
    ctx[JitCtx.exitTag] = tag;
    return reason;
  }

  int _load(int addr, int size, bool signed) {
    final masked = addr & addrMask;
    final page = readPages[masked >>> JitRuntime.pageBits];
    int v;
    if (page == null) {
      v = read(addr, size);
    } else {
      final (host, offset) = page;
      final at = offset + (masked & (JitRuntime.pageSize - 1));
      v = switch (size) {
        1 => host[at],
        2 => host[at] | host[at + 1] << 8,
        _ => host[at] |
            host[at + 1] << 8 |
            host[at + 2] << 16 |
            host[at + 3] << 24,
      };
    }
    return switch (size) {
      1 => signed ? v.toSigned(8) : v & 0xff,
      2 => signed ? v.toSigned(16) : v & 0xffff,
      _ => v,
    }
        .toUnsigned(32);
  }

  void _store(int addr, int size, int v) {
    final masked = addr & addrMask;
    final page = writePages[masked >>> JitRuntime.pageBits];
    if (page == null) {
      write(addr, size, v & (size == 4 ? 0xffffffff : (1 << (size * 8)) - 1));
      return;
    }
    final (host, offset) = page;
    final at = offset + (masked & (JitRuntime.pageSize - 1));
    for (int i = 0; i < size; i++) {
      host[at + i] = v >> (8 * i);
    }
  }

  @override
  int run(int pc, int tag) {
    final ctx = this.ctx;
    for (;;) {
      final block = _blocks[(pc, tag)];
      if (block == null) return _exit(JitReason.miss, pc, tag);
      if (ctx[JitCtx.stop] != 0 || ctx[JitCtx.budget].toSigned(32) <= 0) {
        return _exit(JitReason.budget, pc, tag);
      }
      for (final g in block.guards) {
        final v = mappedWord(g.addr);
        if (v != null && v != g.value) {
          return _exit(JitReason.invalid, pc, tag);
        }
      }
      ctx[JitCtx.budget] -= block.cost;

      final values = List<int>.filled(block.insts.length, 0);
      for (int i = 0; i < block.insts.length; i++) {
        final inst = block.insts[i];
        int a() => values[inst.a];
        int b() => values[inst.b];
        final int v = switch (inst.op) {
          IrOp.constant => inst.imm,
          IrOp.ctxLoad => ctx[inst.imm],
          IrOp.ctxStore => ctx[inst.imm] = a(),
          IrOp.add => a() + b(),
          IrOp.sub => a() - b(),
          IrOp.mul => _mulLo(a(), b()),
          IrOp.mulHiS => _mulHiU(a(), b()) -
              (a() >= 0x80000000 ? b() : 0) -
              (b() >= 0x80000000 ? a() : 0),
          IrOp.mulHiU => _mulHiU(a(), b()),
          IrOp.and => a() & b(),
          IrOp.or => a() | b(),
          IrOp.xor => a() ^ b(),
          IrOp.shl => a() << (b() & 31),
          IrOp.shrU => a() >>> (b() & 31),
          IrOp.shrS => a().toSigned(32) >> (b() & 31),
          IrOp.eq => a() == b() ? 1 : 0,
          IrOp.ne => a() != b() ? 1 : 0,
          IrOp.ltS => a().toSigned(32) < b().toSigned(32) ? 1 : 0,
          IrOp.ltU => a() < b() ? 1 : 0,
          IrOp.select => a() != 0 ? b() : values[inst.c],
          IrOp.sext8 => a().toSigned(8),
          IrOp.sext16 => a().toSigned(16),
          IrOp.zext8 => a() & 0xff,
          IrOp.zext16 => a() & 0xffff,
          IrOp.load => _load(a(), inst.imm, inst.aux != 0),
          IrOp.store => () {
              _store(a(), inst.imm, b());
              return 0;
            }(),
          IrOp.call => _helpers[inst.imm](a(), b(), values[inst.c]),
          IrOp.exitIf => a(),
        };
        values[i] = v.toUnsigned(32);
        if (inst.op == IrOp.exitIf && v != 0) {
          final e = block.exits[inst.aux];
          ctx[JitCtx.budget] += e.refund(block.cost);
          return _exit(e.reason, e.pc, e.tag);
        }
      }

      switch (block.term) {
        case IrJump(pc: final p, tag: final t):
          pc = p;
          tag = t;
        case IrBranch b:
          final taken = values[b.cond.index] != 0;
          pc = taken ? b.pcTrue : b.pcFalse;
          tag = taken ? b.tagTrue : b.tagFalse;
        case IrJumpDyn(pc: final v, tag: final t):
          pc = values[v.index];
          tag = t;
        case IrExitTerm(:final exit):
          ctx[JitCtx.budget] += exit.refund(block.cost);
          return _exit(exit.reason, exit.pc, exit.tag);
      }
      pc = pc.toUnsigned(32);
    }
  }

  // the products below stay within 48 bits, exact on the web too
  static int _mulLo(int a, int b) =>
      ((a & 0xffff) * b + (((a >>> 16) * b) & 0xffff) * 0x10000).toUnsigned(32);

  static int _mulHiU(int a, int b) {
    final al = a & 0xffff, ah = a >>> 16, bl = b & 0xffff, bh = b >>> 16;
    final ll = al * bl, lh = al * bh, hl = ah * bl, hh = ah * bh;
    final mid = (ll >>> 16) + (lh & 0xffff) + (hl & 0xffff);
    return hh + (lh >>> 16) + (hl >>> 16) + (mid >>> 16);
  }
}
