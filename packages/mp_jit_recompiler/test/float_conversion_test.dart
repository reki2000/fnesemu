import 'dart:math';
import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

final _data = ByteData(8);

/// Bit patterns are (low, high) words so dart2js keeps them exact.
(int, int) _bits64(double v) {
  _data.setFloat64(0, v, Endian.little);
  return (_data.getUint32(0, Endian.little), _data.getUint32(4, Endian.little));
}

int _bits32(double v) {
  _data.setFloat32(0, v, Endian.little);
  return _data.getUint32(0, Endian.little);
}

double _single(int bits) {
  _data.setUint32(0, bits, Endian.little);
  return _data.getFloat32(0, Endian.little);
}

int _nearestEven(double v) {
  final floor = v.floorToDouble(), fraction = v - floor;
  return (fraction > 0.5 || (fraction == 0.5 && floor % 2 != 0)
          ? floor + 1
          : floor)
      .toInt();
}

void main() {
  for (final native in [false, true]) {
    group(native ? 'native' : 'reference', () {
      late JitRuntime rt;
      setUp(() {
        rt = native
            ? JitRuntime.native(
                ctxWords: 32,
                addrMask: 0xffff,
                read: (_, __) => 0,
                write: (_, __, ___) {})!
            : JitRuntime.interpreter(
                ctxWords: 32,
                addrMask: 0xffff,
                read: (_, __) => 0,
                write: (_, __, ___) {});
      });
      tearDown(() => rt.dispose());

      void run() {
        rt.ctx[JitCtx.budget] = 1;
        expect(rt.run(0x100, 0), JitReason.user);
      }

      void install(IrValue Function(IrBuilder b) body) {
        final b = IrBuilder(0x100);
        b.ctxStore(12, body(b));
        rt.install(b.finish(
            const IrExitTerm(IrExit(JitReason.user, 0x104)), cost: 1));
      }

      final random = Random(57);
      final edges = <double>[
        0, -0.0, 0.5, -0.5, 1.5, 2.5, -2.5, 3.49999, 1e-40, -1e-45, //
        123456.75, -98765.5, 2147483647.25, -2147483648.0, 3.4e38, 1e-310,
      ];
      final samples = [
        ...edges,
        for (var i = 0; i < 300; i++)
          (random.nextDouble() - 0.5) * pow(2, random.nextInt(64) - 20),
      ];

      test('binary32 widens exactly', () {
        install((b) => b.floatConvert(b.ctxLoad(8)));
        for (final v in samples) {
          final bits = _bits32(v);
          if (!_single(bits).isFinite) continue;
          rt.ctx[8] = bits;
          run();
          expect((rt.ctx[12], rt.ctx[13]), _bits64(_single(bits)),
              reason: '$v');
        }
      });

      test('binary64 narrows to nearest even', () {
        install((b) => b.floatConvert(b.ctxLoad(8, type: IrType.i64)));
        for (final v in samples) {
          final (low, high) = _bits64(v);
          rt.ctx[8] = low;
          rt.ctx[9] = high;
          run();
          expect(rt.ctx[12], _bits32(v), reason: '$v');
        }
      });

      for (final wide in [false, true]) {
        for (final truncate in [false, true]) {
          test(
              '${wide ? 'binary64' : 'binary32'} to word '
              '${truncate ? 'toward zero' : 'to nearest even'}', () {
            install((b) => b.floatToInt(
                b.ctxLoad(8, type: wide ? IrType.i64 : IrType.i32),
                truncate: truncate));
            for (final sample in samples) {
              final v = wide ? sample : _single(_bits32(sample));
              if (!v.isFinite || v.abs() >= 2147483647.0) continue;
              if (wide) {
                final (low, high) = _bits64(v);
                rt.ctx[8] = low;
                rt.ctx[9] = high;
              } else {
                rt.ctx[8] = _bits32(v);
              }
              run();
              final expected = truncate ? v.truncate() : _nearestEven(v);
              expect(rt.ctx[12], expected.toUnsigned(32), reason: '$v');
            }
          });
        }
      }
    },
        skip: native && !JitRuntime.nativeSupported
            ? 'No compiled backend'
            : false);
  }
}
