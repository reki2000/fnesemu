import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

/// Every comparison that an exit or a branch can fuse, with operands in
/// registers, constants of either side and 64-bit values, must behave the
/// same on the compiled and the reference runtimes.
void main() {
  final native = JitRuntime.native(
    ctxWords: 64,
    addrMask: 0xffff,
    read: (_, __) => 0,
    write: (_, __, ___) {},
  );
  if (native == null) {
    test('fused comparisons', () => markTestSkipped('No compiled backend'));
    return;
  }
  final reference = JitRuntime.interpreter(
    ctxWords: 64,
    addrMask: 0xffff,
    read: (_, __) => 0,
    write: (_, __, ___) {},
  );
  tearDownAll(() {
    native.dispose();
    reference.dispose();
  });

  const values = [
    0,
    1,
    3,
    4,
    0x7fffffff,
    0x80000000,
    0xbfffffff,
    0xc0000000,
    0xffffffff,
    0x12345678,
  ];
  IrValue compare(IrBuilder b, int op, IrValue x, IrValue y) => switch (op) {
    0 => b.eq(x, y),
    1 => b.ne(x, y),
    2 => b.ltS(x, y),
    3 => b.ltU(x, y),
    _ => b.and(x, y),
  };

  for (var op = 0; op < 5; op++) {
    for (var shape = 0; shape < 5; shape++) {
      // An and of 64-bit values is a 64-bit value, not a condition.
      if (op == 4 && shape >= 3) continue;
      for (final branch in [false, true]) {
        test(
          'comparison $op shape $shape as ${branch ? 'branch' : 'exit'}',
          () {
            final b = IrBuilder(0x100);
            final x = b.ctxLoad(8), y = b.ctxLoad(9);
            final wideX = b.ctxLoad(10, type: IrType.i64);
            final wideY = b.ctxLoad(12, type: IrType.i64);
            for (final k in [0xbfffffff, 3, 0x80000000]) {
              final constant = b.c32(k);
              final cond = switch (shape) {
                0 => compare(b, op, x, y),
                1 => compare(b, op, x, constant),
                2 => compare(b, op, constant, x),
                3 => compare(b, op, wideX, wideY),
                _ => compare(b, op, wideX, b.c64Parts(k, 0)),
              };
              if (branch) {
                // A branch ends the block, so only the last constant is tested.
                if (k == 0x80000000) {
                  final block = b.finish(IrBranch(cond, 0x200, 0x300), cost: 2);
                  _check(native, reference, block, values);
                }
              } else {
                b.exitIf(
                  cond,
                  IrExit(JitReason.user, 0x200 + k % 7 * 4, spent: 1),
                );
              }
            }
            if (!branch) {
              final block = b.finish(const IrJump(0x300), cost: 2);
              _check(native, reference, block, values);
            }
          },
        );
      }
    }
  }
}

void _check(
  JitRuntime native,
  JitRuntime reference,
  IrBlock block,
  List<int> values,
) {
  for (final x in values) {
    for (final y in values) {
      final results = <List<int>>[];
      for (final rt in [native, reference]) {
        rt.clear();
        rt.ctx[8] = x;
        rt.ctx[9] = y;
        rt.ctx[10] = x;
        rt.ctx[11] = y;
        rt.ctx[12] = y;
        rt.ctx[13] = x;
        rt.ctx[JitCtx.budget] = 100;
        rt.install(block);
        final reason = rt.run(block.pc, block.tag);
        results.add([reason, ...rt.ctx]);
      }
      expect(results[0], results[1], reason: 'x $x y $y');
    }
  }
}
