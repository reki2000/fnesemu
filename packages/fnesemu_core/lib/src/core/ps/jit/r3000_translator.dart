import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../../../util/int.dart';
import 'ps_jit.dart';

/// Translates R3000 code to [IrBlock]s with the semantics of [R3000.step].
///
/// A block ends after a branch and its delay slot. Device accesses and
/// writes to code pages exit before the instruction, so the interpreter
/// observes the exact clocks and architectural state. Code guards are
/// checked again after the interpreter completes the write.
/// The load delay is modelled as in the interpreter: a loaded value lands after
/// the next instruction unless that instruction loads the same register.
/// A load which is still in its delay at the end of a block is passed to
/// the next block as its tag (the register number) with the value in the
/// context, so a block is keyed by the pc and the register in delay.
///
/// Instructions the blocks leave to the interpreter end a block with
/// [PsJit.reasonInterpret] before them: COP0, syscall, break, unknown
/// opcodes, the BIOS hook addresses, and a branch whose delay slot is one
/// of them or may raise an overflow. add, addi and sub leave the block when
/// they overflow, so that the interpreter raises the exception.
final class R3000Translator {
  /// the code word at pc, and whether it is guarded; null if the address
  /// holds no code the blocks can run
  final (int, bool)? Function(int pc) fetch;

  /// whether the block ends after a store at pc, for code next to data
  final bool Function(int pc) endsAfterStore;
  final int cop2Cmd, mfc2, cfc2, mtc2, ctc2, div;

  static const maxInstructions = 64;
  static const _clocksPerInstruction = 2;

  R3000Translator(
      {required this.fetch,
      required this.endsAfterStore,
      required this.cop2Cmd,
      required this.mfc2,
      required this.cfc2,
      required this.mtc2,
      required this.ctc2,
      required this.div});

  /// the addresses where [R3000.step] calls its hook first
  static bool isHook(int pc) => (pc & 0x1fffff) <= 0xc0 || pc == 0x80030000;

  IrBlock translate(int pc, int tag) => _Block(this, pc, tag).translate();
}

enum _Kind { plain, overflow, branch, interpret }

_Kind _kindOf(int inst) {
  final rs = inst.shr21.mask5;
  return switch (inst.shr26.mask6) {
    0x00 => switch (inst.mask6) {
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
    0x12 => rs >= 0x10 || rs == 0 || rs == 2 || rs == 4 || rs == 6
        ? _Kind.plain
        : _Kind.interpret,
    >= 0x20 && <= 0x26 => _Kind.plain,
    0x28 || 0x29 || 0x2a || 0x2b || 0x2e => _Kind.plain,
    0x32 || 0x3a => _Kind.plain,
    _ => _Kind.interpret,
  };
}

final class _Block {
  final R3000Translator t;
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
      _pendingValue = b.ctxLoad(PsJit.ctxPendingValue);
    }
  }

  static int _ctxOf(int reg) => switch (reg) {
        _hi => PsJit.ctxHi,
        _lo => PsJit.ctxLo,
        _ => PsJit.ctxRegs + reg,
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

  /// the context stores of a side exit: the registers not yet written and
  /// the load in delay, written only when the block leaves there
  List<(int, IrValue)> _exitStores() => [
        for (int r = 1; r < 34; r++)
          if (_dirty[r]) (_ctxOf(r), _regs[r]!),
        if (_pendingReg != 0) (PsJit.ctxPendingValue, _pendingValue!),
      ];

  /// writes the known registers and the load in delay to the context
  void _flush() {
    for (int r = 1; r < 34; r++) {
      if (_dirty[r]) {
        b.ctxStore(_ctxOf(r), _regs[r]!);
        _dirty[r] = false;
      }
    }
    if (_pendingReg != 0) b.ctxStore(PsJit.ctxPendingValue, _pendingValue!);
  }

  int get _cost => _count * R3000Translator._clocksPerInstruction;

  /// ends the instruction: the load in delay lands unless [load] replaces
  /// it, then [imm] is written, and [load] starts its delay
  void _commit({(int, IrValue)? imm, (int, IrValue)? load}) {
    if (_pendingReg != 0 && load?.$1 != _pendingReg) {
      _set(_pendingReg, _pendingValue!);
    }
    if (imm != null) _set(imm.$1, imm.$2);
    _pendingReg = load == null ? 0 : load.$1;
    _pendingValue = _pendingReg == 0 ? null : load!.$2;
    _count++;
  }

  IrBlock _interpretAt(int addr) {
    _flush();
    return b.finish(
        IrExitTerm(IrExit(PsJit.reasonInterpret, addr, tag: _pendingReg)),
        cost: _cost);
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
      final addr = (pc + 4 * i).mask32;
      final inst = R3000Translator.isHook(addr) ? null : _fetch(addr);
      if (i > 0 && (inst == null || i >= R3000Translator.maxInstructions)) {
        _flush();
        return b.finish(IrJump(addr, tag: _pendingReg), cost: _cost);
      }
      if (inst == null) return _interpretAt(addr);

      switch (_kindOf(inst)) {
        case _Kind.interpret:
          return _interpretAt(addr);
        case _Kind.plain:
          _exec(inst, addr);
          if (_isStore(inst) && t.endsAfterStore(addr)) {
            _flush();
            return b.finish(IrJump((addr + 4).mask32, tag: _pendingReg),
                cost: _cost);
          }
        case _Kind.overflow:
          _exec(inst, addr);
        case _Kind.branch:
          final slotAddr = (addr + 4).mask32;
          final slot =
              R3000Translator.isHook(slotAddr) ? null : _fetch(slotAddr);
          if (slot == null || _kindOf(slot) != _Kind.plain) {
            return _interpretAt(addr);
          }
          // A device access in the slot exits at the branch with the state
          // before it, which the interpreter runs with its delay slot.
          if (_isMemory(slot)) _beginAccess(addr);
          final term = _branch(inst, addr);
          _exec(slot, slotAddr, accessSet: true);
          _flush();
          return b.finish(term(_pendingReg), cost: _cost);
      }
    }
  }

  static bool _isStore(int inst) => switch (inst.shr26.mask6) {
        0x28 || 0x29 || 0x2a || 0x2b || 0x2e || 0x3a => true,
        _ => false,
      };

  static bool _isMemory(int inst) => switch (inst.shr26.mask6) {
        >= 0x20 && <= 0x26 || 0x32 => true,
        _ => _isStore(inst),
      };

  /// where the accesses of the current instruction leave when their page
  /// is unmapped: before the instruction, or before its branch
  ({int pc, int tag, int spent, List<(int, IrValue)> stores})? _access;

  /// The runtime mappings define ordinary memory. Device accesses and
  /// writes to protected code pages run once through the interpreter, from
  /// the state written here.
  void _beginAccess(int exitPc) {
    _access =
        (pc: exitPc, tag: _pendingReg, spent: _cost, stores: _exitStores());
  }

  IrExit _accessExit(bool write) {
    final at = _access!;
    return IrExit(write ? PsJit.reasonStore : PsJit.reasonInterpret, at.pc,
        tag: at.tag, spent: at.spent, stores: at.stores);
  }

  IrValue _load(int size, IrValue addr, {bool signed = false}) =>
      b.load(size, addr, signed: signed, unmapped: _accessExit(false));

  void _store(int size, IrValue addr, IrValue value) =>
      b.store(size, addr, value, unmapped: _accessExit(true));

  /// translates the branch at [addr] and returns its terminator for the
  /// tag after the delay slot
  IrTerm Function(int tag) _branch(int inst, int addr) {
    final rs = inst.shr21.mask5, rt = inst.shr16.mask5;
    final next = (addr + 8).mask32;
    final rel = (addr + 4 + inst.rel16.shl2).mask32;
    final region = (addr + 4) & 0xf0000000;

    IrTerm Function(int) cond(IrValue c) {
      _commit();
      return (tag) => IrBranch(c, rel, next, tagTrue: tag, tagFalse: tag);
    }

    switch (inst.shr26.mask6) {
      case 0x00:
        final target = _get(rs);
        _commit(
            imm: inst.mask6 == 0x09 ? (inst.shr11.mask5, b.c32(next)) : null);
        return (tag) => IrJumpDyn(target, tag: tag);
      case 0x01:
        // bltz, bgez, and bltzal and bgezal which link even if not taken
        final lt = b.ltS(_get(rs), b.c32(0));
        final c = rt.bit0 ? b.xor(lt, b.c32(1)) : lt;
        if (rt == 0x10 || rt == 0x11) {
          _commit(imm: (31, b.c32(next)));
          return (tag) => IrBranch(c, rel, next, tagTrue: tag, tagFalse: tag);
        }
        return cond(c);
      case 0x02:
        _commit();
        final target = region | inst.mask26.shl2;
        return (tag) => IrJump(target, tag: tag);
      case 0x03:
        _commit(imm: (31, b.c32(next)));
        final target = region | inst.mask26.shl2;
        return (tag) => IrJump(target, tag: tag);
      case 0x04:
        return cond(b.eq(_get(rs), _get(rt)));
      case 0x05:
        return cond(b.ne(_get(rs), _get(rt)));
      case 0x06:
        return cond(b.xor(b.ltS(b.c32(0), _get(rs)), b.c32(1)));
      default: // 0x07
        return cond(b.ltS(b.c32(0), _get(rs)));
    }
  }

  void _exec(int inst, int addr, {bool accessSet = false}) {
    final rs = inst.shr21.mask5, rt = inst.shr16.mask5, rd = inst.shr11.mask5;
    IrValue s() => _get(rs);
    IrValue u() => _get(rt);
    IrValue simm() => b.c32(inst.rel16);
    IrValue zimm() => b.c32(inst.mask16);
    void imm(int reg, IrValue v) => _commit(imm: (reg, v));
    IrValue? address;
    IrValue ea() => address ??= b.add(s(), simm());

    if (!accessSet && _isMemory(inst)) _beginAccess(addr);

    // an operation without side effects whose result is dropped
    final op = inst.shr26.mask6;
    if ((op == 0x00 && rd == 0 && _pure(inst.mask6)) ||
        (op >= 0x09 && op <= 0x0f && rt == 0)) {
      _commit();
      return;
    }

    switch (inst.shr26.mask6) {
      case 0x00:
        final sa = b.c32(inst.shr6.mask5);
        switch (inst.mask6) {
          case 0x00:
            imm(rd, b.shl(u(), sa));
          case 0x02:
            imm(rd, b.shrU(u(), sa));
          case 0x03:
            imm(rd, b.shrS(u(), sa));
          case 0x04:
            imm(rd, b.shl(u(), s()));
          case 0x06:
            imm(rd, b.shrU(u(), s()));
          case 0x07:
            imm(rd, b.shrS(u(), s()));
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
            b.call(t.div, s(), u(), b.c32(inst.mask6 == 0x1a ? 1 : 0));
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
        imm(rt, b.c32(inst.mask16.shl16));
      case 0x12:
        if (rs >= 0x10) {
          b.call(t.cop2Cmd, b.c32(inst));
          _commit();
        } else {
          switch (rs) {
            case 0x00:
              _commit(load: (rt, b.call(t.mfc2, b.c32(rd))));
            case 0x02:
              _commit(load: (rt, b.call(t.cfc2, b.c32(rd))));
            case 0x04:
              b.call(t.mtc2, b.c32(rd), u());
              _commit();
            default: // 0x06
              b.call(t.ctc2, b.c32(rd), u());
              _commit();
          }
        }
      case 0x20:
        _commit(load: (rt, _load(1, ea(), signed: true)));
      case 0x21:
        _commit(load: (rt, _load(2, b.and(ea(), b.c32(~1)), signed: true)));
      case 0x22:
        _commit(load: (rt, _lwl(ea(), _inDelay(rt))));
      case 0x23:
        _commit(load: (rt, _load(4, b.and(ea(), b.c32(~3)))));
      case 0x24:
        _commit(load: (rt, _load(1, ea())));
      case 0x25:
        _commit(load: (rt, _load(2, b.and(ea(), b.c32(~1)))));
      case 0x26:
        _commit(load: (rt, _lwr(ea(), _inDelay(rt))));
      case 0x28:
        _store(1, ea(), u());
        _commit();
      case 0x29:
        _store(2, b.and(ea(), b.c32(~1)), u());
        _commit();
      case 0x2a:
        _swl(ea(), u());
        _commit();
      case 0x2b:
        _store(4, b.and(ea(), b.c32(~3)), u());
        _commit();
      case 0x2e:
        _swr(ea(), u());
        _commit();
      case 0x32: // lwc2
        b.call(t.mtc2, b.c32(rt), _load(4, b.and(ea(), b.c32(~3))));
        _commit();
      default: // 0x3a swc2
        final a = b.and(ea(), b.c32(~3));
        _store(4, a, b.call(t.mfc2, b.c32(rt)));
        _commit();
    }
  }

  static bool _pure(int funct) =>
      funct <= 0x07 ||
      funct == 0x10 ||
      funct == 0x12 ||
      funct == 0x21 ||
      (funct >= 0x23 && funct <= 0x27) ||
      funct == 0x2a ||
      funct == 0x2b;

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
        IrExit(PsJit.reasonInterpret, addr,
            tag: _pendingReg, spent: _cost, stores: _exitStores()));
    _commit(imm: (dst, r));
  }

  // the unaligned accesses, as in alu.dart with shifts by the byte offset

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
