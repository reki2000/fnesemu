import 'dart:convert';
import 'dart:typed_data';

import '../dyn_table.dart';
import '../ir.dart';
import '../runtime.dart';

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

  /// a translation table and the linear-memory offset of its slots, each a
  /// 32-bit key followed by the 32-bit offset of its page
  JitTranslationTable translationTable(int id);
  int translationAddress(int id);

  /// Whether blocks call the import after the helpers at their entry.
  bool get profileBlocks;

  /// Whether the host supports Wasm fixed-width SIMD (v128).
  bool get simd;

  /// Whether the host supports Wasm tail calls (`return_call_indirect`).
  bool get tailCalls;

  int slotFor(int pc, int tag);
}

/// Emits baseline Wasm with i32 and i64 locals for SSA values. Big-endian
/// accesses reverse bytes around little-endian linear-memory operations. When
/// [WasmEnv.tailCalls] is enabled, blocks chain directly via
/// `return_call_indirect` and return the exit reason on exit; otherwise a
/// block returns the next table index (or zero to leave the dispatcher loop),
/// so guest loops never grow the host stack.
abstract final class WasmBackend {
  static const dynEntries = DynTable.entries;
  static int dynIndex(int pc, int tag) => DynTable.index(pc, tag);

  static Uint8List dispatcher(int ctx, {bool tailCalls = false}) {
    final c = _Code();
    if (tailCalls) {
      c.get(0);
      c.op(0x13);
      c.u(0);
      c.u(0); // return_call_indirect () -> i32
      c.op(0x0b);
      return _module(c, 2, const [], const []);
    }
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
    return _module(c, 2, const [], const []);
  }

  static Uint8List compile(IrBlock block, WasmEnv env) {
    final c = _Code();
    final importMap = <int, int>{};
    final importIds = <int>[];
    int importIndex(int id) => importMap.putIfAbsent(id, () {
      final index = importIds.length;
      importIds.add(id);
      return index;
    });
    final insts = block.insts;
    final fused = irFusedCompareConsumers(block);
    bool wide(int v) => insts[v].type == IrType.i64;
    bool vector(int v) => insts[v].type == IrType.v128;

    // The forms of each v128 value that its uses need: the bits, which
    // exits, memory and lane operations take, the binary64 values of the
    // images as two halves, which vector unit operations take, and the
    // flags of a vector unit operation. A value computes them where it is
    // defined.
    final needBits = List<bool>.filled(insts.length, false);
    final needDecoded = List<bool>.filled(insts.length, false);
    final needFlags = List<bool>.filled(insts.length, false);
    void exitNeeds(IrExit e) {
      for (final (_, v) in e.stores) {
        if (vector(v.index)) needBits[v.index] = true;
      }
    }

    block.exits.forEach(exitNeeds);
    if (block.term case IrExitTerm(:final exit)) exitNeeds(exit);
    for (var i = insts.length - 1; i >= 0; i--) {
      final inst = insts[i];
      switch (inst.op) {
        case IrOp.ctxStore when vector(inst.a):
          needBits[inst.a] = true;
        case IrOp.store when vector(inst.b):
          needBits[inst.b] = true;
        case IrOp.vExtract || IrOp.vInsert || IrOp.vShuffle || IrOp.vuItof:
          needBits[inst.a] = true;
        case IrOp.vuMax || IrOp.vuMin || IrOp.vuClip:
          needBits[inst.a] = needBits[inst.b] = true;
        case IrOp.vBlend:
          if (needBits[i]) needBits[inst.a] = needBits[inst.b] = true;
          if (needDecoded[i]) needDecoded[inst.a] = needDecoded[inst.b] = true;
        case IrOp.vuAdd || IrOp.vuSub || IrOp.vuMul:
          needDecoded[inst.a] = needDecoded[inst.b] = true;
        case IrOp.vuMadd || IrOp.vuMsub:
          needDecoded[inst.a] = needDecoded[inst.b] = true;
          needDecoded[inst.c] = true;
        case IrOp.vuMac:
          needFlags[inst.a] = true;
        case IrOp.vuFtoi:
          needDecoded[inst.a] = true;
        default:
      }
    }

    // SSA values occupy locals of their own width: i32 values, the flags
    // of vector unit operations and i32 temporaries first, then i64 values
    // and i64 temporaries, then v128 values, v128 temporaries and the
    // binary64 halves of v128 values.
    final local = List<int>.filled(insts.length, 0);
    var count32 = 0, count64 = 0, count128 = 0;
    for (var i = 0; i < insts.length; i++) {
      local[i] = vector(i)
          ? count128++
          : wide(i)
              ? count64++
              : count32++;
    }
    final flagLocal = List<int>.filled(insts.length, -1);
    final decodedLocal = List<int>.filled(insts.length, -1);
    var flagCount = 0, decodedCount = 0;
    for (var i = 0; i < insts.length; i++) {
      if (needFlags[i]) flagLocal[i] = count32 + flagCount++;
      if (needDecoded[i]) decodedLocal[i] = 2 * decodedCount++;
    }
    final scratch32 = count32 + flagCount;
    final address = scratch32, page = scratch32 + 1, temp = scratch32 + 2;
    final swap32 = scratch32 + 3, value32 = scratch32 + 4;
    final locals32 = scratch32 + 5;
    for (var i = 0; i < insts.length; i++) {
      if (wide(i)) local[i] += locals32;
    }
    final swap64 = locals32 + count64, value64 = swap64 + 1;
    final mulLow = swap64 + 2, mulMiddle = swap64 + 3;
    final locals64 = count64 + 4;
    final vectorBase = locals32 + locals64;
    for (var i = 0; i < insts.length; i++) {
      if (vector(i)) local[i] += vectorBase;
    }
    // v128 temporaries
    final t = [for (var k = 0; k < 8; k++) vectorBase + count128 + k];
    final decodedBase = vectorBase + count128 + t.length;
    final locals128 =
        count128 == 0 ? 0 : count128 + t.length + 2 * decodedCount;
    void get(int v) => c.get(local[v]);
    int decoded(int v, int half) => decodedBase + decodedLocal[v] + half;

    // Emit a single-use comparison directly onto the Wasm if condition
    // stack instead of materializing it in a local and loading it again.
    void emitCondition(int v) {
      if (fused[v] < 0) {
        get(v);
        return;
      }
      final cmp = insts[v];
      get(cmp.a);
      get(cmp.b);
      c.op(switch (cmp.op) {
        IrOp.eq => wide(cmp.a) ? 0x51 : 0x46,
        IrOp.ne => wide(cmp.a) ? 0x52 : 0x47,
        IrOp.ltS => wide(cmp.a) ? 0x53 : 0x48,
        IrOp.ltU => wide(cmp.a) ? 0x54 : 0x49,
        IrOp.and => wide(cmp.a) ? 0x83 : 0x71,
        _ => throw StateError('not a fused condition'),
      });
    }

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
        if (vector(v.index)) {
          c.i32(env.ctxOffset + 4 * word);
          get(v.index);
          c.simd(0x0b);
          c.u(2);
          c.u(0);
          continue;
        }
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
      c.i32(env.tailCalls ? reason : 0);
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
      if (env.tailCalls) {
        c.op(0x13);
        c.u(0);
        c.u(0); // return_call_indirect () -> i32
      } else {
        c.op(0x0f);
      }
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

    // Like lookup, through the translation of inst for an address outside
    // the table's direct window, leaving through e when its slot misses.
    void translatedLookup(IrInst inst, bool write, IrExit e) {
      final id = inst.translationTable;
      final t = env.translationTable(id);
      final windowed = t.directEnd > t.directStart;
      if (windowed) {
        c.get(address);
        c.i32(t.directStart);
        c.op(0x6b);
        c.i32(t.directEnd - t.directStart);
        c.op(0x49, 0x04, 0x40);
        lookup(write);
        exitIfUnmapped(e);
        c.op(0x05);
      }
      c.i32(env.translationAddress(id));
      c.get(address);
      c.i32(env.pageShift);
      c.op(0x76);
      final hash = t.slotHash(inst.translationKey) & (t.slots - 1);
      if (hash != 0) {
        c.i32(hash);
        c.op(0x73);
      }
      c.i32(t.slots - 1);
      c.op(0x71);
      c.i32(3);
      c.op(0x74, 0x6a);
      c.set(temp);
      c.get(temp);
      c.load();
      c.get(address);
      c.i32(~((1 << env.pageShift) - 1));
      c.op(0x71);
      c.i32(inst.translationKey);
      c.op(0x72, 0x47, 0x04, 0x40);
      ctxStore(JitCtx.faultAddr, () => c.get(address));
      sideExit(e);
      c.op(0x0b);
      c.get(temp);
      c.load(offset: 4);
      c.set(page);
      if (windowed) c.op(0x0b);
    }

    // four 32-bit lanes of two binary64 lanes of the words [low], [high]
    List<int> lanes64(int low, int high) => [low, high, low, high];

    // i8x16.shuffle of the two vectors on the stack by 32-bit lanes, 0 to
    // 3 of the first and 4 to 7 of the second
    void shuffle(List<int> lanes) {
      c.simd(0x0d);
      for (final l in lanes) {
        for (var k = 0; k < 4; k++) {
          c.op(4 * l + k);
        }
      }
    }

    /// The lanes of the encoded images of the binary64 lanes in the locals
    /// [low] (lanes 0 and 1) and [high] (lanes 2 and 3) in temporaries:
    /// t0 the image bits below single precision shifted into place (unless
    /// [reversed]), t1 the high words, t3 the underflows, t4 the zeros and
    /// t5 the overflows, in lane order or [reversed].
    void encodeLanes(int low, int high, {required bool reversed}) {
      final order = reversed ? const [3, 2, 1, 0] : const [0, 1, 2, 3];
      void pick(List<int> words) {
        shuffle([for (final o in order) words[o]]);
      }

      c.get(low);
      c.get(high);
      pick(const [1, 3, 5, 7]);
      c.set(t[1]);
      if (!reversed) {
        c.get(low);
        c.i32(29);
        c.simd(0xcd); // i64x2.shr_u
        c.get(high);
        c.i32(29);
        c.simd(0xcd);
        pick(const [0, 2, 4, 6]);
        c.v128(const [896 << 23, 896 << 23, 896 << 23, 896 << 23]);
        c.simd(0xb1);
        c.set(t[0]);
      }
      c.get(t[1]);
      c.v128(const [0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff]);
      c.simd(0x4e);
      c.set(t[2]); // the magnitude of the high words
      c.get(t[2]);
      c.get(low);
      c.get(high);
      pick(const [0, 2, 4, 6]);
      c.simd(0x50);
      c.v128(const [0, 0, 0, 0]);
      c.simd(0x37);
      c.set(t[3]); // zero values
      c.get(t[2]);
      c.v128(const [897 << 20, 897 << 20, 897 << 20, 897 << 20]);
      c.simd(0x39);
      c.set(t[4]);
      c.get(t[2]);
      c.v128(const [
        (1152 << 20) - 1,
        (1152 << 20) - 1,
        (1152 << 20) - 1,
        (1152 << 20) - 1
      ]);
      c.simd(0x3b);
      c.set(t[5]);
      c.get(t[4]);
      c.get(t[3]);
      c.simd(0x4f);
      c.set(t[3]);
    }

    /// the binary64 halves of the images of [v] to its decoded locals; each
    /// binary64 lane takes its image in both words, which puts the sign at
    /// bit 63
    void decodeAt(int v) {
      if (!needDecoded[v]) return;
      final splat = insts[v].op == IrOp.vSplat;
      for (var half = 0; half < (splat ? 1 : 2); half++) {
        final h = half * 2;
        get(v);
        get(v);
        shuffle([h, h, h + 1, h + 1]);
        c.set(t[0]);
        c.get(t[0]);
        c.v128(lanes64(0x7fffffff, 0));
        c.simd(0x4e);
        c.i32(29);
        c.simd(0xcb); // i64x2.shl
        c.v128(lanes64(0, 896 << 20));
        c.simd(0xce); // i64x2.add
        c.get(t[0]);
        c.v128(lanes64(0, 0x80000000));
        c.simd(0x4e);
        c.simd(0x50);
        c.get(t[0]);
        c.v128(lanes64(0x7f800000, 0));
        c.simd(0x4e);
        c.v128(const [0, 0, 0, 0]);
        c.simd(0x37); // i32x4.eq
        c.set(t[1]);
        c.get(t[1]);
        c.get(t[1]);
        shuffle(const [0, 0, 2, 2]);
        c.simd(0x4f); // andnot
        c.set(decoded(v, half));
      }
      if (splat) {
        c.get(decoded(v, 0));
        c.set(decoded(v, 1));
      }
    }

    /// pushes half [half] of the binary64 lanes [lanes] of [v], as
    /// [IrOp.vShuffle] selects them
    void decodedLanes(int v, int lanes, int half) {
      final p = (lanes >> 4 * half) & 3, q = (lanes >> 4 * half + 2) & 3;
      c.get(decoded(v, p >> 1));
      if (p.isEven && q == p + 1) return;
      c.get(decoded(v, q >> 1));
      shuffle([2 * (p & 1), 2 * (p & 1) + 1, 4 + 2 * (q & 1), 5 + 2 * (q & 1)]);
    }

    /// The forms and the flags of the vector unit result [i] from its
    /// binary64 lanes in t6 (lanes 0 and 1) and t7 (lanes 2 and 3); leaves
    /// the bits, or zero when no use needs them.
    void vuResult(int i) {
      encodeLanes(t[6], t[7], reversed: false);
      if (needDecoded[i]) {
        // the zeros are +0, the bits below single precision are dropped,
        // and an overflow is the largest magnitude of its sign
        for (var half = 0; half < 2; half++) {
          final h = 2 * half, r = t[6 + half];
          void expand(int mask) {
            c.get(mask);
            c.get(mask);
            shuffle([h, h, h + 1, h + 1]);
          }

          c.get(r);
          c.v128(lanes64(0xe0000000, 0xffffffff));
          c.simd(0x4e);
          expand(t[4]);
          c.simd(0x4f); // andnot
          c.get(r);
          c.v128(lanes64(0, 0x80000000));
          c.simd(0x4e);
          c.v128(lanes64(0xe0000000, 0x47ffffff));
          c.simd(0x50);
          // the overflow, else the truncated value
          c.set(t[2]);
          c.set(r);
          c.get(t[2]);
          c.get(r);
          expand(t[5]);
          c.simd(0x52); // bitselect
          c.set(decoded(i, half));
        }
      }
      if (needFlags[i]) {
        var first = true;
        for (final (v, shift) in [(t[4], 0), (t[1], 4), (t[3], 8), (t[5], 12)]) {
          c.get(v);
          c.get(v);
          shuffle(const [3, 2, 1, 0]);
          c.simd(0xa4); // i32x4.bitmask
          if (shift != 0) {
            c.i32(shift);
            c.op(0x74);
          }
          if (!first) c.op(0x72);
          first = false;
        }
        c.set(flagLocal[i]);
      }
      if (!needBits[i]) {
        c.v128(const [0, 0, 0, 0]);
        return;
      }
      // the bits of a normal image, the sign, and the largest magnitude of
      // an overflow
      c.get(t[0]);
      c.get(t[4]);
      c.get(t[5]);
      c.simd(0x50);
      c.simd(0x4f);
      c.get(t[1]);
      c.v128(const [0x80000000, 0x80000000, 0x80000000, 0x80000000]);
      c.simd(0x4e);
      c.simd(0x50);
      c.get(t[5]);
      c.i32(1);
      c.simd(0xad); // i32x4.shr_u
      c.simd(0x50);
    }

    /// Replaces the vector on the stack, pushed by [value] as well, by the
    /// vuMax key of its lanes: the magnitude, negated for a sign, and 0
    /// for an exponent 0.
    void imageKey(void Function() value) {
      c.v128(const [0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff]);
      c.simd(0x4e);
      value();
      c.i32(31);
      c.simd(0xac); // i32x4.shr_s
      c.tee(t[0]);
      c.simd(0x51);
      c.get(t[0]);
      c.simd(0xb1);
      value();
      c.v128(const [0x7f800000, 0x7f800000, 0x7f800000, 0x7f800000]);
      c.simd(0x4e);
      c.v128(const [0, 0, 0, 0]);
      c.simd(0x37);
      c.simd(0x4f);
    }

    ctxLoad(JitCtx.stop);
    ctxLoad(JitCtx.budget);
    c.i32(0);
    c.op(0x4c, 0x72);
    c.op(0x04, 0x40);
    exit(JitReason.budget, block.pc, block.tag);
    c.op(0x0b);
    if (block.guards.isNotEmpty) {
      int guardWord(IrGuard g) {
        final v = g.value;
        return g.endian == IrEndian.big
            ? (v & 0xff) << 24 |
                  (v >>> 8 & 0xff) << 16 |
                  (v >>> 16 & 0xff) << 8 |
                  v >>> 24
            : v;
      }

      final pageMask = (1 << env.pageShift) - 1;
      c.op(0x02, 0x40); // block $ok
      c.op(0x02, 0x40); // block $fail
      var gi = 0;
      while (gi < block.guards.length) {
        final pageIndex =
            (block.guards[gi].addr & env.addrMask) >>> env.pageShift;
        var pageEnd = gi + 1;
        while (pageEnd < block.guards.length &&
            ((block.guards[pageEnd].addr & env.addrMask) >>> env.pageShift) ==
                pageIndex) {
          pageEnd++;
        }
        c.i32(env.readTable + 4 * pageIndex);
        c.load();
        c.tee(page);
        c.op(0x04, 0x40); // if (page != 0)
        var k = gi;
        while (k < pageEnd) {
          final off = block.guards[k].addr & pageMask;
          if (env.simd &&
              k + 4 <= pageEnd &&
              (block.guards[k + 1].addr & pageMask) == off + 4 &&
              (block.guards[k + 2].addr & pageMask) == off + 8 &&
              (block.guards[k + 3].addr & pageMask) == off + 12) {
            c.get(page);
            c.simd(0x00); // v128.load
            c.u(2);
            c.u(off);
            c.v128([
              guardWord(block.guards[k]),
              guardWord(block.guards[k + 1]),
              guardWord(block.guards[k + 2]),
              guardWord(block.guards[k + 3]),
            ]);
            c.simd(0x38); // i32x4.ne
            c.simd(0x53); // v128.any_true
            c.op(0x0d, 1); // br_if $fail
            k += 4;
          } else if (k + 2 <= pageEnd &&
              (block.guards[k + 1].addr & pageMask) == off + 4) {
            c.get(page);
            c.load(opcode: 0x29, align: 2, offset: off); // i64.load
            c.i64(guardWord(block.guards[k]), guardWord(block.guards[k + 1]));
            c.op(0x52, 0x0d, 1); // i64.ne; br_if $fail
            k += 2;
          } else {
            c.get(page);
            c.load(offset: off); // i32.load
            c.i32(guardWord(block.guards[k]));
            c.op(0x47, 0x0d, 1); // i32.ne; br_if $fail
            k++;
          }
        }
        c.op(0x0b); // end if
        gi = pageEnd;
      }
      c.op(0x0c, 1); // br $ok
      c.op(0x0b); // end $fail
      exit(JitReason.invalid, block.pc, block.tag);
      c.op(0x0b); // end $ok
    }
    if (env.profileBlocks) {
      c.i32(0);
      c.i32(0);
      c.i32(0);
      c.call(importIndex(2 + env.helperCount));
      c.op(0x1a);
    }
    ctxStore(JitCtx.budget, () {
      ctxLoad(JitCtx.budget);
      c.i32(block.cost);
      c.op(0x6b);
    });

    for (final (i, inst) in insts.indexed) {
      if (fused[i] >= 0) continue;
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
        case IrOp.ctxLoad when inst.type == IrType.v128:
          c.i32(env.ctxOffset + 4 * inst.imm);
          c.simd(0x00);
          c.u(2);
          c.u(0);
        case IrOp.ctxStore when inst.type == IrType.v128:
          c.i32(env.ctxOffset + 4 * inst.imm);
          a();
          c.simd(0x0b);
          c.u(2);
          c.u(0);
        case IrOp.vSplat:
          a();
          c.simd(0x11);
        case IrOp.vExtract:
          a();
          c.simd(0x1b);
          c.op(inst.imm);
        case IrOp.vInsert:
          a();
          b();
          c.simd(0x1c);
          c.op(inst.imm);
        case IrOp.vShuffle:
          a();
          a();
          shuffle([for (var k = 0; k < 4; k++) (inst.imm >> 2 * k) & 3]);
        case IrOp.vBlend:
          if (needDecoded[i]) {
            for (var half = 0; half < 2; half++) {
              final m = (inst.imm >> 2 * half) & 3;
              final low = m & 1 != 0 ? inst.b : inst.a;
              final high = m & 2 != 0 ? inst.b : inst.a;
              c.get(decoded(low, half));
              if (low != high) {
                c.get(decoded(high, half));
                shuffle(const [0, 1, 6, 7]);
              }
              c.set(decoded(i, half));
            }
          }
          if (needBits[i]) {
            b();
            a();
            c.v128([
              for (var k = 0; k < 4; k++) inst.imm & (1 << k) != 0 ? -1 : 0
            ]);
            c.simd(0x52); // bitselect
          } else {
            c.v128(const [0, 0, 0, 0]);
          }
        case IrOp.vuAdd ||
              IrOp.vuSub ||
              IrOp.vuMul ||
              IrOp.vuMadd ||
              IrOp.vuMsub:
          for (var half = 0; half < 2; half++) {
            if (inst.c >= 0) c.get(decoded(inst.c, half));
            decodedLanes(inst.a, inst.imm & 0xff, half);
            decodedLanes(inst.b, inst.imm >> 8, half);
            c.simd(switch (inst.op) {
              IrOp.vuAdd => 0xf0, // f64x2.add
              IrOp.vuSub => 0xf1, // f64x2.sub
              _ => 0xf2, // f64x2.mul
            });
            if (inst.op == IrOp.vuMadd) c.simd(0xf0);
            if (inst.op == IrOp.vuMsub) c.simd(0xf1);
            c.set(t[6 + half]);
          }
          vuResult(i);
        case IrOp.vuMac:
          c.get(flagLocal[inst.a]);
        case IrOp.vuItof:
          for (var half = 0; half < 2; half++) {
            a();
            if (half == 1) {
              a();
              shuffle(const [2, 3, 2, 3]);
            }
            c.simd(0xfe); // f64x2.convert_low_i32x4_s
            if (inst.imm != 0) {
              c.v128(lanes64(0, (1023 - inst.imm) << 20));
              c.simd(0xf2);
            }
            c.set(t[6 + half]);
          }
          vuResult(i);
        case IrOp.vuFtoi:
          // saturated to the limits of the sign
          for (var half = 0; half < 2; half++) {
            c.get(decoded(inst.a, half));
            if (inst.imm != 0) {
              c.v128(lanes64(0, (1023 + inst.imm) << 20));
              c.simd(0xf2);
            }
            c.simd(0xfc); // i32x4.trunc_sat_f64x2_s_zero
          }
          shuffle(const [0, 1, 4, 5]);
        case IrOp.vuMax || IrOp.vuMin:
          b();
          a();
          a();
          imageKey(a);
          b();
          imageKey(b);
          if (inst.op == IrOp.vuMin) {
            c.set(t[0]);
            c.set(t[1]);
            c.get(t[0]);
            c.get(t[1]);
          }
          c.simd(0x39); // i32x4.lt_s: the lanes that take b
          c.simd(0x52);
        case IrOp.vuClip:
          b();
          b();
          shuffle(const [3, 3, 3, 3]);
          c.set(t[0]);
          c.get(t[0]);
          c.v128(const [0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff]);
          c.simd(0x4e);
          c.get(t[0]);
          c.v128(const [0x7f800000, 0x7f800000, 0x7f800000, 0x7f800000]);
          c.simd(0x4e);
          c.v128(const [0, 0, 0, 0]);
          c.simd(0x37);
          c.simd(0x4f);
          c.set(t[2]); // the limit
          a();
          imageKey(a);
          c.set(t[3]);
          c.get(t[3]);
          c.get(t[2]);
          c.simd(0x3b); // above: i32x4.gt_s
          c.set(t[4]);
          c.get(t[3]);
          c.v128(const [0, 0, 0, 0]);
          c.get(t[2]);
          c.simd(0xb1); // i32x4.sub
          c.simd(0x39); // below: i32x4.lt_s
          c.set(t[5]);
          // above and below interleaved by lane
          c.get(t[4]);
          c.get(t[5]);
          shuffle(const [0, 4, 1, 5]);
          c.simd(0xa4);
          c.get(t[4]);
          c.get(t[5]);
          shuffle(const [2, 6, 2, 6]);
          c.simd(0xa4);
          c.i32(3);
          c.op(0x71);
          c.i32(4);
          c.op(0x74, 0x72);
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
        case IrOp.divS || IrOp.divU || IrOp.remS || IrOp.remU:
          // WebAssembly traps on zero divisors and signed MIN / -1, unlike
          // our IR. Guard both paths before emitting the hardware operation.
          final signed = inst.op == IrOp.divS || inst.op == IrOp.remS;
          final remainder = inst.op == IrOp.remS || inst.op == IrOp.remU;
          final blockType = w ? 0x7e : 0x7f;
          void zero() {
            if (w) {
              c.i64(0);
            } else {
              c.i32(0);
            }
          }
          b();
          c.op(w ? 0x50 : 0x45); // i64/i32.eqz
          c.op(0x04, blockType);
          zero();
          c.op(0x05);
          if (signed) {
            a();
            if (w) {
              c.i64(0, 0x80000000);
            } else {
              c.i32(-0x80000000);
            }
            c.op(w ? 0x51 : 0x46);
            b();
            if (w) {
              c.i64(-1, -1);
            } else {
              c.i32(-1);
            }
            c.op(w ? 0x51 : 0x46, 0x71);
            c.op(0x04, blockType);
            if (remainder) {
              zero();
            } else {
              a(); // signed MIN / -1 = MIN after wrapping
            }
            c.op(0x05);
          }
          a();
          b();
          c.op(switch (inst.op) {
            IrOp.divS => w ? 0x7f : 0x6d,
            IrOp.divU => w ? 0x80 : 0x6e,
            IrOp.remS => w ? 0x81 : 0x6f,
            _ => w ? 0x82 : 0x70,
          });
          if (signed) c.op(0x0b);
          c.op(0x0b);
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
        case IrOp.load when inst.type == IrType.v128:
          a();
          c.set(address);
          lookup(false);
          if (inst.exit >= 0) {
            exitIfUnmapped(block.exits[inst.exit]);
            hostAddress();
            c.simd(0x00); // v128.load
            c.u(2);
            c.u(0);
          } else {
            c.get(page);
            c.op(0x04, 0x7b);
            hostAddress();
            c.simd(0x00);
            c.u(2);
            c.u(0);
            c.op(0x05);
            // the words through the callback in address order
            c.v128(const [0, 0, 0, 0]);
            for (var k = 0; k < 4; k++) {
              c.get(address);
              c.i32(4 * k);
              c.op(0x6a);
              c.i32(4);
              c.i32(0);
              c.call(importIndex(0));
              c.simd(0x1c); // i32x4.replace_lane
              c.op(k);
            }
            c.op(0x0b);
          }
        case IrOp.store when vector(inst.b):
          a();
          c.set(address);
          lookup(true);
          if (inst.exit >= 0) {
            exitIfUnmapped(block.exits[inst.exit]);
            hostAddress();
            b();
            c.simd(0x0b); // v128.store
            c.u(2);
            c.u(0);
            break;
          }
          c.get(page);
          c.op(0x04, 0x40);
          hostAddress();
          b();
          c.simd(0x0b);
          c.u(2);
          c.u(0);
          c.op(0x05);
          for (var k = 0; k < 4; k++) {
            c.get(address);
            c.i32(4 * k);
            c.op(0x6a);
            b();
            c.simd(0x1b); // i32x4.extract_lane
            c.op(k);
            c.i32(4);
            c.call(importIndex(1));
            c.op(0x1a);
          }
          c.op(0x0b);
        case IrOp.load:
          a();
          c.set(address);
          inst.translation >= 0
              ? translatedLookup(inst, false, block.exits[inst.exit])
              : lookup(false);
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
            if (inst.translation < 0) exitIfUnmapped(block.exits[inst.exit]);
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
              c.call(importIndex(0));
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
          inst.translation >= 0
              ? translatedLookup(inst, true, block.exits[inst.exit])
              : lookup(true);
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
            if (inst.translation < 0) exitIfUnmapped(block.exits[inst.exit]);
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
            c.call(importIndex(1));
            c.op(0x1a);
          }
          c.op(0x0b);
        case IrOp.floatAdd || IrOp.floatSub || IrOp.floatMul || IrOp.floatDiv:
          // binary32 widens to binary64 before the operation and rounds back.
          for (final v in [a, b]) {
            v();
            c.op(w ? 0xbf : 0xbe); // reinterpret as f64 / f32
            if (!w) c.op(0xbb); // f64.promote_f32
          }
          c.op(switch (inst.op) {
            IrOp.floatAdd => 0xa0,
            IrOp.floatSub => 0xa1,
            IrOp.floatMul => 0xa2,
            _ => 0xa3,
          });
          c.op(w ? 0xbd : 0xb6); // i64.reinterpret_f64 / f32.demote_f64
          if (!w) c.op(0xbc); // i32.reinterpret_f32
        case IrOp.floatSqrt:
          a();
          c.op(w ? 0xbf : 0xbe); // reinterpret as f64 / f32
          if (!w) c.op(0xbb); // f64.promote_f32
          c.op(0x9f); // f64.sqrt
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
          c.call(importIndex(2 + inst.imm));
        case IrOp.exitIf:
          emitCondition(inst.a);
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
      if (vector(i) &&
          !irIsVuArithmetic(inst.op) &&
          inst.op != IrOp.vuItof &&
          inst.op != IrOp.vBlend) {
        decodeAt(i);
      }
    }

    switch (block.term) {
      case IrJump(:final pc, :final tag):
        link(pc, tag);
      case IrBranch t:
        emitCondition(t.cond.index);
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
        c.i32(DynTable.pcShift);
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
        if (env.tailCalls) {
          c.op(0x13);
          c.u(0);
          c.u(0); // return_call_indirect () -> i32
        } else {
          c.op(0x0f);
        }
      case IrExitTerm(:final exit):
        sideExit(exit);
    }
    c.i32(0);
    c.op(0x0b);
    return _module(c, 0, [
      (locals32, 0x7f),
      (locals64, 0x7e),
      (locals128, 0x7b),
    ], importIds);
  }

  static Uint8List _module(
    _Code code,
    int type,
    List<(int, int)> locals,
    List<int> importIds,
  ) {
    final imports = importIds.length;
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
    for (final id in importIds) {
      im.name('env');
      im.name('f$id');
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

  /// a SIMD instruction
  void simd(int opcode) {
    op(0xfd);
    u(opcode);
  }

  /// v128.const of four 32-bit lanes
  void v128(List<int> lanes) {
    simd(0x0c);
    for (final l in lanes) {
      for (var k = 0; k < 4; k++) {
        op((l >> 8 * k) & 0xff);
      }
    }
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
