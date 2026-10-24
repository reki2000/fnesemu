import 'dart:typed_data';

import 'ir.dart';
import 'runtime.dart';

part 'interp_wide.dart';

/// The reference implementation of [JitRuntime], which interprets the IR.
/// The native backends must behave the same.
final class IrInterpreterRuntime extends JitRuntime {
  @override
  final Uint32List ctx;
  final _helpers = <JitHelper>[];
  final _blocks = <(int, int), IrBlock>{};

  IrInterpreterRuntime(
      int ctxWords, super.addrMask, super.read, super.write, super.pageShift)
      : ctx = Uint32List(ctxWords);

  @override
  void shareBuffer(JitRuntime owner, Uint8List buffer) {}

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
  int? blockCost(int pc, int tag) => _blocks[(pc, tag)]?.cost;

  @override
  int installBlock(IrBlock block) {
    checkBlock(block);
    _blocks[(block.pc, block.tag)] = block;
    return 0;
  }

  @override
  void invalidate(int pc, int tag) {
    if (_blocks.remove((pc, tag)) != null) {
      compilationStats?.recordInvalidation(pc, tag);
    }
  }

  @override
  void clear() {
    compilationStats?.recordCacheClear(_blocks.length);
    _blocks.clear();
  }

  @override
  void dispose() => clear();

  final _floatData = ByteData(16);
  int _float32Binary(IrOp op, int a, int b) {
    double value(int at, int bits) {
      _floatData.setUint32(at, bits, Endian.little);
      return _floatData.getFloat32(at, Endian.little);
    }

    final x = value(0, a), y = value(8, b);
    final result = op == IrOp.floatAdd
        ? x + y
        : op == IrOp.floatSub
        ? x - y
        : x * y;
    _floatData.setFloat32(0, result, Endian.little);
    return _floatData.getUint32(0, Endian.little);
  }

  double _float32Value(int bits) {
    _floatData.setUint32(0, bits, Endian.little);
    return _floatData.getFloat32(0, Endian.little);
  }

  /// [IrOp.floatToInt]; unspecified results are the minimum word here
  static int _floatToInt(double v, int mode) {
    if (!v.isFinite || v.abs() >= 0x80000000) return 0x80000000;
    if (mode == 1) return v.truncate().toUnsigned(32);
    final floor = v.floorToDouble(), fraction = v - floor;
    final nearest = fraction > 0.5 || (fraction == 0.5 && floor % 2 != 0)
        ? floor + 1
        : floor;
    return nearest.toInt().toUnsigned(32);
  }

  int _exit(int reason, int pc, int tag) {
    ctx[JitCtx.exitReason] = reason;
    ctx[JitCtx.exitPc] = pc;
    ctx[JitCtx.exitTag] = tag;
    return reason;
  }

  int _load(int addr, int size, bool signed, IrEndian endian) {
    final masked = addr & addrMask;
    final page = readPages[masked >>> pageShift];
    int v;
    if (page == null) {
      v = read(addr, size);
    } else {
      final (host, offset) = page;
      final at = offset + (masked & (pageBytes - 1));
      v = switch (size) {
        1 => host[at],
        2 => host[at] | host[at + 1] << 8,
        _ => host[at] |
            host[at + 1] << 8 |
            host[at + 2] << 16 |
            host[at + 3] << 24,
      };
    }
    if (endian == IrEndian.big) v = _swap(v, size);
    return switch (size) {
      1 => signed ? v.toSigned(8) : v & 0xff,
      2 => signed ? v.toSigned(16) : v & 0xffff,
      _ => v,
    }
        .toUnsigned(32);
  }

  void _store(int addr, int size, int v, IrEndian endian) {
    if (endian == IrEndian.big) v = _swap(v, size);
    final masked = addr & addrMask;
    final page = writePages[masked >>> pageShift];
    if (page == null) {
      write(addr, size, v & (size == 4 ? 0xffffffff : (1 << (size * 8)) - 1));
      return;
    }
    final (host, offset) = page;
    final at = offset + (masked & (pageBytes - 1));
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
        final v = mappedWord(g.addr, endian: g.endian);
        if (v != null && v != g.value) {
          return _exit(JitReason.invalid, pc, tag);
        }
      }
      ctx[JitCtx.budget] -= block.cost;

      final next = block.usesI64 ? _executeWide(block) : _execute(block);
      if (next.exit) return next.$1;
      (pc, tag) = (next.$1.toUnsigned(32), next.$2);
    }
  }

  /// leaves through [e], the exit of [block]
  (int, int, {bool exit}) _leave(
    IrBlock block,
    IrExit e,
    Object Function(IrValue) value,
  ) {
    for (final (word, v) in e.stores) {
      final bits = value(v);
      if (block.insts[v.index].type == IrType.i64) {
        final wide = _Wide._bits(bits);
        ctx[word] = _Wide._word(wide);
        ctx[word + 1] = _Wide._word(wide >> 32);
      } else {
        ctx[word] = bits as int;
      }
    }
    ctx[JitCtx.budget] += e.refund(block.cost);
    if (e.link) return (e.pc, e.tag, exit: false);
    _exit(e.reason, e.pc, e.tag);
    return (e.reason, 0, exit: true);
  }

  /// whether an access at [addr] leaves through the unmapped exit of [inst]
  bool _unmapped(IrInst inst, int addr) {
    final write =
        inst.op == IrOp.store || (inst.op == IrOp.guardMapped && inst.imm != 0);
    if ((write ? writePages : readPages)[(addr & addrMask) >>> pageShift] !=
        null) {
      return false;
    }
    ctx[JitCtx.faultAddr] = addr;
    return true;
  }

  /// the next block key, or the exit reason
  (int, int, {bool exit}) _next(IrBlock block, Object Function(IrValue) value) {
    switch (block.term) {
      case IrJump(pc: final p, tag: final t):
        return (p, t, exit: false);
      case IrBranch b:
        final taken = value(b.cond) != 0;
        return taken
            ? (b.pcTrue, b.tagTrue, exit: false)
            : (b.pcFalse, b.tagFalse, exit: false);
      case IrJumpDyn(pc: final v, tag: final t):
        return (value(v) as int, t, exit: false);
      case IrExitTerm(:final exit):
        return _leave(block, exit, value);
    }
  }

  /// runs an i32 block with unboxed values
  (int, int, {bool exit}) _execute(IrBlock block) {
    final ctx = this.ctx;
    final insts = block.insts;
    final values = Uint32List(insts.length);
    for (int i = 0; i < insts.length; i++) {
      final inst = insts[i];
      int a() => values[inst.a];
      int b() => values[inst.b];
      if (inst.exit >= 0 && _unmapped(inst, a())) {
        final e = block.exits[inst.exit];
        return _leave(block, e, (v) => values[v.index]);
      }
      final int v = switch (inst.op) {
        IrOp.constant => inst.imm,
        IrOp.ctxLoad => ctx[inst.imm],
        IrOp.ctxStore => ctx[inst.imm] = a(),
        IrOp.add => a() + b(),
        IrOp.sub => a() - b(),
        IrOp.mul => _mulLo(a(), b()),
        IrOp.floatAdd ||
        IrOp.floatSub ||
        IrOp.floatMul => _float32Binary(inst.op, a(), b()),
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
        IrOp.load => _load(a(), inst.imm, inst.aux != 0, inst.endian),
        IrOp.store => () {
            _store(a(), inst.imm, b(), inst.endian);
            return 0;
          }(),
        IrOp.call => _helpers[inst.imm](a(), b(), values[inst.c]),
        IrOp.floatToInt => _floatToInt(_float32Value(a()), inst.imm),
        IrOp.sext32 ||
        IrOp.zext32 ||
        IrOp.trunc32 ||
        IrOp.floatConvert =>
          throw StateError('wide conversion in an i32 block'),
        IrOp.exitIf => a(),
        IrOp.guardMapped => _unmapped(inst, a()) ? 1 : 0,
      };
      values[i] = v;
      if ((inst.op == IrOp.exitIf || inst.op == IrOp.guardMapped) && v != 0) {
        final e = block.exits[inst.aux];
        return _leave(block, e, (v) => values[v.index]);
      }
    }
    return _next(block, (v) => values[v.index]);
  }

  /// runs a block with i64 values, which are BigInts
  (int, int, {bool exit}) _executeWide(IrBlock block) {
    final ctx = this.ctx;
    final values = List<Object>.filled(block.insts.length, 0);
    for (int i = 0; i < block.insts.length; i++) {
      final inst = block.insts[i];
      // addresses are i32 at every value width
      if (inst.exit >= 0 && _unmapped(inst, values[inst.a] as int)) {
        final e = block.exits[inst.exit];
        return _leave(block, e, (v) => values[v.index]);
      }
      if (inst.type == IrType.i64 ||
          (inst.a >= 0 && block.insts[inst.a].type == IrType.i64)) {
        values[i] = _wide(inst, values);
        continue;
      }
      int a() => values[inst.a] as int;
      int b() => values[inst.b] as int;
      final int v = switch (inst.op) {
        IrOp.constant => inst.imm,
        IrOp.ctxLoad => ctx[inst.imm],
        IrOp.ctxStore => ctx[inst.imm] = a(),
        IrOp.add => a() + b(),
        IrOp.sub => a() - b(),
        IrOp.mul => _mulLo(a(), b()),
        IrOp.floatAdd ||
        IrOp.floatSub ||
        IrOp.floatMul => _float32Binary(inst.op, a(), b()),
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
        IrOp.select => a() != 0 ? b() : values[inst.c] as int,
        IrOp.sext8 => a().toSigned(8),
        IrOp.sext16 => a().toSigned(16),
        IrOp.zext8 => a() & 0xff,
        IrOp.zext16 => a() & 0xffff,
        IrOp.load => _load(a(), inst.imm, inst.aux != 0, inst.endian),
        IrOp.store => () {
            _store(a(), inst.imm, b(), inst.endian);
            return 0;
          }(),
        IrOp.call => _helpers[inst.imm](a(), b(), values[inst.c] as int),
        IrOp.floatToInt => _floatToInt(_float32Value(a()), inst.imm),
        IrOp.sext32 ||
        IrOp.zext32 ||
        IrOp.trunc32 ||
        IrOp.floatConvert =>
          throw StateError('wide conversion in i32 execution path'),
        IrOp.exitIf => a(),
        IrOp.guardMapped => _unmapped(inst, a()) ? 1 : 0,
      };
      values[i] = v.toUnsigned(32);
      if ((inst.op == IrOp.exitIf || inst.op == IrOp.guardMapped) && v != 0) {
        final e = block.exits[inst.aux];
        return _leave(block, e, (v) => values[v.index]);
      }
    }
    return _next(block, (v) => values[v.index]);
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

  static int _swap(int value, int size) {
    int result = 0;
    for (int i = 0; i < size; i++) {
      result = (result << 8) | ((value >>> (8 * i)) & 0xff);
    }
    return result.toUnsigned(32);
  }
}
