import 'onchip.dart';

abstract class Sh2Bus {
  int read8(int address);
  int read16(int address);
  int read32(int address);
  void write8(int address, int value);
  void write16(int address, int value);
  void write32(int address, int value);
}

/// Integer SH-2 interpreter. Cache control and on-chip peripherals are not emulated yet.
/// Unsupported instructions stop execution instead of acting as NOPs.
class Sh2 {
  /// the bus seen by the instructions: the on-chip registers
  /// (0xfffffe00-0xffffffff) are served inside the cpu
  late final Sh2Bus bus;
  final Sh2OnChip onchip;
  Sh2(Sh2Bus ext, {bool master = true}) : onchip = Sh2OnChip(master) {
    bus = _OnChipBus(ext, onchip);
    onchip.bus = ext;
  }
  final r = List<int>.filled(16, 0);
  int pc = 0, sr = 0xf0, gbr = 0, vbr = 0, pr = 0, mach = 0, macl = 0;
  int clocks = 0, lastOpcode = 0;
  int _irqLevel = 0, _irqVector = 0;
  int? _delayTarget, _restoreSr;
  bool sleeping = false, _inDelay = false;
  bool get t => (sr & 1) != 0;
  set t(bool value) => sr = (sr & ~1) | (value ? 1 : 0);
  int get interruptMask => (sr >> 4) & 15;

  void reset() {
    r.fillRange(0, 16, 0);
    pc = bus.read32(0);
    r[15] = bus.read32(4);
    sr = 0xf0;
    gbr = vbr = pr = mach = macl = clocks = lastOpcode = 0;
    _irqLevel = _irqVector = 0;
    _delayTarget = _restoreSr = null;
    sleeping = _inDelay = false;
    onchip.reset();
  }

  void setInterrupt(int level, int vector) {
    _irqLevel = level;
    _irqVector = vector;
  }

  void _exception(int vector, int savedPc, {int? level}) {
    r[15] = (r[15] - 4) & 0xffffffff;
    bus.write32(r[15], sr);
    r[15] = (r[15] - 4) & 0xffffffff;
    bus.write32(r[15], savedPc);
    if (level != null) sr = (sr & ~0xf0) | (level << 4);
    pc = bus.read32((vbr + vector * 4) & 0xffffffff);
    _delayTarget = _restoreSr = null;
    sleeping = false;
    clocks += 5;
  }

  bool exec() {
    final before = clocks;
    final ok = _execOne();
    onchip.tick(clocks - before);
    return ok;
  }

  bool _execOne() {
    final target = _delayTarget;
    final restore = _restoreSr;
    if (target == null) {
      // the external interrupt (the 32x system) and the on-chip ones (DIVU,
      // DMAC, FRT, WDT): the higher level wins
      final (onchipLevel, onchipVector) =
          onchip.anyPending ? onchip.pendingInterrupt() : (0, 0);
      if (_irqLevel > interruptMask && _irqLevel >= onchipLevel) {
        _exception(_irqVector, pc, level: _irqLevel);
        return true;
      }
      if (onchipLevel > interruptMask) {
        _exception(onchipVector, pc, level: onchipLevel);
        return true;
      }
    }
    if (sleeping) {
      clocks++;
      return true;
    }
    if (pc.isOdd) {
      _exception(9, pc);
      return true;
    }
    final address = pc;
    lastOpcode = bus.read16(address);
    pc = (pc + 2) & 0xffffffff;
    _delayTarget = _restoreSr = null;
    _inDelay = target != null;
    if (!_execute(lastOpcode, address)) {
      pc = address;
      _delayTarget = target;
      _restoreSr = restore;
      return false;
    }
    for (int i = 0; i < 16; i++) {
      r[i] &= 0xffffffff;
    }
    sr &= 0x3f3;
    clocks++;
    if (target != null) {
      pc = target;
      if (restore != null) sr = restore & 0x3f3;
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
            final oldQ = (sr & 0x100) != 0;
            final divisorSign = (sr & 0x200) != 0;
            final dividendSign = (a & 0x80000000) != 0;
            final shifted = ((a << 1) | (t ? 1 : 0)) & 0xffffffff;
            final subtract = oldQ == divisorSign;
            final result = subtract
                ? (shifted - b) & 0xffffffff
                : (shifted + b) & 0xffffffff;
            final carry = subtract ? result > shifted : result < shifted;
            final newQ = oldQ == divisorSign
                ? (oldQ ? dividendSign == carry : dividendSign != carry)
                : (oldQ ? dividendSign != carry : dividendSign == carry);
            r[n] = result;
            sr = (sr & ~0x101) |
                (newQ ? 0x100 : 0) |
                (newQ == divisorSign ? 1 : 0);
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
          // MAC.L reads each operand before incrementing its address register.
          // When m == n, the two reads therefore use consecutive longwords.
          final left = bus.read32(r[n]).toSigned(32);
          r[n] = (r[n] + 4) & 0xffffffff;
          final right = bus.read32(r[m]).toSigned(32);
          r[m] = (r[m] + 4) & 0xffffffff;
          final product = left * right;
          final low = macl + (product & 0xffffffff);
          final high = ((sr & 2) != 0
                  ? (mach & 0xffff).toSigned(16)
                  : mach.toSigned(32)) +
              (product >> 32) +
              (low >> 32);
          if ((sr & 2) != 0 && high > 0x7fff) {
            mach = 0x7fff;
            macl = 0xffffffff;
          } else if ((sr & 2) != 0 && high < -0x8000) {
            mach = 0xffff8000;
            macl = 0;
          } else {
            mach = high & 0xffffffff;
            macl = low & 0xffffffff;
          }
          clocks += 2;
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
        final left = bus.read16(r[n]).toSigned(16);
        r[n] = (r[n] + 2) & 0xffffffff;
        final right = bus.read16(r[m]).toSigned(16);
        r[m] = (r[m] + 2) & 0xffffffff;
        final product = left * right;
        if ((sr & 2) != 0) {
          final sum = macl.toSigned(32) + product;
          macl = (sum > 0x7fffffff
                  ? 0x7fffffff
                  : sum < -0x80000000
                      ? -0x80000000
                      : sum) &
              0xffffffff;
        } else {
          final low = macl + (product & 0xffffffff);
          mach = (mach + (product >> 32) + (low >> 32)) & 0xffffffff;
          macl = low & 0xffffffff;
        }
        clocks += 2;
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

  static String disasm(int op, int address) {
    final n = (op >> 8) & 15, m = (op >> 4) & 15;
    if (op == 9) return 'nop';
    if (op == 0xb) return 'rts';
    if (op == 0x2b) return 'rte';
    if (op == 0x1b) return 'sleep';
    if (op >> 12 == 0xe) return 'mov #${(op & 255).toSigned(8)},r$n';
    if (op >> 12 == 7) return 'add #${(op & 255).toSigned(8)},r$n';
    if ((op & 0xf00f) == 0x6003) return 'mov r$m,r$n';
    if (op >> 12 == 0xa || op >> 12 == 0xb) {
      final target = (address + 4 + (op & 0xfff).toSigned(12) * 2) & 0xffffffff;
      return '${op >> 12 == 0xa ? 'bra' : 'bsr'} 0x${target.toRadixString(16)}';
    }
    return '.word 0x${op.toRadixString(16).padLeft(4, '0')}';
  }

  String dump() =>
      'pc:${pc.toRadixString(16).padLeft(8, '0')} sr:${sr.toRadixString(16)} pr:${pr.toRadixString(16)} ${List.generate(16, (i) => 'r$i:${r[i].toRadixString(16).padLeft(8, '0')}').join(' ')}';
}

class _OnChipBus implements Sh2Bus {
  final Sh2Bus ext;
  final Sh2OnChip onchip;
  _OnChipBus(this.ext, this.onchip);

  // effective addresses (register + register) may exceed 32 bits
  static bool _on(int a) => (a & 0xffffffff) >= 0xfffffe00;
  @override
  int read8(int a) => _on(a) ? onchip.read8(a) : ext.read8(a & 0xffffffff);
  @override
  int read16(int a) => _on(a) ? onchip.read16(a) : ext.read16(a & 0xffffffff);
  @override
  int read32(int a) => _on(a) ? onchip.read32(a) : ext.read32(a & 0xffffffff);
  @override
  void write8(int a, int v) =>
      _on(a) ? onchip.write8(a, v) : ext.write8(a & 0xffffffff, v);
  @override
  void write16(int a, int v) =>
      _on(a) ? onchip.write16(a, v) : ext.write16(a & 0xffffffff, v);
  @override
  void write32(int a, int v) =>
      _on(a) ? onchip.write32(a, v) : ext.write32(a & 0xffffffff, v);
}
