import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../iop/iop_memory.dart';
import 'iop_jit.dart';

/// Translates IOP code to [IrBlock]s with the semantics of [Iop.step].
///
/// A block ends after a branch and its delay slot. The load delay is
/// modelled as in the interpreter: a loaded value lands after the next
/// instruction, over what that instruction wrote to the same register,
/// unless that instruction loads the register itself. A load still in
/// its delay at the end of a block is passed to the next block as its
/// tag (the register number) with the value in the context, so a block
/// is keyed by the pc and the register in delay.
///
/// Accesses outside RAM, misaligned accesses and the trapping adds and
/// subtracts leave before the instruction with the state the interpreter
/// needs to run it, and MTC0, RFE, the other coprocessors, syscall,
/// break and unknown opcodes end a block the same way. MFC0 and the
/// divides run as helpers: the coprocessor registers change only at
/// instructions the blocks leave out (and at the interrupt mirror, which
/// the MFC0 helper applies itself), and a divide writes hi and lo to
/// the context directly, as the IR has no division.
final class IopTranslator {
  /// the code word at pc, and whether it is guarded; null if the address
  /// holds no code the blocks can run
  final (int, bool)? Function(int pc) fetch;

  /// whether the block ends after a store at pc, for code next to data
  final bool Function(int pc) endsAfterStore;
  final int mfc0, div;

  static const maxInstructions = 32;

  IopTranslator(
      {required this.fetch,
      required this.endsAfterStore,
      required this.mfc0,
      required this.div});

  IrBlock? translate(int pc, {int tag = 0}) => _Block(this, pc, tag).translate();
}

enum _Kind { plain, overflow, branch, interpret }

_Kind _kindOf(int inst) {
  final rs = (inst >>> 21) & 31;
  return switch (inst >>> 26) {
    0x00 => switch (inst & 63) {
        0x00 || 0x02 || 0x03 || 0x04 || 0x06 || 0x07 => _Kind.plain,
        0x08 || 0x09 => _Kind.branch,
        0x10 || 0x11 || 0x12 || 0x13 => _Kind.plain,
        0x18 || 0x19 || 0x1a || 0x1b => _Kind.plain,
        0x20 || 0x22 => _Kind.overflow,
        >= 0x21 && <= 0x27 => _Kind.plain,
        0x2a || 0x2b => _Kind.plain,
        _ => _Kind.interpret,
      },
    0x01 || 0x02 || 0x03 || 0x04 || 0x05 || 0x06 || 0x07 => _Kind.branch,
    0x08 => _Kind.overflow,
    >= 0x09 && <= 0x0f => _Kind.plain,
    0x10 => rs == 0 ? _Kind.plain : _Kind.interpret,
    >= 0x20 && <= 0x26 => _Kind.plain,
    0x28 || 0x29 || 0x2a || 0x2b || 0x2e => _Kind.plain,
    _ => _Kind.interpret,
  };
}

final class _Block {
  final IopTranslator t;
  final int pc, tag;
  final IrBuilder b;

  /// the current value of r0..r31, hi (32) and lo (33), if known
  final _regs = List<IrValue?>.filled(34, null);
  final _dirty = List<bool>.filled(34, false);
  static const _hi = 32, _lo = 33;

  /// the load in its delay: lands after the next instruction
  int _pendingReg = 0;
  IrValue? _pendingValue;

  /// instructions translated so far
  int _count = 0;

  _Block(this.t, this.pc, this.tag) : b = IrBuilder(pc, tag: tag) {
    if (tag != 0) {
      _pendingReg = tag;
      _pendingValue = b.ctxLoad(IopJit.ctxPendingValue);
    }
  }

  static int _ctxOf(int reg) => switch (reg) {
        _hi => IopJit.ctxHi,
        _lo => IopJit.ctxLo,
        _ => IopJit.ctxRegs + reg,
      };

  IrValue _get(int reg) {
    if (reg == 0) return b.c32(0);
    return _regs[reg] ??= b.ctxLoad(_ctxOf(reg));
  }

  void _set(int reg, IrValue v) {
    if (reg == 0) return;
    _regs[reg] = v;
    _dirty[reg] = true;
  }

  /// the context stores of a side exit: the registers not yet written
  /// and the load in delay, written only when the block leaves there
  List<(int, IrValue)> _exitStores() => [
        for (int r = 1; r < 34; r++)
          if (_dirty[r]) (_ctxOf(r), _regs[r]!),
        if (_pendingReg != 0) (IopJit.ctxPendingValue, _pendingValue!),
      ];

  /// writes the known registers and the load in delay to the context
  void _flush() {
    for (int r = 1; r < 34; r++) {
      if (_dirty[r]) {
        b.ctxStore(_ctxOf(r), _regs[r]!);
        _dirty[r] = false;
      }
    }
    if (_pendingReg != 0) {
      b.ctxStore(IopJit.ctxPendingValue, _pendingValue!);
    }
  }

  /// Ends the instruction: [imm] is written first, then the load in
  /// delay lands over it, unless [load] replaces that load with its own
  /// to the same register; then [load] starts its delay. The order is
  /// the interpreter's, which applies the in-flight load after the
  /// instruction has executed.
  void _commit({(int, IrValue)? imm, (int, IrValue)? load}) {
    if (imm != null) _set(imm.$1, imm.$2);
    if (_pendingReg != 0 && load?.$1 != _pendingReg) {
      _set(_pendingReg, _pendingValue!);
    }
    _pendingReg = load == null ? 0 : load.$1;
    _pendingValue = _pendingReg == 0 ? null : load!.$2;
    _count++;
  }

  IrBlock _interpretAt(int addr) {
    _flush();
    return b.finish(
        IrExitTerm(IrExit(IopJit.reasonInterpret, addr, tag: _pendingReg)),
        cost: _count);
  }

  int? _fetch(int addr) {
    final f = t.fetch(addr);
    if (f == null) return null;
    final (inst, guarded) = f;
    if (guarded) b.guard(addr, inst);
    return inst;
  }

  IrBlock translate() {
    for (int i = 0;; i++) {
      final addr = (pc + 4 * i) & 0xffffffff;
      final inst = _fetch(addr);
      if (i > 0 && (inst == null || i >= IopTranslator.maxInstructions)) {
        _flush();
        return b.finish(IrJump(addr, tag: _pendingReg), cost: _count);
      }
      if (inst == null) return _interpretAt(addr);

      switch (_kindOf(inst)) {
        case _Kind.interpret:
          return _interpretAt(addr);
        case _Kind.plain:
          _exec(inst, addr);
          if (_isStore(inst) && t.endsAfterStore(addr)) {
            _flush();
            return b.finish(IrJump((addr + 4) & 0xffffffff, tag: _pendingReg),
                cost: _count);
          }
        case _Kind.overflow:
          _exec(inst, addr);
        case _Kind.branch:
          final slotAddr = (addr + 4) & 0xffffffff;
          final slot = _fetch(slotAddr);
          if (slot == null || _kindOf(slot) != _Kind.plain) {
            return _interpretAt(addr);
          }
          // An access in the slot exits at the branch with the state
          // before it, which the interpreter runs with its delay slot.
          if (_isMemory(slot)) _beginAccess(addr);
          final term = _branch(inst, addr);
          _exec(slot, slotAddr, accessSet: true);
          _flush();
          return b.finish(term(_pendingReg), cost: _count);
      }
    }
  }

  static bool _isStore(int inst) => switch (inst >>> 26) {
        0x28 || 0x29 || 0x2a || 0x2b || 0x2e => true,
        _ => false,
      };

  static bool _isMemory(int inst) => switch (inst >>> 26) {
        >= 0x20 && <= 0x26 => true,
        _ => _isStore(inst),
      };

  /// where the accesses of the current instruction leave when their
  /// address is not RAM the blocks run on: before the instruction, or
  /// before its branch
  ({int pc, int tag, int spent, List<(int, IrValue)> stores})? _access;

  /// The blocks run on RAM alone. Accesses outside it, and misaligned
  /// ones (which the interpreter faults), run once through the
  /// interpreter, from the state written here.
  void _beginAccess(int exitPc) {
    _access = (
      pc: exitPc,
      tag: _pendingReg,
      spent: _count,
      stores: _exitStores()
    );
  }

  IrExit _accessExit(bool write) {
    final at = _access!;
    return IrExit(write ? IopJit.reasonStore : IopJit.reasonInterpret, at.pc,
        tag: at.tag, spent: at.spent, stores: at.stores);
  }

  IrValue _load(int size, IrValue addr, {bool signed = false}) {
    _guardAccess(addr, size);
    return b.load(size, addr, signed: signed, unmapped: _accessExit(false));
  }

  void _store(int size, IrValue addr, IrValue value) {
    _guardAccess(addr, size);
    b.store(size, addr, value, unmapped: _accessExit(true));
  }

  /// Leaves through the access exit unless the address is aligned to
  /// [size] and in RAM; the runtime masks the segment bits off the
  /// address the access itself uses, as the bus does.
  void _guardAccess(IrValue addr, int size) {
    final phys = b.and(addr, b.c32(0x1fffffff));
    var bad = b.eq(b.ltU(phys, b.c32(IopMemory.ramSize)), b.c32(0));
    if (size > 1) {
      bad = b.or(bad, b.ne(b.and(addr, b.c32(size - 1)), b.c32(0)));
    }
    b.exitIf(bad, _accessExit(false));
  }

  /// translates the branch at [addr] and returns its terminator for the
  /// tag after the delay slot
  IrTerm Function(int tag) _branch(int inst, int addr) {
    final rs = (inst >>> 21) & 31, rt = (inst >>> 16) & 31;
    final next = (addr + 8) & 0xffffffff;
    final rel =
        (addr + 4 + ((inst & 0xffff).toSigned(16) << 2)) & 0xffffffff;
    final region = (addr + 4) & 0xf0000000;

    IrTerm Function(int) cond(IrValue c) {
      _commit();
      return (tag) => IrBranch(c, rel, next, tagTrue: tag, tagFalse: tag);
    }

    switch (inst >>> 26) {
      case 0x00: // JR and JALR; the target is read before the link write
        final target = _get(rs);
        _commit(
            imm: (inst & 63) == 0x09
                ? ((inst >>> 11) & 31, b.c32(next))
                : null);
        return (tag) => IrJumpDyn(target, tag: tag);
      case 0x01: // REGIMM, with the interpreter's link condition
        final lt = b.ltS(_get(rs), b.c32(0));
        final c = rt & 1 != 0 ? b.xor(lt, b.c32(1)) : lt;
        if ((rt & 0x1e) == 0x10) {
          _commit(imm: (31, b.c32(next)));
          return (tag) =>
              IrBranch(c, rel, next, tagTrue: tag, tagFalse: tag);
        }
        return cond(c);
      case 0x02:
        _commit();
        final target = region | ((inst & 0x3ffffff) << 2);
        return (tag) => IrJump(target, tag: tag);
      case 0x03:
        _commit(imm: (31, b.c32(next)));
        final target = region | ((inst & 0x3ffffff) << 2);
        return (tag) => IrJump(target, tag: tag);
      case 0x04:
        return cond(b.eq(_get(rs), _get(rt)));
      case 0x05:
        return cond(b.ne(_get(rs), _get(rt)));
      case 0x06: // BLEZ
        return cond(b.xor(b.ltS(b.c32(0), _get(rs)), b.c32(1)));
      default: // 0x07 BGTZ
        return cond(b.ltS(b.c32(0), _get(rs)));
    }
  }

  void _exec(int inst, int addr, {bool accessSet = false}) {
    final rs = (inst >>> 21) & 31, rt = (inst >>> 16) & 31;
    final rd = (inst >>> 11) & 31;
    IrValue s() => _get(rs);
    IrValue u() => _get(rt);
    IrValue simm() => b.c32((inst & 0xffff).toSigned(16));
    IrValue zimm() => b.c32(inst & 0xffff);
    void imm(int reg, IrValue v) => _commit(imm: (reg, v));
    IrValue? address;
    IrValue ea() => address ??= b.add(s(), simm());

    if (!accessSet && _isMemory(inst)) _beginAccess(addr);

    switch (inst >>> 26) {
      case 0x00:
        final sa = b.c32((inst >>> 6) & 31);
        switch (inst & 63) {
          case 0x00:
            imm(rd, b.shl(u(), sa));
          case 0x02:
            imm(rd, b.shrU(u(), sa));
          case 0x03:
            imm(rd, b.shrS(u(), sa));
          case 0x04:
            imm(rd, b.shl(u(), b.and(s(), b.c32(31))));
          case 0x06:
            imm(rd, b.shrU(u(), b.and(s(), b.c32(31))));
          case 0x07:
            imm(rd, b.shrS(u(), b.and(s(), b.c32(31))));
          case 0x10:
            imm(rd, _get(_hi));
          case 0x11:
            _set(_hi, s());
            _commit();
          case 0x12:
            imm(rd, _get(_lo));
          case 0x13:
            _set(_lo, s());
            _commit();
          case 0x18:
            final x = s(), y = u();
            _set(_lo, b.mul(x, y));
            _set(_hi, b.mulHiS(x, y));
            _commit();
          case 0x19:
            final x = s(), y = u();
            _set(_lo, b.mul(x, y));
            _set(_hi, b.mulHiU(x, y));
            _commit();
          case 0x1a || 0x1b:
            b.call(t.div, s(), u(), b.c32((inst & 63) == 0x1a ? 1 : 0));
            // the helper writes hi and lo to the context
            _regs[_hi] = _regs[_lo] = null;
            _dirty[_hi] = _dirty[_lo] = false;
            _commit();
          case 0x20:
            _overflowing(rd, s(), u(), addr, add: true);
          case 0x21:
            imm(rd, b.add(s(), u()));
          case 0x22:
            _overflowing(rd, s(), u(), addr, add: false);
          case 0x23:
            imm(rd, b.sub(s(), u()));
          case 0x24:
            imm(rd, b.and(s(), u()));
          case 0x25:
            imm(rd, b.or(s(), u()));
          case 0x26:
            imm(rd, b.xor(s(), u()));
          case 0x27:
            imm(rd, b.not(b.or(s(), u())));
          case 0x2a:
            imm(rd, b.ltS(s(), u()));
          default: // 0x2b
            imm(rd, b.ltU(s(), u()));
        }
      case 0x08:
        _overflowing(rt, s(), simm(), addr, add: true);
      case 0x09:
        imm(rt, b.add(s(), simm()));
      case 0x0a:
        imm(rt, b.ltS(s(), simm()));
      case 0x0b:
        imm(rt, b.ltU(s(), simm()));
      case 0x0c:
        imm(rt, b.and(s(), zimm()));
      case 0x0d:
        imm(rt, b.or(s(), zimm()));
      case 0x0e:
        imm(rt, b.xor(s(), zimm()));
      case 0x0f:
        imm(rt, b.c32((inst & 0xffff) << 16));
      case 0x10: // MFC0
        _commit(load: (rt, b.call(t.mfc0, b.c32(rd))));
      case 0x20:
        _commit(load: (rt, _load(1, ea(), signed: true)));
      case 0x21:
        _commit(load: (rt, _load(2, ea(), signed: true)));
      case 0x22:
        _commit(load: (rt, _lwl(ea(), _inDelay(rt))));
      case 0x23:
        _commit(load: (rt, _load(4, ea())));
      case 0x24:
        _commit(load: (rt, _load(1, ea())));
      case 0x25:
        _commit(load: (rt, _load(2, ea())));
      case 0x26:
        _commit(load: (rt, _lwr(ea(), _inDelay(rt))));
      case 0x28:
        _store(1, ea(), u());
        _commit();
      case 0x29:
        _store(2, ea(), u());
        _commit();
      case 0x2a:
        _swl(ea(), u());
        _commit();
      case 0x2b:
        _store(4, ea(), u());
        _commit();
      case 0x2e:
        _swr(ea(), u());
        _commit();
    }
  }

  /// the value lwl and lwr merge with: the load in delay to the same
  /// register, as the interpreter reads it
  IrValue _inDelay(int reg) =>
      _pendingReg == reg && reg != 0 ? _pendingValue! : _get(reg);

  /// add, addi and sub: leave to the interpreter on an overflow
  void _overflowing(int dst, IrValue x, IrValue y, int addr,
      {required bool add}) {
    final r = add ? b.add(x, y) : b.sub(x, y);
    final sign = add
        ? b.and(b.not(b.xor(x, y)), b.xor(r, x))
        : b.and(b.xor(x, y), b.xor(r, x));
    final overflow = b.shrU(sign, b.c32(31));
    b.exitIf(
        overflow,
        IrExit(IopJit.reasonInterpret, addr,
            tag: _pendingReg, spent: _count, stores: _exitStores()));
    _commit(imm: (dst, r));
  }

  // the unaligned accesses, with shifts by the byte offset within the
  // aligned word, as the interpreter merges them

  IrValue _lwl(IrValue addr, IrValue org) {
    final value = _load(4, b.and(addr, b.c32(~3)));
    final shift = b.shl(b.xor(b.and(addr, b.c32(3)), b.c32(3)), b.c32(3));
    final keep = b.sub(b.shl(b.c32(1), shift), b.c32(1));
    return b.or(b.shl(value, shift), b.and(org, keep));
  }

  IrValue _lwr(IrValue addr, IrValue org) {
    final value = _load(4, b.and(addr, b.c32(~3)));
    final shift = b.shl(b.and(addr, b.c32(3)), b.c32(3));
    final keep = b.not(b.shrU(b.c32(-1), shift));
    return b.or(b.shrU(value, shift), b.and(org, keep));
  }

  void _swl(IrValue addr, IrValue value) {
    final aligned = b.and(addr, b.c32(~3));
    final old = _load(4, aligned);
    final shift = b.shl(b.xor(b.and(addr, b.c32(3)), b.c32(3)), b.c32(3));
    final keep = b.not(b.shrU(b.c32(-1), shift));
    _store(4, aligned, b.or(b.shrU(value, shift), b.and(old, keep)));
  }

  void _swr(IrValue addr, IrValue value) {
    final aligned = b.and(addr, b.c32(~3));
    final old = _load(4, aligned);
    final shift = b.shl(b.and(addr, b.c32(3)), b.c32(3));
    final keep = b.sub(b.shl(b.c32(1), shift), b.c32(1));
    _store(4, aligned, b.or(b.shl(value, shift), b.and(old, keep)));
  }
}
