import 'dart:math';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

void main() {
  test(
      'mixed-width register pressure, helpers and wide snapshots match reference',
      () {
    final reference = JitRuntime.interpreter(
        ctxWords: 128,
        addrMask: 0xffff,
        read: (_, __) => 0,
        write: (_, __, ___) {});
    final native = JitRuntime.native(
        ctxWords: 128,
        addrMask: 0xffff,
        read: (_, __) => 0,
        write: (_, __, ___) {});
    addTearDown(reference.dispose);
    if (native == null) {
      markTestSkipped('No compiled backend');
      return;
    }
    addTearDown(native.dispose);
    for (final rt in [reference, native]) {
      rt.addHelper((a, b, c) {
        rt.ctx[100]++;
        return (a * 17 + b * 3 + c) & 0xffffffff;
      });
    }
    final random = Random(841);
    for (var trial = 0; trial < 200; trial++) {
      final b = IrBuilder(0x100);
      final values = [
        for (var i = 0; i < 8; i++) b.ctxLoad(8 + i * 2, type: IrType.i64)
      ];
      for (var step = 0; step < 80; step++) {
        final dst = random.nextInt(8);
        final x = values[random.nextInt(8)], y = values[random.nextInt(8)];
        values[dst] = switch (random.nextInt(14)) {
          0 => b.add(x, y),
          1 => b.sub(x, y),
          2 => b.mul(x, y),
          3 => b.mulHiS(x, y),
          4 => b.mulHiU(x, y),
          5 => b.and(x, y),
          6 => b.or(x, y),
          7 => b.xor(x, y),
          8 => b.shl(x, b.trunc32(y)),
          9 => b.shrS(x, b.trunc32(y)),
          10 => b.shrU(x, b.trunc32(y)),
          11 => b.select(b.ltS(x, y), x, y),
          12 => b.select(b.ltU(x, y), x, y),
          _ => b.c64Parts(
              random.nextInt(0x100000000), random.nextInt(0x100000000)),
        };
        if (step == 20 || step == 50) {
          final result = b.call(0, b.trunc32(x), b.trunc32(y), b.c32(step));
          values[dst] = b.xor(values[dst], b.zext32(result));
        }
        if (step == 40) {
          b.exitIf(
              b.c32(trial % 3 == 0 ? 1 : 0),
              IrExit(JitReason.user, 0x104, spent: 2, stores: [
                for (var i = 0; i < 8; i++) (32 + i * 2, values[i])
              ]));
        }
      }
      final block = b.finish(
          IrExitTerm(IrExit(JitReason.user, 0x200,
              stores: [for (var i = 0; i < 8; i++) (32 + i * 2, values[i])])),
          cost: 4);
      final initial = List.generate(128, (_) => random.nextInt(0x100000000));
      for (final rt in [reference, native]) {
        rt.clear();
        rt.ctx.setAll(0, initial);
        rt.ctx[JitCtx.stop] = 0;
        rt.ctx[JitCtx.budget] = 10;
        rt.install(block);
        rt.run(0x100, 0);
      }
      expect(native.ctx, reference.ctx, reason: 'trial $trial');
    }
  });
}
