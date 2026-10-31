import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

/// SH-4 blocks for privileged code with the MMU off and a coherent cache.
/// Memory outside mapped main RAM, unaligned accesses, exceptions and mode
/// changes leave before effects so the owning CPU interprets the instruction.
/// The block tag holds FPSCR.SZ, FPSCR.PR and SR.FD.
final class Sh4Translator {
  static const regs = JitCtx.user;
  static const sr = regs + 16, gbr = sr + 1, pr = sr + 2;
  static const mach = sr + 3, macl = sr + 4, fpul = sr + 5, fpscr = sr + 6;
  static const fr = sr + 7, xf = fr + 16, ctxWords = xf + 16;
  static const interpret = JitReason.user;
  static const tagSize = 1, tagDouble = 2, tagFpuDisabled = 4;

  /// Guest page holding the store queues. Store-queue stores are redirected
  /// here; the reserved area 7 page that it shadows is not used by software.
  static const queueAlias = 0x1ffff000;

  /// The block tag for the given status and FPU status registers.
  static int tagOf(int status, int floatStatus) =>
      ((floatStatus >> 20) & 1) |
      ((floatStatus >> 18) & 2) |
      ((status >> 13) & 4);

  final int? Function(int) fetch;
  final void Function(int) protect;

  /// Helper id for FPU arithmetic, called with the opcode and its PC. It
  /// returns 0 on completion or nonzero when the CPU must interpret it.
  final int fpuHelper;
  final int maxInstructions;
  Sh4Translator(
      {required this.fetch,
      required this.protect,
      required this.fpuHelper,
      this.maxInstructions = 32});

  late IrBuilder b;
  final values = <int, IrValue>{};
  final _guarded = <int>{};
  final _constants = <int, int>{};
  int spent = 0, tag = 0;

  IrValue c(int x) {
    final value = b.c32(x & 0xffffffff);
    _constants[value.index] = x & 0xffffffff;
    return value;
  }

  IrValue get(int word) => values[word] ??= b.ctxLoad(word);
  void put(int word, IrValue value) => values[word] = value;
  IrValue r(int n) => get(regs + n);
  void setR(int n, IrValue value) => put(regs + n, value);
  IrValue get t => b.and(get(sr), c(1));
  void setT(IrValue value) => put(sr, b.or(b.and(get(sr), c(~1)), value));
  IrExit snapshot(int pc, int clocks) => IrExit(interpret, pc,
      tag: tag,
      spent: clocks,
      stores: [for (final e in values.entries) (e.key, e.value)]);

  void flush() {
    for (final e in values.entries) {
      b.ctxStore(e.key, e.value);
    }
  }

  bool guard(int at) {
    final aligned = at & ~3;
    if (_guarded.contains(aligned)) return true;
    final lo = fetch(aligned), hi = fetch((aligned + 2) & 0xffffffff);
    if (hi == null || lo == null) return false;
    _guarded.add(aligned);
    b.guard(aligned, (hi << 16) | lo);
    protect(aligned);
    return true;
  }

  IrBlock? translate(int pc, int tag) {
    this.tag = tag;
    values.clear();
    _constants.clear();
    _guarded.clear();
    spent = 0;
    b = IrBuilder(pc, tag: tag);
    var at = pc;
    var count = 0;
    for (; count < maxInstructions; count++) {
      final op = fetch(at);
      if (op == null) break;
      if (branch(op)) {
        final kind = op >>> 12, n = (op >>> 8) & 15;
        final delayed = kind != 8 || n >= 13;
        final slot = delayed ? fetch((at + 2) & 0xffffffff) : null;
        if (delayed &&
            (slot == null ||
                !supported(slot, tag, slot: true) ||
                branch(slot))) {
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
        spent += delayed ? 2 : 1;
        flush();
        final next = (at + (delayed ? 4 : 2)) & 0xffffffff;
        final IrTerm term = dynamicTarget != null
            ? IrJumpDyn(dynamicTarget, tag: tag)
            : condition == null
                ? IrJump(target!, tag: tag)
                : IrBranch(condition, target!, next,
                    tagTrue: tag, tagFalse: tag);
        return b.finish(term, cost: spent);
      }
      if (!supported(op, tag) || !guard(at)) break;
      emit(op, at, snapshot(at, spent));
      spent++;
      at = (at + 2) & 0xffffffff;
      if (op == 0xf3fd) {
        // FSCHG continues in the block of the other transfer size.
        flush();
        return b.finish(IrJump(at, tag: tag ^ tagSize), cost: spent);
      }
    }
    if (spent == 0) return null;
    flush();
    return b.finish(
        count == maxInstructions
            ? IrJump(at, tag: tag)
            : IrExitTerm(IrExit(interpret, at, tag: tag)),
        cost: spent);
  }

  static bool branch(int op) =>
      (op >>> 12 == 10 || op >>> 12 == 11) ||
      (op >>> 12 == 8 && const [9, 11, 13, 15].contains((op >>> 8) & 15)) ||
      const [0x0003, 0x0023, 0x400b, 0x402b].contains(op & 0xf0ff) ||
      op == 0x000b;

  /// FPU arithmetic executed through [fpuHelper].
  static bool helperOp(int op, int tag) {
    if (op >>> 12 != 15 || tag & tagFpuDisabled != 0) return false;
    final low = op & 15;
    if (low <= 5 || low == 14) return true;
    if (low != 13) return false;
    return const [0xf02d, 0xf03d, 0xf06d, 0xf07d, 0xf0ad, 0xf0bd, 0xf0ed]
            .contains(op & 0xf0ff) ||
        op & 0xf3ff == 0xf1fd ||
        op & 0xf1ff == 0xf0fd;
  }

  /// Whether [op] translates. A delay [slot] excludes PC-relative operands
  /// and helper calls, whose exits could not restore the branch state.
  static bool supported(int op, int tag, {bool slot = false}) {
    final top = op >>> 12, low = op & 15, n = (op >>> 8) & 15;
    if (const [1, 5, 6, 7, 14].contains(top)) return true;
    if (top == 9 || top == 13) return !slot;
    if (top == 2) return low != 3;
    if (top == 3) return low != 1 && low != 9;
    if (top == 8) return const [0, 1, 4, 5, 8].contains(n);
    if (top == 12) return n != 3 && !(slot && n == 7);
    final fpu = tag & tagFpuDisabled == 0;
    if (top == 15) {
      if (!fpu) return false;
      if (low >= 6 && low <= 12) return true;
      if (helperOp(op, tag)) return !slot;
      final code = op & 0xf0ff, double = tag & tagDouble != 0;
      if (code == 0xf00d || code == 0xf01d) return true;
      if (code == 0xf04d || code == 0xf05d) return !double || n.isEven;
      if (code == 0xf08d || code == 0xf09d) return !double;
      return (op == 0xfbfd || op == 0xf3fd) && !double && !slot;
    }
    if (top == 0) {
      if (const [4, 5, 6, 7, 12, 13, 14].contains(low)) return true;
      final code = op & 0xf0ff;
      if (const [0x0002, 0x0012, 0x000a, 0x001a, 0x002a, 0x0029, 0x0083]
          .contains(code)) {
        return true;
      }
      if (const [0x0093, 0x00a3, 0x00b3, 0x00c3].contains(code)) return true;
      if (code == 0x005a || code == 0x006a) return fpu;
      return const [0x0008, 0x0018, 0x0009, 0x0019, 0x0028, 0x0048, 0x0058]
          .contains(op);
    }
    if (top == 4) {
      final kind = op & 255;
      if (low == 12 || low == 13) return true;
      if (const [0x52, 0x56, 0x5a, 0x62].contains(kind)) return fpu;
      return const [
        0x00, 0x20, 0x01, 0x21, 0x04, 0x05, 0x24, 0x25, //
        0x08, 0x09, 0x18, 0x19, 0x28, 0x29, 0x10, 0x11, 0x15, 0x1b,
        0x1e, 0x0a, 0x1a, 0x2a, 0x02, 0x12, 0x22, 0x06, 0x16, 0x26,
        0x13, 0x17, 0x03,
      ].contains(kind);
    }
    return false;
  }

  void emit(int op, int at, IrExit exit) {
    final top = op >>> 12,
        n = (op >>> 8) & 15,
        m = (op >>> 4) & 15,
        low = op & 15;

    IrValue add(IrValue value, int amount) {
      final known = _constants[value.index];
      return known == null ? b.add(value, c(amount)) : c(known + amount);
    }

    IrValue address(IrValue value, int size) {
      final known = _constants[value.index];
      if (known != null && known < 0xc0000000 && known & (size - 1) == 0) {
        return value;
      }
      // P3 and P4 are never ordinary RAM; unaligned accesses raise errors.
      final outside = b.ltU(c(0xbfffffff), value);
      b.exitIf(
          size == 1 ? outside : b.or(outside, b.and(value, c(size - 1))), exit);
      return value;
    }

    IrValue storeAddress(IrValue value, int size) {
      if (size < 4) return address(value, size);
      final known = _constants[value.index];
      if (known != null) {
        return address(
            known - 0xe0000000 < 0x04000000 && known >= 0xe0000000
                ? c(queueAlias | (known & 63))
                : value,
            size);
      }
      final queue = b.ltU(b.sub(value, c(0xe0000000)), c(0x04000000));
      return address(
          b.select(queue, b.or(b.and(value, c(63)), c(queueAlias)), value),
          size);
    }

    IrValue read(IrValue a, int size) =>
        b.load(size, address(a, size), signed: size < 4, unmapped: exit);
    void write(IrValue a, IrValue v, int size) =>
        b.store(size, storeAddress(a, size), v, unmapped: exit);

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
      setR(n, read(c(literal), size));
      return;
    }
    if (top == 1) {
      write(add(r(n), low * 4), r(m), 4);
      return;
    }
    if (top == 5) {
      setR(n, read(add(r(m), low * 4), 4));
      return;
    }
    if (top == 6) {
      final v = r(m);
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
            _ => throw StateError('unsupported SH-4 operation')
          });
      return;
    }
    if (top == 2) {
      final old = r(n), v = r(m);
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
        case 12:
          final x = b.xor(old, v);
          setT(b.or(
              b.or(b.eq(b.and(x, c(0xff)), c(0)),
                  b.eq(b.and(x, c(0xff00)), c(0))),
              b.or(b.eq(b.and(x, c(0xff0000)), c(0)),
                  b.eq(b.and(x, c(0xff000000)), c(0)))));
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
        case 5:
          put(macl, b.mul(x, y));
          put(mach, b.mulHiU(x, y));
        case 13:
          put(macl, b.mul(x, y));
          put(mach, b.mulHiS(x, y));
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
        write(add(r(m), low * size), r(0), size);
      } else {
        setR(0, read(add(r(m), low * size), size));
      }
      return;
    }
    if (top == 12) {
      final imm = op & 255;
      if (n < 3) {
        final size = 1 << n;
        write(add(get(gbr), imm * size), r(0), size);
      } else if (n >= 4 && n <= 6) {
        final size = 1 << (n - 4);
        setR(0, read(add(get(gbr), imm * size), size));
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
      } else {
        final a = b.add(get(gbr), r(0));
        final value = b.zext8(read(a, 1));
        switch (n) {
          case 12:
            setT(b.eq(b.and(value, c(imm)), c(0)));
          case 13:
            write(a, b.and(value, c(imm)), 1);
          case 14:
            write(a, b.xor(value, c(imm)), 1);
          case 15:
            write(a, b.or(value, c(imm)), 1);
        }
      }
      return;
    }
    if (top == 15) {
      _float(op, at, n, m, low, exit, address, storeAddress);
      return;
    }
    if (top == 0) {
      if (low >= 4 && low <= 6) {
        write(b.add(r(n), r(0)), r(m), 1 << (low - 4));
        return;
      }
      if (low >= 12 && low <= 14) {
        setR(n, read(b.add(r(m), r(0)), 1 << (low - 12)));
        return;
      }
      if (low == 7) {
        put(macl, b.mul(r(n), r(m)));
        return;
      }
      final code = op & 0xf0ff;
      final source = switch (code) {
        0x0002 => sr,
        0x0012 => gbr,
        0x000a => mach,
        0x001a => macl,
        0x002a => pr,
        0x005a => fpul,
        0x006a => fpscr,
        _ => -1
      };
      if (source >= 0) {
        setR(n, get(source));
        return;
      }
      switch (code) {
        case 0x0029:
          setR(n, t);
          return;
        case 0x0083:
          // A store-queue burst writes external memory through the CPU.
          final queue = b.ltU(b.sub(r(n), c(0xe0000000)), c(0x04000000));
          b.exitIf(queue, exit);
          return;
        case 0x0093 || 0x00a3 || 0x00b3:
          // A coherent cache holds no operand lines to operate on.
          return;
        case 0x00c3:
          write(r(n), r(0), 4);
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
        case 0x0048:
          put(sr, b.and(get(sr), c(~2)));
        case 0x0058:
          put(sr, b.or(get(sr), c(2)));
      }
      return;
    }
    if (top == 4) {
      final kind = op & 255;
      if (low == 12 || low == 13) {
        final a = r(n), shift = r(m);
        final count = b.and(shift, c(31));
        final left = b.shl(a, count);
        final zero = b.eq(count, c(0));
        final reverse = b.sub(c(0), count);
        final right = low == 12
            ? b.select(zero, b.shrS(a, c(31)), b.shrS(a, reverse))
            : b.select(zero, c(0), b.shrU(a, reverse));
        setR(n, b.select(b.ltS(shift, c(0)), right, left));
        return;
      }
      final special = switch (kind) {
        0x02 || 0x06 || 0x0a => mach,
        0x12 || 0x16 || 0x1a => macl,
        0x22 || 0x26 || 0x2a => pr,
        0x52 || 0x56 || 0x5a => fpul,
        0x62 => fpscr,
        0x13 || 0x17 || 0x1e => gbr,
        0x03 => sr,
        _ => -1
      };
      if (special >= 0) {
        final pointer = r(n);
        if (low == 2 || low == 3) {
          final destination = add(pointer, -4);
          write(destination, get(special), 4);
          setR(n, destination);
        } else if (low == 6 || low == 7) {
          put(special, read(pointer, 4));
          setR(n, add(pointer, 4));
        } else {
          put(special, pointer);
        }
        return;
      }
      final old = r(n);
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
          setR(n, b.shl(old, c(const {8: 2, 0x18: 8, 0x28: 16}[kind]!)));
        case 9 || 0x19 || 0x29:
          setR(n, b.shrU(old, c(const {9: 2, 0x19: 8, 0x29: 16}[kind]!)));
        case 0x10:
          final v = add(old, -1);
          setR(n, v);
          setT(b.eq(v, c(0)));
        case 0x11:
          setT(b.eq(b.ltS(old, c(0)), c(0)));
        case 0x15:
          setT(b.ltS(c(0), old));
        case 0x1b:
          final value = b.zext8(read(old, 1));
          write(old, b.or(value, c(0x80)), 1);
          setT(b.eq(value, c(0)));
      }
    }
  }

  /// Single FADD, FSUB, FMUL, FMAC, FCMP/EQ and FCMP/GT on host doubles.
  /// Operands must be normal or zero; anything that could round twice,
  /// leave the normal range or raise an exception exits to the CPU.
  bool _nativeFloat(int op, int n, int m, int low, IrExit exit) {
    if (op >>> 12 != 15 || tag & (tagDouble | tagFpuDisabled) != 0) {
      return false;
    }
    if (low == 13) return _nativeConversion(op, n, exit);
    if (!(low <= 2 || low == 4 || low == 5 || low == 14)) return false;
    IrValue magnitude(IrValue x) => b.and(x, c(0x7fffffff));
    IrValue zero(IrValue x) => b.eq(magnitude(x), c(0));
    final special = _special;
    final x = get(fr + n), y = get(fr + m);
    var bad = b.or(special(x), special(y));
    if (low == 4 || low == 5) {
      b.exitIf(bad, exit);
      final IrValue result;
      if (low == 4) {
        result = b.or(b.eq(x, y), b.and(zero(x), zero(y)));
      } else {
        IrValue order(IrValue v) =>
            b.select(b.shrU(v, c(31)), b.sub(c(0), magnitude(v)), magnitude(v));
        result = b.ltS(order(y), order(x));
      }
      setT(result);
      put(fpscr, b.and(get(fpscr), c(~0x3f000)));
      return true;
    }
    final status = get(fpscr);
    // Enabled exceptions and round-to-zero stay with the exact model.
    bad = b.or(bad, b.and(status, c(0xf83)));
    final f0 = low == 14 ? get(fr) : null;
    if (f0 != null) {
      // The exact model owns the sign of a zero sum of zeros.
      bad = b.or(bad, special(f0));
      bad = b.or(bad, b.and(b.or(zero(f0), zero(y)), zero(x)));
    }
    b.exitIf(bad, exit);
    final wx = b.floatConvert(x), wy = b.floatConvert(y);
    final IrValue sum, error;
    if (low == 2) {
      // A product of two singles is exact in a double.
      sum = b.floatBinary(IrOp.floatMul, wx, wy);
      error = c(0);
    } else {
      final IrValue left, right;
      if (f0 != null) {
        left = b.floatBinary(IrOp.floatMul, b.floatConvert(f0), wy);
        right = wx;
      } else {
        left = wx;
        right = low == 0 ? wy : b.xor(wy, b.c64Parts(0, 0x80000000));
      }
      // Two-sum: the exact sum is sum + error.
      sum = b.floatBinary(IrOp.floatAdd, left, right);
      final virtual = b.floatBinary(IrOp.floatSub, sum, left);
      final residual = b.floatBinary(
          IrOp.floatAdd,
          b.floatBinary(
              IrOp.floatSub, left, b.floatBinary(IrOp.floatSub, sum, virtual)),
          b.floatBinary(IrOp.floatSub, right, virtual));
      error =
          b.ne(b.and(residual, b.c64Parts(-1, 0x7fffffff)), b.c64Parts(0, 0));
    }
    final result = b.floatConvert(sum);
    final inexact = b.or(b.ne(b.floatConvert(result), sum), error);
    // Denormal, infinite or underflowed-to-zero results, and a double on a
    // single midpoint with a nonzero error, take the exact path.
    var unusual = b.or(
        special(result),
        b.and(zero(result),
            b.ne(b.and(sum, b.c64Parts(-1, 0x7fffffff)), b.c64Parts(0, 0))));
    if (low != 2) {
      final midpoint = b.eq(
          b.and(sum, b.c64Parts(0x1fffffff, 0)), b.c64Parts(0x10000000, 0));
      unusual = b.or(unusual, b.and(midpoint, error));
    }
    b.exitIf(unusual, exit);
    put(fr + n, result);
    put(fpscr,
        b.or(b.and(status, c(~0x3f000)), b.select(inexact, c(0x1004), c(0))));
    return true;
  }

  /// Denormal, infinity or NaN: field 0 or 255 without being zero.
  IrValue _special(IrValue x) => b.and(
      b.ltU(c(253), b.sub(b.and(b.shrU(x, c(23)), c(255)), c(1))),
      b.ne(b.and(x, c(0x7fffffff)), c(0)));

  /// FLOAT, FTRC, FIPR and FTRV on host doubles. Inner products sum the
  /// exact products in double precision and round once more to single,
  /// where the exact model rounds the exact sum once.
  bool _nativeConversion(int op, int n, IrExit exit) {
    final code = op & 0xf0ff;
    final transform = op & 0xf3ff == 0xf1fd;
    if (code != 0xf02d && code != 0xf03d && code != 0xf0ed && !transform) {
      return false;
    }
    final status = get(fpscr);
    if (code == 0xf03d) {
      // From 2^31 in magnitude, and for NaN, the exact model saturates.
      final x = get(fr + n);
      b.exitIf(b.ltU(c(157), b.and(b.shrU(x, c(23)), c(255))), exit);
      put(fpul, b.floatToInt(x, truncate: true));
      put(fpscr, b.and(status, c(~0x3f000)));
      return true;
    }
    // Enabled exceptions and round-to-zero stay with the exact model.
    var bad = b.ne(b.and(status, c(0xf83)), c(0));
    if (code == 0xf02d) {
      b.exitIf(bad, exit);
      // The word biased into a double mantissa at 2^52, minus the bias.
      final wide = b.floatBinary(
          IrOp.floatSub,
          b.or(b.zext32(b.xor(get(fpul), c(0x80000000))),
              b.c64Parts(0, 0x43300000)),
          b.c64Parts(0x80000000, 0x43300000));
      final result = b.floatConvert(wide);
      final inexact = b.ne(b.floatConvert(result), wide);
      put(fr + n, result);
      put(fpscr,
          b.or(b.and(status, c(~0x3f000)), b.select(inexact, c(0x1004), c(0))));
      return true;
    }
    final destination = (op >> 10 & 3) * 4;
    final vector = [for (var i = 0; i < 4; i++) get(fr + destination + i)];
    for (final x in vector) {
      bad = b.or(bad, _special(x));
    }
    final wideVector = [for (final x in vector) b.floatConvert(x)];
    IrValue product(List<IrValue> row) {
      for (final x in row) {
        bad = b.or(bad, _special(x));
      }
      var sum =
          b.floatBinary(IrOp.floatMul, wideVector[0], b.floatConvert(row[0]));
      for (var i = 1; i < 4; i++) {
        sum = b.floatBinary(
            IrOp.floatAdd,
            sum,
            b.floatBinary(
                IrOp.floatMul, wideVector[i], b.floatConvert(row[i])));
      }
      return b.floatConvert(sum);
    }

    final List<IrValue> results;
    if (transform) {
      results = [
        for (var row = 0; row < 4; row++)
          product([for (var i = 0; i < 4; i++) get(xf + row + 4 * i)])
      ];
    } else {
      final source = (op >> 8 & 3) * 4;
      results = [
        product([for (var i = 0; i < 4; i++) get(fr + source + i)])
      ];
    }
    // Overflowed or denormal results take the exact path.
    for (final result in results) {
      bad = b.or(bad, _special(result));
    }
    b.exitIf(bad, exit);
    for (var i = 0; i < results.length; i++) {
      put(fr + destination + (transform ? i : 3), results[i]);
    }
    // The exact model reports these products as inexact.
    put(fpscr, b.or(b.and(status, c(~0x3f000)), c(0x1004)));
    return true;
  }

  void _float(
      int op,
      int at,
      int n,
      int m,
      int low,
      IrExit exit,
      IrValue Function(IrValue, int) address,
      IrValue Function(IrValue, int) storeAddress) {
    if (_nativeFloat(op, n, m, low, exit)) return;
    if (helperOp(op, tag)) {
      // The helper works on the context, so every pending value goes there.
      flush();
      values.clear();
      final status = b.call(fpuHelper, c(op), c(at));
      b.exitIf(status, IrExit(interpret, at, tag: tag, spent: exit.spent));
      return;
    }
    final code = op & 0xf0ff;
    switch (code) {
      case 0xf00d:
        put(fr + n, get(fpul));
        return;
      case 0xf01d:
        put(fpul, get(fr + n));
        return;
      case 0xf04d:
        put(fr + n, b.xor(get(fr + n), c(0x80000000)));
        return;
      case 0xf05d:
        put(fr + n, b.and(get(fr + n), c(0x7fffffff)));
        return;
      case 0xf08d:
        put(fr + n, c(0));
        return;
      case 0xf09d:
        put(fr + n, c(0x3f800000));
        return;
    }
    if (op == 0xfbfd) {
      // FRCHG swaps the banks; the tag does not record FPSCR.FR.
      for (var i = 0; i < 16; i++) {
        final front = get(fr + i);
        put(fr + i, get(xf + i));
        put(xf + i, front);
      }
      put(fpscr, b.xor(get(fpscr), c(0x200000)));
      return;
    }
    if (op == 0xf3fd) {
      put(fpscr, b.xor(get(fpscr), c(0x100000)));
      return;
    }
    final pair = tag & tagSize != 0;
    int file(int register) =>
        pair ? (register.isOdd ? xf : fr) + (register & ~1) : fr + register;
    if (low == 12) {
      put(file(n), get(file(m)));
      if (pair) put(file(n) + 1, get(file(m) + 1));
      return;
    }
    final size = pair ? 8 : 4;
    final load = low == 6 || low == 8 || low == 9;
    final IrValue a;
    if (load) {
      a = low == 6 ? b.add(r(0), r(m)) : r(m);
    } else {
      a = low == 7
          ? b.add(r(0), r(n))
          : low == 11
              ? b.sub(r(n), c(size))
              : r(n);
    }
    // Both words of an 8-byte access share one page.
    final register = file(load ? n : m);
    if (load) {
      final checked = address(a, size);
      final first = b.load(4, checked, unmapped: exit);
      if (pair) {
        final second = b.load(4, b.add(checked, c(4)), unmapped: exit);
        put(register + 1, second);
      }
      put(register, first);
      if (low == 9) setR(m, b.add(a, c(size)));
    } else {
      final checked = storeAddress(a, size);
      b.store(4, checked, get(register), unmapped: exit);
      if (pair) {
        b.store(4, b.add(checked, c(4)), get(register + 1), unmapped: exit);
      }
      if (low == 11) setR(n, a);
    }
  }
}
