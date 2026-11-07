import 'dart:math';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:mp_jit_recompiler/src/optimizer.dart';
import 'package:test/test.dart';

List<Object> execute(IrBlock block, {int x = 0x87654321, int y = 0}) {
  final effects = <String>[];
  final rt = JitRuntime.interpreter(
      ctxWords: 64,
      addrMask: 0xffff,
      read: (a, s) {
        effects.add('read $a $s');
        return 7;
      },
      write: (a, s, v) {
        effects.add('write $a $s $v');
      });
  rt.addHelper((a, b, c) {
    effects.add('call $a $b $c');
    return a + b + c;
  });
  rt.ctx[8] = x;
  rt.ctx[9] = y;
  rt.ctx[JitCtx.budget] = 100;
  rt.install(block);
  rt.run(block.pc, block.tag);
  final result = <Object>[rt.ctx.toList(), effects];
  rt.dispose();
  return result;
}

void main() {
  test('folding preserves signed, unsigned and wrapped i32 operations', () {
    for (final x in [-0x80000000, -1, 0, 1, 0x7fffffff]) {
      for (final y in [-0x80000000, -33, -1, 0, 1, 32, 0x7fffffff]) {
        final b = IrBuilder(0x100);
        final a = b.c32(x), c = b.c32(y);
        final results = [
          b.add(a, c),
          b.sub(a, c),
          b.mul(a, c),
          b.and(a, c),
          b.or(a, c),
          b.xor(a, c),
          b.shl(a, c),
          b.shrS(a, c),
          b.shrU(a, c),
          b.eq(a, c),
          b.ne(a, c),
          b.ltS(a, c),
          b.ltU(a, c),
          b.sext8(a),
          b.sext16(a),
          b.zext8(a),
          b.zext16(a),
          b.select(a, c, b.c32(99))
        ];
        for (final (i, v) in results.indexed) {
          b.ctxStore(16 + i, v);
        }
        final block = b.finish(const IrExitTerm(IrExit(16, 0x104)), cost: 5);
        final optimized = optimizeIrBlock(block);
        expect(execute(optimized), execute(block), reason: '$x $y');
        expect(
            optimized.insts
                .every((i) => i.op == IrOp.constant || i.op == IrOp.ctxStore),
            isTrue);
      }
    }
  });

  test('identities and unused pure values disappear without removing effects',
      () {
    final b = IrBuilder(0x100);
    final x = b.ctxLoad(8);
    b.ctxStore(9, b.mul(b.add(x, b.c32(0)), b.c32(1)));
    b.ctxStore(10, b.select(b.c32(0), b.c32(4), x));
    b.xor(x, b.c32(42));
    b.load(4, b.c32(0x2000));
    b.call(0, x, b.c32(3));
    b.store(4, b.c32(0x3000), x);
    final block = b.finish(const IrExitTerm(IrExit(16, 0x104)), cost: 6);
    final optimized = optimizeIrBlock(block);
    expect(optimized.insts.length, lessThan(block.insts.length));
    expect(execute(optimized), execute(block));
    expect(optimized.insts.where((i) => i.op == IrOp.load).length, 1);
    expect(optimized.insts.where((i) => i.op == IrOp.call).length, 1);
  });

  test('side-exit snapshots, guards, tags and budget refunds survive remapping',
      () {
    final b = IrBuilder(0x100, tag: 3);
    b.guard(0x100, 0x12345678);
    final x = b.add(b.ctxLoad(8), b.c32(0));
    b.exitIf(b.c32(1), IrExit(17, 0x108, tag: 5, spent: 2, stores: [(9, x)]));
    b.ctxStore(9, b.c32(99));
    final block = b.finish(const IrExitTerm(IrExit(18, 0x110)), cost: 8);
    // The unmapped guard word is ignored by the reference runtime.
    final optimized = optimizeIrBlock(block);
    expect(execute(optimized), execute(block));
    expect(optimized.guards, block.guards);
  });

  test('proven false exits disappear while dynamic and taken exits survive', () {
    final b = IrBuilder(0x100);
    b.exitIf(b.ne(b.c32(4), b.c32(4)), const IrExit(17, 0x102));
    b.exitIf(b.ctxLoad(9), const IrExit(18, 0x104));
    b.exitIf(b.c32(1), const IrExit(19, 0x106));
    final original = b.finish(const IrJump(0x108), cost: 4);
    final optimized = optimizeIrBlock(original);
    expect(optimized.insts.where((i) => i.op == IrOp.exitIf).length, 2);
    expect(execute(optimized), execute(original));
  });

  test('constant branches retain target tags and i64 constants retain all bits',
      () {
    final b = IrBuilder(0x100);
    final block = b.finish(
        IrBranch(b.eq(b.c32(1), b.c32(2)), 0x200, 0x300,
            tagTrue: 4, tagFalse: 7),
        cost: 2);
    final optimized = optimizeIrBlock(block);
    expect(optimized.insts, isEmpty);
    final jump = optimized.term as IrJump;
    expect((jump.pc, jump.tag), (0x300, 7));
    final wide = IrBuilder(0x100);
    wide.ctxStore(8, wide.c64Parts(-1, 0x12345678));
    final original = wide.finish(const IrExitTerm(IrExit(16, 0x104)), cost: 2);
    final optimizedWide = optimizeIrBlock(original);
    expect(optimizedWide.insts.first.type, IrType.i64);
    expect(optimizedWide.insts.first.imm, -1);
    expect(optimizedWide.insts.first.immHi, 0x12345678);
  });

  test(
    'bit extraction through or, and and shifts keeps the extracted value',
    () {
      final random = Random(5);
      const inputs = [
        (0, 0),
        (-1, -1),
        (0x87654321, 0x12345678),
        (0x40000000, 1),
        (0x7fffffff, -0x80000000),
        (3, 0xc0000000),
      ];
      for (var round = 0; round < 400; round++) {
        final b = IrBuilder(0x100);
        final pool = <IrValue>[b.ctxLoad(8), b.ctxLoad(9), b.ctxLoad(24)];
        IrValue pick() => pool[random.nextInt(pool.length)];
        int maskConstant() {
          final shape = random.nextInt(4);
          if (shape == 0) return 1;
          if (shape == 1) return ~(1 << random.nextInt(32));
          if (shape == 2)
            return (random.nextInt(0x7fffffff) << random.nextInt(2));
          return random.nextInt(0x7fffffff);
        }

        for (var i = 0; i < 14; i++) {
          final value = switch (random.nextInt(9)) {
            0 => b.and(pick(), b.c32(maskConstant())),
            1 => b.or(pick(), pick()),
            2 => b.shl(pick(), b.c32(random.nextInt(32))),
            3 => b.shrU(pick(), b.c32(random.nextInt(32))),
            4 => b.eq(pick(), pick()),
            5 => b.ltU(pick(), pick()),
            6 => b.add(pick(), pick()),
            7 => b.and(b.shrU(pick(), b.c32(random.nextInt(32))), b.c32(1)),
            _ => b.xor(pick(), pick()),
          };
          pool.add(value);
        }
        for (var i = 0; i < 8; i++) {
          b.ctxStore(16 + i, pool[pool.length - 1 - i]);
        }
        b.exitIf(
          b.or(pick(), pick()),
          const IrExit(JitReason.user, 0x300, spent: 1),
        );
        final block = b.finish(const IrExitTerm(IrExit(16, 0x104)), cost: 5);
        final optimized = optimizeIrBlock(block);
        for (final (x, y) in inputs) {
          expect(
            execute(optimized, x: x.toUnsigned(32), y: y.toUnsigned(32)),
            execute(block, x: x.toUnsigned(32), y: y.toUnsigned(32)),
            reason: 'round $round inputs $x $y',
          );
        }
      }
    },
  );

  test('a flag stored beside others and read back is the compared value', () {
    final b = IrBuilder(0x100);
    final status = b.ctxLoad(24);
    final flag = b.eq(b.ctxLoad(8), b.c32(0));
    final packed = b.or(b.and(status, b.c32(-2)), flag);
    b.ctxStore(24, packed);
    b.ctxStore(16, b.and(packed, b.c32(1)));
    final block = b.finish(const IrExitTerm(IrExit(16, 0x104)), cost: 2);
    final optimized = optimizeIrBlock(block);
    // The stored bit is the comparison itself, not a re-extraction.
    final extractions = optimized.insts.where(
      (i) =>
          i.op == IrOp.and &&
          optimized.insts[i.b].op == IrOp.constant &&
          optimized.insts[i.b].imm == 1,
    );
    expect(extractions, isEmpty);
    for (final x in [0, 1, 0x87654321]) {
      expect(execute(optimized, x: x), execute(block, x: x));
    }
  });

  test('a shift right of a shift left by the same amount is the value', () {
    final b = IrBuilder(0x100);
    final flag = b.ltU(b.ctxLoad(8), b.ctxLoad(9));
    b.ctxStore(16, b.shrU(b.shl(flag, b.c32(30)), b.c32(30)));
    final block = b.finish(const IrExitTerm(IrExit(16, 0x104)), cost: 2);
    final optimized = optimizeIrBlock(block);
    expect(
      optimized.insts.where((i) => i.op == IrOp.shl || i.op == IrOp.shrU),
      isEmpty,
    );
    for (final (x, y) in [(1, 2), (2, 1), (5, 5)]) {
      expect(execute(optimized, x: x, y: y), execute(block, x: x, y: y));
    }
  });

  test('an exit on an or of conditions becomes one exit per condition', () {
    final b = IrBuilder(0x100);
    final address = b.ctxLoad(8);
    final bad = b.or(
      b.ltU(b.c32(0xbfffffff), address),
      b.and(address, b.c32(3)),
    );
    b.exitIf(bad, const IrExit(JitReason.user, 0x200, spent: 1));
    final block = b.finish(const IrJump(0x300), cost: 2);
    final optimized = optimizeIrBlock(block);
    expect(optimized.insts.where((i) => i.op == IrOp.exitIf), hasLength(2));
    expect(optimized.insts.where((i) => i.op == IrOp.or), isEmpty);
    for (final x in [0, 4, 6, 0xbfffffff, 0xc0000000, 0xffffffff, 0x1001]) {
      expect(
        execute(optimized, x: x),
        execute(block, x: x),
        reason: '$x',
      );
    }
  });
}
