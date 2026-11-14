part of 'interp_runtime.dart';

/// The vector operations, on lanes of 32-bit words so that they are exact
/// on every platform: a v128 value is a [Uint32List] of four words, and a
/// binary64 lane is two of them, the low word first.
extension _Vector on IrInterpreterRuntime {
  static Uint32List _lanes(Object value) => value as Uint32List;

  Object _vector(IrInst inst, List<Object> values) {
    Uint32List a() => _lanes(values[inst.a]);
    Uint32List b() => _lanes(values[inst.b]);
    switch (inst.op) {
      case IrOp.ctxLoad:
        return Uint32List.fromList(ctx.sublist(inst.imm, inst.imm + 4));
      case IrOp.ctxStore:
        ctx.setRange(inst.imm, inst.imm + 4, a());
        return 0;
      case IrOp.vSplat:
        return Uint32List(4)..fillRange(0, 4, values[inst.a] as int);
      case IrOp.vExtract:
        return a()[inst.imm];
      case IrOp.vInsert:
        return Uint32List.fromList(a())..[inst.imm] = values[inst.b] as int;
      case IrOp.vShuffle:
        final x = a();
        return Uint32List.fromList([
          for (var i = 0; i < 4; i++) x[(inst.imm >> 2 * i) & 3],
        ]);
      case IrOp.vBlend:
        final x = a(), y = b();
        return Uint32List.fromList([
          for (var i = 0; i < 4; i++) inst.imm & (1 << i) != 0 ? y[i] : x[i],
        ]);
      case IrOp.vuDecode:
        final x = a(), r = Uint32List(4);
        for (var k = 0; k < 2; k++) {
          final image = x[2 * inst.imm + k];
          if (image & 0x7f800000 == 0) continue;
          final magnitude = image & 0x7fffffff;
          r[2 * k] = (magnitude << 29) & 0xffffffff;
          r[2 * k + 1] =
              ((magnitude >>> 3) + (896 << 20)) | (image & 0x80000000);
        }
        return r;
      case IrOp.vFloatAdd || IrOp.vFloatSub || IrOp.vFloatMul:
        final x = a(), y = b(), r = Uint32List(4);
        for (var k = 0; k < 2; k++) {
          final p = _double64(x, k), q = _double64(y, k);
          final v = switch (inst.op) {
            IrOp.vFloatAdd => p + q,
            IrOp.vFloatSub => p - q,
            _ => p * q,
          };
          _floatData.setFloat64(0, v, Endian.little);
          r[2 * k] = _floatData.getUint32(0, Endian.little);
          r[2 * k + 1] = _floatData.getUint32(4, Endian.little);
        }
        return r;
      case IrOp.vuEncode || IrOp.vuFlags:
        final x = a(), y = b(), r = Uint32List(4);
        var flags = 0;
        for (var i = 0; i < 4; i++) {
          final source = i < 2 ? x : y, k = i & 1;
          final low = source[2 * k], high = source[2 * k + 1];
          final magnitudeHigh = high & 0x7fffffff;
          final sign = high & 0x80000000;
          final zero = magnitudeHigh < 897 << 20;
          final over = magnitudeHigh > (1152 << 20) - 1;
          final under = zero && (magnitudeHigh != 0 || low != 0);
          final shifted = ((high & 0x1fffffff) << 3) | (low >>> 29);
          r[i] = zero
              ? sign
              : over
              ? sign | 0x7fffffff
              : sign | ((shifted - (896 << 23)) & 0xffffffff);
          final at = 3 - i;
          if (zero) flags |= 1 << at;
          if (sign != 0) flags |= 1 << (4 + at);
          if (under) flags |= 1 << (8 + at);
          if (over) flags |= 1 << (12 + at);
        }
        return inst.op == IrOp.vuEncode ? r : flags;
      case IrOp.vuMax || IrOp.vuMin:
        final x = a(), y = b();
        return Uint32List.fromList([
          for (var i = 0; i < 4; i++)
            (inst.op == IrOp.vuMax
                    ? _key(x[i]) < _key(y[i])
                    : _key(y[i]) < _key(x[i]))
                ? y[i]
                : x[i],
        ]);
      case IrOp.vuClip:
        final x = a(), w = b()[3];
        final limit = w & 0x7f800000 == 0 ? 0 : w & 0x7fffffff;
        var bits = 0;
        for (var i = 0; i < 3; i++) {
          final k = _key(x[i]);
          if (limit < k) bits |= 1 << 2 * i;
          if (k < -limit) bits |= 2 << 2 * i;
        }
        return bits;
      default:
        throw StateError('${inst.op} on v128 values');
    }
  }

  /// an integer ordered as the values of register images
  static int _key(int image) {
    if (image & 0x7f800000 == 0) return 0;
    final magnitude = image & 0x7fffffff;
    return image & 0x80000000 != 0 ? -magnitude : magnitude;
  }

  double _double64(Uint32List lanes, int k) {
    _floatData.setUint32(0, lanes[2 * k], Endian.little);
    _floatData.setUint32(4, lanes[2 * k + 1], Endian.little);
    return _floatData.getFloat64(0, Endian.little);
  }
}
