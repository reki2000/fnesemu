import 'dart:math';
import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

JitRuntime _reference([List<String>? log]) => JitRuntime.interpreter(
  ctxWords: 256,
  addrMask: 0xffff,
  read: (address, _) => _read(address, log),
  write: (address, value, size) => log?.add('w $address $value $size'),
);

JitRuntime? _native([List<String>? log]) => JitRuntime.native(
  ctxWords: 256,
  addrMask: 0xffff,
  read: (address, _) => _read(address, log),
  write: (address, value, size) => log?.add('w $address $value $size'),
);

int _read(int address, List<String>? log) {
  log?.add('r $address');
  return (address * 0x9e3779b1) & 0xffffffff;
}

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
  test('the reference vector unit operations match a model of the images', () {
    final rt = _reference();
    addTearDown(rt.dispose);
    final random = Random(7);
    const ops = [IrOp.vuAdd, IrOp.vuSub, IrOp.vuMul, IrOp.vuMadd, IrOp.vuMsub];
    for (var trial = 0; trial < 500; trial++) {
      final b = IrBuilder(0x100);
      final x = b.ctxLoad(16, type: IrType.v128);
      final y = b.ctxLoad(20, type: IrType.v128);
      final acc = b.ctxLoad(28, type: IrType.v128);
      final op = ops[trial % ops.length];
      final aLanes = random.nextInt(256), bLanes = random.nextInt(256);
      final r = b.vuArithmetic(
        op,
        x,
        y,
        c: op == IrOp.vuMadd || op == IrOp.vuMsub ? acc : null,
        aLanes: aLanes,
        bLanes: bLanes,
      );
      b.ctxStore(24, r);
      b.ctxStore(32, b.vuMac(r));
      final block = b.finish(IrExitTerm(IrExit(JitReason.user, 0)), cost: 1);
      final xs = [for (var i = 0; i < 4; i++) _randomImage(random)];
      final ys = [for (var i = 0; i < 4; i++) _randomImage(random)];
      final accs = [for (var i = 0; i < 4; i++) _randomImage(random)];
      rt.clear();
      rt.ctx.setAll(16, [...xs, ...ys]);
      rt.ctx.setAll(28, accs);
      rt.ctx[JitCtx.budget] = 10;
      rt.install(block);
      rt.run(0x100, 0);
      var flags = 0;
      for (var i = 0; i < 4; i++) {
        final p = _value(xs[(aLanes >> 2 * i) & 3]);
        final q = _value(ys[(bLanes >> 2 * i) & 3]);
        final c = _value(accs[i]);
        final v = switch (op) {
          IrOp.vuAdd => p + q,
          IrOp.vuSub => p - q,
          IrOp.vuMul => p * q,
          IrOp.vuMadd => c + p * q,
          _ => c - p * q,
        };
        final (image, zero, sign, under, over) = _image(v);
        expect(rt.ctx[24 + i], image, reason: 'trial $trial lane $i');
        final at = 3 - i;
        flags |=
            (zero ? 1 : 0) << at |
            (sign ? 1 : 0) << (4 + at) |
            (under ? 1 : 0) << (8 + at) |
            (over ? 1 : 0) << (12 + at);
      }
      expect(rt.ctx[32], flags, reason: 'trial $trial');
    }
  });

  test('the reference ITOF and FTOI match a model', () {
    final rt = _reference();
    addTearDown(rt.dispose);
    final random = Random(5);
    for (var trial = 0; trial < 300; trial++) {
      final shift = random.nextInt(32);
      final b = IrBuilder(0x100);
      final x = b.ctxLoad(16, type: IrType.v128);
      b.ctxStore(24, b.vuItof(x, shift));
      b.ctxStore(28, b.vuFtoi(x, shift));
      final block = b.finish(IrExitTerm(IrExit(JitReason.user, 0)), cost: 1);
      final xs = [for (var i = 0; i < 4; i++) _randomImage(random)];
      rt.clear();
      rt.ctx.setAll(16, xs);
      rt.ctx[JitCtx.budget] = 10;
      rt.install(block);
      rt.run(0x100, 0);
      for (var i = 0; i < 4; i++) {
        expect(
          rt.ctx[24 + i],
          _image(xs[i].toSigned(32) / pow(2, shift)).$1,
          reason: 'itof $trial',
        );
        final v = _value(xs[i]) * pow(2, shift);
        final int expected = v >= pow(2, 31)
            ? 0x7fffffff
            : v <= -pow(2, 31)
            ? 0x80000000
            : v.truncate() & 0xffffffff;
        expect(rt.ctx[28 + i], expected, reason: 'ftoi $trial');
      }
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
    final referenceLog = <String>[], nativeLog = <String>[];
    final reference = _reference(referenceLog);
    addTearDown(reference.dispose);
    final native = _native(nativeLog);
    if (native == null || !native.vectors) {
      native?.dispose();
      markTestSkipped('No compiled vector backend');
      return;
    }
    addTearDown(native.dispose);
    // the first page is mapped, the second one goes to the callbacks
    final memories = [reference.alloc(4096), native.alloc(4096)];
    final random = Random(913);
    for (var trial = 0; trial < 1000; trial++) {
      final b = IrBuilder(0x100);
      final vectors = [
        for (var i = 0; i < 6; i++) b.ctxLoad(16 + 4 * i, type: IrType.v128),
      ];
      final scalars = [for (var i = 0; i < 4; i++) b.ctxLoad(64 + i)];
      IrValue v() => vectors[random.nextInt(vectors.length)];
      IrValue s() => scalars[random.nextInt(scalars.length)];
      for (var step = 0; step < 40; step++) {
        switch (random.nextInt(16)) {
          case 0:
            vectors[random.nextInt(6)] = b.vSplat(s());
          case 1:
            scalars[random.nextInt(4)] = b.vExtract(v(), random.nextInt(4));
          case 2:
            vectors[random.nextInt(6)] = b.vInsert(v(), s(), random.nextInt(4));
          case 3:
            vectors[random.nextInt(6)] = b.vShuffle(v(), random.nextInt(256));
          case 4 || 5:
            vectors[random.nextInt(6)] = b.vBlend(v(), v(), random.nextInt(16));
          case 6 || 7 || 8:
            final op = const [
              IrOp.vuAdd,
              IrOp.vuSub,
              IrOp.vuMul,
              IrOp.vuMadd,
              IrOp.vuMsub,
            ][random.nextInt(5)];
            // a broadcast, a cross product's lanes or random lanes
            int lanes() => switch (random.nextInt(4)) {
              0 => 0xe4,
              1 => 0x55 * random.nextInt(4),
              2 => 0xc9,
              _ => random.nextInt(256),
            };
            final r = b.vuArithmetic(
              op,
              v(),
              v(),
              c: op == IrOp.vuMadd || op == IrOp.vuMsub ? v() : null,
              aLanes: lanes(),
              bLanes: lanes(),
            );
            vectors[random.nextInt(6)] = r;
            if (random.nextBool()) {
              scalars[random.nextInt(4)] = b.xor(s(), b.vuMac(r));
            }
          case 9:
            scalars[random.nextInt(4)] = b.add(
              s(),
              b.vuMac(b.vuArithmetic(IrOp.vuMul, v(), v())),
            );
          case 13:
            final shift = const [0, 4, 12, 15, 31][random.nextInt(5)];
            vectors[random.nextInt(6)] = random.nextBool()
                ? b.vuItof(v(), shift)
                : b.vuFtoi(v(), shift);
          case 10:
            vectors[random.nextInt(6)] = b.vuMax(v(), v());
          case 11:
            vectors[random.nextInt(6)] = b.vuMin(v(), v());
          case 12:
            scalars[random.nextInt(4)] = b.xor(s(), b.vuClip(v(), v()));
          case 14:
            final address = b.shl(b.and(s(), b.c32(0x1ff)), b.c32(4));
            if (random.nextBool()) {
              vectors[random.nextInt(6)] = b.load(
                16,
                address,
                type: IrType.v128,
              );
            } else {
              b.store(16, address, v());
            }
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
      final bytes = List.generate(4096, (_) => random.nextInt(256));
      referenceLog.clear();
      nativeLog.clear();
      for (final rt in [reference, native]) {
        memories[rt == reference ? 0 : 1].setAll(0, bytes);
        rt.clear();
        rt.mapPages(0, 4096, memories[rt == reference ? 0 : 1]);
        rt.ctx.setAll(0, initial);
        rt.ctx[JitCtx.stop] = 0;
        rt.ctx[JitCtx.budget] = 10;
        rt.install(block);
        rt.run(0x100, 0);
      }
      expect(native.ctx, reference.ctx, reason: 'trial $trial');
      expect(memories[1], memories[0], reason: 'trial $trial');
      expect(nativeLog, referenceLog, reason: 'trial $trial');
    }
  });
}
