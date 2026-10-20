import 'dart:convert';
import 'dart:typed_data';

import '../ir.dart';

/// Linear-memory offsets and link slots shared by generated Wasm modules.
abstract interface class WasmEnv {
  int get ctxOffset;
  int get readTable;
  int get writeTable;
  int get slots;
  int get dyn;
  int get addrMask;
  int get helperCount;
  int slotFor(int pc, int tag);
}

/// Emits baseline Wasm with i32 locals for SSA values. A block returns the
/// next table index, or zero to leave the dispatcher. Chaining uses a loop
/// rather than recursive calls, so guest loops cannot grow the host stack.
abstract final class WasmBackend {
  static const dynEntries = 4096;
  static int dynIndex(int pc, int tag) => ((pc >>> 2) ^ tag) & (dynEntries - 1);

  static Uint8List dispatcher(int ctx) {
    final c = _Code();
    c.op(0x03, 0x40); // loop
    c.get(0);
    c.op(0x11);
    c.u(0);
    c.u(0); // call_indirect () -> i32
    c.tee(0);
    c.op(0x45, 0x04, 0x40); // if result == 0
    c.i32(ctx + 4 * JitCtx.exitReason);
    c.load();
    c.op(0x0f);
    c.op(0x0b, 0x0c);
    c.u(0); // end; br loop
    c.op(0x0b);
    c.i32(0);
    c.op(0x0b);
    return _module(c, 2, 0, 0);
  }

  static Uint8List compile(IrBlock block, WasmEnv env) {
    if (block.usesI64 || block.usesBigEndian) {
      throw UnsupportedError(
          'Wasm backend currently emits i32 little-endian IR');
    }
    final c = _Code();
    final address = block.insts.length;
    final page = address + 1, temp = page + 1;
    void ctxLoad(int word) {
      c.i32(env.ctxOffset + 4 * word);
      c.load();
    }

    void ctxStore(int word, void Function() value) {
      c.i32(env.ctxOffset + 4 * word);
      value();
      c.store();
    }

    void exit(int reason, int pc, int tag, {int refund = 0, int? pcLocal}) {
      ctxStore(JitCtx.exitReason, () => c.i32(reason));
      ctxStore(
          JitCtx.exitPc, () => pcLocal == null ? c.i32(pc) : c.get(pcLocal));
      ctxStore(JitCtx.exitTag, () => c.i32(tag));
      if (refund != 0) {
        ctxStore(JitCtx.budget, () {
          ctxLoad(JitCtx.budget);
          c.i32(refund);
          c.op(0x6a);
        });
      }
      c.i32(0);
      c.op(0x0f);
    }

    void sideExit(IrExit e) =>
        exit(e.reason, e.pc, e.tag, refund: e.refund(block.cost));
    void lookup(bool write) {
      c.i32(write ? env.writeTable : env.readTable);
      c.get(address);
      c.i32(env.addrMask);
      c.op(0x71);
      c.i32(12);
      c.op(0x76);
      c.i32(2);
      c.op(0x74, 0x6a);
      c.load();
      c.set(page);
    }

    void hostAddress() {
      c.get(page);
      c.get(address);
      c.i32(0xfff);
      c.op(0x71, 0x6a);
    }

    ctxLoad(JitCtx.stop);
    ctxLoad(JitCtx.budget);
    c.i32(0);
    c.op(0x4c, 0x72);
    c.op(0x04, 0x40);
    exit(JitReason.budget, block.pc, block.tag);
    c.op(0x0b);
    for (final g in block.guards) {
      c.i32(g.addr);
      c.set(address);
      lookup(false);
      c.get(page);
      c.op(0x04, 0x40);
      hostAddress();
      c.load();
      c.i32(g.value);
      c.op(0x47, 0x04, 0x40);
      exit(JitReason.invalid, block.pc, block.tag);
      c.op(0x0b, 0x0b);
    }
    ctxStore(JitCtx.budget, () {
      ctxLoad(JitCtx.budget);
      c.i32(block.cost);
      c.op(0x6b);
    });

    for (final (i, inst) in block.insts.indexed) {
      void a() => c.get(inst.a);
      void b() => c.get(inst.b);
      void binary(int opcode) {
        a();
        b();
        c.op(opcode);
      }

      switch (inst.op) {
        case IrOp.sext32 || IrOp.zext32 || IrOp.trunc32:
          throw UnsupportedError('Wasm i64 emission is not implemented');
        case IrOp.constant:
          c.i32(inst.imm);
        case IrOp.ctxLoad:
          ctxLoad(inst.imm);
        case IrOp.ctxStore:
          ctxStore(inst.imm, a);
        case IrOp.add:
          binary(0x6a);
        case IrOp.sub:
          binary(0x6b);
        case IrOp.mul:
          binary(0x6c);
        case IrOp.mulHiS || IrOp.mulHiU:
          final extend = inst.op == IrOp.mulHiS ? 0xac : 0xad;
          a();
          c.op(extend);
          b();
          c.op(extend, 0x7e, 0x42);
          c.s(32);
          c.op(inst.op == IrOp.mulHiS ? 0x87 : 0x88, 0xa7);
        case IrOp.and:
          binary(0x71);
        case IrOp.or:
          binary(0x72);
        case IrOp.xor:
          binary(0x73);
        case IrOp.shl:
          binary(0x74);
        case IrOp.shrS:
          binary(0x75);
        case IrOp.shrU:
          binary(0x76);
        case IrOp.eq:
          binary(0x46);
        case IrOp.ne:
          binary(0x47);
        case IrOp.ltS:
          binary(0x48);
        case IrOp.ltU:
          binary(0x49);
        case IrOp.select:
          b();
          c.get(inst.c);
          a();
          c.op(0x1b);
        case IrOp.sext8:
          a();
          c.op(0xc0);
        case IrOp.sext16:
          a();
          c.op(0xc1);
        case IrOp.zext8:
          a();
          c.i32(0xff);
          c.op(0x71);
        case IrOp.zext16:
          a();
          c.i32(0xffff);
          c.op(0x71);
        case IrOp.load:
          a();
          c.set(address);
          lookup(false);
          c.get(page);
          c.op(0x04, 0x7f); // if -> i32
          hostAddress();
          final opcode = switch ((inst.imm, inst.aux != 0)) {
            (1, false) => 0x2d,
            (1, true) => 0x2c,
            (2, false) => 0x2f,
            (2, true) => 0x2e,
            _ => 0x28,
          };
          c.load(
              opcode: opcode,
              align: inst.imm == 4
                  ? 2
                  : inst.imm == 2
                      ? 1
                      : 0);
          c.op(0x05);
          c.get(address);
          c.i32(inst.imm);
          c.i32(0);
          c.call(0);
          if (inst.imm != 4) {
            if (inst.aux != 0) {
              c.op(inst.imm == 1 ? 0xc0 : 0xc1);
            } else {
              c.i32(inst.imm == 1 ? 0xff : 0xffff);
              c.op(0x71);
            }
          }
          c.op(0x0b);
        case IrOp.store:
          a();
          c.set(address);
          lookup(true);
          c.get(page);
          c.op(0x04, 0x40);
          hostAddress();
          b();
          c.store(
              opcode: inst.imm == 1
                  ? 0x3a
                  : inst.imm == 2
                      ? 0x3b
                      : 0x36,
              align: inst.imm == 4
                  ? 2
                  : inst.imm == 2
                      ? 1
                      : 0);
          c.op(0x05);
          c.get(address);
          b();
          c.i32(inst.imm);
          c.call(1);
          c.op(0x1a, 0x0b);
        case IrOp.call:
          a();
          b();
          c.get(inst.c);
          c.call(2 + inst.imm);
        case IrOp.exitIf:
          a();
          c.op(0x04, 0x40);
          sideExit(block.exits[inst.aux]);
          c.op(0x0b);
        case IrOp.guardMapped:
          a();
          c.set(address);
          lookup(inst.imm != 0);
          c.get(page);
          c.op(0x45, 0x04, 0x40);
          sideExit(block.exits[inst.aux]);
          c.op(0x0b);
      }
      if (irHasResult(inst.op)) c.set(i);
    }

    void link(int pc, int tag) {
      c.i32(env.slots + 4 * env.slotFor(pc, tag));
      c.load();
      c.tee(page);
      c.op(0x45, 0x04, 0x40);
      exit(JitReason.miss, pc, tag);
      c.op(0x0b);
      c.get(page);
      c.op(0x0f);
    }

    switch (block.term) {
      case IrJump(:final pc, :final tag):
        link(pc, tag);
      case IrBranch t:
        c.get(t.cond.index);
        c.op(0x04, 0x40);
        link(t.pcTrue, t.tagTrue);
        c.op(0x05);
        link(t.pcFalse, t.tagFalse);
        c.op(0x0b);
      case IrJumpDyn(pc: final value, :final tag):
        c.get(value.index);
        c.set(address);
        c.i32(env.dyn);
        c.get(address);
        c.i32(2);
        c.op(0x76);
        c.i32(tag);
        c.op(0x73);
        c.i32(dynEntries - 1);
        c.op(0x71);
        c.i32(12);
        c.op(0x6c, 0x6a);
        c.set(temp);
        c.get(temp);
        c.load();
        c.get(address);
        c.op(0x47);
        c.get(temp);
        c.load(offset: 4);
        c.i32(tag);
        c.op(0x47, 0x72);
        c.get(temp);
        c.load(offset: 8);
        c.tee(page);
        c.op(0x45, 0x72, 0x04, 0x40);
        exit(JitReason.miss, 0, tag, pcLocal: address);
        c.op(0x0b);
        c.get(page);
        c.op(0x0f);
      case IrExitTerm(:final exit):
        sideExit(exit);
    }
    c.i32(0);
    c.op(0x0b);
    return _module(c, 0, block.insts.length + 3, 2 + env.helperCount);
  }

  static Uint8List _module(_Code code, int type, int locals, int imports) {
    final m = _Code()..bytes.addAll([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0]);
    final types = _Code()..u(3);
    for (final params in [0, 3, 1]) {
      types.op(0x60);
      types.u(params);
      for (int i = 0; i < params; i++) {
        types.op(0x7f);
      }
      types.op(1, 0x7f);
    }
    m.section(1, types);
    final im = _Code()..u(imports + 2);
    im.name('env');
    im.name('memory');
    im.op(2, 0);
    im.u(1);
    im.name('env');
    im.name('table');
    im.op(1, 0x70, 0);
    im.u(0);
    for (int i = 0; i < imports; i++) {
      im.name('env');
      im.name('f$i');
      im.op(0);
      im.u(1);
    }
    m.section(2, im);
    m.section(
        3,
        _Code()
          ..u(1)
          ..u(type));
    final exports = _Code()
      ..u(1)
      ..name('run')
      ..op(0)
      ..u(imports);
    m.section(7, exports);
    final body = _Code()..u(locals == 0 ? 0 : 1);
    if (locals != 0) {
      body.u(locals);
      body.op(0x7f);
    }
    body.bytes.addAll(code.bytes);
    m.section(
        10,
        _Code()
          ..u(1)
          ..u(body.bytes.length)
          ..bytes.addAll(body.bytes));
    return Uint8List.fromList(m.bytes);
  }
}

final class _Code {
  final bytes = <int>[];
  void op(int a, [int? b, int? c, int? d]) {
    bytes.add(a);
    if (b != null) bytes.add(b);
    if (c != null) bytes.add(c);
    if (d != null) bytes.add(d);
  }

  void u(int value) {
    do {
      final b = value & 0x7f;
      value >>>= 7;
      bytes.add(b | (value != 0 ? 0x80 : 0));
    } while (value != 0);
  }

  void s(int value) {
    for (;;) {
      final b = value & 0x7f;
      value = (value - b) ~/ 128;
      final done =
          (value == 0 && b & 0x40 == 0) || (value == -1 && b & 0x40 != 0);
      bytes.add(b | (done ? 0 : 0x80));
      if (done) return;
    }
  }

  void i32(int value) {
    op(0x41);
    s(value.toSigned(32));
  }

  void get(int index) {
    op(0x20);
    u(index);
  }

  void set(int index) {
    op(0x21);
    u(index);
  }

  void tee(int index) {
    op(0x22);
    u(index);
  }

  void call(int index) {
    op(0x10);
    u(index);
  }

  void load({int opcode = 0x28, int align = 2, int offset = 0}) {
    op(opcode);
    u(align);
    u(offset);
  }

  void store({int opcode = 0x36, int align = 2}) {
    op(opcode);
    u(align);
    u(0);
  }

  void name(String value) {
    final b = utf8.encode(value);
    u(b.length);
    bytes.addAll(b);
  }

  void section(int id, _Code data) {
    op(id);
    u(data.bytes.length);
    bytes.addAll(data.bytes);
  }
}
