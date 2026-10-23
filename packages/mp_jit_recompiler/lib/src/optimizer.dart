import 'ir.dart';

/// Folds i32 constants and identities, then removes unused pure values.
/// Loads, calls, guards and exits retain their effects and guest clock costs.
IrBlock optimizeIrBlock(IrBlock block) {
  final values = <IrInst>[];
  final aliases = List<int>.filled(block.insts.length, -1);
  final constants = <int, int>{};
  int remap(int v) => v < 0 ? -1 : aliases[v];
  int? constant(int v) =>
      v >= 0 && values[v].op == IrOp.constant && values[v].type == IrType.i32
          ? values[v].imm
          : null;
  bool narrowValue(int v) => v < 0 || values[v].type == IrType.i32;
  int emitConstant(int value) {
    value = value.toSigned(32);
    return constants.putIfAbsent(value, () {
      values.add(IrInst(IrOp.constant, imm: value));
      return values.length - 1;
    });
  }

  for (final (index, original) in block.insts.indexed) {
    var a = remap(original.a), b = remap(original.b);
    final c = remap(original.c);
    final x = constant(a), y = constant(b);
    // A checked specialization can prove later address guards unnecessary.
    if (original.op == IrOp.exitIf && x == 0) continue;
    final narrow = original.type == IrType.i32 &&
        narrowValue(a) &&
        narrowValue(b) &&
        narrowValue(c);
    final folded = narrow ? _fold(original, x, y, constant(c)) : null;
    if (folded != null) {
      aliases[index] = emitConstant(folded);
      continue;
    }
    int? alias;
    switch (original.op) {
      case IrOp.add || IrOp.or || IrOp.xor:
        if (y == 0) alias = a;
        if (x == 0) alias = b;
      case IrOp.sub:
        if (y == 0) alias = a;
      case IrOp.mul:
        if (y == 1) alias = a;
        if (x == 1) alias = b;
      case IrOp.and:
        if (y == -1) alias = a;
        if (x == -1) alias = b;
      case IrOp.shl || IrOp.shrU || IrOp.shrS:
        if (y != null && y & (original.type.bits - 1) == 0) alias = a;
      case IrOp.select:
        if (x != null) alias = x != 0 ? b : c;
        if (b == c) alias = b;
      default:
        break;
    }
    if (alias != null) {
      aliases[index] = alias;
      continue;
    }
    if (x != null &&
        y == null &&
        const {
          IrOp.add,
          IrOp.mul,
          IrOp.and,
          IrOp.or,
          IrOp.xor,
          IrOp.eq,
          IrOp.ne
        }.contains(original.op)) {
      (a, b) = (b, a);
    }
    aliases[index] = values.length;
    values.add(_copy(original, a, b, c));
  }
  IrExit mapExit(IrExit e, int Function(int) map) => IrExit(
    e.reason,
    e.pc,
    tag: e.tag,
    spent: e.spent,
    link: e.link,
    stores: [for (final (word, v) in e.stores) (word, IrValue(map(v.index)))],
  );
  IrTerm mapTerm(IrTerm term, int Function(int) map) => switch (term) {
        IrBranch t => IrBranch(IrValue(map(t.cond.index)), t.pcTrue, t.pcFalse,
            tagTrue: t.tagTrue, tagFalse: t.tagFalse),
        IrJumpDyn t => IrJumpDyn(IrValue(map(t.pc.index)), tag: t.tag),
        IrExitTerm t => IrExitTerm(mapExit(t.exit, map)),
        _ => term,
      };
  var term = mapTerm(block.term, remap);
  if (term case IrBranch t) {
    final condition = constant(t.cond.index);
    if (condition != null) {
      term = IrJump(condition != 0 ? t.pcTrue : t.pcFalse,
          tag: condition != 0 ? t.tagTrue : t.tagFalse);
    }
  }
  final exits = [for (final e in block.exits) mapExit(e, remap)];
  final live = List<bool>.filled(values.length, false);
  void markExit(IrExit e) {
    for (final (_, v) in e.stores) {
      live[v.index] = true;
    }
  }

  for (final e in exits) {
    markExit(e);
  }
  switch (term) {
    case IrBranch t:
      live[t.cond.index] = true;
    case IrJumpDyn t:
      live[t.pc.index] = true;
    case IrExitTerm t:
      markExit(t.exit);
    default:
      break;
  }
  for (int i = values.length - 1; i >= 0; i--) {
    final inst = values[i];
    if (!irHasResult(inst.op) || inst.op == IrOp.load || inst.op == IrOp.call) {
      live[i] = true;
    }
    if (live[i]) {
      if (inst.a >= 0) live[inst.a] = true;
      if (inst.b >= 0) live[inst.b] = true;
      if (inst.c >= 0) live[inst.c] = true;
    }
  }
  final compact = List<int>.filled(values.length, -1);
  final insts = <IrInst>[];
  int compactValue(int v) => v < 0 ? -1 : compact[v];
  for (int i = 0; i < values.length; i++) {
    if (!live[i]) continue;
    compact[i] = insts.length;
    final inst = values[i];
    insts.add(_copy(inst, compactValue(inst.a), compactValue(inst.b),
        compactValue(inst.c)));
  }
  return IrBlock(
      block.pc,
      block.tag,
      block.cost,
      List.unmodifiable(insts),
      mapTerm(term, compactValue),
      block.guards,
      List.unmodifiable([for (final e in exits) mapExit(e, compactValue)]));
}

IrInst _copy(IrInst i, int a, int b, int c) => i.a == a && i.b == b && i.c == c
    ? i
    : IrInst(i.op,
        a: a,
        b: b,
        c: c,
        imm: i.imm,
        aux: i.aux,
        exit: i.exit,
        type: i.type,
        endian: i.endian,
        immHi: i.immHi);

int? _fold(IrInst i, int? a, int? b, int? c) {
  if (i.op == IrOp.constant) return i.imm;
  if ((i.op == IrOp.mul || i.op == IrOp.and) && (a == 0 || b == 0)) return 0;
  if (i.a >= 0 && i.a == i.b) {
    if (i.op == IrOp.sub ||
        i.op == IrOp.xor ||
        i.op == IrOp.ltS ||
        i.op == IrOp.ltU ||
        i.op == IrOp.ne) {
      return 0;
    }
    if (i.op == IrOp.eq) return 1;
  }
  if (a == null) return null;
  if (i.op == IrOp.sext8) return a.toSigned(8);
  if (i.op == IrOp.sext16) return a.toSigned(16);
  if (i.op == IrOp.zext8) return a & 0xff;
  if (i.op == IrOp.zext16) return a & 0xffff;
  if (i.op == IrOp.select) return a != 0 ? b : c;
  if (b == null) return null;
  return switch (i.op) {
    IrOp.add => (a + b).toSigned(32),
    IrOp.sub => (a - b).toSigned(32),
    IrOp.mul => _mul32(a, b),
    IrOp.and => (a & b).toSigned(32),
    IrOp.or => (a | b).toSigned(32),
    IrOp.xor => (a ^ b).toSigned(32),
    IrOp.shl => (a << (b & 31)).toSigned(32),
    IrOp.shrS => a >> (b & 31),
    IrOp.shrU => (a.toUnsigned(32) >>> (b & 31)).toSigned(32),
    IrOp.eq => a == b ? 1 : 0,
    IrOp.ne => a != b ? 1 : 0,
    IrOp.ltS => a < b ? 1 : 0,
    IrOp.ltU => a.toUnsigned(32) < b.toUnsigned(32) ? 1 : 0,
    _ => null,
  };
}

// Mask the cross products before combining them, keeping every intermediate
// exact on dart2js as well as 64-bit Dart hosts.
int _mul32(int a, int b) {
  final al = a & 0xffff, ah = (a >>> 16) & 0xffff;
  final bl = b & 0xffff, bh = (b >>> 16) & 0xffff;
  return (al * bl + ((al * bh + ah * bl) & 0xffff) * 0x10000).toSigned(32);
}
