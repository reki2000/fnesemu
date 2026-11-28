part of 'interp_runtime.dart';

/// The vector operations, on lanes of 32-bit words so that they are exact
/// on every platform: a v128 value is a [Uint32List] of four words. The
/// result of a vector unit operation has its flags ([IrOp.vuMac]) as a
/// fifth word.
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
      case IrOp.load:
        final address = values[inst.a] as int;
        return Uint32List.fromList([
          for (var k = 0; k < 4; k++)
            _load(address + 4 * k, 4, false, IrEndian.little),
        ]);
      case IrOp.store:
        final address = values[inst.a] as int, x = b();
        for (var k = 0; k < 4; k++) {
          _store(address + 4 * k, 4, x[k], IrEndian.little);
        }
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
      case IrOp.vuAdd ||
            IrOp.vuSub ||
            IrOp.vuMul ||
            IrOp.vuMadd ||
            IrOp.vuMsub:
        // the images, then the flags of the result
        final x = a(), y = b(), r = Uint32List(5);
        final c = inst.c >= 0 ? _lanes(values[inst.c]) : null;
        var flags = 0;
        for (var i = 0; i < 4; i++) {
          final p = _value(x[(inst.imm >> 2 * i) & 3]);
          final q = _value(y[(inst.imm >> 8 + 2 * i) & 3]);
          final v = switch (inst.op) {
            IrOp.vuAdd => p + q,
            IrOp.vuSub => p - q,
            IrOp.vuMul => p * q,
            IrOp.vuMadd => _value(c![i]) + p * q,
            _ => _value(c![i]) - p * q,
          };
          _floatData.setFloat64(0, v, Endian.little);
          final low = _floatData.getUint32(0, Endian.little);
          final high = _floatData.getUint32(4, Endian.little);
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
        r[4] = flags;
        return r;
      case IrOp.vuMac:
        return a()[4];
      case IrOp.vuItof:
        final x = a(), r = Uint32List(4);
        for (var i = 0; i < 4; i++) {
          r[i] = _image(x[i].toSigned(32) / (1 << inst.imm));
        }
        return r;
      case IrOp.vuFtoi:
        final x = a(), r = Uint32List(4);
        for (var i = 0; i < 4; i++) {
          final v = _value(x[i]) * (1 << inst.imm);
          r[i] = v >= 0x80000000
              ? 0x7fffffff
              : v <= -0x80000000
              ? 0x80000000
              : v.truncate() & 0xffffffff;
        }
        return r;
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

  /// the register image of [v], truncated
  int _image(double v) {
    _floatData.setFloat64(0, v, Endian.little);
    final low = _floatData.getUint32(0, Endian.little);
    final high = _floatData.getUint32(4, Endian.little);
    final magnitudeHigh = high & 0x7fffffff;
    final sign = high & 0x80000000;
    if (magnitudeHigh < 897 << 20) return sign;
    if (magnitudeHigh > (1152 << 20) - 1) return sign | 0x7fffffff;
    final shifted = ((high & 0x1fffffff) << 3) | (low >>> 29);
    return sign | ((shifted - (896 << 23)) & 0xffffffff);
  }

  /// the value of a register image, exactly
  double _value(int image) {
    if (image & 0x7f800000 == 0) return 0;
    final magnitude = image & 0x7fffffff;
    _floatData.setUint32(0, (magnitude << 29) & 0xffffffff, Endian.little);
    _floatData.setUint32(4,
        ((magnitude >>> 3) + (896 << 20)) | (image & 0x80000000), Endian.little);
    return _floatData.getFloat64(0, Endian.little);
  }
}
