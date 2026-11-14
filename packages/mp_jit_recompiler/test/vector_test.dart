import 'dart:math';
import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

JitRuntime _reference() => JitRuntime.interpreter(
  ctxWords: 256,
  addrMask: 0xffff,
  read: (_, __) => 0,
  write: (_, __, ___) {},
);

JitRuntime? _native() => JitRuntime.native(
  ctxWords: 256,
  addrMask: 0xffff,
  read: (_, __) => 0,
  write: (_, __, ___) {},
);

final _data = ByteData(8);

/// the value of a register image, from its fields
double _value(int image) {
  final e = (image >> 23) & 255;
  if (e == 0) return 0;
  final v = (1 + (image & 0x7fffff) / 0x800000) * pow(2.0, e - 127);
  return image & 0x80000000 != 0 ? -v : v;
}

/// the image of [v] and its flags (zero, sign, under, over)
(int, bool, bool, bool, bool) _image(double v) {
  _data.setFloat64(0, v, Endian.little);
  final high = _data.getUint32(4, Endian.little);
  final low = _data.getUint32(0, Endian.little);
  final sign = high & 0x80000000;
  final m = v.abs();
  if (m < pow(2.0, -126)) return (sign, true, sign != 0, m != 0, false);
  if (m >= pow(2.0, 129)) {
    return (sign | 0x7fffffff, false, sign != 0, false, true);
  }
  final e = ((high >> 20) & 0x7ff) - 896;
  final fraction = (high & 0xfffff) << 3 | low >>> 29;
  return (sign | e << 23 | fraction, false, sign != 0, false, false);
}

int _randomImage(Random r) => switch (r.nextInt(8)) {
  0 => r.nextInt(0x800000) | (r.nextBool() ? 0x80000000 : 0), // exponent 0
  1 => 0x7f800000 | r.nextInt(0x800000) | (r.nextBool() ? 0x80000000 : 0),
  2 =>
    (r.nextInt(16) << 23 | r.nextInt(0x800000)) |
        (r.nextBool() ? 0x80000000 : 0), // tiny
  3 =>
    ((240 + r.nextInt(16)) << 23 | r.nextInt(0x800000)) |
        (r.nextBool() ? 0x80000000 : 0), // huge
  _ => r.nextInt(0x100000000),
};

void main() {
  test('the reference vector operations match a model of the images', () {
    final rt = _reference();
    addTearDown(rt.dispose);
    final random = Random(7);
    for (var trial = 0; trial < 300; trial++) {
      final b = IrBuilder(0x100);
      final x = b.ctxLoad(16, type: IrType.v128);
      final y = b.ctxLoad(20, type: IrType.v128);
      final op = const [
        IrOp.vFloatAdd,
        IrOp.vFloatSub,
        IrOp.vFloatMul,
      ][trial % 3];
      final low = b.vFloat(op, b.vuDecode(x, 0), b.vuDecode(y, 0));
      final high = b.vFloat(op, b.vuDecode(x, 1), b.vuDecode(y, 1));
      b.ctxStore(24, b.vuEncode(low, high));
      b.ctxStore(28, b.vuFlags(low, high));
      final block = b.finish(IrExitTerm(IrExit(JitReason.user, 0)), cost: 1);
      final xs = [for (var i = 0; i < 4; i++) _randomImage(random)];
      final ys = [for (var i = 0; i < 4; i++) _randomImage(random)];
      rt.clear();
      rt.ctx.setAll(16, [...xs, ...ys]);
      rt.ctx[JitCtx.budget] = 10;
      rt.install(block);
      rt.run(0x100, 0);
      var flags = 0;
      for (var i = 0; i < 4; i++) {
        final p = _value(xs[i]), q = _value(ys[i]);
        final v = switch (op) {
          IrOp.vFloatAdd => p + q,
          IrOp.vFloatSub => p - q,
          _ => p * q,
        };
        final (image, zero, sign, under, over) = _image(v);
        expect(
          rt.ctx[24 + i],
          image,
          reason:
              'trial $trial lane $i ${xs[i].toRadixString(16)} '
              '${ys[i].toRadixString(16)}',
        );
        final at = 3 - i;
        flags |=
            (zero ? 1 : 0) << at |
            (sign ? 1 : 0) << (4 + at) |
            (under ? 1 : 0) << (8 + at) |
            (over ? 1 : 0) << (12 + at);
      }
      expect(rt.ctx[28], flags, reason: 'trial $trial');
    }
  });

  test('the reference MAX, MINI and CLIP compare the values of images', () {
    final rt = _reference();
    addTearDown(rt.dispose);
    final random = Random(11);
    for (var trial = 0; trial < 300; trial++) {
      final b = IrBuilder(0x100);
      final x = b.ctxLoad(16, type: IrType.v128);
      final y = b.ctxLoad(20, type: IrType.v128);
      b.ctxStore(24, b.vuMax(x, y));
      b.ctxStore(28, b.vuMin(x, y));
      b.ctxStore(32, b.vuClip(x, y));
      final block = b.finish(IrExitTerm(IrExit(JitReason.user, 0)), cost: 1);
      final xs = [for (var i = 0; i < 4; i++) _randomImage(random)];
      final ys = [for (var i = 0; i < 4; i++) _randomImage(random)];
      rt.clear();
      rt.ctx.setAll(16, [...xs, ...ys]);
      rt.ctx[JitCtx.budget] = 10;
      rt.install(block);
      rt.run(0x100, 0);
      for (var i = 0; i < 4; i++) {
        final p = _value(xs[i]), q = _value(ys[i]);
        expect(rt.ctx[24 + i], p < q ? ys[i] : xs[i], reason: 'max $trial');
        expect(rt.ctx[28 + i], q < p ? ys[i] : xs[i], reason: 'min $trial');
      }
      final w = _value(ys[3]).abs();
      var clip = 0;
      for (var i = 0; i < 3; i++) {
        if (_value(xs[i]) > w) clip |= 1 << 2 * i;
        if (_value(xs[i]) < -w) clip |= 2 << 2 * i;
      }
      expect(rt.ctx[32], clip, reason: 'clip $trial');
    }
  });

  test('compiled vector operations match the reference', () {
    final reference = _reference();
    addTearDown(reference.dispose);
    final native = _native();
    if (native == null || !native.vectors) {
      native?.dispose();
      markTestSkipped('No compiled vector backend');
      return;
    }
    addTearDown(native.dispose);
    final random = Random(913);
    for (var trial = 0; trial < 300; trial++) {
      final b = IrBuilder(0x100);
      final vectors = [
        for (var i = 0; i < 6; i++) b.ctxLoad(16 + 4 * i, type: IrType.v128),
      ];
      final scalars = [for (var i = 0; i < 4; i++) b.ctxLoad(64 + i)];
      IrValue v() => vectors[random.nextInt(vectors.length)];
      IrValue s() => scalars[random.nextInt(scalars.length)];
      IrValue decoded() => b.vuDecode(v(), random.nextInt(2));
      for (var step = 0; step < 40; step++) {
        switch (random.nextInt(13)) {
          case 0:
            vectors[random.nextInt(6)] = b.vSplat(s());
          case 1:
            scalars[random.nextInt(4)] = b.vExtract(v(), random.nextInt(4));
          case 2:
            vectors[random.nextInt(6)] = b.vInsert(v(), s(), random.nextInt(4));
          case 3:
            vectors[random.nextInt(6)] = b.vShuffle(v(), random.nextInt(256));
          case 4:
            vectors[random.nextInt(6)] = b.vBlend(v(), v(), random.nextInt(16));
          case 5 || 6:
            final op = const [
              IrOp.vFloatAdd,
              IrOp.vFloatSub,
              IrOp.vFloatMul,
            ][random.nextInt(3)];
            final low = b.vFloat(op, decoded(), decoded());
            final high = b.vFloat(op, decoded(), decoded());
            // the flags then the encode, as the VU translator puts them
            final flags = b.vuFlags(low, high);
            vectors[random.nextInt(6)] = b.vuEncode(low, high);
            scalars[random.nextInt(4)] = b.xor(s(), flags);
          case 7:
            vectors[random.nextInt(6)] = b.vuEncode(decoded(), decoded());
          case 8:
            scalars[random.nextInt(4)] = b.add(s(), b.vuFlags(v(), v()));
          case 9:
            vectors[random.nextInt(6)] = b.vuMax(v(), v());
          case 10:
            vectors[random.nextInt(6)] = b.vuMin(v(), v());
          case 11:
            scalars[random.nextInt(4)] = b.xor(s(), b.vuClip(v(), v()));
          default:
            b.ctxStore(96 + 4 * random.nextInt(8), v());
        }
        if (step == 25) {
          b.exitIf(
            b.c32(trial % 3 == 0 ? 1 : 0),
            IrExit(
              JitReason.user,
              0x104,
              spent: 1,
              stores: [
                for (var i = 0; i < 6; i++) (128 + 4 * i, vectors[i]),
                for (var i = 0; i < 4; i++) (160 + i, scalars[i]),
              ],
            ),
          );
        }
      }
      final block = b.finish(
        IrExitTerm(
          IrExit(
            JitReason.user,
            0x200,
            stores: [
              for (var i = 0; i < 6; i++) (128 + 4 * i, vectors[i]),
              for (var i = 0; i < 4; i++) (160 + i, scalars[i]),
            ],
          ),
        ),
        cost: 2,
      );
      final initial = List.generate(256, (i) => _randomImage(random));
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
