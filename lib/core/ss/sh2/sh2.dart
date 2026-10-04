import 'dart:typed_data';

import '../cpu.dart';
import 'disasm.dart';
import 'onchip.dart';

// SH-2 address space: cache areas and on-chip modules in front of the external bus
class _Sh2Memory implements SsCpuBus {
  final SsCpuBus ext;
  final Sh2OnChip onchip;

  /// number of writes, used for idle loop detection
  int writes = 0;

  _Sh2Memory(this.ext, this.onchip);

  // area by address bits 31-29
  static const _areaCache = 0, _areaThrough = 1, _areaPurge = 2;
  static const _areaAddressArray = 3, _areaDataArray = 6, _areaIo = 7;

  @override
  int read8(int a) {
    a &= 0xffffffff;
    switch (a >>> 29) {
      case _areaCache || _areaThrough:
        return ext.read8(a);
      case _areaDataArray:
        return onchip.cacheData[a & 0xfff];
      case _areaIo:
        return a >= 0xfffffe00 ? onchip.read8(a) : 0;
      case _areaPurge || _areaAddressArray:
        return 0;
      default:
        return ext.read8(a);
    }
  }

  @override
  int read16(int a) {
    a &= 0xfffffffe;
    switch (a >>> 29) {
      case _areaCache || _areaThrough:
        return ext.read16(a);
      case _areaDataArray:
        return onchip.cacheData[a & 0xffe] << 8 |
            onchip.cacheData[(a & 0xffe) + 1];
      case _areaIo:
        return a >= 0xfffffe00 ? onchip.read16(a) : 0;
      case _areaPurge || _areaAddressArray:
        return 0;
      default:
        return ext.read16(a);
    }
  }

  @override
  int read32(int a) {
    a &= 0xfffffffc;
    switch (a >>> 29) {
      case _areaCache || _areaThrough:
        return ext.read32(a);
      case _areaDataArray:
        return read16(a) << 16 | read16(a + 2);
      case _areaIo:
        return a >= 0xfffffe00 ? onchip.read32(a) : 0;
      case _areaPurge || _areaAddressArray:
        return 0;
      default:
        return ext.read32(a);
    }
  }

  @override
  void write8(int a, int d) {
    writes++;
    a &= 0xffffffff;
    switch (a >>> 29) {
      case _areaCache || _areaThrough:
        ext.write8(a, d);
      case _areaDataArray:
        onchip.cacheData[a & 0xfff] = d & 0xff;
      case _areaIo:
        if (a >= 0xfffffe00) onchip.write8(a, d);
      case _areaPurge || _areaAddressArray:
        break; // cache is not emulated
      default:
        ext.write8(a, d);
    }
  }

  @override
  void write16(int a, int d) {
    writes++;
    a &= 0xfffffffe;
    switch (a >>> 29) {
      case _areaCache || _areaThrough:
        ext.write16(a, d);
      case _areaDataArray:
        onchip.cacheData[a & 0xffe] = d >> 8 & 0xff;
        onchip.cacheData[(a & 0xffe) + 1] = d & 0xff;
      case _areaIo:
        if (a >= 0xfffffe00) onchip.write16(a, d);
      case _areaPurge || _areaAddressArray:
        break;
      default:
        ext.write16(a, d);
    }
  }

  @override
  void write32(int a, int d) {
    writes++;
    a &= 0xfffffffc;
    switch (a >>> 29) {
      case _areaCache || _areaThrough:
        ext.write32(a, d);
      case _areaDataArray:
        write16(a, d >> 16);
        write16(a + 2, d);
      case _areaIo:
        if (a >= 0xfffffe00) onchip.write32(a, d);
      case _areaPurge || _areaAddressArray:
        break;
      default:
        ext.write32(a, d);
    }
  }
}

/// Integer SH-2 (SH7604) interpreter for SS.
/// Derived from another SH-2 core of this project, extended with DIV1 / MAC,
/// on-chip peripherals, cache areas, NMI and vectored external interrupts.
/// Unsupported instructions stop execution instead of acting as NOPs.
class Sh2 extends SsCpu {
  late final SsCpuBus bus;
  final Sh2OnChip onchip;

  Sh2(SsCpuBus ext, {bool master = true}) : onchip = Sh2OnChip(master) {
    _mem = _Sh2Memory(ext, onchip);
    bus = _mem;
    onchip.bus = bus;
  }

  late final _Sh2Memory _mem;

  // stores wrap to 32 bits, and typed data keeps the values unboxed
  final r = Uint32List(16);
  @override
  int pc = 0;
  int sr = 0xf0, gbr = 0, vbr = 0, pr = 0, mach = 0, macl = 0;
  @override
  int clocks = 0;
  int lastOpcode = 0;
  int _irl = 0;
  bool _nmi = false;
  // -1: none (avoids boxing of nullable ints)
  int _delayTarget = -1, _restoreSr = -1;
  bool sleeping = false, _inDelay = false;
  bool get t => (sr & 1) != 0;
  set t(bool value) => sr = (sr & ~1) | (value ? 1 : 0);
  bool get _q => (sr & 0x100) != 0;
  bool get _m => (sr & 0x200) != 0;
  set _q(bool value) => sr = (sr & ~0x100) | (value ? 0x100 : 0);
  bool get _s => (sr & 2) != 0;
  int get interruptMask => (sr >> 4) & 15;

  @override
  int get sp => r[15];

  // direct instruction fetch from work RAM high / boot ROM
  ByteData? _fetchWram;
  ByteData? _fetchRom;

  /// sets memories which instructions can be fetched from without the bus
  void setFastFetch({ByteData? wramHigh, ByteData? rom}) {
    _fetchWram = wramHigh;
    _fetchRom = rom;
  }

  int _fetch(int a) {
    // 0x06000000-0x07ffffff in cache / cache-through area
    final wram = _fetchWram;
    if (wram != null && a & 0xde000000 == 0x06000000) {
      return wram.getUint16(a & 0xffffe);
    }
    final rom = _fetchRom;
    if (rom != null && a & 0xdff00000 == 0) {
      return rom.getUint16(a & 0x7fffe);
    }
    return bus.read16(a);
  }

  @override
  void reset() {
    onchip.reset();
    r.fillRange(0, 16, 0);
    pc = bus.read32(0);
    r[15] = bus.read32(4);
    sr = 0xf0;
    gbr = vbr = pr = mach = macl = clocks = lastOpcode = 0;
    _irl = 0;
    _nmi = false;
    _delayTarget = _restoreSr = -1;
    sleeping = _inDelay = false;
  }

  @override
  void setIrl(int level) => _irl = level;

  @override
  void nmi() => _nmi = true;

  @override
  void frtInputCapture() => onchip.inputCapture();

  @override
  bool step() {
    final before = clocks;
    final ok = exec();
    onchip.tick(clocks - before);
    return ok;
  }

  /// fast-forwards idle loops (see _isIdle)
  bool idleSkip = true;

  @override
  bool run(int targetClocks) {
    final before = clocks;
    bool ok = true;
    while (clocks < targetClocks) {
      final prev = pc;
      if (!exec()) {
        ok = false;
        break;
      }
      if (idleSkip &&
          (sleeping || (pc < prev && prev - pc <= 32 && _isIdle()))) {
        clocks = targetClocks;
        break;
      }
    }
    onchip.tick(clocks - before);
    return ok;
  }

  // Other devices do not advance while this CPU runs to the target clocks.
  // So a loop is idle when it comes back to the same place with the same
  // registers and without any memory write: it repeats until the target.
  int _idlePc = -1;
  int _idleWrites = -1;
  final _idleRegs = Uint32List(16);
  int _idleSr = 0, _idleGbr = 0, _idleMach = 0, _idleMacl = 0, _idlePr = 0;

  bool _isIdle() {
    final writes = _mem.writes;
    if (pc == _idlePc &&
        writes == _idleWrites &&
        sr == _idleSr &&
        gbr == _idleGbr &&
        mach == _idleMach &&
        macl == _idleMacl &&
        pr == _idlePr) {
      bool same = true;
      for (int i = 0; i < 16; i++) {
        if (r[i] != _idleRegs[i]) {
          same = false;
          break;
        }
      }
      if (same) {
        _idlePc = -1;
        return true;
      }
    }

    _idlePc = pc;
    _idleWrites = writes;
    _idleSr = sr;
    _idleGbr = gbr;
    _idleMach = mach;
    _idleMacl = macl;
    _idlePr = pr;
    _idleRegs.setAll(0, r);
    return false;
  }

  // cheap check whether any interrupt may be accepted now
  bool get _interruptRequested =>
      _nmi || _irl > ((sr >> 4) & 15) || onchip.anyPending;

  // accepts the highest priority interrupt, returns true when accepted
  bool _acceptInterrupt() {
    if (_nmi) {
      _nmi = false;
      _exception(11, pc, level: 15);
      return true;
    }

    final (onchipLevel, onchipVector) = onchip.pendingInterrupt();
    final mask = interruptMask;

    if (_irl > mask && _irl >= onchipLevel) {
      final level = _irl;
      final vector = onIrlAck();
      _exception(
          onchip.externalVector ? vector : 64 + (level >> 1), pc,
          level: level);
      return true;
    }

    if (onchipLevel > mask) {
      _exception(onchipVector, pc, level: onchipLevel);
      return true;
    }

    return false;
  }

  void _exception(int vector, int savedPc, {int? level}) {
    r[15] = (r[15] - 4) & 0xffffffff;
    bus.write32(r[15], sr);
    r[15] = (r[15] - 4) & 0xffffffff;
    bus.write32(r[15], savedPc);
    if (level != null) sr = (sr & ~0xf0) | (level << 4);
    pc = bus.read32((vbr + vector * 4) & 0xffffffff);
    _delayTarget = _restoreSr = -1;
    sleeping = false;
    clocks += 5;
  }

  bool exec() {
    final target = _delayTarget;
    final restore = _restoreSr;
    if (target < 0 && _interruptRequested && _acceptInterrupt()) {
      return true;
    }
    if (sleeping) {
      clocks++;
      return true;
    }
    if (pc & 1 != 0) {
      _exception(9, pc);
      return true;
    }
    final address = pc;
    lastOpcode = _fetch(address);
    pc = (pc + 2) & 0xffffffff;
    _delayTarget = _restoreSr = -1;
    _inDelay = target >= 0;
    if (!_execute(lastOpcode, address)) {
      pc = address;
      _delayTarget = target;
      _restoreSr = restore;
      return false;
    }
    sr &= 0x3f3;
    clocks++;
    if (target >= 0) {
      pc = target;
      if (restore >= 0) sr = restore & 0x3f3;
    }
    return true;
  }

  bool _branch(int target, {bool delay = true}) {
    if (_inDelay) return false;
    if (delay) {
      _delayTarget = target & 0xffffffff;
    } else {
      pc = target & 0xffffffff;
    }
    clocks++;
    return true;
  }

  bool _execute(int op, int address) {
    final n = (op >> 8) & 15, m = (op >> 4) & 15, low = op & 15;
    switch (op >> 12) {
      case 0xe:
        r[n] = (op & 255).toSigned(8);
        return true;
      case 7:
        r[n] += (op & 255).toSigned(8);
        return true;
      case 9:
        r[n] = bus.read16(address + 4 + (op & 255) * 2).toSigned(16);
        return true;
      case 0xd:
        r[n] = bus.read32(((address + 4) & ~3) + (op & 255) * 4);
        return true;
      case 1:
        bus.write32(r[n] + low * 4, r[m]);
        return true;
      case 5:
        r[n] = bus.read32(r[m] + low * 4);
        return true;
      case 0xa:
        return _branch(address + 4 + (op & 0xfff).toSigned(12) * 2);
      case 0xb:
        if (_inDelay) return false;
        pr = (address + 4) & 0xffffffff;
        return _branch(address + 4 + (op & 0xfff).toSigned(12) * 2);
      case 6:
        final value = r[m];
        switch (low) {
          case 0:
            r[n] = bus.read8(value).toSigned(8);
          case 1:
            r[n] = bus.read16(value).toSigned(16);
          case 2:
            r[n] = bus.read32(value);
          case 3:
            r[n] = value;
          case 4:
            r[n] = bus.read8(value).toSigned(8);
            if (n != m) r[m] += 1;
          case 5:
            r[n] = bus.read16(value).toSigned(16);
            if (n != m) r[m] += 2;
          case 6:
            r[n] = bus.read32(value);
            if (n != m) r[m] += 4;
          case 7:
            r[n] = ~value;
          case 8:
            r[n] = (value & 0xffff0000) |
                ((value & 255) << 8) |
                ((value >> 8) & 255);
          case 9:
            r[n] = ((value & 0xffff) << 16) | (value >> 16);
          case 10:
            final result = -value - (t ? 1 : 0);
            r[n] = result;
            t = result < 0;
          case 11:
            r[n] = -value;
          case 12:
            r[n] = value & 255;
          case 13:
            r[n] = value & 0xffff;
          case 14:
            r[n] = value.toSigned(8);
          case 15:
            r[n] = value.toSigned(16);
        }
        return true;
      case 2:
        final value = r[m];
        switch (low) {
          case 0:
            bus.write8(r[n], value);
          case 1:
            bus.write16(r[n], value);
          case 2:
            bus.write32(r[n], value);
          case 4:
            r[n] -= 1;
            bus.write8(r[n], value);
          case 5:
            r[n] -= 2;
            bus.write16(r[n], value);
          case 6:
            r[n] -= 4;
            bus.write32(r[n], value);
          case 7:
            final q = (r[n] >> 31) & 1, mb = (value >> 31) & 1;
            sr = (sr & ~0x301) | (q << 8) | (mb << 9) | (q ^ mb);
          case 8:
            t = (r[n] & value) == 0;
          case 9:
            r[n] &= value;
          case 10:
            r[n] ^= value;
          case 11:
            r[n] |= value;
          case 12:
            final diff = r[n] ^ value;
            t = List.generate(4, (i) => (diff >> (i * 8)) & 255).contains(0);
          case 13:
            r[n] = (value << 16) | (r[n] >> 16);
          case 14:
            macl = (r[n] & 0xffff) * (value & 0xffff);
          case 15:
            macl = (r[n].toSigned(16) * value.toSigned(16)) & 0xffffffff;
          default:
            return false;
        }
        return true;
      case 3:
        final a = r[n], b = r[m];
        switch (low) {
          case 0:
            t = a == b;
          case 2:
            t = a >= b;
          case 3:
            t = a.toSigned(32) >= b.toSigned(32);
          case 4:
            _div1(n, b);
          case 5 || 13:
            final product = low == 5 ? a * b : a.toSigned(32) * b.toSigned(32);
            macl = product & 0xffffffff;
            mach = (product >> 32) & 0xffffffff;
          case 6:
            t = a > b;
          case 7:
            t = a.toSigned(32) > b.toSigned(32);
          case 8:
            r[n] = a - b;
          case 10:
            final result = a - b - (t ? 1 : 0);
            r[n] = result;
            t = result < 0;
          case 11:
            final result = a - b;
            r[n] = result;
            t = ((a ^ b) & (a ^ result) & 0x80000000) != 0;
          case 12:
            r[n] = a + b;
          case 14:
            final result = a + b + (t ? 1 : 0);
            r[n] = result;
            t = result > 0xffffffff;
          case 15:
            final result = a + b;
            r[n] = result;
            t = (~(a ^ b) & (a ^ result) & 0x80000000) != 0;
          default:
            return false;
        }
        return true;
      case 8:
        final displacement = (op & 255).toSigned(8) * 2;
        switch ((op >> 8) & 15) {
          case 0:
            bus.write8(r[m] + low, r[0]);
          case 1:
            bus.write16(r[m] + low * 2, r[0]);
          case 4:
            r[0] = bus.read8(r[m] + low).toSigned(8);
          case 5:
            r[0] = bus.read16(r[m] + low * 2).toSigned(16);
          case 8:
            t = r[0] == ((op & 255).toSigned(8) & 0xffffffff);
          case 9 || 11 || 13 || 15:
            if (_inDelay) return false;
            final take = (n == 9 || n == 13) ? t : !t;
            if (take) {
              return _branch(address + 4 + displacement, delay: n >= 13);
            }
          default:
            return false;
        }
        return true;
      case 0xc:
        final imm = op & 255;
        switch (n) {
          case 0:
            bus.write8(gbr + imm, r[0]);
          case 1:
            bus.write16(gbr + imm * 2, r[0]);
          case 2:
            bus.write32(gbr + imm * 4, r[0]);
          case 3:
            if (_inDelay) return false;
            _exception(imm, pc);
          case 4:
            r[0] = bus.read8(gbr + imm).toSigned(8);
          case 5:
            r[0] = bus.read16(gbr + imm * 2).toSigned(16);
          case 6:
            r[0] = bus.read32(gbr + imm * 4);
          case 7:
            r[0] = ((address + 4) & ~3) + imm * 4;
          case 8:
            t = (r[0] & imm) == 0;
          case 9:
            r[0] &= imm;
          case 10:
            r[0] ^= imm;
          case 11:
            r[0] |= imm;
          case 12:
            t = (bus.read8(gbr + r[0]) & imm) == 0;
          case 13:
            bus.write8(gbr + r[0], bus.read8(gbr + r[0]) & imm);
          case 14:
            bus.write8(gbr + r[0], bus.read8(gbr + r[0]) ^ imm);
          case 15:
            bus.write8(gbr + r[0], bus.read8(gbr + r[0]) | imm);
        }
        return true;
    }
    if ((op >> 12) == 0) {
      switch (low) {
        case 4:
          bus.write8(r[n] + r[0], r[m]);
          return true;
        case 5:
          bus.write16(r[n] + r[0], r[m]);
          return true;
        case 6:
          bus.write32(r[n] + r[0], r[m]);
          return true;
        case 7:
          macl = (r[n] * r[m]) & 0xffffffff;
          return true;
        case 12:
          r[n] = bus.read8(r[m] + r[0]).toSigned(8);
          return true;
        case 13:
          r[n] = bus.read16(r[m] + r[0]).toSigned(16);
          return true;
        case 14:
          r[n] = bus.read32(r[m] + r[0]);
          return true;
        case 15:
          _macL(n, m);
          return true;
      }
      switch (op & 0xf0ff) {
        case 0x0002:
          r[n] = sr;
          return true;
        case 0x0012:
          r[n] = gbr;
          return true;
        case 0x0022:
          r[n] = vbr;
          return true;
        case 0x000a:
          r[n] = mach;
          return true;
        case 0x001a:
          r[n] = macl;
          return true;
        case 0x002a:
          r[n] = pr;
          return true;
        case 0x0029:
          r[n] = t ? 1 : 0;
          return true;
        case 0x0003:
          if (_inDelay) return false;
          pr = address + 4;
          return _branch(address + 4 + r[n]);
        case 0x0023:
          return _branch(address + 4 + r[n]);
      }
      switch (op) {
        case 0x0008:
          t = false;
          return true;
        case 0x0018:
          t = true;
          return true;
        case 0x0009:
          return true;
        case 0x0019:
          sr &= ~0x301;
          return true;
        case 0x0028:
          mach = macl = 0;
          return true;
        case 0x000b:
          return _branch(pr);
        case 0x001b:
          if (_inDelay) return false;
          sleeping = true;
          return true;
        case 0x002b:
          if (_inDelay) return false;
          final next = bus.read32(r[15]);
          final status = bus.read32(r[15] + 4);
          r[15] += 8;
          _restoreSr = status;
          return _branch(next);
      }
    }
    if ((op >> 12) == 4) {
      if (low == 15) {
        _macW(n, m);
        return true;
      }
      switch (op & 255) {
        case 0x00 || 0x20:
          t = (r[n] & 0x80000000) != 0;
          r[n] <<= 1;
        case 0x01:
          t = r[n].isOdd;
          r[n] >>= 1;
        case 0x21:
          t = r[n].isOdd;
          r[n] = r[n].toSigned(32) >> 1;
        case 0x04:
          final carry = (r[n] >> 31) & 1;
          r[n] = (r[n] << 1) | carry;
          t = carry != 0;
        case 0x05:
          final carry = r[n] & 1;
          r[n] = (r[n] >> 1) | (carry << 31);
          t = carry != 0;
        case 0x24:
          final old = t;
          t = (r[n] & 0x80000000) != 0;
          r[n] = (r[n] << 1) | (old ? 1 : 0);
        case 0x25:
          final old = t;
          t = r[n].isOdd;
          r[n] = (r[n] >> 1) | (old ? 0x80000000 : 0);
        case 0x08:
          r[n] <<= 2;
        case 0x09:
          r[n] >>= 2;
        case 0x18:
          r[n] <<= 8;
        case 0x19:
          r[n] >>= 8;
        case 0x28:
          r[n] <<= 16;
        case 0x29:
          r[n] >>= 16;
        case 0x10:
          r[n]--;
          t = (r[n] & 0xffffffff) == 0;
        case 0x11:
          t = r[n].toSigned(32) >= 0;
        case 0x15:
          t = r[n].toSigned(32) > 0;
        case 0x0b:
          if (_inDelay) return false;
          pr = address + 4;
          return _branch(r[n]);
        case 0x2b:
          return _branch(r[n]);
        case 0x1b:
          final value = bus.read8(r[n]);
          t = value == 0;
          bus.write8(r[n], value | 0x80);
        case 0x0e:
          sr = r[n] & 0x3f3;
        case 0x1e:
          gbr = r[n];
        case 0x2e:
          vbr = r[n];
        case 0x0a:
          mach = r[n];
        case 0x1a:
          macl = r[n];
        case 0x2a:
          pr = r[n];
        case 0x02 || 0x12 || 0x22 || 0x03 || 0x13 || 0x23:
          final value = switch (op & 255) {
            2 => mach,
            0x12 => macl,
            0x22 => pr,
            3 => sr,
            0x13 => gbr,
            _ => vbr
          };
          r[n] -= 4;
          bus.write32(r[n], value);
        case 0x06 || 0x16 || 0x26 || 0x07 || 0x17 || 0x27:
          final value = bus.read32(r[n]);
          r[n] += 4;
          switch (op & 255) {
            case 6:
              mach = value;
            case 0x16:
              macl = value;
            case 0x26:
              pr = value;
            case 7:
              sr = value & 0x3f3;
            case 0x17:
              gbr = value;
            case 0x27:
              vbr = value;
          }
        default:
          return false;
      }
      return true;
    }
    return false;
  }

  void _div1(int n, int rm) {
    final oldQ = _q;
    final msb = (r[n] & 0x80000000) != 0;
    int rn = ((r[n] << 1) | (t ? 1 : 0)) & 0xffffffff;
    final tmp0 = rn;
    bool carry;
    if (oldQ == _m) {
      rn = (rn - rm) & 0xffffffff;
      carry = rn > tmp0; // borrow
    } else {
      rn = (rn + rm) & 0xffffffff;
      carry = rn < tmp0;
    }
    r[n] = rn;
    _q = (msb != carry) != _m;
    t = _q == _m;
  }

  void _macL(int n, int m) {
    final rn = bus.read32(r[n]).toSigned(32);
    r[n] = (r[n] + 4) & 0xffffffff;
    final rm = bus.read32(r[m]).toSigned(32);
    r[m] = (r[m] + 4) & 0xffffffff;

    final product = rn * rm;
    int result;
    if (_s) {
      // 48-bit saturation
      final acc = (((mach & 0xffff) << 32) | macl) << 16 >> 16;
      result = acc + product;
      const max = 0x7fffffffffff, min = -0x800000000000;
      if (result > max) result = max;
      if (result < min) result = min;
    } else {
      result = ((mach << 32) | macl) + product;
    }
    mach = (result >> 32) & 0xffffffff;
    macl = result & 0xffffffff;
  }

  void _macW(int n, int m) {
    final rn = bus.read16(r[n]).toSigned(16);
    r[n] = (r[n] + 2) & 0xffffffff;
    final rm = bus.read16(r[m]).toSigned(16);
    r[m] = (r[m] + 2) & 0xffffffff;

    final product = rn * rm;
    if (_s) {
      // 32-bit saturation, MACH bit 0 flags an overflow
      int result = macl.toSigned(32) + product;
      if (result > 0x7fffffff) {
        result = 0x7fffffff;
        mach |= 1;
      } else if (result < -0x80000000) {
        result = -0x80000000;
        mach |= 1;
      }
      macl = result & 0xffffffff;
    } else {
      final result = ((mach << 32) | macl) + product;
      mach = (result >> 32) & 0xffffffff;
      macl = result & 0xffffffff;
    }
  }

  @override
  (String, int) disasm(int addr) {
    final op = bus.read16(addr);
    String hex(int v, int w) => v.toRadixString(16).padLeft(w, '0');
    return ("${hex(addr & 0xffffffff, 8)}: ${hex(op, 4)}  ${Sh2Disasm.disasm(op, addr)}", 2);
  }

  @override
  String dump() {
    String h(int v) => (v & 0xffffffff).toRadixString(16).padLeft(8, '0');
    return 'pc:${h(pc)} sr:${(sr & 0x3f3).toRadixString(16).padLeft(3, '0')} gbr:${h(gbr)} vbr:${h(vbr)} pr:${h(pr)} mach:${h(mach)} macl:${h(macl)}\n'
        '${List.generate(16, (i) => 'r$i:${h(r[i])}').join(' ')}\n${onchip.dump()}';
  }
}
