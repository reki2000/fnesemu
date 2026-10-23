import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:mp_jit_recompiler/src/optimizer.dart';
import 'package:test/test.dart';

List<Object> execute(IrBlock block) {
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
  rt.ctx[8] = 0x87654321;
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
}
