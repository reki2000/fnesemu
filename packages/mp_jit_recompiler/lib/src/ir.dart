/// The IR of a guest code block.
///
/// A block is straight-line SSA code with one entry, optional side exits
/// ([IrBuilder.exitIf]) and one terminator. Values have explicit i32 or i64 widths.
/// Guest state lives in the context, an array of 32-bit words shared with the
/// host; [IrBuilder.ctxLoad] and [IrBuilder.ctxStore] access it by a constant
/// word index; i64 context values occupy two words, low word first. Guest
/// addresses remain i32 independently of value width. Memory byte order is
/// explicit on each access and is independent of the context layout.
library;

/// Value widths for bit patterns; integer arithmetic wraps at the declared width.
enum IrType {
  i32(32),
  i64(64);

  final int bits;
  const IrType(this.bits);
  int get bytes => bits ~/ 8;
}

/// Byte order of a guest memory access, independent of host byte order.
enum IrEndian { little, big }

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

  /// IEEE bit patterns: evaluate in binary64, then round to the result width.
  /// Frontends requiring specific NaN payload behavior must guard operands.
  floatAdd,
  floatSub,
  floatMul,

  /// Converts IEEE bits between binary32 (i32) and binary64 (i64); widening
  /// is exact and narrowing rounds to nearest even.
  floatConvert,

  /// Converts IEEE bits (binary32 in i32 or binary64 in i64) to a signed
  /// 32-bit integer, rounding to nearest even (imm 0) or toward zero (imm 1).
  /// Nonfinite and out-of-range results are unspecified; frontends guard.
  floatToInt,

  /// the upper half of the signed double-width product
  mulHiS,

  /// the upper half of the unsigned double-width product
  mulHiU,
  and,
  or,
  xor,

  /// a << (b & (width - 1)); b is i32
  shl,

  /// a >>> (b & (width - 1)); b is i32
  shrU,

  /// a >> (b & (width - 1)), arithmetic; b is i32
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

  /// Sign/zero extends an i32 value to i64, or truncates i64 to i32.
  sext32,
  zext32,
  trunc32,

  /// loads imm bytes (1, 2, 4 or 8) at the guest address a; aux is 1 to sign
  /// extend. With an [IrInst.exit], an unmapped page exits the block instead
  /// of calling the host read function
  load,

  /// stores imm bytes (1, 2, 4 or 8) of b at the guest address a; an
  /// [IrInst.exit] works as for load
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
      IrOp.sext32 ||
      IrOp.zext32 ||
      IrOp.trunc32 ||
      IrOp.floatConvert ||
      IrOp.floatToInt ||
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

  /// Result width, or the stored value width for ctxStore/store.
  /// Comparisons and conditions produce i32, even with i64 operands.
  final IrType type;
  final IrEndian endian;

  /// Upper constant word for i64; imm holds the low word. This avoids
  /// routing exact 64-bit constants through JavaScript numbers.
  final int immHi;
  final int a, b, c;

  /// constant, context index, access size or helper id
  final int imm;

  /// sign extension of a load, or the exit of an exitIf
  final int aux;

  /// the exit of a load or store at an unmapped page, or -1 to call the
  /// host read or write function
  final int exit;

  const IrInst(this.op,
      {this.a = -1,
      this.b = -1,
      this.c = -1,
      this.imm = 0,
      this.aux = 0,
      this.exit = -1,
      this.type = IrType.i32,
      this.endian = IrEndian.little,
      this.immHi = 0});

  @override
  String toString() {
    final ops = [a, b, c].where((v) => v >= 0).map((v) => 'v$v').join(', ');
    return '${op.name}.${type.name}.${endian.name}($ops${ops.isEmpty ? '' : ', '}imm: $imm, immHi: $immHi, aux: $aux${exit < 0 ? '' : ', exit: $exit'})';
  }
}

/// A side exit either returns to the host or links to another block.
/// After a host return, the reserved context words contain [reason], [pc] and [tag].
final class IrExit {
  /// a host defined reason, at least [JitReason.user]
  final int reason;

  /// Chain to (pc, tag) after stores and the refund, with normal entry checks.
  /// A missing target returns JitReason.miss; reason is ignored when linking.
  final bool link;
  final int pc;
  final int tag;

  /// clocks of the block cost taken by the part run before the exit; the
  /// rest is given back to the budget. Null takes the whole cost.
  final int? spent;

  /// context words written only when the block leaves through this exit,
  /// such as guest registers kept in values; an i64 value writes two words
  final List<(int, IrValue)> stores;

  const IrExit(
    this.reason,
    this.pc, {
    this.tag = 0,
    this.spent,
    this.stores = const [],
    this.link = false,
  });

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

  /// the guest address of the access which left through an unmapped page
  /// exit, see [IrInst.exit] and [IrOp.guardMapped]
  static const faultAddr = 5;

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
typedef IrGuard = ({int addr, int value, IrEndian endian});

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

  late final bool usesI64 = insts.any((i) => i.type == IrType.i64);

  /// Checks SSA operands and widths; runtimes also check context bounds.
  void verify({int? ctxWords}) {
    // Messages are built only on failure; verification runs per block.
    Never fail(String message) =>
        throw StateError('IrBlock ${pc.toRadixString(16)}: $message');

    void value(int v, int at) {
      if (!(v >= 0 && v < at && irHasResult(insts[v].op))) {
        fail('v$at uses an invalid value v$v');
      }
    }

    IrType type(int v) => insts[v].type;
    if (!(cost >= 0)) {
      fail('negative block cost');
    }
    void exitStores(int at, IrExit e) {
      for (final (word, v) in e.stores) {
        value(v.index, at);
        if (!(word >= 0 &&
            (ctxWords == null ||
                word + insts[v.index].type.bytes ~/ 4 <= ctxWords))) {
          fail('an exit of v$at has an invalid store');
        }
      }
    }

    void exitAt(int i, int e) {
      if (!(e >= 0 && e < exits.length)) {
        fail('v$i has an invalid exit');
      }
      final spent = exits[e].spent;
      if (!(spent == null || (spent >= 0 && spent <= cost))) {
        fail('v$i spends more than the cost');
      }
      exitStores(i, exits[e]);
    }

    for (int i = 0; i < insts.length; i++) {
      final inst = insts[i];
      final n = irOperandCount(inst.op);
      if (n > 0) {
        value(inst.a, i);
      } else {
        if (!(inst.a == -1)) {
          fail('v$i has an extra operand');
        }
      }
      if (n > 1) {
        value(inst.b, i);
      } else {
        if (!(inst.b == -1)) {
          fail('v$i has an extra operand');
        }
      }
      if (n > 2) {
        value(inst.c, i);
      } else {
        if (!(inst.c == -1)) {
          fail('v$i has an extra operand');
        }
      }
      void width(bool ok) {
        if (!ok) fail('v$i has incompatible operand/result widths');
      }

      if (!(inst.op == IrOp.load ||
          inst.op == IrOp.store ||
          inst.endian == IrEndian.little)) {
        fail('v$i assigns byte order to a non-memory operation');
      }
      if (!(inst.op == IrOp.constant || inst.immHi == 0)) {
        fail('v$i has an extra constant word');
      }
      if (!(inst.op == IrOp.load || inst.op == IrOp.store || inst.exit == -1)) {
        fail('v$i has an unmapped exit on a non-memory operation');
      }
      switch (inst.op) {
        case IrOp.constant:
          if (!(inst.type == IrType.i64 || inst.immHi == 0)) {
            fail('i32 constant has an upper word');
          }
        case IrOp.ctxLoad || IrOp.ctxStore:
          if (!(inst.imm >= 0 &&
              (ctxWords == null ||
                  inst.imm + inst.type.bytes ~/ 4 <= ctxWords))) {
            fail('v$i has an out-of-bounds context access');
          }
          if (inst.op == IrOp.ctxStore) width(type(inst.a) == inst.type);
        case IrOp.load || IrOp.store:
          if (!([1, 2, 4, 8].contains(inst.imm) &&
              inst.imm <= inst.type.bytes)) {
            fail('v$i has an invalid access size ${inst.imm}');
          }
          width(type(inst.a) == IrType.i32);
          if (inst.exit >= 0) exitAt(i, inst.exit);
          if (inst.op == IrOp.store) {
            width(type(inst.b) == inst.type);
          } else {
            if (!(inst.aux == 0 || inst.aux == 1)) {
              fail('v$i has invalid sign extension');
            }
          }
        case IrOp.call:
          width(
            inst.type == IrType.i32 &&
                [inst.a, inst.b, inst.c].every((v) => type(v) == IrType.i32),
          );
        case IrOp.exitIf || IrOp.guardMapped:
          width(inst.type == IrType.i32 && type(inst.a) == IrType.i32);
          exitAt(i, inst.aux);
          if (inst.op == IrOp.guardMapped) {
            if (!(inst.imm == 0 || inst.imm == 1)) {
              fail('v$i has an invalid mapping access mode');
            }
          }
        case IrOp.eq || IrOp.ne || IrOp.ltS || IrOp.ltU:
          width(inst.type == IrType.i32 && type(inst.a) == type(inst.b));
        case IrOp.shl || IrOp.shrU || IrOp.shrS:
          width(inst.type == type(inst.a) && type(inst.b) == IrType.i32);
        case IrOp.select:
          width(
            type(inst.a) == IrType.i32 &&
                type(inst.b) == type(inst.c) &&
                inst.type == type(inst.b),
          );
        case IrOp.sext32 || IrOp.zext32:
          width(type(inst.a) == IrType.i32 && inst.type == IrType.i64);
        case IrOp.trunc32:
          width(type(inst.a) == IrType.i64 && inst.type == IrType.i32);
        case IrOp.floatConvert:
          width(type(inst.a) != inst.type);
        case IrOp.floatToInt:
          width(inst.type == IrType.i32);
          if (!(inst.imm == 0 || inst.imm == 1)) {
            fail('v$i has an invalid rounding mode');
          }
        case IrOp.sext8 || IrOp.sext16 || IrOp.zext8 || IrOp.zext16:
          // These conversions may extend a narrow value to either width.
          break;
        default:
          width(inst.type == type(inst.a) && inst.type == type(inst.b));
      }
    }
    switch (term) {
      case IrExitTerm(:final exit):
        exitStores(insts.length, exit);
      case IrBranch(:final cond):
        value(cond.index, insts.length);
        if (!(type(cond.index) == IrType.i32)) {
          fail('branch condition must be i32');
        }
      case IrJumpDyn(pc: final v):
        value(v.index, insts.length);
        if (!(type(v.index) == IrType.i32)) {
          fail('guest addresses must be i32');
        }
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
  final _constants = <(IrType, int, int), IrValue>{};

  IrBuilder(this.pc, {this.tag = 0});

  int get length => _insts.length;

  IrValue _emit(IrInst inst) {
    _insts.add(inst);
    return IrValue(_insts.length - 1);
  }

  IrType typeOf(IrValue value) => _insts[value.index].type;

  IrValue _bin(IrOp op, IrValue a, IrValue b) =>
      _emit(IrInst(op, a: a.index, b: b.index, type: typeOf(a)));

  IrValue _compare(IrOp op, IrValue a, IrValue b) =>
      _emit(IrInst(op, a: a.index, b: b.index));

  /// a constant; the same constant is shared in a block
  IrValue c32(int value) {
    value = value.toSigned(32);
    return _constants[(IrType.i32, value, 0)] ??=
        _emit(IrInst(IrOp.constant, imm: value));
  }

  /// Portable exact constants, including in dart2js builds.
  IrValue c64(BigInt value) => c64Parts(
      (value & BigInt.from(0xffffffff)).toInt(),
      ((value >> 32) & BigInt.from(0xffffffff)).toInt());

  IrValue c64Parts(int low, int high) {
    low = low.toSigned(32);
    high = high.toSigned(32);
    return _constants[(IrType.i64, low, high)] ??=
        _emit(IrInst(IrOp.constant, imm: low, immHi: high, type: IrType.i64));
  }

  IrValue ctxLoad(int index, {IrType type = IrType.i32}) =>
      _emit(IrInst(IrOp.ctxLoad, imm: index, type: type));
  void ctxStore(int index, IrValue v) =>
      _emit(IrInst(IrOp.ctxStore, a: v.index, imm: index, type: typeOf(v)));

  IrValue add(IrValue a, IrValue b) => _bin(IrOp.add, a, b);
  IrValue sub(IrValue a, IrValue b) => _bin(IrOp.sub, a, b);
  IrValue mul(IrValue a, IrValue b) => _bin(IrOp.mul, a, b);
  IrValue mulHiS(IrValue a, IrValue b) => _bin(IrOp.mulHiS, a, b);
  IrValue mulHiU(IrValue a, IrValue b) => _bin(IrOp.mulHiU, a, b);
  IrValue and(IrValue a, IrValue b) => _bin(IrOp.and, a, b);
  IrValue or(IrValue a, IrValue b) => _bin(IrOp.or, a, b);
  IrValue xor(IrValue a, IrValue b) => _bin(IrOp.xor, a, b);
  IrValue not(IrValue a) =>
      xor(a, typeOf(a) == IrType.i32 ? c32(-1) : c64Parts(-1, -1));
  IrValue shl(IrValue a, IrValue b) => _bin(IrOp.shl, a, b);
  IrValue shrU(IrValue a, IrValue b) => _bin(IrOp.shrU, a, b);
  IrValue shrS(IrValue a, IrValue b) => _bin(IrOp.shrS, a, b);
  IrValue eq(IrValue a, IrValue b) => _compare(IrOp.eq, a, b);
  IrValue ne(IrValue a, IrValue b) => _compare(IrOp.ne, a, b);
  IrValue ltS(IrValue a, IrValue b) => _compare(IrOp.ltS, a, b);
  IrValue ltU(IrValue a, IrValue b) => _compare(IrOp.ltU, a, b);
  IrValue select(IrValue cond, IrValue a, IrValue b) =>
      _emit(IrInst(IrOp.select,
          a: cond.index, b: a.index, c: b.index, type: typeOf(a)));
  IrValue sext8(IrValue a, {IrType? type}) =>
      _emit(IrInst(IrOp.sext8, a: a.index, type: type ?? typeOf(a)));
  IrValue sext16(IrValue a, {IrType? type}) =>
      _emit(IrInst(IrOp.sext16, a: a.index, type: type ?? typeOf(a)));
  IrValue zext8(IrValue a, {IrType? type}) =>
      _emit(IrInst(IrOp.zext8, a: a.index, type: type ?? typeOf(a)));
  IrValue zext16(IrValue a, {IrType? type}) =>
      _emit(IrInst(IrOp.zext16, a: a.index, type: type ?? typeOf(a)));

  IrValue sext32(IrValue a) =>
      _emit(IrInst(IrOp.sext32, a: a.index, type: IrType.i64));
  IrValue zext32(IrValue a) =>
      _emit(IrInst(IrOp.zext32, a: a.index, type: IrType.i64));
  IrValue trunc32(IrValue a) => _emit(IrInst(IrOp.trunc32, a: a.index));

  int _exitIndex(IrExit? exit) {
    if (exit == null) return -1;
    if (_exits.isNotEmpty && identical(_exits.last, exit))
      return _exits.length - 1;
    _exits.add(exit);
    return _exits.length - 1;
  }

  /// [unmapped] exits the block before an access to an unmapped page,
  /// instead of calling the host; the address is left in [JitCtx.faultAddr]
  IrValue load(int size, IrValue addr,
          {bool signed = false,
          IrType type = IrType.i32,
          IrEndian endian = IrEndian.little,
          IrExit? unmapped}) =>
      _emit(IrInst(IrOp.load,
          a: addr.index,
          imm: size,
          aux: signed ? 1 : 0,
          exit: _exitIndex(unmapped),
          type: type,
          endian: endian));
  void store(int size, IrValue addr, IrValue v,
          {IrEndian endian = IrEndian.little, IrExit? unmapped}) =>
      _emit(IrInst(IrOp.store,
          a: addr.index,
          b: v.index,
          imm: size,
          exit: _exitIndex(unmapped),
          type: typeOf(v),
          endian: endian));

  IrValue floatBinary(IrOp op, IrValue a, IrValue value) {
    if (!const [IrOp.floatAdd, IrOp.floatSub, IrOp.floatMul].contains(op)) {
      throw ArgumentError.value(op);
    }
    return _emit(IrInst(op, a: a.index, b: value.index, type: typeOf(a)));
  }

  /// binary32 (i32) to binary64 (i64) exactly, or back rounding to nearest
  IrValue floatConvert(IrValue a) => _emit(IrInst(IrOp.floatConvert,
      a: a.index,
      type: typeOf(a) == IrType.i32 ? IrType.i64 : IrType.i32));

  /// IEEE bits to a signed word, to nearest even or with [truncate] toward zero
  IrValue floatToInt(IrValue a, {bool truncate = false}) =>
      _emit(IrInst(IrOp.floatToInt, a: a.index, imm: truncate ? 1 : 0));

  IrValue call(int helper, [IrValue? a, IrValue? b, IrValue? c]) {
    final zero = c32(0);
    return _emit(IrInst(IrOp.call,
        a: (a ?? zero).index,
        b: (b ?? zero).index,
        c: (c ?? zero).index,
        imm: helper));
  }

  void exitIf(IrValue cond, IrExit exit) {
    _emit(IrInst(IrOp.exitIf, a: cond.index, aux: _exitIndex(exit)));
  }

  /// Exits before an access requiring a host callback. The caller can
  /// synchronize guest state and execute that access outside the block.
  void guardMapped(IrValue address, IrExit exit, {bool write = false}) {
    _emit(IrInst(IrOp.guardMapped,
        a: address.index, imm: write ? 1 : 0, aux: _exitIndex(exit)));
  }

  void guard(int addr, int value, {IrEndian endian = IrEndian.little}) =>
      _guards.add((
        addr: addr.toUnsigned(32),
        value: value.toUnsigned(32),
        endian: endian
      ));

  IrBlock finish(IrTerm term, {required int cost}) => IrBlock(
      pc,
      tag,
      cost,
      List.unmodifiable(_insts),
      term,
      List.unmodifiable(_guards),
      List.unmodifiable(_exits));
}
