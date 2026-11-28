import '../dyn_table.dart';
import '../ir.dart';
import '../native_env.dart';
import 'allocation.dart';
import 'assembler.dart';

/// AAPCS64 code generation, also used by the ARM64 desktop ABIs.
/// X19-X23 hold runtime pointers; X18 and V8-V15 are untouched.
/// SSA spill slots survive every helper and unmapped-memory callback.
/// X24-X28 and X8-X15 hold values that [Arm64Allocation] assigns.
/// V16-V31 hold copies of v128 values until a host call, and V0-V7 are
/// temporaries.
abstract final class Arm64Backend {
  static const maxValues = 4096;

  /// the v128 values of a block
  static const maxVectors = 1024;

  /// The v128 value slots, above the scalar slots: the bits of a value,
  /// then the flags of a vector unit operation.
  static const _vectorSlots = 16 + maxValues * 8;
  static const _vectorSlot = 32;
  static const frame = _vectorSlots + maxVectors * _vectorSlot;
  static const saved = [
    (19, 20),
    (21, 22),
    (23, 24),
    (25, 26),
    (27, 28),
    (29, 30),
  ];

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
    final fused = irFusedCompareConsumers(block, selects: true);
    final registers = Arm64Allocation(block, fused).registers;
    final insts = block.insts;
    bool wide(int v) => insts[v].type == IrType.i64;
    bool vector(int v) => insts[v].type == IrType.v128;

    // The slots of the v128 values are numbered densely.
    final vectorIndex = List<int>.filled(insts.length, -1);
    var vectorCount = 0;
    for (var v = 0; v < insts.length; v++) {
      if (vector(v)) vectorIndex[v] = vectorCount++;
    }
    if (vectorCount > maxVectors) {
      throw StateError('block too long: $vectorCount vector values');
    }
    int vectorSlot(int v) => _vectorSlots + _vectorSlot * vectorIndex[v];
    // the vector unit operations whose flags are read, and the last use of
    // each v128 value
    final needFlags = List<bool>.filled(insts.length, false);
    final vectorUse = List<int>.filled(insts.length, -1);
    for (var i = 0; i < insts.length; i++) {
      final inst = insts[i];
      if (inst.op == IrOp.vuMac) needFlags[inst.a] = true;
      for (final x in [inst.a, inst.b, inst.c]) {
        if (x >= 0 && x < i && vector(x)) vectorUse[x] = i;
      }
    }

    // V16 to V31 are copies of the forms of v128 values: the key 4 * v is
    // the bits of v, and 4 * v + 1 + half the binary64 values of a half of
    // its lanes. The slots hold the bits all the same, which exits, stubs
    // and the code after a host call read.
    const firstCopy = 16, copies = 16;
    final copyKey = List<int>.filled(copies, -1);
    final copyStamp = List<int>.filled(copies, 0);
    final copyOf = <int, int>{};
    var stamp = 0, at = 0, opStamp = 0;

    /// the copy of [key], or null
    int? copy(int key) {
      final c = copyOf[key];
      if (c == null) return null;
      copyStamp[c] = ++stamp;
      return firstCopy + c;
    }

    /// a copy for [key]: its own, a dead one, or the one used least
    /// recently, which is not one that the current operation reads
    int claim(int key) {
      var c = copyOf[key];
      if (c == null) {
        var best = 0;
        for (var k = 0; k < copies; k++) {
          final other = copyKey[k];
          if (other < 0 || vectorUse[other >> 2] < at) {
            best = k;
            break;
          }
          if (copyStamp[k] < copyStamp[best]) best = k;
        }
        final other = copyKey[best];
        if (other >= 0) {
          if (copyStamp[best] > opStamp && vectorUse[other >> 2] >= at) {
            throw StateError('too many vector copies');
          }
          copyOf.remove(other);
        }
        c = best;
        copyKey[c] = key;
        copyOf[key] = c;
      }
      copyStamp[c] = ++stamp;
      return firstCopy + c;
    }

    void forget() {
      copyKey.fillRange(0, copies, -1);
      copyOf.clear();
    }

    /// the register with the bits of [v]
    int bits(int v) {
      final c = copy(4 * v);
      if (c != null) return c;
      final d = claim(4 * v);
      a.vmemory(true, d, 31, vectorSlot(v));
      return d;
    }

    /// Writes the bits of [v] to its slot from [d], its copy.
    void putBits(int v, int d) => a.vmemory(false, d, 31, vectorSlot(v));

    void lanes32(int q, int x) => a.vconstant(q, [x, x, x, x]);
    void lanes64(int q, int x) => a.vconstant(q, [x, x >> 32, x, x >> 32]);

    /// the binary64 values of half [half] of the lanes of [v], with the
    /// temporaries V2, V3 and V7
    int decoded(int v, int half) {
      final c = copy(4 * v + 1 + half);
      if (c != null) return c;
      final x = bits(v);
      // an exponent 0 is the value +0
      lanes32(7, 0x7f800000);
      a.v3(V.and, 2, x, 7);
      a.v2(V.cmeq0, 2, 2);
      a.v3(V.bic, 2, x, 2);
      lanes32(7, 0x7fffffff);
      a.v3(V.and, 3, 2, 7);
      a.v3(V.eor, 2, 2, 3);
      // The magnitude shifted into a binary64 keeps its exponent field, so
      // that a multiplication by 2^896 gives its value exactly; then the
      // sign.
      final lo = claim(4 * v + 1), hi = claim(4 * v + 2);
      a.vushll(lo, 3, 29);
      a.vushll(hi, 3, 29, high: true);
      lanes64(7, (1023 + 896) << 52);
      a.v3(V.fmul2d, lo, lo, 7);
      a.v3(V.fmul2d, hi, hi, 7);
      a.vshll32(3, 2);
      a.v3(V.orr, lo, lo, 3);
      a.vshll32(3, 2, high: true);
      a.v3(V.orr, hi, hi, 3);
      return half == 0 ? lo : hi;
    }

    /// the binary64 values of half [half] of the lanes [lanes] of [v], as
    /// [IrOp.vShuffle] selects them, in a copy or in [temp]
    int selected(int v, int lanes, int half, int temp) {
      final p = (lanes >> 4 * half) & 3, q = (lanes >> 4 * half + 2) & 3;
      final x = decoded(v, p >> 1), y = decoded(v, q >> 1);
      if (p & 1 == 0 && q == p + 1) return x;
      a.vdupLane64(temp, x, p & 1);
      if (q != p) a.vins64(temp, 1, y, q & 1);
      return temp;
    }

    /// The images of the binary64 values in V0 (lanes 0 and 1) and V1
    /// (lanes 2 and 3), truncated, as the bits of [v], and their flags when
    /// [IrOp.vuMac] reads them.
    void encode(int v) {
      a.v3(V.uzp2, 2, 0, 1); // the high words
      a.v3(V.uzp1, 3, 0, 1); // the low words
      lanes32(7, 0x7fffffff);
      a.v3(V.and, 4, 2, 7);
      lanes32(7, 897 << 20);
      a.v3(V.cmhi4s, 5, 7, 4); // the zeros, below the smallest normal
      lanes32(7, (1152 << 20) - 1);
      a.v3(V.cmhi4s, 6, 4, 7); // the overflows
      // the bits of a normal image: the exponent rebiased and the fraction
      // truncated
      a.vshl(0, 2, 3);
      a.vsri(0, 3, 29);
      lanes32(7, 896 << 23);
      a.v3(V.sub4s, 0, 0, 7);
      final d = claim(4 * v);
      a.v3(V.bic, d, 0, 5);
      a.v3(V.orr, d, d, 6);
      lanes32(7, 0x80000000);
      a.v3(V.bit, d, 2, 7);
      putBits(v, d);
      if (!needFlags[v]) return;
      a.v3(V.orr, 1, 4, 3);
      a.v3(V.cmtst4s, 1, 1, 1);
      a.v3(V.and, 1, 1, 5); // the underflows
      a.v2(V.cmlt0, 3, 2); // the signs
      // the bit of lane k of each mask, at 3 - k of its group
      for (final (x, group) in const [(5, 0), (3, 4), (1, 8), (6, 12)]) {
        a.vconstant(7, [for (var k = 0; k < 4; k++) 1 << (group + 3 - k)]);
        a.v3(V.and, x, x, 7);
      }
      a.v3(V.orr, 5, 5, 3);
      a.v3(V.orr, 1, 1, 6);
      a.v3(V.orr, 5, 5, 1);
      a.v2(V.addv4s, 5, 5);
      a.vumov(0, 5, 0);
      a.memory(false, 0, 31, vectorSlot(v) + 16, size: 4);
    }

    /// The [IrOp.vuMax] key of each lane of [x] into [k], with the
    /// temporaries [t], [u] and V7: the magnitude, negated for a sign, and
    /// 0 for an exponent 0.
    void imageKey(int k, int x, int t, int u) {
      lanes32(7, 0x7fffffff);
      a.v3(V.and, k, x, 7);
      a.v2(V.neg4s, t, k);
      a.v2(V.cmlt0, u, x);
      a.v3(V.bit, k, t, u);
      lanes32(7, 0x7f800000);
      a.v3(V.and, t, x, 7);
      a.v2(V.cmeq0, t, t);
      a.v3(V.bic, k, k, t);
    }
    void load(int reg, int value) {
      final i = block.insts[value];
      final r = registers[value];
      if (r >= 0) {
        if (r != reg) a.move(reg, r, wide: wide(value));
      } else if (i.op == IrOp.constant) {
        a.constant(
          reg,
          wide(value) ? (i.imm & 0xffffffff) | (i.immHi << 32) : i.imm,
          wide: wide(value),
        );
      } else {
        a.memory(true, reg, 31, 16 + 8 * value, size: wide(value) ? 8 : 4);
      }
    }

    void save(int reg, int value) {
      final r = registers[value];
      if (r < 0) {
        a.memory(false, reg, 31, 16 + 8 * value, size: wide(value) ? 8 : 4);
      } else if (r != reg) {
        a.move(r, reg, wide: wide(value));
      }
    }

    // the register that holds [value], loading it into [temp] when it has
    // none
    int source(int value, int temp) {
      final r = registers[value];
      if (r >= 0) return r;
      load(temp, value);
      return temp;
    }

    // the register to write [value] into, then [save] it from there
    int target(int value, int temp) {
      final r = registers[value];
      return r >= 0 ? r : temp;
    }

    int constValue(int value) {
      final i = block.insts[value];
      return wide(value) ? (i.imm & 0xffffffff) | (i.immHi << 32) : i.imm;
    }

    bool isConst(int value) => block.insts[value].op == IrOp.constant;

    /// Emits `CMP left, #imm` when [right] is a constant that fits in an
    /// A64 add/sub immediate (0..4095 or shifted 12-bit); returns whether
    /// it was emitted.
    bool emitCmpWithConst(int left, int right, {required bool isWide}) {
      if (!isConst(right)) return false;
      final u = isWide ? constValue(right) : (constValue(right) & 0xffffffff);
      if (u == 0) {
        a.cmp(left, 31, wide: isWide);
        return true;
      }
      if (u > 0 && u <= 4095) {
        a.cmpImmediate(left, u, wide: isWide);
        return true;
      }
      if (u > 0 && (u & ~0xfff000) == 0) {
        a.cmpImmediate(left, u >>> 12, shifted: true, wide: isWide);
        return true;
      }
      return false;
    }

    /// Emits `ADD`/`SUB d, src, #imm` when [constIdx] is a constant that fits
    /// in an A64 12-bit (or shifted 12-bit) immediate; returns whether emitted.
    bool emitAddSubImm(
      int d,
      int src,
      int constIdx, {
      required bool sub,
      required bool isWide,
    }) {
      if (!isConst(constIdx)) return false;
      final raw = constValue(constIdx);
      final c = isWide ? raw : raw.toSigned(32);
      if (c >= 0 && c <= 4095) {
        a.immediate(d, src, c, sub: sub, wide: isWide);
        return true;
      }
      if (c < 0 && c >= -4095) {
        a.immediate(d, src, -c, sub: !sub, wide: isWide);
        return true;
      }
      if (c > 0 && (c & ~0xfff000) == 0) {
        a.immediate(d, src, c >>> 12, sub: sub, shifted: true, wide: isWide);
        return true;
      }
      if (c < 0 && ((-c) & ~0xfff000) == 0) {
        a.immediate(
          d,
          src,
          (-c) >>> 12,
          sub: !sub,
          shifted: true,
          wide: isWide,
        );
        return true;
      }
      return false;
    }

    /// Emits a logical immediate (`0x12000000` AND, `0x32000000` ORR,
    /// `0x52000000` EOR, `0x72000000` ANDS) when [constIdx] is a representable
    /// A64 bitmask immediate; returns whether it was emitted.
    bool emitLogicalImm(
      int opcode,
      int d,
      int src,
      int constIdx, {
      required bool isWide,
    }) {
      if (!isConst(constIdx)) return false;
      final enc = Arm64Assembler.encodeLogicalImm(
        constValue(constIdx),
        wide: isWide,
      );
      if (enc == null) return false;
      a.logicalImmediate(opcode, d, src, enc, wide: isWide);
      return true;
    }

    /// Emits NZCV-setting comparison for a fused condition [cmp] and returns
    /// the A64 condition code that is true when [cmp] holds.
    int emitCompareFlags(IrInst cmp) {
      final isWide = wide(cmp.a);
      if (cmp.op == IrOp.and) {
        if (isConst(cmp.b) &&
            emitLogicalImm(
              0x72000000,
              31,
              source(cmp.a, 0),
              cmp.b,
              isWide: isWide,
            )) {
          return 1;
        }
        if (isConst(cmp.a) &&
            emitLogicalImm(
              0x72000000,
              31,
              source(cmp.b, 0),
              cmp.a,
              isWide: isWide,
            )) {
          return 1;
        }
        final left = source(cmp.a, 0), right = source(cmp.b, 1);
        // ANDS zero-register, lhs, rhs is a TST that sets NZCV.
        a.alu(0x6a000000, 31, left, right, wide: isWide);
        return 1;
      }
      final left = source(cmp.a, 0);
      if (!emitCmpWithConst(left, cmp.b, isWide: isWide)) {
        a.cmp(left, source(cmp.b, 1), wide: isWide);
      }
      return switch (cmp.op) {
        IrOp.eq => 0,
        IrOp.ne => 1,
        IrOp.ltS => 11,
        IrOp.ltU => 3,
        _ => throw StateError('not a fused condition'),
      };
    }

    int? singleBitIndex(int value, {required bool isWide}) {
      final v = isWide ? value : (value & 0xffffffff);
      if (v == 0 || (v & (v - 1)) != 0) return null;
      var bit = 0;
      var x = v;
      while ((x & 1) == 0) {
        x >>>= 1;
        bit++;
      }
      return bit;
    }

    void branchOnCondition(int v, Arm64Label dest, {required bool whenTrue}) {
      if (fused[v] >= 0) {
        final cmp = block.insts[v];
        final isWide = wide(cmp.a);
        if (cmp.op == IrOp.and && block.insts.length < 512) {
          int? bit;
          int? reg;
          if (isConst(cmp.b)) {
            bit = singleBitIndex(constValue(cmp.b), isWide: isWide);
            if (bit != null) reg = source(cmp.a, 0);
          } else if (isConst(cmp.a)) {
            bit = singleBitIndex(constValue(cmp.a), isWide: isWide);
            if (bit != null) reg = source(cmp.b, 0);
          }
          if (bit != null && reg != null) {
            if (whenTrue) {
              a.tbnz(reg, bit, dest);
            } else {
              a.tbz(reg, bit, dest);
            }
            return;
          }
        }
        if ((cmp.op == IrOp.eq || cmp.op == IrOp.ne) &&
            isConst(cmp.b) &&
            (isWide ? constValue(cmp.b) : (constValue(cmp.b) & 0xffffffff)) ==
                0) {
          final left = source(cmp.a, 0);
          final jumpIfZero = (cmp.op == IrOp.eq) == whenTrue;
          if (jumpIfZero) {
            a.cbz(left, dest, wide: isWide);
          } else {
            a.cbnz(left, dest, wide: isWide);
          }
          return;
        }
        if ((cmp.op == IrOp.eq || cmp.op == IrOp.ne) &&
            isConst(cmp.a) &&
            (isWide ? constValue(cmp.a) : (constValue(cmp.a) & 0xffffffff)) ==
                0) {
          final right = source(cmp.b, 0);
          final jumpIfZero = (cmp.op == IrOp.eq) == whenTrue;
          if (jumpIfZero) {
            a.cbz(right, dest, wide: isWide);
          } else {
            a.cbnz(right, dest, wide: isWide);
          }
          return;
        }
        final cc = emitCompareFlags(cmp);
        a.branch(dest, whenTrue ? cc : cc ^ 1);
      } else {
        final reg = source(v, 0);
        if (whenTrue) {
          a.cbnz(reg, dest);
        } else {
          a.cbz(reg, dest);
        }
      }
    }

    void budget(int delta) {
      a.memory(true, 0, 19, 4 * JitCtx.budget, size: 4);
      if (delta >= 0 && delta <= 4095) {
        a.immediate(0, 0, delta, wide: false);
      } else if (delta < 0 && delta >= -4095) {
        a.immediate(0, 0, -delta, sub: true, wide: false);
      } else {
        a.constant(1, delta);
        a.alu(0x0b000000, 0, 0, 1);
      }
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
        if (vector(v.index)) {
          a.vmemory(true, 0, 31, vectorSlot(v.index));
          a.vmemory(false, 0, 19, word * 4);
          continue;
        }
        a.memory(false, source(v.index, 0), 19, word * 4,
            size: wide(v.index) ? 8 : 4);
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
      a.cbz(0, miss, wide: true);
      a.emit(0xd61f0000);
    };

    final entryExit = stub(() => leave(JitReason.budget, block.pc, block.tag));
    a.memory(true, 0, 19, JitCtx.stop * 4, size: 4);
    a.cbnz(0, entryExit);
    a.memory(true, 0, 19, JitCtx.budget * 4, size: 4);
    a.cmp(0, 31);
    a.branch(entryExit, 13); // LE
    if (block.guards.isNotEmpty) {
      final invalid = stub(() => leave(JitReason.invalid, block.pc, block.tag));
      // Guarded words sorted by host address; adjacent 4-word runs compare in
      // 128-bit SIMD lanes and combine into V1, 2-word runs compare in 64 bits.
      final guarded = <(int, int)>[
        for (final g in block.guards)
          if (env.guardAddr(g.addr) case final host?)
            (
              host,
              g.endian == IrEndian.little
                  ? g.value & 0xffffffff
                  : ((g.value & 255) << 24) |
                      ((g.value & 0xff00) << 8) |
                      ((g.value >>> 8) & 0xff00) |
                      ((g.value >>> 24) & 255),
            ),
      ]..sort((x, y) => x.$1.compareTo(y.$1));
      int? base;
      int offsetFor(int host, int align) {
        if (base == null ||
            host < base! ||
            host - base! >= 4096 * align ||
            (host - base!) % align != 0) {
          base = host;
          a.constant(0, host, wide: true);
        }
        return host - base!;
      }

      var groups = 0;
      var k = 0;
      while (k < guarded.length) {
        final host = guarded[k].$1;
        if (k + 3 < guarded.length &&
            guarded[k + 1].$1 == host + 4 &&
            guarded[k + 2].$1 == host + 8 &&
            guarded[k + 3].$1 == host + 12) {
          final off = offsetFor(host, 16);
          final q = groups == 0 ? 1 : 0;
          a.vmemory(true, q, 0, off);
          a.vconstant(2, [for (var j = 0; j < 4; j++) guarded[k + j].$2]);
          a.v3(V.eor, q, q, 2);
          if (groups > 0) a.v3(V.orr, 1, 1, 0);
          groups++;
          k += 4;
          continue;
        }
        if (k + 1 < guarded.length && guarded[k + 1].$1 == host + 4) {
          final off = offsetFor(host, 8);
          a.memory(true, 1, 0, off);
          a.constant(
            2,
            guarded[k].$2 | (guarded[k + 1].$2 << 32),
            wide: true,
          );
          a.cmp(1, 2, wide: true);
          a.branch(invalid, 1);
          k += 2;
          continue;
        }
        final off = offsetFor(host, 4);
        a.memory(true, 1, 0, off, size: 4);
        a.constant(2, guarded[k].$2);
        a.cmp(1, 2);
        a.branch(invalid, 1);
        k++;
      }
      if (groups > 0) {
        a.v2(V.umaxv4s, 1, 1);
        a.vumov(1, 1, 0);
        a.cbnz(1, invalid);
      }
    }
    if (env.blockEntryFn != 0) {
      a.constant(16, env.blockEntryFn, wide: true);
      a.emit(0xd63f0200); // BLR x16
    }
    budget(-block.cost);

    final pageMask = (1 << env.pageShift) - 1;
    final addrMask = env.addrMask & 0xffffffff;
    final contiguousMask =
        addrMask != 0 && ((addrMask + 1) & addrMask) == 0;
    final addrBits = contiguousMask ? addrMask.bitLength : 0;
    final fullPageMask = (addrMask & pageMask) == pageMask;

    final addrMaskEnc = Arm64Assembler.encodeLogicalImm(addrMask);

    // [addr] retains the guest address, X5 is the mapped host address or null,
    // and X3 is the offset in the page when [needOffset] is true.
    void lookup(bool write, {int addr = 0, bool needOffset = true}) {
      if (contiguousMask && addrBits > env.pageShift && env.pageShift > 0) {
        a.ubfx(4, addr, env.pageShift, addrBits - env.pageShift);
        a.memoryIndexed(true, 5, write ? 21 : 20, 4, size: 8, scaled: true);
        if (needOffset) a.ubfx(3, addr, 0, env.pageShift);
      } else {
        if (addrMaskEnc != null) {
          a.logicalImmediate(0x12000000, 3, addr, addrMaskEnc);
        } else {
          a.constant(3, addrMask);
          a.alu(0x0a000000, 3, addr, 3);
        }
        if (env.pageShift > 0) {
          a.lsrImm(4, 3, env.pageShift);
        } else {
          a.move(4, 3);
        }
        a.memoryIndexed(true, 5, write ? 21 : 20, 4, size: 8, scaled: true);
        if (needOffset) {
          if (env.pageShift > 0) {
            a.ubfx(3, fullPageMask ? addr : 3, 0, env.pageShift);
          } else {
            a.constant(3, 0);
          }
        }
      }
    }

    // Like lookup, through the translation of i for an address outside the
    // table's direct window, branching to miss when its slot misses.
    void translatedLookup(
      IrInst i,
      bool write,
      Arm64Label miss, {
      int addr = 0,
    }) {
      final id = i.translationTable;
      final t = env.translationTable(id);
      final done = Arm64Label(), direct = Arm64Label();
      final windowed = t.directEnd > t.directStart;
      if (windowed) {
        a.constant(3, t.directStart);
        a.alu(0x4b000000, 3, addr, 3);
        a.constant(4, t.directEnd - t.directStart);
        a.cmp(3, 4);
        a.branch(direct, 3);
      }
      if (env.pageShift > 0) {
        a.lsrImm(4, addr, env.pageShift);
      } else {
        a.move(4, addr);
      }
      final hash = t.slotHash(i.translationKey) & (t.slots - 1);
      if (hash != 0) {
        final enc = Arm64Assembler.encodeLogicalImm(hash);
        if (enc != null) {
          a.logicalImmediate(0x52000000, 4, 4, enc);
        } else {
          a.constant(5, hash);
          a.alu(0x4a000000, 4, 4, 5);
        }
      }
      final slotBits = (t.slots - 1).bitLength;
      if (slotBits > 0) {
        a.ubfx(4, 4, 0, slotBits);
      } else {
        a.constant(4, 0);
      }
      a.lslImm(4, 4, 4);
      a.constant(5, env.translationAddress(id), wide: true);
      a.alu(0x0b000000, 4, 5, 4, wide: true);
      a.memory(true, 5, 4, 0, size: 4);
      final pageTagMask = ~pageMask & 0xffffffff;
      final tagMaskEnc = Arm64Assembler.encodeLogicalImm(pageTagMask);
      if (tagMaskEnc != null) {
        a.logicalImmediate(0x12000000, 6, addr, tagMaskEnc);
      } else {
        a.constant(6, pageTagMask);
        a.alu(0x0a000000, 6, addr, 6);
      }
      if (i.translationKey != 0) {
        final keyEnc = Arm64Assembler.encodeLogicalImm(i.translationKey);
        if (keyEnc != null) {
          a.logicalImmediate(0x32000000, 6, 6, keyEnc);
        } else {
          a.constant(7, i.translationKey);
          a.alu(0x2a000000, 6, 6, 7);
        }
      }
      a.cmp(6, 5);
      a.branch(miss, 1);
      a.memory(true, 5, 4, 8);
      if (env.pageShift > 0) {
        a.ubfx(3, addr, 0, env.pageShift);
      } else {
        a.constant(3, 0);
      }
      if (windowed) {
        a.branch(done);
        a.bind(direct);
        lookup(write, addr: addr);
        a.cbz(5, miss, wide: true);
        a.bind(done);
      }
    }

    void swap(int reg, int size, IrEndian endian) {
      if (endian == IrEndian.big && size > 1) a.reverse(reg, size);
    }

    void finishLoad(IrInst i) {
      swap(0, i.imm, i.endian);
      if (i.imm < 4 || (i.imm == 4 && i.type == IrType.i64 && i.aux != 0)) {
        a.extend(
          0,
          0,
          i.imm * 8,
          signed: i.aux != 0,
          wide: i.type == IrType.i64,
        );
      }
    }

    Arm64Label unmapped(IrExit e, [int addr = 0]) => stub(() {
      a.memory(false, addr, 19, 4 * JitCtx.faultAddr, size: 4);
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
      at = v;
      opStamp = stamp;
      void binary(int op) {
        final left = source(i.a, 0), right = source(i.b, 1);
        final d = target(v, 0);
        a.alu(op, d, left, right, wide: w);
        save(d, v);
      }

      void compare(int cc) {
        final isWide = wide(i.a);
        final left = source(i.a, 0);
        if (!emitCmpWithConst(left, i.b, isWide: isWide)) {
          a.cmp(left, source(i.b, 1), wide: isWide);
        }
        final d = target(v, 0);
        a.cset(d, cc);
        save(d, v);
      }

      switch (i.op) {
        case IrOp.vSplat:
          final x = source(i.a, 0), d = claim(4 * v);
          a.vdupGeneral(d, x);
          putBits(v, d);
        case IrOp.vExtract:
          final x = bits(i.a), d = target(v, 0);
          a.vumov(d, x, i.imm);
          save(d, v);
        case IrOp.vInsert:
          final x = bits(i.a), y = source(i.b, 0), d = claim(4 * v);
          a.vmov(d, x);
          a.vinsGeneral(d, i.imm, y);
          putBits(v, d);
        case IrOp.vShuffle:
          final x = bits(i.a), d = claim(4 * v), lanes = i.imm;
          if (lanes == 0xe4) {
            a.vmov(d, x);
          } else if (lanes == 0x55 * (lanes & 3)) {
            a.vdupLane(d, x, lanes & 3);
          } else {
            // the byte indexes of the lanes for TBL
            a.vconstant(7, [
              for (var k = 0; k < 4; k++)
                0x03020100 + 0x04040404 * ((lanes >> 2 * k) & 3),
            ]);
            a.v3(V.tbl, d, x, 7);
          }
          putBits(v, d);
        case IrOp.vBlend:
          final x = bits(i.a), y = bits(i.b), d = claim(4 * v);
          if (i.imm == 15) {
            a.vmov(d, y);
          } else {
            a.vmov(d, x);
            if (i.imm != 0) {
              a.vconstant(7, [
                for (var k = 0; k < 4; k++) i.imm & (1 << k) != 0 ? -1 : 0,
              ]);
              a.v3(V.bit, d, y, 7);
            }
          }
          putBits(v, d);
        case IrOp.vuAdd ||
            IrOp.vuSub ||
            IrOp.vuMul ||
            IrOp.vuMadd ||
            IrOp.vuMsub:
          // the binary64 results of the halves into V0 and V1, from the
          // selected lanes in copies or in V4 and V5
          final aLanes = i.imm & 0xff, bLanes = i.imm >> 8;
          for (var half = 0; half < 2; half++) {
            final x = selected(i.a, aLanes, half, 4);
            final y = selected(i.b, bLanes, half, 5);
            switch (i.op) {
              case IrOp.vuAdd:
                a.v3(V.fadd2d, half, x, y);
              case IrOp.vuSub:
                a.v3(V.fsub2d, half, x, y);
              case IrOp.vuMul:
                a.v3(V.fmul2d, half, x, y);
              default:
                // rounded after the product and after the sum, unfused
                a.v3(V.fmul2d, 6, x, y);
                a.v3(i.op == IrOp.vuMadd ? V.fadd2d : V.fsub2d, half,
                    decoded(i.c, half), 6);
            }
          }
          encode(v);
        case IrOp.vuMac:
          final d = target(v, 0);
          a.memory(true, d, 31, vectorSlot(i.a) + 16, size: 4);
          save(d, v);
        case IrOp.vuItof:
          final x = bits(i.a);
          a.vsxtl(2, x);
          a.vsxtl(3, x, high: true);
          a.vscvtf(0, 2, i.imm);
          a.vscvtf(1, 3, i.imm);
          encode(v);
        case IrOp.vuFtoi:
          // saturated to 64 bits, then to 32 bits
          a.vfcvtzs(0, decoded(i.a, 0), i.imm);
          a.vfcvtzs(1, decoded(i.a, 1), i.imm);
          final d = claim(4 * v);
          a.vsqxtn(d, 0);
          a.vsqxtn(d, 1, high: true);
          putBits(v, d);
        case IrOp.vuMax || IrOp.vuMin:
          final x = bits(i.a), y = bits(i.b);
          imageKey(2, x, 3, 4);
          imageKey(5, y, 3, 4);
          // the lanes that take b
          if (i.op == IrOp.vuMax) {
            a.v3(V.cmgt4s, 6, 5, 2);
          } else {
            a.v3(V.cmgt4s, 6, 2, 5);
          }
          final d = claim(4 * v);
          a.vmov(d, x);
          a.v3(V.bit, d, y, 6);
          putBits(v, d);
        case IrOp.vuClip:
          final x = bits(i.a), y = bits(i.b);
          // the limit, the magnitude of lane 3 of b, as a key
          a.vdupLane(2, y, 3);
          lanes32(7, 0x7fffffff);
          a.v3(V.and, 3, 2, 7);
          lanes32(7, 0x7f800000);
          a.v3(V.and, 4, 2, 7);
          a.v2(V.cmeq0, 4, 4);
          a.v3(V.bic, 3, 3, 4);
          imageKey(5, x, 4, 6);
          a.v3(V.cmgt4s, 4, 5, 3); // above
          a.v2(V.neg4s, 6, 3);
          a.v3(V.cmgt4s, 6, 6, 5); // below
          a.vconstant(7, const [1, 4, 16, 0]);
          a.v3(V.and, 4, 4, 7);
          a.vconstant(7, const [2, 8, 32, 0]);
          a.v3(V.and, 6, 6, 7);
          a.v3(V.orr, 4, 4, 6);
          a.v2(V.addv4s, 4, 4);
          final d = target(v, 0);
          a.vumov(d, 4, 0);
          save(d, v);
        case IrOp.ctxLoad when vector(v):
          final d = claim(4 * v);
          a.vmemory(true, d, 19, i.imm * 4);
          putBits(v, d);
        case IrOp.ctxStore when vector(i.a):
          a.vmemory(false, bits(i.a), 19, i.imm * 4);
        case IrOp.load when vector(v):
          // the callbacks read the words into the slot
          final done = Arm64Label();
          final slot = vectorSlot(v);
          final addr = source(i.a, 0);
          final slow = i.exit >= 0
              ? unmapped(block.exits[i.exit], addr)
              : stub(() {
                  a.memory(false, addr, 31, 0, size: 4);
                  for (var k = 0; k < 4; k++) {
                    a.memory(true, 0, 31, 0, size: 4);
                    if (k != 0) {
                      a.immediate(0, 0, 4 * k, wide: false);
                    }
                    a.constant(1, 4);
                    a.constant(2, 0);
                    a.call(env.readFn);
                    a.memory(false, 0, 31, slot + 4 * k, size: 4);
                  }
                  a.branch(done);
                });
          lookup(false, addr: addr);
          a.cbz(5, slow, wide: true);
          a.vmemoryIndexed(true, 0, 5, 3);
          a.vmemory(false, 0, 31, slot);
          a.bind(done);
          if (i.exit < 0) forget();
        case IrOp.store when vector(i.b):
          final done = Arm64Label();
          final slot = vectorSlot(i.b);
          final x = bits(i.b);
          final addr = source(i.a, 0);
          final slow = i.exit >= 0
              ? unmapped(block.exits[i.exit], addr)
              : stub(() {
                  a.memory(false, addr, 31, 0, size: 4);
                  for (var k = 0; k < 4; k++) {
                    a.memory(true, 0, 31, 0, size: 4);
                    if (k != 0) {
                      a.immediate(0, 0, 4 * k, wide: false);
                    }
                    a.memory(true, 1, 31, slot + 4 * k, size: 4);
                    a.constant(2, 4);
                    a.call(env.writeFn);
                  }
                  a.branch(done);
                });
          lookup(true, addr: addr);
          a.cbz(5, slow, wide: true);
          a.vmemoryIndexed(false, x, 5, 3);
          a.bind(done);
          if (i.exit < 0) forget();
        case IrOp.constant:
          break;
        case IrOp.ctxLoad:
          final d = target(v, 0);
          a.memory(true, d, 19, i.imm * 4, size: w ? 8 : 4);
          save(d, v);
        case IrOp.ctxStore:
          a.memory(false, source(i.a, 0), 19, i.imm * 4, size: w ? 8 : 4);
        case IrOp.add:
          final d = target(v, 0);
          if (isConst(i.b) &&
              emitAddSubImm(d, source(i.a, 0), i.b, sub: false, isWide: w)) {
            save(d, v);
          } else if (isConst(i.a) &&
              emitAddSubImm(d, source(i.b, 0), i.a, sub: false, isWide: w)) {
            save(d, v);
          } else {
            binary(0x0b000000);
          }
        case IrOp.sub:
          final d = target(v, 0);
          if (isConst(i.b) &&
              emitAddSubImm(d, source(i.a, 0), i.b, sub: true, isWide: w)) {
            save(d, v);
          } else {
            binary(0x4b000000);
          }
        case IrOp.and:
          if (fused[v] < 0) {
            final d = target(v, 0);
            if (isConst(i.b) &&
                emitLogicalImm(
                  0x12000000,
                  d,
                  source(i.a, 0),
                  i.b,
                  isWide: w,
                )) {
              save(d, v);
            } else if (isConst(i.a) &&
                emitLogicalImm(
                  0x12000000,
                  d,
                  source(i.b, 0),
                  i.a,
                  isWide: w,
                )) {
              save(d, v);
            } else {
              binary(0x0a000000);
            }
          }
        case IrOp.or:
          final d = target(v, 0);
          if (isConst(i.b) &&
              emitLogicalImm(0x32000000, d, source(i.a, 0), i.b, isWide: w)) {
            save(d, v);
          } else if (isConst(i.a) &&
              emitLogicalImm(0x32000000, d, source(i.b, 0), i.a, isWide: w)) {
            save(d, v);
          } else {
            binary(0x2a000000);
          }
        case IrOp.xor:
          final d = target(v, 0);
          if (isConst(i.b) &&
              emitLogicalImm(0x52000000, d, source(i.a, 0), i.b, isWide: w)) {
            save(d, v);
          } else if (isConst(i.a) &&
              emitLogicalImm(0x52000000, d, source(i.b, 0), i.a, isWide: w)) {
            save(d, v);
          } else {
            binary(0x4a000000);
          }
        case IrOp.mul:
          binary(0x1b007c00);
        case IrOp.divS || IrOp.divU || IrOp.remS || IrOp.remU:
          // AArch64 SDIV/UDIV do not trap: zero divisors yield a zero
          // quotient, and MIN / -1 wraps. Explicitly zero the remainder for
          // a zero divisor to match the common IR contract.
          load(0, i.a);
          load(1, i.b);
          final signed = i.op == IrOp.divS || i.op == IrOp.remS;
          a.alu(signed ? 0x1ac00c00 : 0x1ac00800, 2, 0, 1, wide: w);
          if (i.op == IrOp.remS || i.op == IrOp.remU) {
            // MSUB: dividend - quotient * divisor (modulo operand width).
            a.emit((w ? 0x9b008000 : 0x1b008000) |
                (1 << 16) | (2 << 5));
            a.cmp(1, 31, wide: w);
            a.select(0, 0, 31, 1, wide: w); // divisor != 0
            save(0, v);
          } else {
            save(2, v);
          }
        case IrOp.shl || IrOp.shrU || IrOp.shrS:
          if (isConst(i.b)) {
            final shift = constValue(i.b) & (w ? 63 : 31);
            final left = source(i.a, 0);
            final d = target(v, 0);
            if (shift == 0) {
              if (d != left) a.move(d, left, wide: w);
            } else if (i.op == IrOp.shl) {
              a.lslImm(d, left, shift, wide: w);
            } else if (i.op == IrOp.shrU) {
              a.lsrImm(d, left, shift, wide: w);
            } else {
              a.asrImm(d, left, shift, wide: w);
            }
            save(d, v);
          } else {
            binary(
              i.op == IrOp.shl
                  ? 0x1ac02000
                  : i.op == IrOp.shrU
                  ? 0x1ac02400
                  : 0x1ac02800,
            );
          }
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
            a.lsrImm(0, 0, 32, wide: true);
          }
          save(0, v);
        case IrOp.eq:
          if (fused[v] < 0) compare(0);
        case IrOp.ne:
          if (fused[v] < 0) compare(1);
        case IrOp.ltS:
          if (fused[v] < 0) compare(11);
        case IrOp.ltU:
          if (fused[v] < 0) compare(3);
        case IrOp.select:
          final int cc;
          if (fused[i.a] == v) {
            cc = emitCompareFlags(block.insts[i.a]);
          } else {
            a.cmp(source(i.a, 0), 31);
            cc = 1;
          }
          final yes = source(i.b, 1), no = source(i.c, 2);
          final d = target(v, 0);
          a.select(d, yes, no, cc, wide: w);
          save(d, v);
        case IrOp.sext8 ||
            IrOp.sext16 ||
            IrOp.zext8 ||
            IrOp.zext16 ||
            IrOp.sext32 ||
            IrOp.zext32 ||
            IrOp.trunc32:
          final from = source(i.a, 0), d = target(v, 0);
          final bits = switch (i.op) {
            IrOp.sext8 || IrOp.zext8 => 8,
            IrOp.sext16 || IrOp.zext16 => 16,
            _ => 32,
          };
          a.extend(
            d,
            from,
            bits,
            wide: w,
            signed:
                i.op == IrOp.sext8 ||
                i.op == IrOp.sext16 ||
                i.op == IrOp.sext32,
          );
          save(d, v);
        case IrOp.load:
          final done = Arm64Label();
          final addr = source(i.a, 0);
          final direct =
              i.endian == IrEndian.little &&
              (i.imm == 8 ||
                  (i.imm == 4 && (!w || i.aux == 0)) ||
                  (i.imm < 4 && i.aux == 0));
          final d = direct ? target(v, 0) : 0;
          final slow = i.exit >= 0
              ? unmapped(block.exits[i.exit], addr)
              : stub(() {
                  a.memory(false, addr, 31, 0, size: 4);
                  void part(int offset) {
                    a.memory(true, 0, 31, 0, size: 4);
                    if (offset != 0) {
                      a.immediate(0, 0, offset, wide: false);
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
                    a.lslImm(0, 0, 32, wide: true);
                    a.memory(true, 1, 31, 8);
                    a.alu(0x2a000000, 0, 0, 1, wide: true);
                  }
                  if (direct) {
                    if (i.imm < 4) a.extend(0, 0, i.imm * 8);
                    if (d != 0) a.move(d, 0, wide: w);
                  }
                  a.branch(done);
                });
          if (i.translation >= 0) {
            translatedLookup(i, false, slow, addr: addr);
          } else {
            lookup(false, addr: addr);
            a.cbz(5, slow, wide: true);
          }
          a.memoryIndexed(true, d, 5, 3, size: i.imm);
          a.bind(done);
          if (!direct) finishLoad(i);
          save(d, v);
          if (i.exit < 0) forget();
        case IrOp.store:
          final done = Arm64Label();
          final addr = source(i.a, 0);
          final slow = i.exit >= 0
              ? unmapped(block.exits[i.exit], addr)
              : stub(() {
                  a.memory(false, addr, 31, 0, size: 4);
                  load(0, i.b);
                  swap(0, i.imm, i.endian);
                  a.memory(false, 0, 31, 8);
                  void part(int offset) {
                    a.memory(true, 0, 31, 0, size: 4);
                    if (offset != 0) {
                      a.immediate(0, 0, offset, wide: false);
                    }
                    a.memory(true, 1, 31, 8 + offset, size: 4);
                    a.constant(2, i.imm == 8 ? 4 : i.imm);
                    a.call(env.writeFn);
                  }

                  part(0);
                  if (i.imm == 8) part(4);
                  a.branch(done);
                });
          if (i.translation >= 0) {
            translatedLookup(i, true, slow, addr: addr);
          } else {
            lookup(true, addr: addr);
            a.cbz(5, slow, wide: true);
          }
          if (i.endian == IrEndian.little || i.imm == 1) {
            final val = source(i.b, 0);
            a.memoryIndexed(false, val, 5, 3, size: i.imm);
          } else {
            load(0, i.b);
            swap(0, i.imm, i.endian);
            a.memoryIndexed(false, 0, 5, 3, size: i.imm);
          }
          a.bind(done);
          if (i.exit < 0) forget();
        case IrOp.floatAdd || IrOp.floatSub || IrOp.floatMul || IrOp.floatDiv:
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
                : i.op == IrOp.floatMul
                ? 0x1e610800
                : 0x1e611800,
          );
          if (!w) a.emit(0x1e624000);
          a.emit(w ? 0x9e660000 : 0x1e260000);
          save(0, v);
        case IrOp.floatSqrt:
          load(0, i.a);
          a.emit(w ? 0x9e670000 : 0x1e270000);
          if (!w) a.emit(0x1e22c000);
          a.emit(0x1e61c000);
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
          forget();
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
          branchOnCondition(i.a, dest, whenTrue: true);
        case IrOp.guardMapped:
          final addr = source(i.a, 0);
          lookup(i.imm != 0, addr: addr, needOffset: false);
          a.cbz(5, unmapped(block.exits[i.aux], addr), wide: true);
      }
    }

    switch (block.term) {
      case IrJump(:final pc, :final tag):
        link(pc, tag);
      case IrBranch t:
        final no = Arm64Label();
        branchOnCondition(t.cond.index, no, whenTrue: false);
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
        a.lsrImm(1, 0, DynTable.pcShift);
        if (t.tag != 0) {
          a.constant(2, t.tag);
          a.alu(0x4a000000, 1, 1, 2);
        }
        a.ubfx(1, 1, 0, (DynTable.entries - 1).bitLength);
        a.lslImm(1, 1, DynTable.entryBits);
        a.alu(0x0b000000, 1, 23, 1, wide: true);
        a.memory(true, 2, 1, 0, size: 4);
        a.cmp(0, 2);
        a.branch(miss, 1);
        a.memory(true, 2, 1, 4, size: 4);
        final tag = t.tag & 0xffffffff;
        if (tag == 0) {
          a.cbnz(2, miss);
        } else if (tag <= 4095) {
          a.cmpImmediate(2, tag);
          a.branch(miss, 1);
        } else {
          a.constant(3, t.tag);
          a.cmp(2, 3);
          a.branch(miss, 1);
        }
        a.memory(true, 2, 1, 8);
        a.cbz(2, miss, wide: true);
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
    a.finishPool();
    return a.bytes;
  }
}
