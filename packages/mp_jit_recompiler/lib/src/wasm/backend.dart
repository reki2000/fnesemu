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
  int get pageShift;
  int get helperCount;

  /// Whether blocks call the import after the helpers at their entry.
  bool get profileBlocks;
  int slotFor(int pc, int tag);
}

/// Emits baseline Wasm with i32 and i64 locals for SSA values. Big-endian
/// accesses reverse bytes around little-endian linear-memory operations. A block returns the
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
    return _module(c, 2, const [], 0);
  }

  static Uint8List compile(IrBlock block, WasmEnv env) {
    final c = _Code();
    final insts = block.insts;
    bool wide(int v) => insts[v].type == IrType.i64;

    // SSA values occupy locals of their own width: i32 values and i32
    // temporaries first, then i64 values and i64 temporaries.
    final local = List<int>.filled(insts.length, 0);
    var count32 = 0, count64 = 0;
    for (var i = 0; i < insts.length; i++) {
      local[i] = wide(i) ? count64++ : count32++;
    }
    final address = count32, page = count32 + 1, temp = count32 + 2;
    final swap32 = count32 + 3, value32 = count32 + 4;
    final locals32 = count32 + 5;
    for (var i = 0; i < insts.length; i++) {
      if (wide(i)) local[i] += locals32;
    }
    final swap64 = locals32 + count64, value64 = swap64 + 1;
    final mulLow = swap64 + 2, mulMiddle = swap64 + 3;
    final locals64 = count64 + 4;
    void get(int v) => c.get(local[v]);

    void ctxLoad(int word, {bool wide = false}) {
      c.i32(env.ctxOffset + 4 * word);
      c.load(opcode: wide ? 0x29 : 0x28);
    }

    void ctxStore(int word, void Function() value, {bool wide = false}) {
      c.i32(env.ctxOffset + 4 * word);
      value();
      c.store(opcode: wide ? 0x37 : 0x36);
    }

    // Reverses the low [size] bytes of the i32 value on the stack.
    void reverse32(int size) {
      if (size == 1) return;
      c.set(swap32);
      if (size == 2) {
        c.get(swap32);
        c.i32(0xff);
        c.op(0x71);
        c.i32(8);
        c.op(0x74);
        c.get(swap32);
        c.i32(8);
        c.op(0x76);
        c.i32(0xff);
        c.op(0x71, 0x72);
        return;
      }
      c.get(swap32);
      c.i32(0x00ff00ff);
      c.op(0x71);
      c.i32(8);
      c.op(0x78); // rotr
      c.get(swap32);
      c.i32(8);
      c.op(0x77); // rotl
      c.i32(0x00ff00ff);
      c.op(0x71, 0x72);
    }

    // Reverses the bytes of the i64 value on the stack: swap bytes within
    // halfwords, halfwords within words, then the two words.
    void reverse64() {
      for (final (bits, mask) in [(8, 0x00ff00ff), (16, 0x0000ffff)]) {
        c.set(swap64);
        c.get(swap64);
        c.i64(mask, mask);
        c.op(0x83);
        c.i64(bits);
        c.op(0x86);
        c.get(swap64);
        c.i64(bits);
        c.op(0x88);
        c.i64(mask, mask);
        c.op(0x83, 0x84);
      }
      c.i64(32);
      c.op(0x89); // rotl
    }

    late void Function(int, int) link;
    void exit(
      int reason,
      int pc,
      int tag, {
      int refund = 0,
      bool linked = false,
      int? pcLocal,
      List<(int, IrValue)> stores = const [],
    }) {
      for (final (word, v) in stores) {
        ctxStore(word, () => get(v.index), wide: wide(v.index));
      }
      if (refund != 0) {
        ctxStore(JitCtx.budget, () {
          ctxLoad(JitCtx.budget);
          c.i32(refund);
          c.op(0x6a);
        });
      }
      if (linked) {
        link(pc, tag);
        return;
      }
      ctxStore(JitCtx.exitReason, () => c.i32(reason));
      ctxStore(
        JitCtx.exitPc,
        () => pcLocal == null ? c.i32(pc) : c.get(pcLocal),
      );
      ctxStore(JitCtx.exitTag, () => c.i32(tag));
      c.i32(0);
      c.op(0x0f);
    }

    link = (pc, tag) {
      c.i32(env.slots + 4 * env.slotFor(pc, tag));
      c.load();
      c.tee(page);
      c.op(0x45, 0x04, 0x40);
      exit(JitReason.miss, pc, tag);
      c.op(0x0b);
      c.get(page);
      c.op(0x0f);
    };

    void sideExit(IrExit e) => exit(
      e.reason,
      e.pc,
      e.tag,
      refund: e.refund(block.cost),
      stores: e.stores,
      linked: e.link,
    );
    void lookup(bool write) {
      c.i32(write ? env.writeTable : env.readTable);
      c.get(address);
      c.i32(env.addrMask);
      c.op(0x71);
      c.i32(env.pageShift);
      c.op(0x76);
      c.i32(2);
      c.op(0x74, 0x6a);
      c.load();
      c.set(page);
    }

    // leaves through e when the page looked up is unmapped, with the guest
    // address as the fault address
    void exitIfUnmapped(IrExit e) {
      c.get(page);
      c.op(0x45, 0x04, 0x40);
      ctxStore(JitCtx.faultAddr, () => c.get(address));
      sideExit(e);
      c.op(0x0b);
    }

    void hostAddress() {
      c.get(page);
      c.get(address);
      c.i32((1 << env.pageShift) - 1);
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
      // Compare with the raw little-endian word in linear memory.
      final v = g.value;
      c.i32(
        g.endian == IrEndian.big
            ? (v & 0xff) << 24 |
                  (v >>> 8 & 0xff) << 16 |
                  (v >>> 16 & 0xff) << 8 |
                  v >>> 24
            : v,
      );
      c.op(0x47, 0x04, 0x40);
      exit(JitReason.invalid, block.pc, block.tag);
      c.op(0x0b, 0x0b);
    }
    if (env.profileBlocks) {
      c.i32(0);
      c.i32(0);
      c.i32(0);
      c.call(2 + env.helperCount);
      c.op(0x1a);
    }
    ctxStore(JitCtx.budget, () {
      ctxLoad(JitCtx.budget);
      c.i32(block.cost);
      c.op(0x6b);
    });

    for (final (i, inst) in insts.indexed) {
      final w = inst.type == IrType.i64;
      void a() => get(inst.a);
      void b() => get(inst.b);
      void binary(int op32, int op64) {
        a();
        b();
        c.op(w ? op64 : op32);
      }

      void compare(int op32, int op64) {
        a();
        b();
        c.op(wide(inst.a) ? op64 : op32);
      }

      void shift(int op32, int op64) {
        a();
        b();
        if (w) c.op(0xad); // the i32 count as i64
        c.op(w ? op64 : op32);
      }

      switch (inst.op) {
        case IrOp.constant:
          w ? c.i64(inst.imm, inst.immHi) : c.i32(inst.imm);
        case IrOp.ctxLoad:
          ctxLoad(inst.imm, wide: w);
        case IrOp.ctxStore:
          ctxStore(inst.imm, a, wide: w);
        case IrOp.add:
          binary(0x6a, 0x7c);
        case IrOp.sub:
          binary(0x6b, 0x7d);
        case IrOp.mul:
          binary(0x6c, 0x7e);
        case IrOp.mulHiS || IrOp.mulHiU when !w:
          final extend = inst.op == IrOp.mulHiS ? 0xac : 0xad;
          a();
          c.op(extend);
          b();
          c.op(extend, 0x7e);
          c.i64(32);
          c.op(inst.op == IrOp.mulHiS ? 0x87 : 0x88, 0xa7);
        case IrOp.mulHiS || IrOp.mulHiU:
          // 32-bit limbs: high(a) * 2^32 + low(a), likewise for b.
          void low(void Function() v) {
            v();
            c.i64(0xffffffff);
            c.op(0x83);
          }

          void high(void Function() v) {
            v();
            c.i64(32);
            c.op(0x88);
          }

          high(a);
          low(b);
          c.op(0x7e);
          c.set(mulLow);
          low(a);
          high(b);
          c.op(0x7e);
          low(a);
          low(b);
          c.op(0x7e);
          c.i64(32);
          c.op(0x88, 0x7c);
          c.get(mulLow);
          c.i64(0xffffffff);
          c.op(0x83, 0x7c);
          c.set(mulMiddle);
          high(a);
          high(b);
          c.op(0x7e);
          c.get(mulLow);
          c.i64(32);
          c.op(0x88, 0x7c);
          c.get(mulMiddle);
          c.i64(32);
          c.op(0x88, 0x7c);
          if (inst.op == IrOp.mulHiS) {
            // signed = unsigned - (a < 0 ? b : 0) - (b < 0 ? a : 0)
            for (final (x, y) in [(b, a), (a, b)]) {
              x();
              c.i64(0);
              y();
              c.i64(0);
              c.op(0x53, 0x1b, 0x7d);
            }
          }
        case IrOp.and:
          binary(0x71, 0x83);
        case IrOp.or:
          binary(0x72, 0x84);
        case IrOp.xor:
          binary(0x73, 0x85);
        case IrOp.shl:
          shift(0x74, 0x86);
        case IrOp.shrS:
          shift(0x75, 0x87);
        case IrOp.shrU:
          shift(0x76, 0x88);
        case IrOp.eq:
          compare(0x46, 0x51);
        case IrOp.ne:
          compare(0x47, 0x52);
        case IrOp.ltS:
          compare(0x48, 0x53);
        case IrOp.ltU:
          compare(0x49, 0x54);
        case IrOp.select:
          b();
          get(inst.c);
          a();
          c.op(0x1b);
        case IrOp.sext8 || IrOp.sext16 || IrOp.zext8 || IrOp.zext16:
          a();
          // The operand may have either width.
          if (w && !wide(inst.a)) c.op(0xad);
          if (!w && wide(inst.a)) c.op(0xa7);
          switch (inst.op) {
            case IrOp.sext8:
              c.op(w ? 0xc2 : 0xc0);
            case IrOp.sext16:
              c.op(w ? 0xc3 : 0xc1);
            default:
              final mask = inst.op == IrOp.zext8 ? 0xff : 0xffff;
              w ? c.i64(mask) : c.i32(mask);
              c.op(w ? 0x83 : 0x71);
          }
        case IrOp.sext32:
          a();
          c.op(0xac);
        case IrOp.zext32:
          a();
          c.op(0xad);
        case IrOp.trunc32:
          a();
          c.op(0xa7);
        case IrOp.load:
          a();
          c.set(address);
          lookup(false);
          final size = inst.imm;
          // Both paths leave the raw little-endian bytes: an i64 for eight
          // bytes, otherwise the low bytes of an i32.
          void memory() {
            hostAddress();
            switch (size) {
              case 8:
                c.load(opcode: 0x29, align: 3);
              case 4:
                c.load();
              case 2:
                c.load(opcode: 0x2f, align: 1);
              default:
                c.load(opcode: 0x2d, align: 0);
            }
          }

          if (inst.exit >= 0) {
            exitIfUnmapped(block.exits[inst.exit]);
            memory();
          } else {
            c.get(page);
            c.op(0x04, size == 8 ? 0x7e : 0x7f);
            memory();
            c.op(0x05);
            // Eight bytes are read as two words in address order.
            for (final offset in size == 8 ? [0, 4] : [0]) {
              c.get(address);
              if (offset != 0) {
                c.i32(offset);
                c.op(0x6a);
              }
              c.i32(size == 8 ? 4 : size);
              c.i32(0);
              c.call(0);
              if (size == 8) c.op(0xad);
            }
            if (size == 8) {
              c.i64(32);
              c.op(0x86, 0x84);
            }
            c.op(0x0b);
          }
          if (inst.endian == IrEndian.big) {
            size == 8 ? reverse64() : reverse32(size);
          }
          if (size != 8) {
            final signed = inst.aux != 0;
            if (size < 4 && signed) {
              c.op(size == 1 ? 0xc0 : 0xc1);
            } else if (size < 4) {
              c.i32(size == 1 ? 0xff : 0xffff);
              c.op(0x71);
            }
            if (w) c.op(signed ? 0xac : 0xad);
          }
        case IrOp.store:
          a();
          c.set(address);
          lookup(true);
          final size = inst.imm;
          final value = size == 8 ? value64 : value32;
          b();
          if (size == 8) {
            if (inst.endian == IrEndian.big) reverse64();
          } else {
            if (w) c.op(0xa7);
            if (inst.endian == IrEndian.big) reverse32(size);
          }
          c.set(value);
          void memory() {
            hostAddress();
            c.get(value);
            switch (size) {
              case 8:
                c.store(opcode: 0x37, align: 3);
              case 4:
                c.store();
              case 2:
                c.store(opcode: 0x3b, align: 1);
              default:
                c.store(opcode: 0x3a, align: 0);
            }
          }

          if (inst.exit >= 0) {
            exitIfUnmapped(block.exits[inst.exit]);
            memory();
            break;
          }
          c.get(page);
          c.op(0x04, 0x40);
          memory();
          c.op(0x05);
          // Eight bytes are written as two words in address order.
          for (final offset in size == 8 ? [0, 4] : [0]) {
            c.get(address);
            if (offset != 0) {
              c.i32(offset);
              c.op(0x6a);
            }
            c.get(value);
            if (size == 8) {
              if (offset != 0) {
                c.i64(32);
                c.op(0x88);
              }
              c.op(0xa7);
            }
            c.i32(size == 8 ? 4 : size);
            c.call(1);
            c.op(0x1a);
          }
          c.op(0x0b);
        case IrOp.floatAdd || IrOp.floatSub || IrOp.floatMul:
          // binary32 widens to binary64 before the operation and rounds back.
          for (final v in [a, b]) {
            v();
            c.op(w ? 0xbf : 0xbe); // reinterpret as f64 / f32
            if (!w) c.op(0xbb); // f64.promote_f32
          }
          c.op(switch (inst.op) {
            IrOp.floatAdd => 0xa0,
            IrOp.floatSub => 0xa1,
            _ => 0xa2,
          });
          c.op(w ? 0xbd : 0xb6); // i64.reinterpret_f64 / f32.demote_f64
          if (!w) c.op(0xbc); // i32.reinterpret_f32
        case IrOp.floatConvert:
          a();
          w
              ? c.op(0xbe, 0xbb, 0xbd) // f32 bits -> f64 bits
              : c.op(0xbf, 0xb6, 0xbc); // f64 bits -> f32 bits, nearest
        case IrOp.floatToInt:
          a();
          wide(inst.a) ? c.op(0xbf) : c.op(0xbe, 0xbb);
          if (inst.imm == 0) c.op(0x9e); // f64.nearest
          c.op(0xfc); // i32.trunc_sat_f64_s
          c.u(2);
        case IrOp.call:
          a();
          b();
          get(inst.c);
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
          exitIfUnmapped(block.exits[inst.aux]);
      }
      if (irHasResult(inst.op)) c.set(local[i]);
    }

    switch (block.term) {
      case IrJump(:final pc, :final tag):
        link(pc, tag);
      case IrBranch t:
        get(t.cond.index);
        c.op(0x04, 0x40);
        link(t.pcTrue, t.tagTrue);
        c.op(0x05);
        link(t.pcFalse, t.tagFalse);
        c.op(0x0b);
      case IrJumpDyn(pc: final value, :final tag):
        get(value.index);
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
    return _module(c, 0, [
      (locals32, 0x7f),
      (locals64, 0x7e),
    ], 2 + env.helperCount + (env.profileBlocks ? 1 : 0));
  }

  static Uint8List _module(
    _Code code,
    int type,
    List<(int, int)> locals,
    int imports,
  ) {
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
    final groups = [
      for (final g in locals)
        if (g.$1 != 0) g,
    ];
    final body = _Code()..u(groups.length);
    for (final (count, type) in groups) {
      body.u(count);
      body.op(type);
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

  /// An exact i64 constant from 32-bit words, also on dart2js.
  void i64(int low, [int high = 0]) {
    op(0x42);
    var value =
        BigInt.from(high.toSigned(32)) << 32 | BigInt.from(low.toUnsigned(32));
    for (;;) {
      final b = (value & BigInt.from(0x7f)).toInt();
      value >>= 7;
      final done =
          (value == BigInt.zero && b & 0x40 == 0) ||
          (value == BigInt.from(-1) && b & 0x40 != 0);
      bytes.add(b | (done ? 0 : 0x80));
      if (done) return;
    }
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
