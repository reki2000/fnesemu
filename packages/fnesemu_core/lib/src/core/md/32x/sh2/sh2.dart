import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../../../../components/sh2/jit/jit.dart';
import '../../../../util/int.dart';
import '../../../../util/register_dump.dart';
import '../../../../util/state.dart';
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
  final _OnChipBus _bus;
  Sh2Bus get bus => _bus;
  final Sh2OnChip onchip;
  Sh2(Sh2Bus ext, {bool master = true, Sh2Jit? jit})
      : this._(ext, jit, Sh2OnChip(master));

  Sh2._(Sh2Bus ext, Sh2Jit? jit, Sh2OnChip onchip)
      : jit = jit,
        onchip = onchip,
        _bus = _OnChipBus(ext, onchip),
        r = jit?.regs ?? Uint32List(16),
        _state = jit?.state ?? Uint32List(8) {
    sr = 0xf0;
    jit?.attach(
        (address) => _jitCodeAddress(address) ? ext.read16(address) : null);
    onchip.bus = ext;
    if (jit != null) {
      jit.diagnostics.memoryRegion = _memoryRegion;
      jit.diagnostics.bindExecutionStats((stats) {
        executionStats = stats;
        _bus.executionStats = stats;
      });
    }
  }
  // Only even SDRAM addresses and their P1 aliases can be compiled here.
  static bool _jitCodeAddress(int address) =>
      (address & 0xdffc0001) == 0x06000000;

  final Sh2Jit? jit;
  JitExecutionStats? executionStats;
  final Uint32List r, _state;
  int pc = 0;
  @pragma('vm:prefer-inline')
  int get sr => _state[0];
  @pragma('vm:prefer-inline')
  set sr(int value) => _state[0] = value;
  @pragma('vm:prefer-inline')
  int get gbr => _state[1];
  @pragma('vm:prefer-inline')
  set gbr(int value) => _state[1] = value;
  @pragma('vm:prefer-inline')
  int get vbr => _state[2];
  @pragma('vm:prefer-inline')
  set vbr(int value) => _state[2] = value;
  @pragma('vm:prefer-inline')
  int get pr => _state[3];
  @pragma('vm:prefer-inline')
  set pr(int value) => _state[3] = value;
  @pragma('vm:prefer-inline')
  int get mach => _state[4];
  @pragma('vm:prefer-inline')
  set mach(int value) => _state[4] = value;
  @pragma('vm:prefer-inline')
  int get macl => _state[5];
  @pragma('vm:prefer-inline')
  set macl(int value) => _state[5] = value;
  int clocks = 0;
  @pragma('vm:prefer-inline')
  int get lastOpcode => _state[6];
  @pragma('vm:prefer-inline')
  set lastOpcode(int value) => _state[6] = value;
  int _irqLevel = 0, _irqVector = 0;
  int? _delayTarget, _restoreSr;
  bool sleeping = false, _inDelay = false;
  @pragma('vm:prefer-inline')
  bool get t => sr.bit0;
  @pragma('vm:prefer-inline')
  set t(bool value) => sr = (sr & ~1) | (value ? 1 : 0);
  @pragma('vm:prefer-inline')
  int get interruptMask => sr.shr4.mask4;

  /// Saves logical state while the owning core identifies external media.
  void saveState(StateWriter w) {
    w.section('32x-sh2');
    w.ints(r);
    w.ints(_state);
    w.int64(pc);
    w.int64(clocks);
    w.int64(_irqLevel);
    w.int64(_irqVector);
    w.boolean(_delayTarget != null);
    if (_delayTarget != null) w.int64(_delayTarget!);
    w.boolean(_restoreSr != null);
    if (_restoreSr != null) w.int64(_restoreSr!);
    w.boolean(sleeping);
    w.boolean(_inDelay);
    onchip.saveState(w);
  }

  /// Restores existing buffers and keeps callback and bus wiring.
  void loadState(StateReader s) {
    s.section('32x-sh2');
    jit?.reset();
    s.intsInto(r);
    s.intsInto(_state);
    pc = s.int64();
    clocks = s.int64();
    _irqLevel = s.int64();
    _irqVector = s.int64();
    _delayTarget = s.boolean() ? s.int64() : null;
    _restoreSr = s.boolean() ? s.int64() : null;
    sleeping = s.boolean();
    _inDelay = s.boolean();
    onchip.loadState(s);
  }

  void reset() {
    jit?.reset();
    r.fillRange(0, 16, 0);
    pc = _bus.read32(0);
    r[15] = _bus.read32(4);
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
    r[15] = (r[15] - 4).mask32;
    _bus.write32(r[15], sr);
    r[15] = (r[15] - 4).mask32;
    _bus.write32(r[15], savedPc);
    if (level != null) sr = (sr & ~0xf0) | level.shl4;
    pc = _bus.read32((vbr + vector * 4).mask32);
    _delayTarget = _restoreSr = null;
    sleeping = false;
    clocks += 5;
  }

  bool exec({bool compiled = true}) {
    final before = clocks;
    final ok = _execOne(compiled);
    onchip.tick(clocks - before);
    return ok;
  }

  /// Runs to the adapter deadline, retaining instruction-based debug stepping.
  bool run(int targetClocks, {bool compiled = true}) {
    while (clocks < targetClocks) {
      final before = clocks;
      final ok = _execOne(compiled, targetClocks - clocks);
      onchip.tick(clocks - before);
      if (!ok) return false;
    }
    return true;
  }

  bool _execOne(bool compiled, [int budget = 1]) {
    final stats = executionStats;
    if (stats == null) return _execOneUnprofiled(compiled, budget);
    final at = pc, before = clocks, wasSleeping = sleeping;
    final opcode = stats.opcodeAt(at);
    stats.beginCpuStep();
    try {
      return _execOneUnprofiled(compiled, budget);
    } finally {
      final interpreted = stats.cpuActive;
      stats.endCpuStep();
      if (interpreted) {
        if (wasSleeping && sleeping) {
          stats.recordIdle(clocks - before);
        } else {
          stats.recordCpuStep(at, opcode, clocks - before);
        }
      }
    }
  }

  static String _memoryRegion(int address) {
    final a = address & 0xffffffff;
    if (a >= 0xfffffe00) return 'onchip';
    if (a & 0xe0000000 == 0xc0000000) return 'cacheData';
    final p = a & 0x1fffffff;
    if (p >= 0x06000000 && p < 0x06040000) return 'ram';
    if (p >= 0x02000000 && p < 0x02400000) return 'rom';
    if (p >= 0x04000000 && p < 0x04060000) return 'framebuffer';
    if (p < 0x4000) return 'bios';
    return 'device';
  }

  int _fetchInstruction(int address) {
    final stats = executionStats;
    if (stats == null) return _bus.read16(address);
    stats.fetching = true;
    stats.recordMemory(address, 2, fetch: true);
    try {
      return _bus.read16(address);
    } finally {
      stats.fetching = false;
    }
  }

  bool _execOneUnprofiled(bool compiled, int budget) {
    final target = _delayTarget;
    final restore = _restoreSr;
    if (target == null) {
      // the external interrupt (the 32x system) and the on-chip ones (DIVU,
      // DMAC, FRT, WDT): the higher level wins
      var onchipLevel = 0;
      if (onchip.anyPending) {
        onchip.updatePendingInterrupt();
        onchipLevel = onchip.pendingLevel;
      }
      final mask = interruptMask;
      if (_irqLevel > mask && _irqLevel >= onchipLevel) {
        _exception(_irqVector, pc, level: _irqLevel);
        return true;
      }
      if (onchipLevel > mask) {
        _exception(onchip.pendingVector, pc, level: onchipLevel);
        return true;
      }
    }
    if (compiled &&
        jit != null &&
        !jit!.suspended &&
        target == null &&
        !sleeping &&
        _jitCodeAddress(pc)) {
      executionStats?.pauseCpuStep();
      final result = jit!.run(pc, budget);
      if (result != null) {
        pc = result.$1;
        clocks += result.$2;
        return true;
      }
    }
    executionStats?.resumeCpuStep();
    if (sleeping) {
      clocks++;
      return true;
    }
    if (pc.isOdd) {
      _exception(9, pc);
      return true;
    }
    final address = pc;
    lastOpcode = _fetchInstruction(address);
    pc = (pc + 2).mask32;
    _delayTarget = _restoreSr = null;
    _inDelay = target != null;
    if (!_execute(lastOpcode, address)) {
      pc = address;
      _delayTarget = target;
      _restoreSr = restore;
      return false;
    }
    sr &= 0x3f3;
    clocks++;
    if (target != null) {
      pc = target;
      if (restore != null) sr = restore & 0x3f3;
    }
    return true;
  }

  @pragma('vm:prefer-inline')
  bool _branch(int target, {bool delay = true}) {
    if (_inDelay) return false;
    if (delay) {
      _delayTarget = target.mask32;
    } else {
      pc = target.mask32;
    }
    clocks++;
    return true;
  }

  bool _execute(int op, int address) {
    final n = op.shr8.mask4, m = op.shr4.mask4, low = op.mask4;
    switch (op.shr12) {
      case 0xe:
        r[n] = op.rel8;
        return true;
      case 7:
        r[n] += op.rel8;
        return true;
      case 9:
        r[n] = _bus.read16(address + 4 + op.mask8 * 2).rel16;
        return true;
      case 0xd:
        r[n] = _bus.read32(((address + 4) & ~3) + op.mask8 * 4);
        return true;
      case 1:
        _bus.write32(r[n] + low * 4, r[m]);
        return true;
      case 5:
        r[n] = _bus.read32(r[m] + low * 4);
        return true;
      case 0xa:
        return _branch(address + 4 + op.rel12 * 2);
      case 0xb:
        if (_inDelay) return false;
        pr = (address + 4).mask32;
        return _branch(address + 4 + op.rel12 * 2);
      case 6:
        final value = r[m];
        switch (low) {
          case 0:
            r[n] = _bus.read8(value).rel8;
          case 1:
            r[n] = _bus.read16(value).rel16;
          case 2:
            r[n] = _bus.read32(value);
          case 3:
            r[n] = value;
          case 4:
            r[n] = _bus.read8(value).rel8;
            if (n != m) r[m] += 1;
          case 5:
            r[n] = _bus.read16(value).rel16;
            if (n != m) r[m] += 2;
          case 6:
            r[n] = _bus.read32(value);
            if (n != m) r[m] += 4;
          case 7:
            r[n] = ~value;
          case 8:
            r[n] = (value & 0xffff0000) | value.mask8.shl8 | value.shr8.mask8;
          case 9:
            r[n] = value.mask16.shl16 | value.shr16;
          case 10:
            final result = -value - (t ? 1 : 0);
            r[n] = result;
            t = result < 0;
          case 11:
            r[n] = -value;
          case 12:
            r[n] = value.mask8;
          case 13:
            r[n] = value.mask16;
          case 14:
            r[n] = value.rel8;
          case 15:
            r[n] = value.rel16;
        }
        return true;
      case 2:
        final value = r[m];
        switch (low) {
          case 0:
            _bus.write8(r[n], value);
          case 1:
            _bus.write16(r[n], value);
          case 2:
            _bus.write32(r[n], value);
          case 4:
            r[n] -= 1;
            _bus.write8(r[n], value);
          case 5:
            r[n] -= 2;
            _bus.write16(r[n], value);
          case 6:
            r[n] -= 4;
            _bus.write32(r[n], value);
          case 7:
            final q = r[n].shr31.mask1, mb = value.shr31.mask1;
            sr = (sr & ~0x301) | q.shl8 | mb.shl9 | (q ^ mb);
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
            t = List.generate(4, (i) => (diff >> (i * 8)).mask8).contains(0);
          case 13:
            r[n] = value.shl16 | r[n].shr16;
          case 14:
            macl = r[n].mask16 * value.mask16;
          case 15:
            macl = (r[n].rel16 * value.rel16).mask32;
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
            t = a.rel32 >= b.rel32;
          case 4:
            final oldQ = sr.bit8;
            final divisorSign = sr.bit9;
            final dividendSign = a.bit31;
            final shifted = (a.shl1 | (t ? 1 : 0)).mask32;
            final subtract = oldQ == divisorSign;
            final result =
                subtract ? (shifted - b).mask32 : (shifted + b).mask32;
            final carry = subtract ? result > shifted : result < shifted;
            final newQ = oldQ == divisorSign
                ? (oldQ ? dividendSign == carry : dividendSign != carry)
                : (oldQ ? dividendSign != carry : dividendSign == carry);
            r[n] = result;
            sr = (sr & ~0x101) |
                (newQ ? 0x100 : 0) |
                (newQ == divisorSign ? 1 : 0);
          case 5 || 13:
            final product = low == 5 ? a * b : a.rel32 * b.rel32;
            macl = product.mask32;
            mach = (product >> 32).mask32;
          case 6:
            t = a > b;
          case 7:
            t = a.rel32 > b.rel32;
          case 8:
            r[n] = a - b;
          case 10:
            final result = a - b - (t ? 1 : 0);
            r[n] = result;
            t = result < 0;
          case 11:
            final result = a - b;
            r[n] = result;
            t = ((a ^ b) & (a ^ result)).bit31;
          case 12:
            r[n] = a + b;
          case 14:
            final result = a + b + (t ? 1 : 0);
            r[n] = result;
            t = result > 0xffffffff;
          case 15:
            final result = a + b;
            r[n] = result;
            t = (~(a ^ b) & (a ^ result)).bit31;
          default:
            return false;
        }
        return true;
      case 8:
        final displacement = op.rel8 * 2;
        switch (op.shr8.mask4) {
          case 0:
            _bus.write8(r[m] + low, r[0]);
          case 1:
            _bus.write16(r[m] + low * 2, r[0]);
          case 4:
            r[0] = _bus.read8(r[m] + low).rel8;
          case 5:
            r[0] = _bus.read16(r[m] + low * 2).rel16;
          case 8:
            t = r[0] == op.rel8.mask32;
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
        final imm = op.mask8;
        switch (n) {
          case 0:
            _bus.write8(gbr + imm, r[0]);
          case 1:
            _bus.write16(gbr + imm * 2, r[0]);
          case 2:
            _bus.write32(gbr + imm * 4, r[0]);
          case 3:
            if (_inDelay) return false;
            _exception(imm, pc);
          case 4:
            r[0] = _bus.read8(gbr + imm).rel8;
          case 5:
            r[0] = _bus.read16(gbr + imm * 2).rel16;
          case 6:
            r[0] = _bus.read32(gbr + imm * 4);
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
            t = (_bus.read8(gbr + r[0]) & imm) == 0;
          case 13:
            _bus.write8(gbr + r[0], _bus.read8(gbr + r[0]) & imm);
          case 14:
            _bus.write8(gbr + r[0], _bus.read8(gbr + r[0]) ^ imm);
          case 15:
            _bus.write8(gbr + r[0], _bus.read8(gbr + r[0]) | imm);
        }
        return true;
    }
    if (op.shr12 == 0) {
      switch (low) {
        case 4:
          _bus.write8(r[n] + r[0], r[m]);
          return true;
        case 5:
          _bus.write16(r[n] + r[0], r[m]);
          return true;
        case 6:
          _bus.write32(r[n] + r[0], r[m]);
          return true;
        case 7:
          macl = (r[n] * r[m]).mask32;
          return true;
        case 12:
          r[n] = _bus.read8(r[m] + r[0]).rel8;
          return true;
        case 13:
          r[n] = _bus.read16(r[m] + r[0]).rel16;
          return true;
        case 14:
          r[n] = _bus.read32(r[m] + r[0]);
          return true;
        case 15:
          // MAC.L reads each operand before incrementing its address register.
          // When m == n, the two reads therefore use consecutive longwords.
          final left = _bus.read32(r[n]).rel32;
          r[n] = (r[n] + 4).mask32;
          final right = _bus.read32(r[m]).rel32;
          r[m] = (r[m] + 4).mask32;
          final product = left * right;
          final low = macl + product.mask32;
          final high = (sr.bit1 ? mach.rel16 : mach.rel32) +
              (product >> 32) +
              (low >> 32);
          if (sr.bit1 && high > 0x7fff) {
            mach = 0x7fff;
            macl = 0xffffffff;
          } else if (sr.bit1 && high < -0x8000) {
            mach = 0xffff8000;
            macl = 0;
          } else {
            mach = high.mask32;
            macl = low.mask32;
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
          final next = _bus.read32(r[15]);
          final status = _bus.read32(r[15] + 4);
          r[15] += 8;
          _restoreSr = status;
          return _branch(next);
      }
    }
    if (op.shr12 == 4) {
      if (low == 15) {
        final left = _bus.read16(r[n]).rel16;
        r[n] = (r[n] + 2).mask32;
        final right = _bus.read16(r[m]).rel16;
        r[m] = (r[m] + 2).mask32;
        final product = left * right;
        if (sr.bit1) {
          final sum = macl.rel32 + product;
          macl = (sum > 0x7fffffff
                  ? 0x7fffffff
                  : sum < -0x80000000
                      ? -0x80000000
                      : sum)
              .mask32;
        } else {
          final low = macl + product.mask32;
          mach = (mach + (product >> 32) + (low >> 32)).mask32;
          macl = low.mask32;
        }
        clocks += 2;
        return true;
      }
      switch (op.mask8) {
        case 0x00 || 0x20:
          t = r[n].bit31;
          r[n] <<= 1;
        case 0x01:
          t = r[n].isOdd;
          r[n] >>= 1;
        case 0x21:
          t = r[n].isOdd;
          r[n] = r[n].rel32.shr1;
        case 0x04:
          final carry = r[n].shr31.mask1;
          r[n] = r[n].shl1 | carry;
          t = carry != 0;
        case 0x05:
          final carry = r[n].mask1;
          r[n] = r[n].shr1 | carry.shl31;
          t = carry != 0;
        case 0x24:
          final old = t;
          t = r[n].bit31;
          r[n] = r[n].shl1 | (old ? 1 : 0);
        case 0x25:
          final old = t;
          t = r[n].isOdd;
          r[n] = r[n].shr1 | (old ? 0x80000000 : 0);
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
          t = r[n].mask32 == 0;
        case 0x11:
          t = r[n].rel32 >= 0;
        case 0x15:
          t = r[n].rel32 > 0;
        case 0x0b:
          if (_inDelay) return false;
          pr = address + 4;
          return _branch(r[n]);
        case 0x2b:
          return _branch(r[n]);
        case 0x1b:
          final value = _bus.read8(r[n]);
          t = value == 0;
          _bus.write8(r[n], value | 0x80);
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
          final value = switch (op.mask8) {
            2 => mach,
            0x12 => macl,
            0x22 => pr,
            3 => sr,
            0x13 => gbr,
            _ => vbr
          };
          r[n] -= 4;
          _bus.write32(r[n], value);
        case 0x06 || 0x16 || 0x26 || 0x07 || 0x17 || 0x27:
          final value = _bus.read32(r[n]);
          r[n] += 4;
          switch (op.mask8) {
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
    final n = op.shr8.mask4, m = op.shr4.mask4;
    if (op == 9) return 'nop';
    if (op == 0xb) return 'rts';
    if (op == 0x2b) return 'rte';
    if (op == 0x1b) return 'sleep';
    if (op.shr12 == 0xe) return 'mov #${op.rel8},r$n';
    if (op.shr12 == 7) return 'add #${op.rel8},r$n';
    if ((op & 0xf00f) == 0x6003) return 'mov r$m,r$n';
    if (op.shr12 == 0xa || op.shr12 == 0xb) {
      final target = (address + 4 + op.rel12 * 2).mask32;
      return '${op.shr12 == 0xa ? 'bra' : 'bsr'} 0x${target.toRadixString(16)}';
    }
    return '.word 0x${op.toRadixString(16).padLeft(4, '0')}';
  }

  String dump() => '${registerRows([
            ('pc', pc),
            ('sr', sr),
            ('gbr', gbr),
            ('vbr', vbr),
            ('pr', pr),
            ('mach', mach),
            ('macl', macl),
          ])}\n'
      '${registerRows([for (var i = 0; i < 16; i++) ('r$i', r[i])])}';
}

class _OnChipBus implements Sh2Bus {
  final Sh2Bus ext;
  JitExecutionStats? executionStats;
  final Sh2OnChip onchip;
  _OnChipBus(this.ext, this.onchip);

  // effective addresses (register + register) may exceed 32 bits
  static bool _on(int a) => a.mask32 >= 0xfffffe00;
  @override
  int read8(int a) {
    executionStats?.recordMemory(a.mask32, 1);
    return _on(a) ? onchip.read8(a) : ext.read8(a.mask32);
  }

  @override
  int read16(int a) {
    executionStats?.recordMemory(a.mask32, 2);
    return _on(a) ? onchip.read16(a) : ext.read16(a.mask32);
  }

  @override
  int read32(int a) {
    executionStats?.recordMemory(a.mask32, 4);
    return _on(a) ? onchip.read32(a) : ext.read32(a.mask32);
  }

  @override
  void write8(int a, int v) {
    executionStats?.recordMemory(a.mask32, 1, write: true);
    _on(a) ? onchip.write8(a, v) : ext.write8(a.mask32, v);
  }

  @override
  void write16(int a, int v) {
    executionStats?.recordMemory(a.mask32, 2, write: true);
    _on(a) ? onchip.write16(a, v) : ext.write16(a.mask32, v);
  }

  @override
  void write32(int a, int v) {
    executionStats?.recordMemory(a.mask32, 4, write: true);
    _on(a) ? onchip.write32(a, v) : ext.write32(a.mask32, v);
  }
}
