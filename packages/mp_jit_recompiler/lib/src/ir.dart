/// The IR of a guest code block.
///
/// A block is straight-line SSA code with one entry, optional side exits
/// ([IrBuilder.exitIf]) and one terminator. Every value is a 32-bit integer.
/// Guest state lives in the context, an array of 32-bit words shared with the
/// host; [IrBuilder.ctxLoad] and [IrBuilder.ctxStore] access it by a constant
/// word index. Guest memory is accessed through the page table of the runtime.
library;

/// The operations of [IrInst].
enum IrOp {
  /// `imm`
  constant,

  /// ctx[imm]
  ctxLoad,

  /// ctx[imm] = a
  ctxStore,

  add,
  sub,
  mul,

  /// the upper 32 bits of the signed 64-bit product
  mulHiS,

  /// the upper 32 bits of the unsigned 64-bit product
  mulHiU,
  and,
  or,
  xor,

  /// a << (b & 31)
  shl,

  /// a >>> (b & 31)
  shrU,

  /// a >> (b & 31), arithmetic
  shrS,

  /// 1 if a == b else 0
  eq,
  ne,

  /// signed a < b
  ltS,

  /// unsigned a < b
  ltU,

  /// a != 0 ? b : c
  select,
  sext8,
  sext16,
  zext8,
  zext16,

  /// loads imm bytes (1, 2 or 4) at the guest address a; aux is 1 to sign
  /// extend
  load,

  /// stores imm bytes (1, 2 or 4) of b at the guest address a
  store,

  /// calls the helper imm with (a, b, c) and returns its result
  call,

  /// exits the block if a != 0, see [IrExit]
  exitIf,

  /// exits through aux if address a has no mapped page; imm is 1 for write
  guardMapped,
}

/// Number of value operands of each [IrOp].
int irOperandCount(IrOp op) => switch (op) {
      IrOp.constant || IrOp.ctxLoad => 0,
      IrOp.ctxStore ||
      IrOp.sext8 ||
      IrOp.sext16 ||
      IrOp.zext8 ||
      IrOp.zext16 ||
      IrOp.load ||
      IrOp.exitIf ||
      IrOp.guardMapped =>
        1,
      IrOp.select || IrOp.call => 3,
      _ => 2,
    };

/// Whether an [IrOp] produces a value.
bool irHasResult(IrOp op) =>
    op != IrOp.ctxStore &&
    op != IrOp.store &&
    op != IrOp.exitIf &&
    op != IrOp.guardMapped;

/// A value produced by an instruction, identified by its index in the block.
extension type const IrValue(int index) {}

/// One instruction. Unused operands are -1.
final class IrInst {
  final IrOp op;
  final int a, b, c;

  /// constant, context index, access size or helper id
  final int imm;

  /// sign extension of a load, or the exit of an exitIf
  final int aux;

  const IrInst(this.op,
      {this.a = -1, this.b = -1, this.c = -1, this.imm = 0, this.aux = 0});

  @override
  String toString() {
    final ops = [a, b, c].where((v) => v >= 0).map((v) => 'v$v').join(', ');
    return '${op.name}($ops${ops.isEmpty ? '' : ', '}imm: $imm, aux: $aux)';
  }
}

/// Where a block leaves to the host. The host reads [reason], [pc] and [tag]
/// from the reserved context words after the run returns.
final class IrExit {
  /// a host defined reason, at least [JitReason.user]
  final int reason;
  final int pc;
  final int tag;

  /// clocks of the block cost taken by the part run before the exit; the
  /// rest is given back to the budget. Null takes the whole cost.
  final int? spent;

  const IrExit(this.reason, this.pc, {this.tag = 0, this.spent});

  int refund(int cost) => spent == null ? 0 : cost - spent!;
}

/// The reasons a run returns with. Host reasons start at [user].
abstract final class JitReason {
  /// the budget ran out or the stop word was set at the entry of a block
  static const budget = 1;

  /// the next block (exit pc and tag) is not installed
  static const miss = 2;

  /// a code guard of the block failed at its entry
  static const invalid = 3;

  static const user = 16;
}

/// The reserved words at the start of the context.
abstract final class JitCtx {
  static const exitReason = 0;
  static const exitPc = 1;
  static const exitTag = 2;

  /// signed clocks left; a block exits at its entry when this is <= 0
  static const budget = 3;

  /// a block exits at its entry when this is not 0
  static const stop = 4;

  /// the first word free for the guest
  static const user = 8;
}

/// How a block ends.
sealed class IrTerm {
  const IrTerm();
}

/// Continues at the block ([pc], [tag]).
final class IrJump extends IrTerm {
  final int pc, tag;
  const IrJump(this.pc, {this.tag = 0});
}

/// Continues at ([pcTrue], [tagTrue]) if [cond] != 0, else at the other.
final class IrBranch extends IrTerm {
  final IrValue cond;
  final int pcTrue, tagTrue, pcFalse, tagFalse;
  const IrBranch(this.cond, this.pcTrue, this.pcFalse,
      {this.tagTrue = 0, this.tagFalse = 0});
}

/// Continues at the block whose pc is the value [pc].
final class IrJumpDyn extends IrTerm {
  final IrValue pc;
  final int tag;
  const IrJumpDyn(this.pc, {this.tag = 0});
}

/// Returns to the host.
final class IrExitTerm extends IrTerm {
  final IrExit exit;
  const IrExitTerm(this.exit);
}

/// A word of guest memory that must still hold [value] when the block is
/// entered, used to detect modified code.
typedef IrGuard = ({int addr, int value});

final class IrBlock {
  /// the key of the block
  final int pc, tag;

  /// clocks taken from the budget at the entry
  final int cost;
  final List<IrInst> insts;
  final IrTerm term;
  final List<IrGuard> guards;

  /// side exits referenced by exitIf instructions
  final List<IrExit> exits;

  IrBlock(this.pc, this.tag, this.cost, this.insts, this.term, this.guards,
      this.exits) {
    verify();
  }

  /// checks the operands of every instruction
  void verify() {
    void check(bool ok, String message) {
      if (!ok) throw StateError('IrBlock ${pc.toRadixString(16)}: $message');
    }

    void value(int v, int at) => check(
        v >= 0 && v < at && irHasResult(insts[v].op),
        'v$at uses an invalid value v$v');

    for (int i = 0; i < insts.length; i++) {
      final inst = insts[i];
      final n = irOperandCount(inst.op);
      for (final (k, v) in [inst.a, inst.b, inst.c].indexed) {
        if (k < n) {
          value(v, i);
        } else {
          check(v == -1, 'v$i has an extra operand');
        }
      }
      switch (inst.op) {
        case IrOp.load || IrOp.store:
          check(inst.imm == 1 || inst.imm == 2 || inst.imm == 4,
              'v$i has an invalid size ${inst.imm}');
        case IrOp.exitIf || IrOp.guardMapped:
          check(inst.aux >= 0 && inst.aux < exits.length,
              'v$i has an invalid exit ${inst.aux}');
          final spent = exits[inst.aux].spent;
          check(spent == null || (spent >= 0 && spent <= cost),
              'v$i spends more than the cost');
        case IrOp.ctxLoad || IrOp.ctxStore:
          check(inst.imm >= 0, 'v$i has an invalid context index');
        default:
      }
    }
    switch (term) {
      case IrBranch(:final cond):
        value(cond.index, insts.length);
      case IrJumpDyn(pc: final v):
        value(v.index, insts.length);
      default:
    }
  }

  @override
  String toString() => [
        'block ${pc.toRadixString(16)}/$tag cost $cost',
        for (final g in guards)
          '  guard ${g.addr.toRadixString(16)} == ${g.value.toRadixString(16)}',
        for (final (i, inst) in insts.indexed) '  v$i = $inst',
        '  $term',
      ].join('\n');
}

/// Builds an [IrBlock].
final class IrBuilder {
  final int pc, tag;
  final _insts = <IrInst>[];
  final _guards = <IrGuard>[];
  final _exits = <IrExit>[];
  final _constants = <int, IrValue>{};

  IrBuilder(this.pc, {this.tag = 0});

  int get length => _insts.length;

  IrValue _emit(IrInst inst) {
    _insts.add(inst);
    return IrValue(_insts.length - 1);
  }

  IrValue _bin(IrOp op, IrValue a, IrValue b) =>
      _emit(IrInst(op, a: a.index, b: b.index));

  /// a constant; the same constant is shared in a block
  IrValue c32(int value) {
    value = value.toSigned(32);
    return _constants[value] ??= _emit(IrInst(IrOp.constant, imm: value));
  }

  IrValue ctxLoad(int index) => _emit(IrInst(IrOp.ctxLoad, imm: index));
  void ctxStore(int index, IrValue v) =>
      _emit(IrInst(IrOp.ctxStore, a: v.index, imm: index));

  IrValue add(IrValue a, IrValue b) => _bin(IrOp.add, a, b);
  IrValue sub(IrValue a, IrValue b) => _bin(IrOp.sub, a, b);
  IrValue mul(IrValue a, IrValue b) => _bin(IrOp.mul, a, b);
  IrValue mulHiS(IrValue a, IrValue b) => _bin(IrOp.mulHiS, a, b);
  IrValue mulHiU(IrValue a, IrValue b) => _bin(IrOp.mulHiU, a, b);
  IrValue and(IrValue a, IrValue b) => _bin(IrOp.and, a, b);
  IrValue or(IrValue a, IrValue b) => _bin(IrOp.or, a, b);
  IrValue xor(IrValue a, IrValue b) => _bin(IrOp.xor, a, b);
  IrValue not(IrValue a) => xor(a, c32(-1));
  IrValue shl(IrValue a, IrValue b) => _bin(IrOp.shl, a, b);
  IrValue shrU(IrValue a, IrValue b) => _bin(IrOp.shrU, a, b);
  IrValue shrS(IrValue a, IrValue b) => _bin(IrOp.shrS, a, b);
  IrValue eq(IrValue a, IrValue b) => _bin(IrOp.eq, a, b);
  IrValue ne(IrValue a, IrValue b) => _bin(IrOp.ne, a, b);
  IrValue ltS(IrValue a, IrValue b) => _bin(IrOp.ltS, a, b);
  IrValue ltU(IrValue a, IrValue b) => _bin(IrOp.ltU, a, b);
  IrValue select(IrValue cond, IrValue a, IrValue b) =>
      _emit(IrInst(IrOp.select, a: cond.index, b: a.index, c: b.index));
  IrValue sext8(IrValue a) => _emit(IrInst(IrOp.sext8, a: a.index));
  IrValue sext16(IrValue a) => _emit(IrInst(IrOp.sext16, a: a.index));
  IrValue zext8(IrValue a) => _emit(IrInst(IrOp.zext8, a: a.index));
  IrValue zext16(IrValue a) => _emit(IrInst(IrOp.zext16, a: a.index));

  IrValue load(int size, IrValue addr, {bool signed = false}) =>
      _emit(IrInst(IrOp.load, a: addr.index, imm: size, aux: signed ? 1 : 0));
  void store(int size, IrValue addr, IrValue v) =>
      _emit(IrInst(IrOp.store, a: addr.index, b: v.index, imm: size));

  IrValue call(int helper, [IrValue? a, IrValue? b, IrValue? c]) {
    final zero = c32(0);
    return _emit(IrInst(IrOp.call,
        a: (a ?? zero).index,
        b: (b ?? zero).index,
        c: (c ?? zero).index,
        imm: helper));
  }

  void exitIf(IrValue cond, IrExit exit) {
    _exits.add(exit);
    _emit(IrInst(IrOp.exitIf, a: cond.index, aux: _exits.length - 1));
  }

  /// Exits before an access requiring a host callback. The caller can
  /// synchronize guest state and execute that access outside the block.
  void guardMapped(IrValue address, IrExit exit, {bool write = false}) {
    _exits.add(exit);
    _emit(IrInst(IrOp.guardMapped,
        a: address.index, imm: write ? 1 : 0, aux: _exits.length - 1));
  }

  void guard(int addr, int value) =>
      _guards.add((addr: addr.toUnsigned(32), value: value.toUnsigned(32)));

  IrBlock finish(IrTerm term, {required int cost}) => IrBlock(
      pc,
      tag,
      cost,
      List.unmodifiable(_insts),
      term,
      List.unmodifiable(_guards),
      List.unmodifiable(_exits));
}
