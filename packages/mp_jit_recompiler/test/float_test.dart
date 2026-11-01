import 'dart:math';
import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

void main() {
  for (final native in [false, true]) {
    for (final wide in [false, true]) {
      for (final op in [
        IrOp.floatAdd,
        IrOp.floatSub,
        IrOp.floatMul,
        IrOp.floatDiv,
      ]) {
        test('$native $wide $op preserves finite IEEE arithmetic', () {
          if (native && !JitRuntime.nativeSupported) {
            markTestSkipped('Native runtime unavailable');
            return;
          }
          final rt = native
              ? JitRuntime.native(
                  ctxWords: 32,
                  addrMask: 0xffff,
                  read: (_, __) => 0,
                  write: (_, __, ___) {},
                )!
              : JitRuntime.interpreter(
                  ctxWords: 32,
                  addrMask: 0xffff,
                  read: (_, __) => 0,
                  write: (_, __, ___) {},
                );
          addTearDown(rt.dispose);
          final type = wide ? IrType.i64 : IrType.i32;
          final b = IrBuilder(0x100);
          b.ctxStore(
            12,
            b.floatBinary(
              op,
              b.ctxLoad(8, type: type),
              b.ctxLoad(10, type: type),
            ),
          );
          rt.install(b.finish(const IrJump(0x200), cost: 1));
          final data = ByteData(24), random = Random(42);
          // Bit patterns are (low, high) words so dart2js keeps them exact.
          final edges = wide
              ? const [
                  (0, 0),
                  (0, 0x80000000),
                  (1, 0),
                  (1, 0x80000000),
                  (0, 0x00100000),
                  (0, 0x3ff00000),
                  (0xffffffff, 0x7fefffff),
                  (0xffffffff, 0xffefffff),
                ]
              : const [
                  (0, 0),
                  (0x80000000, 0),
                  (1, 0),
                  (0x80000001, 0),
                  (0x00800000, 0),
                  (0x3f800000, 0),
                  (0x7f7fffff, 0),
                  (0xff7fffff, 0),
                ];
          void check((int, int) x, (int, int) y) {
            data.setUint32(0, x.$1, Endian.little);
            data.setUint32(4, x.$2, Endian.little);
            data.setUint32(8, y.$1, Endian.little);
            data.setUint32(12, y.$2, Endian.little);
            final a = wide
                ? data.getFloat64(0, Endian.little)
                : data.getFloat32(0, Endian.little);
            final c = wide
                ? data.getFloat64(8, Endian.little)
                : data.getFloat32(8, Endian.little);
            if (!a.isFinite || !c.isFinite) return;
            final result = switch (op) {
              IrOp.floatAdd => a + c,
              IrOp.floatSub => a - c,
              IrOp.floatMul => a * c,
              _ => a / c,
            };
            // NaN payloads are not part of the IR contract.
            if (result.isNaN) return;
            if (wide) {
              data.setFloat64(16, result, Endian.little);
            } else {
              data.setFloat32(16, result, Endian.little);
            }
            rt.ctx[8] = x.$1;
            rt.ctx[9] = x.$2;
            rt.ctx[10] = y.$1;
            rt.ctx[11] = y.$2;
            rt.ctx[JitCtx.budget] = 1;
            rt.run(0x100, 0);
            expect(
              rt.ctx[12],
              data.getUint32(16, Endian.little),
              reason: '$x $y low',
            );
            if (wide) {
              expect(
                rt.ctx[13],
                data.getUint32(20, Endian.little),
                reason: '$x $y high',
              );
            }
          }

          for (final a in edges) {
            for (final c in edges) {
              check(a, c);
            }
          }
          for (var i = 0; i < 1000; i++) {
            (int, int) bits() => (
              random.nextInt(0x100000000),
              wide ? random.nextInt(0x100000000) : 0,
            );
            check(bits(), bits());
          }
        });
      }
    }
  }
  for (final native in [false, true]) {
    for (final wide in [false, true]) {
      test('$native $wide floatSqrt matches the host square root', () {
        if (native && !JitRuntime.nativeSupported) {
          markTestSkipped('Native runtime unavailable');
          return;
        }
        final rt = native
            ? JitRuntime.native(
                ctxWords: 32,
                addrMask: 0xffff,
                read: (_, __) => 0,
                write: (_, __, ___) {},
              )!
            : JitRuntime.interpreter(
                ctxWords: 32,
                addrMask: 0xffff,
                read: (_, __) => 0,
                write: (_, __, ___) {},
              );
        addTearDown(rt.dispose);
        final type = wide ? IrType.i64 : IrType.i32;
        final b = IrBuilder(0x100);
        b.ctxStore(12, b.floatSqrt(b.ctxLoad(8, type: type)));
        rt.install(b.finish(const IrJump(0x200), cost: 1));
        final data = ByteData(24), random = Random(7);
        void check(int lo, int hi) {
          data.setUint32(0, lo, Endian.little);
          data.setUint32(4, hi, Endian.little);
          final a = wide
              ? data.getFloat64(0, Endian.little)
              : data.getFloat32(0, Endian.little);
          if (!a.isFinite || a < 0) return;
          final result = sqrt(a);
          if (wide) {
            data.setFloat64(16, result, Endian.little);
          } else {
            data.setFloat32(16, result, Endian.little);
          }
          rt.ctx[8] = lo;
          rt.ctx[9] = hi;
          rt.ctx[JitCtx.budget] = 1;
          rt.run(0x100, 0);
          expect(
            rt.ctx[12],
            data.getUint32(16, Endian.little),
            reason: '$lo $hi low',
          );
          if (wide) {
            expect(
              rt.ctx[13],
              data.getUint32(20, Endian.little),
              reason: '$lo $hi high',
            );
          }
        }

        check(0, 0);
        check(0x3f800000, 0);
        check(0, 0x3ff00000);
        check(0x7f7fffff, 0);
        check(0xffffffff, 0x7fefffff);
        for (var i = 0; i < 1000; i++) {
          check(
            random.nextInt(0x100000000),
            wide ? random.nextInt(0x100000000) : 0,
          );
        }
      });
    }
  }
}
