part of 'interp_runtime.dart';

/// BigInt makes the reference semantics exact on the VM, dart2wasm and
/// dart2js. Compiled i64 backends can use machine registers/Wasm i64 later.
extension _Wide on IrInterpreterRuntime {
  static final _mask32 = BigInt.from(0xffffffff);
  static BigInt _bits(Object value) =>
      value is BigInt ? value : BigInt.from(value as int);
  static int _word(BigInt value) => (value & _mask32).toInt();

  Object _wide(IrInst inst, List<Object> values) {
    BigInt a() => _bits(values[inst.a]);
    BigInt b() => _bits(values[inst.b]);
    Object result(BigInt value) =>
        inst.type == IrType.i64 ? value.toUnsigned(64) : _word(value);
    switch (inst.op) {
      case IrOp.constant:
        return result(BigInt.from(inst.imm.toUnsigned(32)) |
            BigInt.from(inst.immHi.toUnsigned(32)) << 32);
      case IrOp.ctxLoad:
        return result(
            BigInt.from(ctx[inst.imm]) | BigInt.from(ctx[inst.imm + 1]) << 32);
      case IrOp.ctxStore:
        ctx[inst.imm] = _word(a());
        ctx[inst.imm + 1] = _word(a() >> 32);
        return 0;
      case IrOp.add:
        return result(a() + b());
      case IrOp.sub:
        return result(a() - b());
      case IrOp.mul:
        return result(a() * b());
      case IrOp.mulHiS:
        return result((a().toSigned(64) * b().toSigned(64)) >> 64);
      case IrOp.mulHiU:
        return result((a() * b()) >> 64);
      case IrOp.and:
        return result(a() & b());
      case IrOp.or:
        return result(a() | b());
      case IrOp.xor:
        return result(a() ^ b());
      case IrOp.shl:
        return result(a() << ((values[inst.b] as int) & 63));
      case IrOp.shrU:
        return result(a() >> ((values[inst.b] as int) & 63));
      case IrOp.shrS:
        return result(a().toSigned(64) >> ((values[inst.b] as int) & 63));
      case IrOp.eq:
        return a() == b() ? 1 : 0;
      case IrOp.ne:
        return a() != b() ? 1 : 0;
      case IrOp.ltS:
        return a().toSigned(64) < b().toSigned(64) ? 1 : 0;
      case IrOp.ltU:
        return a() < b() ? 1 : 0;
      case IrOp.select:
        return result(
            (values[inst.a] as int) != 0 ? b() : _bits(values[inst.c]));
      case IrOp.sext8:
        return result(a().toSigned(8));
      case IrOp.sext16:
        return result(a().toSigned(16));
      case IrOp.zext8:
        return result(a().toUnsigned(8));
      case IrOp.zext16:
        return result(a().toUnsigned(16));
      case IrOp.sext32:
        return result(a().toSigned(32));
      case IrOp.zext32:
        return result(a().toUnsigned(32));
      case IrOp.trunc32:
        return _word(a());
      case IrOp.load:
        return result(_loadWide(
            values[inst.a] as int, inst.imm, inst.aux != 0, inst.endian));
      case IrOp.store:
        _storeWide(values[inst.a] as int, inst.imm, b(), inst.endian);
        return 0;
      default:
        throw StateError('unexpected wide operation ${inst.op.name}');
    }
  }

  BigInt _loadWide(int addr, int size, bool signed, IrEndian endian) {
    if (size <= 4) {
      final bits = BigInt.from(_load(addr, size, false, endian));
      return signed ? bits.toSigned(size * 8) : bits;
    }
    final masked = addr & addrMask;
    final page = readPages[masked >>> JitRuntime.pageBits];
    BigInt bits;
    if (page == null) {
      bits = BigInt.from(read(addr, 4).toUnsigned(32)) |
          BigInt.from(read((addr + 4).toUnsigned(32), 4).toUnsigned(32)) << 32;
    } else {
      final (host, offset) = page;
      final at = offset + (masked & (JitRuntime.pageSize - 1));
      bits = BigInt.zero;
      for (int i = 0; i < 8; i++) {
        bits |= BigInt.from(host[at + i]) << (8 * i);
      }
    }
    if (endian == IrEndian.big) bits = _swapWide(bits);
    return signed ? bits.toSigned(64) : bits;
  }

  void _storeWide(int addr, int size, BigInt value, IrEndian endian) {
    if (size <= 4) {
      _store(addr, size, _word(value), endian);
      return;
    }
    if (endian == IrEndian.big) value = _swapWide(value);
    final masked = addr & addrMask;
    final page = writePages[masked >>> JitRuntime.pageBits];
    if (page == null) {
      write(addr, 4, _word(value));
      write((addr + 4).toUnsigned(32), 4, _word(value >> 32));
    } else {
      final (host, offset) = page;
      final at = offset + (masked & (JitRuntime.pageSize - 1));
      for (int i = 0; i < 8; i++) {
        host[at + i] = ((value >> (8 * i)) & BigInt.from(255)).toInt();
      }
    }
  }

  static BigInt _swapWide(BigInt value) {
    var result = BigInt.zero;
    for (int i = 0; i < 8; i++) {
      result = (result << 8) | ((value >> (8 * i)) & BigInt.from(255));
    }
    return result;
  }
}
