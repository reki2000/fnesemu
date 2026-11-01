import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

JitRuntime _runtime(bool native) {
  final create = native ? JitRuntime.native : JitRuntime.interpreter;
  return create(
    ctxWords: 64,
    addrMask: 0xffff,
    read: (_, __) => 0,
    write: (_, __, ___) {},
  )!;
}

BigInt _read64(JitRuntime runtime, int index) =>
    BigInt.from(runtime.ctx[index]) |
    (BigInt.from(runtime.ctx[index + 1]) << 32);

void _write64(JitRuntime runtime, int index, BigInt value) {
  runtime.ctx[index] = (value & BigInt.from(0xffffffff)).toInt();
  runtime.ctx[index + 1] = ((value >> 32) & BigInt.from(0xffffffff)).toInt();
}

void _run(JitRuntime runtime, IrBlock block) {
  runtime.ctx[JitCtx.budget] = 100;
  runtime.install(block);
  expect(runtime.run(block.pc, block.tag), JitReason.user);
}

void main() {
  for (final native in [false, true]) {
    test('${native ? 'native' : 'reference'} i32 division edges', () {
      if (native && !JitRuntime.nativeSupported) {
        markTestSkipped('No compiled backend');
        return;
      }
      final rt = _runtime(native);
      addTearDown(rt.dispose);
      for (final (x, y) in [
        (-7, 3),
        (7, -3),
        (-7, -3),
        (-0x80000000, -1),
        (-0x80000000, 1),
        (0x7fffffff, 0),
        (-1, 0),
        (0, 0),
        (0xffffffff, 2),
        (0x80000000, 0xffffffff),
      ]) {
        rt.clear();
        rt.ctx[8] = x.toUnsigned(32);
        rt.ctx[9] = y.toUnsigned(32);
        final builder = IrBuilder(0x100);
        final a = builder.ctxLoad(8), b = builder.ctxLoad(9);
        builder.ctxStore(10, builder.divS(a, b));
        builder.ctxStore(11, builder.remS(a, b));
        builder.ctxStore(12, builder.divU(a, b));
        builder.ctxStore(13, builder.remU(a, b));
        _run(rt, builder.finish(
            const IrExitTerm(IrExit(JitReason.user, 0x104)), cost: 1));
        final sx = x.toSigned(32), sy = y.toSigned(32);
        final ux = x.toUnsigned(32), uy = y.toUnsigned(32);
        expect(rt.ctx[10], sy == 0 ? 0 : (sx ~/ sy).toUnsigned(32),
            reason: 'signed quotient $x / $y');
        expect(rt.ctx[11],
            sy == 0 ? 0 : sx.remainder(sy).toUnsigned(32),
            reason: 'signed remainder $x / $y');
        expect(rt.ctx[12],
            uy == 0 ? 0 : (ux ~/ uy).toUnsigned(32),
            reason: 'unsigned quotient $x / $y');
        expect(rt.ctx[13],
            uy == 0 ? 0 : (ux % uy).toUnsigned(32),
            reason: 'unsigned remainder $x / $y');
      }
    });

    test('${native ? 'native' : 'reference'} i64 division edges', () {
      if (native && !JitRuntime.nativeSupported) {
        markTestSkipped('No compiled backend');
        return;
      }
      final rt = _runtime(native);
      addTearDown(rt.dispose);
      final min = -(BigInt.one << 63);
      for (final (x, y) in [
        (BigInt.from(-7), BigInt.from(3)),
        (BigInt.from(7), BigInt.from(-3)),
        (min, -BigInt.one),
        (min, BigInt.from(17)),
        ((BigInt.one << 64) - BigInt.one, BigInt.from(3)),
        (BigInt.one << 63, BigInt.zero),
        (BigInt.zero, BigInt.zero),
        (BigInt.one << 63, (BigInt.one << 64) - BigInt.one),
      ]) {
        rt.clear();
        _write64(rt, 8, x);
        _write64(rt, 10, y);
        final builder = IrBuilder(0x100);
        final a = builder.ctxLoad(8, type: IrType.i64);
        final b = builder.ctxLoad(10, type: IrType.i64);
        builder.ctxStore(12, builder.divS(a, b));
        builder.ctxStore(14, builder.remS(a, b));
        builder.ctxStore(16, builder.divU(a, b));
        builder.ctxStore(18, builder.remU(a, b));
        _run(rt, builder.finish(
            const IrExitTerm(IrExit(JitReason.user, 0x104)), cost: 1));
        final sx = x.toSigned(64), sy = y.toSigned(64);
        final ux = x.toUnsigned(64), uy = y.toUnsigned(64);
        expect(_read64(rt, 12),
            (sy == BigInt.zero ? BigInt.zero : sx ~/ sy).toUnsigned(64));
        expect(_read64(rt, 14),
            (sy == BigInt.zero ? BigInt.zero : sx.remainder(sy)).toUnsigned(64));
        expect(_read64(rt, 16),
            uy == BigInt.zero ? BigInt.zero : ux ~/ uy);
        expect(_read64(rt, 18),
            uy == BigInt.zero ? BigInt.zero : ux % uy);
      }
    });

    for (final op in [IrOp.eq, IrOp.ne, IrOp.ltS, IrOp.ltU]) {
      test('${native ? 'native' : 'reference'} $op fuses a delayed exit',
          () {
        if (native && !JitRuntime.nativeSupported) {
          markTestSkipped('No compiled backend');
          return;
        }
        final rt = _runtime(native);
        addTearDown(rt.dispose);
        for (final (x, y) in [(0, 0), (-1, 1), (1, -1), (7, 9)]) {
          rt.clear();
          rt.ctx[8] = x.toUnsigned(32);
          rt.ctx[9] = y.toUnsigned(32);
          final b = IrBuilder(0x100);
          final lhs = b.ctxLoad(8), rhs = b.ctxLoad(9);
          final condition = switch (op) {
            IrOp.eq => b.eq(lhs, rhs),
            IrOp.ne => b.ne(lhs, rhs),
            IrOp.ltS => b.ltS(lhs, rhs),
            _ => b.ltU(lhs, rhs),
          };
          // The operands stay live through a helper and ALU operations.
          b.ctxStore(12, b.add(lhs, b.c32(3)));
          b.exitIf(condition,
              const IrExit(JitReason.user, 0x200, spent: 0));
          final block = b.finish(
              const IrExitTerm(IrExit(JitReason.user, 0x300)), cost: 2);
          final fused = irFusedCompareConsumers(block);
          expect(fused[condition.index], greaterThanOrEqualTo(0));
          _run(rt, block);
          final taken = switch (op) {
            IrOp.eq => x == y,
            IrOp.ne => x != y,
            IrOp.ltS => x < y,
            _ => x.toUnsigned(32) < y.toUnsigned(32),
          };
          expect(rt.ctx[JitCtx.exitPc], taken ? 0x200 : 0x300);
        }
      });
    }

    test('${native ? 'native' : 'reference'} reused compare is not fused',
        () {
      if (native && !JitRuntime.nativeSupported) {
        markTestSkipped('No compiled backend');
        return;
      }
      final rt = _runtime(native);
      addTearDown(rt.dispose);
      rt.ctx[8] = 7;
      rt.ctx[9] = 9;
      final b = IrBuilder(0x100);
      final cond = b.ltU(b.ctxLoad(8), b.ctxLoad(9));
      b.ctxStore(12, cond);
      b.exitIf(cond, const IrExit(JitReason.user, 0x200));
      final block = b.finish(
          const IrExitTerm(IrExit(JitReason.user, 0x300)), cost: 2);
      expect(irFusedCompareConsumers(block)[cond.index], -1);
      _run(rt, block);
      expect(rt.ctx[12], 1);
      expect(rt.ctx[JitCtx.exitPc], 0x200);
    });
  }
}
