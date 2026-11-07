import 'ir.dart';

/// Folds i32 constants and identities, then removes unused pure values.
/// Loads, calls, guards and exits retain their effects and guest clock costs.
IrBlock optimizeIrBlock(IrBlock block) {
  final values = <IrInst>[];
  final aliases = List<int>.filled(block.insts.length, -1);
  final constants = <int, int>{};
  // The bits that can be set in each i32 value; 32-bit values of unknown
  // content have every bit set.
  final masks = <int>[];
  const full = 0xffffffff;
  int maskOfValue(int v) =>
      v >= 0 && values[v].type == IrType.i32 ? masks[v] : full;
  int maskOf(IrInst i, int? y) {
    if (i.type != IrType.i32) return full;
    final ma = maskOfValue(i.a), mb = maskOfValue(i.b);
    switch (i.op) {
      case IrOp.constant:
        return i.imm.toUnsigned(32);
      case IrOp.and:
        return ma & mb;
      case IrOp.or || IrOp.xor:
        return ma | mb;
      case IrOp.shl:
        return y == null ? full : (ma << (y & 31)).toUnsigned(32);
      case IrOp.shrU:
        return y == null ? full : ma >>> (y & 31);
      case IrOp.shrS:
        return y == null || ma >>> 31 != 0 ? full : ma >>> (y & 31);
      case IrOp.eq || IrOp.ne || IrOp.ltS || IrOp.ltU:
        return 1;
      case IrOp.select:
        return maskOfValue(i.b) | maskOfValue(i.c);
      case IrOp.zext8:
        return 0xff;
      case IrOp.zext16:
        return 0xffff;
      case IrOp.add when ma & mb == 0:
        return ma | mb;
      default:
        return full;
    }
  }

  int remap(int v) => v < 0 ? -1 : aliases[v];
  int? constant(int v) =>
      v >= 0 && values[v].op == IrOp.constant && values[v].type == IrType.i32
          ? values[v].imm
          : null;
  bool narrowValue(int v) => v < 0 || values[v].type == IrType.i32;
  int addValue(IrInst inst) {
    final y = inst.b >= 0 && values[inst.b].op == IrOp.constant
        ? values[inst.b].imm
        : null;
    // Reading the mask before the append keeps operand indices valid.
    final mask = maskOf(inst, y);
    values.add(inst);
    masks.add(mask);
    return values.length - 1;
  }

  int emitConstant(int value) {
    value = value.toSigned(32);
    return constants.putIfAbsent(value, () {
      return addValue(IrInst(IrOp.constant, imm: value));
    });
  }

  // A shift by a constant, simplified when it only undoes a shift left.
  int emitShift(IrOp op, int x, int amount) {
    final k = amount & 31;
    if (k == 0) return x;
    final xi = values[x];
    if (xi.op == IrOp.constant) {
      return emitConstant(op == IrOp.shl
          ? xi.imm << k
          : op == IrOp.shrU
              ? xi.imm.toUnsigned(32) >>> k
              : xi.imm >> k);
    }
    if (op == IrOp.shrU &&
        xi.op == IrOp.shl &&
        xi.type == IrType.i32 &&
        constant(xi.b) == k &&
        maskOfValue(xi.a) >>> (32 - k) == 0) {
      return xi.a;
    }
    return addValue(IrInst(op, a: x, b: emitConstant(k)));
  }

  // A value equal to [v] on the bits of [demand]; the other bits are
  // arbitrary. Bits that are known to be zero let an or drop an operand.
  final extracted = <(int, int), int>{};
  int extract(int v, int demand) {
    if (maskOfValue(v) & demand == 0) return emitConstant(0);
    final inst = values[v];
    if (inst.type != IrType.i32) return v;
    final key = (v, demand);
    final known = extracted[key];
    if (known != null) return known;
    int result = v;
    switch (inst.op) {
      case IrOp.or:
        final p = extract(inst.a, demand), q = extract(inst.b, demand);
        if (constant(p) == 0) {
          result = q;
        } else if (constant(q) == 0) {
          result = p;
        } else if (p != inst.a || q != inst.b) {
          result = addValue(IrInst(IrOp.or, a: p, b: q));
        }
      case IrOp.and:
        final k = constant(inst.b);
        if (k != null) {
          final mask = k.toUnsigned(32);
          final inner = extract(inst.a, demand & mask);
          if (inner != inst.a) {
            result = maskOfValue(inner) & demand & ~mask == 0
                ? inner
                : addValue(IrInst(IrOp.and, a: inner, b: inst.b));
          }
        }
      case IrOp.shrU || IrOp.shl:
        final k = constant(inst.b);
        if (k != null && k & 31 != 0) {
          final shift = k & 31;
          final wanted = inst.op == IrOp.shrU
              ? (demand << shift).toUnsigned(32)
              : demand >>> shift;
          final inner = extract(inst.a, wanted);
          if (inner != inst.a) result = emitShift(inst.op, inner, shift);
        }
      default:
        break;
    }
    return extracted[key] = result;
  }

  for (final (index, original) in block.insts.indexed) {
    var a = remap(original.a), b = remap(original.b);
    final c = remap(original.c);
    final x = constant(a), y = constant(b);
    // A checked specialization can prove later address guards unnecessary.
    if (original.op == IrOp.exitIf && x == 0) continue;
    if (original.op == IrOp.exitIf &&
        a >= 0 &&
        values[a].op == IrOp.or &&
        values[a].type == IrType.i32) {
      // An exit on an or of conditions is one exit per condition, each of
      // which a backend can branch on directly.
      final leaves = <int>[];
      void split(int v) {
        if (values[v].op == IrOp.or && values[v].type == IrType.i32) {
          split(values[v].a);
          split(values[v].b);
        } else {
          leaves.add(v);
        }
      }

      split(a);
      for (final leaf in leaves) {
        if (constant(leaf) == 0) continue;
        aliases[index] = values.length;
        addValue(_copy(original, leaf, b, c));
      }
      aliases[index] = values.length - 1;
      continue;
    }
    final narrow = original.type == IrType.i32 &&
        narrowValue(a) &&
        narrowValue(b) &&
        narrowValue(c);
    final folded = narrow ? _fold(original, x, y, constant(c)) : null;
    if (folded != null) {
      aliases[index] = emitConstant(folded);
      continue;
    }
    if (original.op == IrOp.and && narrow) {
      // Only the bits of the constant mask are read, so the operand can
      // drop the parts that cannot reach them.
      final mask = (x ?? y);
      final operand = x != null ? b : a;
      if (mask != null && (x == null || y == null) && operand >= 0) {
        final wanted = mask.toUnsigned(32);
        final reduced = extract(operand, wanted);
        final known = maskOfValue(reduced);
        if (known & wanted == 0) {
          aliases[index] = emitConstant(0);
          continue;
        }
        if (known & ~wanted == 0) {
          aliases[index] = reduced;
          continue;
        }
        if (reduced != operand) {
          aliases[index] =
              addValue(IrInst(IrOp.and, a: reduced, b: emitConstant(mask)));
          continue;
        }
      }
    }
    if (original.op == IrOp.shrU && narrow && y != null && a >= 0) {
      final shifted = emitShift(IrOp.shrU, a, y);
      if (shifted != a || y & 31 == 0) {
        aliases[index] = shifted;
        continue;
      }
    }
    int? alias;
    switch (original.op) {
      case IrOp.add || IrOp.or || IrOp.xor:
        if (y == 0) alias = a;
        if (x == 0) alias = b;
        if (original.op == IrOp.or && a == b && a >= 0) alias = a;
      case IrOp.sub:
        if (y == 0) alias = a;
      case IrOp.mul:
        if (y == 1) alias = a;
        if (x == 1) alias = b;
      case IrOp.and:
        if (y == -1) alias = a;
        if (x == -1) alias = b;
        if (a == b && a >= 0) alias = a;
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
    addValue(_copy(original, a, b, c));
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
        immHi: i.immHi,
        translation: i.translation);

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
    IrOp.divS => b == 0 ? 0 : (a ~/ b).toSigned(32),
    IrOp.divU => b == 0 ? 0 : (a.toUnsigned(32) ~/ b.toUnsigned(32)).toSigned(32),
    IrOp.remS => b == 0 ? 0 : a.remainder(b).toSigned(32),
    IrOp.remU => b == 0 ? 0 : (a.toUnsigned(32) % b.toUnsigned(32)).toSigned(32),
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
