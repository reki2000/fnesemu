import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../../../../components/sh2/bus.dart';
import '../../../../components/sh2/interpreter.dart';
import '../../../../components/sh2/jit/idle.dart';
import '../../../../components/sh2/jit/jit.dart';
import '../../../../components/sh2/onchip.dart';
import '../../../../util/int.dart';
import '../../../../util/register_dump.dart';
import '../../../../util/state.dart';

/// Integer SH-2 interpreter for the 32X, built on the shared interpreter and on-chip modules in components/sh2.
/// The 32X keeps its interrupt acceptance, compiled-block dispatch and the on-chip synchronization before register accesses here.
/// Unsupported instructions stop execution instead of acting as NOPs.
class Sh2 with Sh2Interpreter {
  /// the bus seen by the instructions: the on-chip registers
  /// (0xfffffe00-0xffffffff) are served inside the cpu
  final _OnChipBus _bus;
  Sh2Bus get bus => _bus;

  @override
  Sh2Bus get execBus => _bus;

  final Sh2OnChip onchip;
  Sh2(Sh2Bus ext, {bool master = true, Sh2Jit? jit})
      : this._(ext, jit, Sh2OnChip(master, stateSection: '32x-onchip'));

  Sh2._(Sh2Bus ext, Sh2Jit? jit, Sh2OnChip onchip)
      : jit = jit,
        onchip = onchip,
        _bus = _OnChipBus(ext, onchip) {
    r = jit?.regs ?? Uint32List(16);
    state = jit?.state ?? Uint32List(8);
    sr = 0xf0;
    jit?.attach(
        (address) => _jitCodeAddress(address) ? ext.read16(address) : null);
    _jitFtcsr = jit?.addReadRegister(
        (address, size) => address == 0xfffffe11 && size == 1);
    _bus.sync = _syncOnchip;
    onchip.bus = ext;
    if (jit != null) {
      jit.diagnostics.memoryRegion = _memoryRegion;
      jit.diagnostics.bindExecutionStats((stats) {
        executionStats = stats;
        _bus.executionStats = stats;
      });
    }
  }
  // Only even SDRAM addresses with their P1 aliases and the cache data array
  // can be compiled here.
  static bool _jitCodeAddress(int address) =>
      (address & 0xdffc0001) == 0x06000000 ||
      (address & 0xfffff001) == 0xc0000000;

  final Sh2Jit? jit;
  late final Uint32List? _jitFtcsr;
  JitExecutionStats? executionStats;
  int _irqLevel = 0, _irqVector = 0;

  /// Saves logical state while the owning core identifies external media.
  void saveState(StateWriter w) {
    w.section('32x-sh2');
    w.ints(r);
    w.ints(state);
    w.int64(pc);
    w.int64(clocks);
    w.int64(_irqLevel);
    w.int64(_irqVector);
    w.boolean(delayTarget >= 0);
    if (delayTarget >= 0) w.int64(delayTarget);
    w.boolean(restoreSr >= 0);
    if (restoreSr >= 0) w.int64(restoreSr);
    w.boolean(sleeping);
    w.boolean(inDelay);
    onchip.saveState(w);
  }

  /// Restores existing buffers and keeps callback and bus wiring.
  void loadState(StateReader s) {
    s.section('32x-sh2');
    jit?.reset();
    s.intsInto(r);
    s.intsInto(state);
    pc = s.int64();
    clocks = _tickedAt = s.int64();
    _irqLevel = s.int64();
    _irqVector = s.int64();
    delayTarget = s.boolean() ? s.int64() : -1;
    restoreSr = s.boolean() ? s.int64() : -1;
    sleeping = s.boolean();
    inDelay = s.boolean();
    onchip.loadState(s);
  }

  void reset() {
    jit?.reset();
    _idle.reset();
    r.fillRange(0, 16, 0);
    pc = _bus.read32(0);
    r[15] = _bus.read32(4);
    sr = 0xf0;
    gbr = vbr = pr = mach = macl = clocks = _tickedAt = lastOpcode = 0;
    _irqLevel = _irqVector = 0;
    delayTarget = restoreSr = -1;
    sleeping = inDelay = false;
    onchip.reset();
  }

  void setInterrupt(int level, int vector) {
    _irqLevel = level;
    _irqVector = vector;
  }

  /// the clock up to which the on-chip modules have advanced
  int _tickedAt = 0;

  /// Advances the on-chip modules to [clocks]. Runs do it at their end and
  /// before an access to a module register, so a register read sees the time
  /// of the instruction; interrupts of the modules reach the CPU at the next
  /// run.
  void _syncOnchip() {
    final elapsed = clocks - _tickedAt;
    _tickedAt = clocks;
    if (elapsed != 0) onchip.tick(elapsed);
  }

  /// Moves the CPU clock without advancing the on-chip modules.
  void setClocks(int value) {
    clocks = _tickedAt = value;
  }

  bool exec({bool compiled = true}) {
    final ok = _execOne(compiled);
    _syncOnchip();
    return ok;
  }

  /// fast-forwards idle loops (see _isIdle)
  bool idleSkip = true;

  /// whether the last [_execOneUnprofiled] ran compiled code
  bool _nativeStep = false;

  /// Runs to the adapter deadline, retaining instruction-based debug stepping.
  /// A loop that repeats without effect waits for the deadline at once, because
  /// the other devices advance only between runs.
  bool run(int targetClocks, {bool compiled = true}) {
    final skip = idleSkip && compiled;
    final status = _jitFtcsr;
    var ok = true;
    while (clocks < targetClocks) {
      final prev = pc;
      if (status != null) status[0] = onchip.ftcsr;
      _nativeStep = false;
      ok = _execOne(compiled, targetClocks - clocks);
      if (!ok) break;
      if (skip && _idleAfterStep(prev) && clocks < targetClocks) {
        executionStats?.recordIdle(targetClocks - clocks);
        clocks = targetClocks;
      }
    }
    _syncOnchip();
    return ok;
  }

  bool _idleAfterStep(int prev) {
    if (sleeping) return true;
    final from = _nativeStep ? jit!.idleCheckPc : prev;
    return jit != null && _nativeStep && jit!.idleDetected ||
        from != null &&
            Sh2IdleDetector.isBackEdge(pc, from, compiled: _nativeStep) &&
            _idle.check(pc, _bus.writes + state[7]);
  }

  late final _idle = Sh2IdleDetector(r, state, keepSnapshot: true);

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
    if (delayTarget < 0) {
      // the external interrupt (the 32x system) and the on-chip ones (DIVU,
      // DMAC, FRT, WDT): the higher level wins
      var onchipLevel = 0;
      if (onchip.anyPending) {
        onchip.updatePendingInterrupt();
        onchipLevel = onchip.pendingLevel;
      }
      final mask = interruptMask;
      if (_irqLevel > mask && _irqLevel >= onchipLevel) {
        raiseException(_irqVector, pc, level: _irqLevel);
        return true;
      }
      if (onchipLevel > mask) {
        raiseException(onchip.pendingVector, pc, level: onchipLevel);
        return true;
      }
    }
    if (compiled &&
        jit != null &&
        !jit!.suspended &&
        delayTarget < 0 &&
        !sleeping &&
        _jitCodeAddress(pc)) {
      executionStats?.pauseCpuStep();
      final result = jit!.run(pc, budget);
      if (result != null) {
        _nativeStep = true;
        pc = result.$1;
        clocks += result.$2;
        return true;
      }
    }
    executionStats?.resumeCpuStep();
    return execInterpreted(_fetchInstruction);
  }

  @override
  void div1(int n, int rm) {
    final a = r[n], b = rm;
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
  }

  @override
  void macL(int n, int m) {
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
  }

  @override
  void macW(int n, int m) {
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

  /// advances the module clocks before a module register is accessed
  void Function()? sync;

  /// writes issued by the interpreter, for idle loop detection
  int writes = 0;

  // effective addresses (register + register) may exceed 32 bits
  static bool _on(int a) => a.mask32 >= 0xfffffe00;
  @override
  int read8(int a) {
    executionStats?.recordMemory(a.mask32, 1);
    if (_on(a)) {
      sync?.call();
      return onchip.read8(a);
    }
    return ext.read8(a.mask32);
  }

  @override
  int read16(int a) {
    executionStats?.recordMemory(a.mask32, 2);
    if (_on(a)) {
      sync?.call();
      return onchip.read16(a);
    }
    return ext.read16(a.mask32);
  }

  @override
  int read32(int a) {
    executionStats?.recordMemory(a.mask32, 4);
    if (_on(a)) {
      sync?.call();
      return onchip.read32(a);
    }
    return ext.read32(a.mask32);
  }

  @override
  void write8(int a, int v) {
    writes++;
    executionStats?.recordMemory(a.mask32, 1, write: true);
    if (_on(a)) {
      sync?.call();
      onchip.write8(a, v);
    } else {
      ext.write8(a.mask32, v);
    }
  }

  @override
  void write16(int a, int v) {
    writes++;
    executionStats?.recordMemory(a.mask32, 2, write: true);
    if (_on(a)) {
      sync?.call();
      onchip.write16(a, v);
    } else {
      ext.write16(a.mask32, v);
    }
  }

  @override
  void write32(int a, int v) {
    writes++;
    executionStats?.recordMemory(a.mask32, 4, write: true);
    if (_on(a)) {
      sync?.call();
      onchip.write32(a, v);
    } else {
      ext.write32(a.mask32, v);
    }
  }
}
