import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

/// SH-2 integer blocks. Exceptions and unhandled device/privileged operations
/// leave before effects so the owning CPU can use its existing interpreter.
final class Sh2Translator {
  static const regs = JitCtx.user;
  static const sr = regs + 16, gbr = sr + 1, vbr = sr + 2;
  static const pr = sr + 3, mach = sr + 4, macl = sr + 5;
  static const lastOpcode = sr + 6, writes = sr + 7;
  static const idleFromPc = sr + 8, readRegisters = sr + 9;
  static const readRegisterCount = 4,
      ctxWords = readRegisters + readRegisterCount;
  static const idleBranchDistance = 32;
  static const interpret = JitReason.user;
  static const profileMiss = JitReason.user + 1;
  static const idleDetected = JitReason.user + 2;
  final int? Function(int) fetch;
  final void Function(int) protect;
  final int maxInstructions;
  final bool alignMemory;
  final bool stopOnNoStore;

  /// Lets accesses at 0xc0000000 and above reach the runtime pages. The
  /// runtime mask must keep bit 31 for them to stay apart from the low pages.
  final bool highMemory;

  /// Whether a store from [at] must end its block, because the code page was
  /// released from write protection. The next block guards its own words.
  final bool Function(int at)? endsAfterStore;
  final bool macLong;
  // Enables MAC.W (0x400F) translation. The SS interpreter is the reference.
  final bool macWord;
  final bool idleGuards;
  final int? Function(int address, int size)? readContextFor;
  final int? Function(int address, int size)? readHelperFor;
  bool foldLiterals;
  Sh2Translator(
      {required this.fetch,
      required this.protect,
      this.maxInstructions = 24,
      this.alignMemory = true,
      this.stopOnNoStore = true,
      this.highMemory = false,
      this.endsAfterStore,
      this.macLong = false,
      this.macWord = false,
      this.idleGuards = false,
      this.readContextFor,
      this.readHelperFor,
      this.foldLiterals = false});
  late IrBuilder b;
  final values = <int, IrValue>{};
  final _entry = <int, IrValue>{};
  int spent = 0, last = 0;
  bool _hasHelper = false, _stored = false;
  final _guarded = <int>{};
  Map<int, int> _memoryBases = const {};
  final _constants = <int, int>{};
  IrValue c(int x) {
    final value = b.c32(x & 0xffffffff);
    _constants[value.index] = x & 0xffffffff;
    return value;
  }

  IrValue get(int word) => values[word] ??= b.ctxLoad(word);
  void put(int word, IrValue value) {
    if (idleGuards) _entry.putIfAbsent(word, () => b.ctxLoad(word));
    values[word] = value;
  }

  IrValue r(int n) => get(regs + n);
  void setR(int n, IrValue value) => put(regs + n, value);
  IrValue get t => b.and(get(sr), c(1));
  void setT(IrValue value) => put(sr, b.or(b.and(get(sr), c(~1)), value));
  IrExit snapshot(int pc, int clocks) => IrExit(interpret, pc,
      spent: clocks,
      stores: [for (final e in values.entries) (e.key, e.value)]);
  void flush({required IrValue destination}) {
    for (final e in values.entries) {
      b.ctxStore(e.key, e.value);
    }
    b.ctxStore(lastOpcode, c(last));
    // Only short back edges are candidates for the adapter's idle detector.
    // Preserve the source block PC when several forward blocks chain first.
    if (stopOnNoStore && !values.containsKey(writes)) {
      final eligible = b.and(b.eq(b.ltU(c(b.pc), destination), c(0)),
          b.ltU(b.sub(c(b.pc), destination), c(idleBranchDistance + 1)));
      if (idleGuards && !_hasHelper) {
        final self = b.eq(destination, c(b.pc));
        var same = c(1);
        for (final e in _entry.entries) {
          same = b.and(same, b.eq(e.value, values[e.key]!));
        }
        b.ctxStore(idleFromPc, c(b.pc));
        b.ctxStore(JitCtx.stop, b.and(eligible, b.or(b.eq(self, c(0)), same)));
        // A complete pure self-loop with unchanged state repeats until devices advance.
        b.exitIf(b.and(self, same), IrExit(idleDetected, b.pc, spent: spent));
      } else {
        b.ctxStore(idleFromPc, c(b.pc));
        b.ctxStore(JitCtx.stop, eligible);
      }
    }
  }

  bool guard(int at) {
    final aligned = at & ~3;
    if (_guarded.contains(aligned)) return true;
    final hi = fetch(aligned), lo = fetch((aligned + 2) & 0xffffffff);
    if (hi == null || lo == null) return false;
    _guarded.add(aligned);
    b.guard(aligned, (hi << 16) | lo, endian: IrEndian.big);
    protect(aligned);
    return true;
  }

  IrBlock? translate(int pc, {Map<int, int> memoryBases = const {}}) {
    _memoryBases = memoryBases;
    values.clear();
    _entry.clear();
    _constants.clear();
    _guarded.clear();
    _hasHelper = false;
    var endedByStore = false;
    spent = 0;
    last = 0;
    b = IrBuilder(pc);
    var at = pc;
    var count = 0;
    for (; count < maxInstructions; count++) {
      final op = fetch(at);
      if (op == null) break;
      if (_branch(op)) {
        if (maxInstructions == 1) break;
        final kind = op >>> 12, n = (op >>> 8) & 15;
        final delayed = kind != 8 || n >= 13;
        final slot = delayed ? fetch((at + 2) & 0xffffffff) : null;
        if (delayed && (slot == null || !supports(slot) || _branch(slot))) {
          break;
        }
        if (!guard(at) || (delayed && !guard((at + 2) & 0xffffffff))) break;
        final before = snapshot(at, spent);
        IrValue? condition;
        IrValue? dynamicTarget;
        int? target;
        if (kind == 8) {
          condition = (n == 9 || n == 13) ? t : b.eq(t, c(0));
          target = (at + 4 + (op & 255).toSigned(8) * 2) & 0xffffffff;
        } else if (kind == 10 || kind == 11) {
          target = (at + 4 + (op & 4095).toSigned(12) * 2) & 0xffffffff;
        } else if (op == 0x000b) {
          dynamicTarget = get(pr);
        } else {
          dynamicTarget = r(n);
          if (kind == 0) dynamicTarget = b.add(c(at + 4), dynamicTarget);
        }
        final call =
            kind == 11 || op & 0xf0ff == 0x0003 || op & 0xf0ff == 0x400b;
        if (call) put(pr, c(at + 4));
        if (delayed) emit(slot!, (at + 2) & 0xffffffff, before);
        // A taken branch costs one more clock; a delayed branch executes its slot.
        spent += delayed ? 3 : 2;
        if (condition != null) {
          b.ctxStore(JitCtx.budget,
              b.add(b.ctxLoad(JitCtx.budget), b.select(condition, c(0), c(1))));
        }
        last = delayed ? slot! : op;
        final destination = dynamicTarget ??
            (condition == null
                ? c(target!)
                : b.select(condition, c(target!),
                    c((at + (delayed ? 4 : 2)) & 0xffffffff)));
        flush(destination: destination);
        final IrTerm term = dynamicTarget != null
            ? IrJumpDyn(dynamicTarget)
            : condition == null
                ? IrJump(target!)
                : IrBranch(
                    condition, target!, (at + (delayed ? 4 : 2)) & 0xffffffff);
        return b.finish(term, cost: spent);
      }
      if (!supports(op) || !guard(at)) break;
      _stored = false;
      emit(op, at, snapshot(at, spent));
      spent++;
      last = op;
      final stored = _stored && endsAfterStore?.call(at) == true;
      at = (at + 2) & 0xffffffff;
      if (stored) {
        endedByStore = true;
        break;
      }
    }
    if (spent == 0) return null;
    flush(destination: c(at));
    // A translation-size boundary is not an unsupported guest instruction.
    return b.finish(
        count == maxInstructions || endedByStore
            ? IrJump(at)
            : IrExitTerm(IrExit(interpret, at)),
        cost: spent);
  }

  static bool _branch(int op) =>
      (op >>> 12 == 10 || op >>> 12 == 11) ||
      (op >>> 12 == 8 && const [9, 11, 13, 15].contains((op >>> 8) & 15)) ||
      const [0x0003, 0x0023, 0x400b, 0x402b].contains(op & 0xf0ff) ||
      op == 0x000b;

  bool supports(int op) => supported(op, macLong: macLong, macWord: macWord);

  static bool supported(int op, {bool macLong = false, bool macWord = false}) {
    if (macLong && op & 0xf00f == 0x000f) return true;
    if (macWord && op & 0xf00f == 0x400f) return true;
    final top = op >>> 12, low = op & 15;
    if (const [1, 5, 7, 9, 13, 14].contains(top)) return true;
    if (top == 6) return true;
    if (top == 2) {
      return const [0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 13, 14, 15]
          .contains(low);
    }
    if (top == 3) {
      return const [0, 2, 3, 4, 6, 7, 8, 10, 11, 12, 14, 15].contains(low);
    }
    if (top == 8) return const [0, 1, 4, 5, 8].contains((op >>> 8) & 15);
    if (top == 12) return ((op >>> 8) & 15) != 3 && ((op >>> 8) & 15) < 12;
    if (top == 0) {
      return const [4, 5, 6, 7, 12, 13, 14].contains(low) ||
          const [0x0002, 0x0012, 0x0022, 0x000a, 0x001a, 0x002a, 0x0029]
              .contains(op & 0xf0ff) ||
          const [0x0008, 0x0018, 0x0009, 0x0019, 0x0028].contains(op);
    }
    if (top == 4) {
      return const [
        0,
        0x20,
        1,
        0x21,
        4,
        5,
        0x24,
        0x25,
        8,
        9,
        0x18,
        0x19,
        0x28,
        0x29,
        0x10,
        0x11,
        0x15,
        0x1e,
        0x2e,
        0x0a,
        0x1a,
        0x2a,
        0x02,
        0x12,
        0x22,
        0x06,
        0x16,
        0x26
      ].contains(op & 255);
    }
    return false;
  }

  void emit(int op, int at, IrExit exit) {
    final top = op >>> 12,
        n = (op >>> 8) & 15,
        m = (op >>> 4) & 15,
        low = op & 15;
    IrValue base(int n) {
      final expected = _memoryBases[n];
      if (expected != null && !values.containsKey(regs + n)) {
        // Guard before replacing an entry register with an observed constant.
        // Earlier register writes or reads keep the general SSA value instead.
        final actual = b.ctxLoad(regs + n);
        b.exitIf(
            b.ne(actual, c(expected)),
            IrExit(profileMiss, exit.pc,
                tag: b.pc, spent: exit.spent, stores: exit.stores));
        put(regs + n, c(expected));
      }
      return r(n);
    }

    IrValue add(IrValue value, int amount) {
      final known = _constants[value.index];
      return known == null ? b.add(value, c(amount)) : c(known + amount);
    }

    IrValue address(IrValue value, int size) {
      // Biasing by 0x40000000 turns the allowed 0xc0000000..0x3fffffff into
      // 0..0x7fffffff, one unsigned compare.
      b.exitIf(
          highMemory
              ? b.ltU(c(0x7fffffff), b.add(value, c(0x40000000)))
              : b.ltU(c(0x3fffffff), value),
          exit);
      if (!alignMemory && size > 1) {
        b.exitIf(b.and(value, c(size - 1)), exit);
        return value;
      }
      // The SS bus aligns halfword/word accesses before dispatch.
      return size == 1 ? value : b.and(value, c(~(size - 1)));
    }

    IrValue read(IrValue a, int size) {
      final known = _constants[a.index];
      if (known != null && (alignMemory || (known & (size - 1)) == 0)) {
        final effective = known & ~(size - 1);
        final context = readContextFor?.call(effective, size);
        if (context != null) {
          final value = b.ctxLoad(context);
          return size == 1
              ? b.sext8(value)
              : size == 2
                  ? b.sext16(value)
                  : value;
        }
        final helper = readHelperFor?.call(effective, size);
        if (helper != null) {
          _hasHelper = true;
          final value = b.call(helper, c(effective), c(size));
          return size == 1
              ? b.sext8(value)
              : size == 2
                  ? b.sext16(value)
                  : value;
        }
      }
      return b.load(size, address(a, size),
          signed: size < 4, endian: IrEndian.big, unmapped: exit);
    }

    void write(IrValue a, IrValue v, int size) {
      _stored = true;
      b.store(size, address(a, size), v, endian: IrEndian.big, unmapped: exit);
      put(writes, add(get(writes), 1));
    }

    if (top == 14) {
      setR(n, c((op & 255).toSigned(8)));
      return;
    }
    if (top == 7) {
      setR(n, add(r(n), (op & 255).toSigned(8)));
      return;
    }
    if (top == 9 || top == 13) {
      final size = top == 9 ? 2 : 4;
      final literal =
          (((at + 4) & ~(size - 1)) + (op & 255) * size) & 0xffffffff;
      final hi = foldLiterals ? fetch(literal) : null;
      final lo = size == 4 && hi != null ? fetch(literal + 2) : null;
      final value = hi == null || (size == 4 && lo == null)
          ? null
          : size == 2
              ? hi.toSigned(16)
              : (hi << 16) | lo!;
      if (value != null &&
          (readHelperFor?.call(value & 0xffffffff, 1) != null ||
              readContextFor?.call(value & 0xffffffff, 1) != null) &&
          guard(literal)) {
        // Fold only pointers into adapter-approved helper regions. Entry guards
        // and page protection cover the literal bytes as well as instructions.
        setR(n, c(value));
      } else {
        setR(n, read(c(literal), size));
      }
      return;
    }
    if (top == 1) {
      write(add(base(n), low * 4), r(m), 4);
      return;
    }
    if (top == 5) {
      setR(n, read(add(base(m), low * 4), 4));
      return;
    }
    if (top == 6) {
      final v = (low <= 2 || (low >= 4 && low <= 6)) ? base(m) : r(m);
      if (low <= 2 || (low >= 4 && low <= 6)) {
        final size = 1 << (low & 3);
        setR(n, read(v, size));
        if (low >= 4 && n != m) setR(m, add(v, size));
        return;
      }
      if (low == 10) {
        final borrow = t;
        final negated = b.sub(c(0), v);
        setR(n, b.sub(negated, borrow));
        setT(b.or(b.ne(v, c(0)), b.ltU(negated, borrow)));
        return;
      }
      setR(
          n,
          switch (low) {
            3 => v,
            7 => b.xor(v, c(-1)),
            8 => b.or(
                b.and(v, c(0xffff0000)),
                b.or(b.shl(b.and(v, c(255)), c(8)),
                    b.and(b.shrU(v, c(8)), c(255)))),
            9 => b.or(b.shl(v, c(16)), b.shrU(v, c(16))),
            11 => b.sub(c(0), v),
            12 => b.zext8(v),
            13 => b.zext16(v),
            14 => b.sext8(v),
            15 => b.sext16(v),
            _ => throw StateError('unsupported SH-2 operation')
          });
      return;
    }
    if (top == 2) {
      final old = (low <= 2 || (low >= 4 && low <= 6)) ? base(n) : r(n);
      final v = r(m);
      if (low <= 2 || (low >= 4 && low <= 6)) {
        final size = 1 << (low & 3), a = low >= 4 ? add(old, -size) : old;
        write(a, v, size);
        if (low >= 4) setR(n, a);
        return;
      }
      switch (low) {
        case 7:
          final q = b.shrU(old, c(31)), sign = b.shrU(v, c(31));
          put(
              sr,
              b.or(
                  b.and(get(sr), c(~0x301)),
                  b.or(b.or(b.shl(q, c(8)), b.shl(sign, c(9))),
                      b.xor(q, sign))));
        case 8:
          setT(b.eq(b.and(old, v), c(0)));
        case 9:
          setR(n, b.and(old, v));
        case 10:
          setR(n, b.xor(old, v));
        case 11:
          setR(n, b.or(old, v));
        case 13:
          setR(n, b.or(b.shl(v, c(16)), b.shrU(old, c(16))));
        case 14:
          put(macl, b.mul(b.zext16(old), b.zext16(v)));
        case 15:
          put(macl, b.mul(b.sext16(old), b.sext16(v)));
      }
      return;
    }
    if (top == 3) {
      final x = r(n), y = r(m);
      switch (low) {
        case 0:
          setT(b.eq(x, y));
        case 2:
          setT(b.eq(b.ltU(x, y), c(0)));
        case 3:
          setT(b.eq(b.ltS(x, y), c(0)));
        case 4:
          final status = get(sr);
          final q = b.and(b.shrU(status, c(8)), c(1));
          final sign = b.and(b.shrU(status, c(9)), c(1));
          final shifted = b.or(b.shl(x, c(1)), t);
          final subtract = b.eq(q, sign);
          final result =
              b.select(subtract, b.sub(shifted, y), b.add(shifted, y));
          final carry = b.select(
              subtract, b.ltU(shifted, result), b.ltU(result, shifted));
          final nextQ = b.xor(b.xor(b.shrU(x, c(31)), carry), sign);
          setR(n, result);
          put(
              sr,
              b.or(b.and(status, c(~0x101)),
                  b.or(b.shl(nextQ, c(8)), b.eq(nextQ, sign))));
        case 6:
          setT(b.ltU(y, x));
        case 7:
          setT(b.ltS(y, x));
        case 8:
          setR(n, b.sub(x, y));
        case 10:
          final borrow = t;
          final difference = b.sub(x, y);
          setR(n, b.sub(difference, borrow));
          setT(b.or(b.ltU(x, y), b.ltU(difference, borrow)));
        case 11:
          final result = b.sub(x, y);
          setR(n, result);
          setT(b.shrU(b.and(b.xor(x, y), b.xor(x, result)), c(31)));
        case 12:
          setR(n, b.add(x, y));
        case 14:
          final sum = b.add(x, y);
          final result = b.add(sum, t);
          setR(n, result);
          setT(b.or(b.ltU(sum, x), b.ltU(result, sum)));
        case 15:
          final result = b.add(x, y);
          setR(n, result);
          setT(b.shrU(b.and(b.not(b.xor(x, y)), b.xor(x, result)), c(31)));
      }
      return;
    }
    if (top == 8) {
      if (n == 8) {
        setT(b.eq(r(0), c((op & 255).toSigned(8))));
        return;
      }
      final size = (n & 1) == 0 ? 1 : 2;
      if (n < 4) {
        write(add(base(m), low * size), r(0), size);
      } else {
        setR(0, read(add(base(m), low * size), size));
      }
      return;
    }
    if (top == 12) {
      final imm = op & 255;
      if (n < 3) {
        final size = 1 << n;
        write(add(base(gbr - regs), imm * size), r(0), size);
      } else if (n >= 4 && n <= 6) {
        final size = 1 << (n - 4);
        setR(0, read(add(base(gbr - regs), imm * size), size));
      } else if (n == 7) {
        setR(0, c(((at + 4) & ~3) + imm * 4));
      } else if (n == 8) {
        setT(b.eq(b.and(r(0), c(imm)), c(0)));
      } else if (n == 9) {
        setR(0, b.and(r(0), c(imm)));
      } else if (n == 10) {
        setR(0, b.xor(r(0), c(imm)));
      } else if (n == 11) {
        setR(0, b.or(r(0), c(imm)));
      }
      return;
    }
    if (top == 0) {
      if (low == 15) {
        final a = base(n);
        final left = b.sext32(read(a, 4));
        setR(n, add(a, 4));
        // Equal address registers read consecutive words.
        // Either read exit restores both increments from the original snapshot.
        final other = base(m);
        final right = b.sext32(read(other, 4));
        setR(m, add(other, 4));
        final shift32 = c(32);
        final wide =
            b.or(b.shl(b.zext32(get(mach)), shift32), b.zext32(get(macl)));
        final saturated = b.and(get(sr), c(2));
        final acc48 = b.shrS(b.shl(wide, c(16)), c(16));
        final acc = b.select(saturated, acc48, wide);
        final result = b.add(acc, b.mul(left, right));
        final minimum = b.c64Parts(0, 0xffff8000);
        final maximum = b.c64Parts(0xffffffff, 0x7fff);
        final clipped = b.select(b.ltS(result, minimum), minimum,
            b.select(b.ltS(maximum, result), maximum, result));
        final value = b.select(saturated, clipped, result);
        put(mach, b.trunc32(b.shrU(value, shift32)));
        put(macl, b.trunc32(value));
        return;
      }
      if (low >= 4 && low <= 6) {
        write(b.add(base(n), base(0)), r(m), 1 << (low - 4));
        return;
      }
      if (low >= 12 && low <= 14) {
        setR(n, read(b.add(base(m), base(0)), 1 << (low - 12)));
        return;
      }
      if (low == 7) {
        put(macl, b.mul(r(n), r(m)));
        return;
      }
      final special = op & 0xf0ff;
      final source = switch (special) {
        0x0002 => sr,
        0x0012 => gbr,
        0x0022 => vbr,
        0x000a => mach,
        0x001a => macl,
        0x002a => pr,
        _ => -1
      };
      if (source >= 0) {
        setR(n, get(source));
        return;
      }
      if (special == 0x0029) {
        setR(n, t);
        return;
      }
      switch (op) {
        case 0x0008:
          setT(c(0));
        case 0x0018:
          setT(c(1));
        case 0x0019:
          put(sr, b.and(get(sr), c(~0x301)));
        case 0x0028:
          put(mach, c(0));
          put(macl, c(0));
      }
      return;
    }
    if (top == 4) {
      if (low == 15) {
        // Each operand read precedes its address increment. Equal address
        // registers therefore read consecutive words.
        // A read exit restores both increments from the snapshot.
        final a = base(n);
        final left = b.sext32(read(a, 2));
        setR(n, add(a, 2));
        final other = base(m);
        final right = b.sext32(read(other, 2));
        setR(m, add(other, 2));
        final shift32 = c(32);
        final product = b.mul(left, right);
        final saturated = b.and(get(sr), c(2));
        // S = 1: 32-bit saturation of MACL. MACH bit 0 flags the overflow.
        final sum = b.add(b.sext32(get(macl)), product);
        final maximum = b.c64Parts(0x7fffffff, 0);
        final minimum = b.c64Parts(0x80000000, 0xffffffff);
        final over = b.ltS(maximum, sum);
        final under = b.ltS(sum, minimum);
        final clipped = b.select(over, maximum, b.select(under, minimum, sum));
        final satMach = b.or(get(mach), b.and(b.or(over, under), c(1)));
        // S = 0: 64-bit accumulate into MACH:MACL.
        final wide = b.add(
            b.or(b.shl(b.zext32(get(mach)), shift32), b.zext32(get(macl))),
            product);
        put(mach,
            b.select(saturated, satMach, b.trunc32(b.shrU(wide, shift32))));
        put(macl, b.select(saturated, b.trunc32(clipped), b.trunc32(wide)));
        return;
      }
      final kind = op & 255;
      if (const [0x02, 0x12, 0x22, 0x06, 0x16, 0x26].contains(kind)) {
        final special =
            switch (kind & 0x30) { 0 => mach, 0x10 => macl, _ => pr };
        final pointer = base(n);
        if (kind & 4 == 0) {
          final destination = add(pointer, -4);
          write(destination, get(special), 4);
          setR(n, destination);
        } else {
          put(special, read(pointer, 4));
          setR(n, add(pointer, 4));
        }
        return;
      }
      final old = r(n);
      if (const [0x1e, 0x2e, 0x0a, 0x1a, 0x2a].contains(kind)) {
        put(
            switch (kind) {
              0x1e => gbr,
              0x2e => vbr,
              0x0a => mach,
              0x1a => macl,
              _ => pr
            },
            old);
        return;
      }
      switch (kind) {
        case 0 || 0x20:
          setR(n, b.shl(old, c(1)));
          setT(b.shrU(old, c(31)));
        case 1 || 0x21:
          setR(n, kind == 1 ? b.shrU(old, c(1)) : b.shrS(old, c(1)));
          setT(b.and(old, c(1)));
        case 4 || 0x24:
          final carry = kind == 4 ? b.shrU(old, c(31)) : t;
          setR(n, b.or(b.shl(old, c(1)), carry));
          setT(b.shrU(old, c(31)));
        case 5 || 0x25:
          final carry = kind == 5 ? b.and(old, c(1)) : t;
          setR(n, b.or(b.shrU(old, c(1)), b.shl(carry, c(31))));
          setT(b.and(old, c(1)));
        case 8 || 0x18 || 0x28:
          setR(
              n,
              b.shl(
                  old,
                  c(kind == 8
                      ? 2
                      : kind == 0x18
                          ? 8
                          : 16)));
        case 9 || 0x19 || 0x29:
          setR(
              n,
              b.shrU(
                  old,
                  c(kind == 9
                      ? 2
                      : kind == 0x19
                          ? 8
                          : 16)));
        case 0x10:
          final v = add(old, -1);
          setR(n, v);
          setT(b.eq(v, c(0)));
        case 0x11:
          setT(b.eq(b.ltS(old, c(0)), c(0)));
        case 0x15:
          setT(b.ltS(c(0), old));
      }
    }
  }
}
