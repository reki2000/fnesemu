import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../../../components/sh2/bus.dart';
import '../../../components/sh2/interpreter.dart';
import '../../../components/sh2/jit/idle.dart';
import '../../../components/sh2/jit/jit.dart';
import '../../../components/sh2/onchip.dart';
import '../../../state.dart';
import '../../../util/disasm.dart';
import '../../../util/int.dart';
import '../../../util/register_dump.dart';
import '../cpu.dart';
import 'disasm.dart';

// SH-2 address space: cache areas and on-chip modules in front of the external bus
class _Sh2Memory implements SsCpuBus {
  final SsCpuBus ext;
  final Sh2OnChip onchip;

  /// number of writes, used for idle loop detection
  int writes = 0;

  _Sh2Memory(this.ext, this.onchip);

  // work RAM high accessed without the external bus (see Sh2.setFastFetch).
  // the bus has no side effect on this area, so the result is the same.
  bool _fastWram = false;
  Uint8List _wram = Uint8List(0);
  ByteData _wramData = ByteData(0);

  // 0x06000000-0x07ffffff in the cache / cache-through area
  @pragma('vm:prefer-inline')
  static bool _isWram(int a) => a & 0xc6000000 == 0x06000000;

  // area by address bits 31-29
  static const _areaCache = 0, _areaThrough = 1, _areaPurge = 2;
  static const _areaAddressArray = 3, _areaDataArray = 6, _areaIo = 7;

  @override
  int read8(int a) {
    a &= 0xffffffff;
    if (_fastWram && _isWram(a)) return _wram[a & 0xfffff];
    switch (a >>> 29) {
      case _areaCache || _areaThrough:
        return ext.read8(a);
      case _areaDataArray:
        return onchip.cacheData[a.mask12];
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
    if (_fastWram && _isWram(a)) return _wramData.getUint16(a & 0xffffe);
    switch (a >>> 29) {
      case _areaCache || _areaThrough:
        return ext.read16(a);
      case _areaDataArray:
        return onchip.cacheData[a & 0xffe].shl8 |
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
    if (_fastWram && _isWram(a)) return _wramData.getUint32(a & 0xffffc);
    switch (a >>> 29) {
      case _areaCache || _areaThrough:
        return ext.read32(a);
      case _areaDataArray:
        return read16(a).shl16 | read16(a + 2);
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
    if (_fastWram && _isWram(a)) {
      _wram[a & 0xfffff] = d.mask8;
      return;
    }
    switch (a >>> 29) {
      case _areaCache || _areaThrough:
        ext.write8(a, d);
      case _areaDataArray:
        onchip.cacheData[a.mask12] = d.mask8;
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
    if (_fastWram && _isWram(a)) {
      _wramData.setUint16(a & 0xffffe, d.mask16);
      return;
    }
    switch (a >>> 29) {
      case _areaCache || _areaThrough:
        ext.write16(a, d);
      case _areaDataArray:
        onchip.cacheData[a & 0xffe] = d.shr8.mask8;
        onchip.cacheData[(a & 0xffe) + 1] = d.mask8;
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
    if (_fastWram && _isWram(a)) {
      _wramData.setUint32(a & 0xffffc, d.mask32);
      return;
    }
    switch (a >>> 29) {
      case _areaCache || _areaThrough:
        ext.write32(a, d);
      case _areaDataArray:
        write16(a, d.shr16);
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

/// Records each CPU data request, then forwards it to the memory.
/// Installed only while execution statistics are bound, so the CPU data path
/// has no per-access check when statistics are off.
class _ObservedBus implements SsCpuBus {
  final SsCpuBus inner;
  final JitExecutionStats stats;

  _ObservedBus(this.inner, this.stats);

  @override
  int read8(int a) {
    stats.recordMemory(a & 0xffffffff, 1);
    return inner.read8(a);
  }

  @override
  int read16(int a) {
    stats.recordMemory(a & 0xffffffff, 2);
    return inner.read16(a);
  }

  @override
  int read32(int a) {
    stats.recordMemory(a & 0xffffffff, 4);
    return inner.read32(a);
  }

  @override
  void write8(int a, int d) {
    stats.recordMemory(a & 0xffffffff, 1, write: true);
    inner.write8(a, d);
  }

  @override
  void write16(int a, int d) {
    stats.recordMemory(a & 0xffffffff, 2, write: true);
    inner.write16(a, d);
  }

  @override
  void write32(int a, int d) {
    stats.recordMemory(a & 0xffffffff, 4, write: true);
    inner.write32(a, d);
  }
}

/// Integer SH-2 (SH7604) interpreter for SS, built on the shared
/// interpreter and on-chip modules in components/sh2 and extended with the
/// SS cache areas, NMI and vectored external interrupts.
/// Unsupported instructions stop execution instead of acting as NOPs.
class Sh2 extends SsCpu with Sh2Interpreter {
  /// CPU data bus: the memory, or the memory behind _ObservedBus while bound
  late SsCpuBus bus;
  JitExecutionStats? executionStats;
  final Sh2OnChip onchip;

  Sh2(SsCpuBus ext, {bool master = true, Sh2Jit? jit, bool jitFtcsr = true})
      : jit = jit,
        onchip = Sh2OnChip(master) {
    r = jit?.regs ?? Uint32List(16);
    state = jit?.state ?? Uint32List(8);
    sr = 0xf0;
    _jitFtcsr = jitFtcsr
        ? jit?.addReadRegister(
            (address, size) => address == 0xfffffe11 && size == 1)
        : null;
    jit?.attach(_jitFetch);
    _mem = _Sh2Memory(ext, onchip);
    bus = _mem;
    onchip.bus = bus;
    if (jit != null) {
      jit.diagnostics.memoryRegion = _memoryRegion;
      // called at once with the current recorder, and again when it changes
      jit.diagnostics.bindExecutionStats((stats) {
        executionStats = stats;
        bus = stats == null ? _mem : _ObservedBus(_mem, stats);
        onchip.bus = bus;
      });
    }
  }

  late final _Sh2Memory _mem;
  late final Uint32List? _jitFtcsr;

  final Sh2Jit? jit;
  int _irl = 0;
  bool _nmi = false;
  bool get _q => sr.bit8;
  bool get _m => sr.bit9;
  set _q(bool value) => sr = (sr & ~0x100) | (value ? 0x100 : 0);
  bool get _s => sr.bit1;

  @override
  Sh2Bus get execBus => bus;

  @override
  int get sp => r[15];

  // direct instruction fetch from work RAM high / boot ROM
  bool _hasFetchWram = false, _hasFetchRom = false;
  ByteData _fetchWram = ByteData(0);
  ByteData _fetchRom = ByteData(0);
  Uint8List _fetchWramBytes = Uint8List(0);
  Uint8List _fetchRomBytes = Uint8List(0);

  /// sets memories which instructions can be fetched from without the bus.
  /// work RAM high is also read and written directly by data accesses.
  void setFastFetch({ByteData? wramHigh, ByteData? rom}) {
    _hasFetchWram = wramHigh != null;
    _fetchWram = wramHigh ?? ByteData(0);
    _hasFetchRom = rom != null;
    _fetchRom = rom ?? ByteData(0);
    _fetchWramBytes = _fetchWram.buffer
        .asUint8List(_fetchWram.offsetInBytes, _fetchWram.lengthInBytes);
    _fetchRomBytes = _fetchRom.buffer
        .asUint8List(_fetchRom.offsetInBytes, _fetchRom.lengthInBytes);
    _mem._fastWram = _hasFetchWram;
    _mem._wramData = _fetchWram;
    _mem._wram = _fetchWram.buffer
        .asUint8List(_fetchWram.offsetInBytes, _fetchWram.lengthInBytes);
  }

  int? _jitFetch(int address) {
    if (address & 0xc0000001 != 0) return null;
    final physical = address & 0x07ffffff;
    if (physical < 0x100000 ||
        physical >= 0x6000000 ||
        (physical >= 0x200000 && physical < 0x300000))
      return _mem.read16(address);
    return null;
  }

  @pragma('vm:prefer-inline')
  int _fetch(int a) {
    // 0x06000000-0x07ffffff in cache / cache-through area
    // big-endian halfword from the bytes (cheaper than ByteData.getUint16)
    if (_hasFetchWram && a & 0xde000000 == 0x06000000) {
      final m = _fetchWramBytes, i = a & 0xffffe;
      return m[i].shl8 | m[i + 1];
    }
    if (_hasFetchRom && a & 0xdff00000 == 0) {
      final m = _fetchRomBytes, i = a & 0x7fffe;
      return m[i].shl8 | m[i + 1];
    }
    // instruction fetches bypass the bus wrapper; see _execObserved
    return _mem.read16(a);
  }

  @override
  void reset() {
    jit?.reset();
    state[7] = 0;
    _idle.reset();
    onchip.reset();
    r.fillRange(0, 16, 0);
    pc = bus.read32(0);
    r[15] = bus.read32(4);
    sr = 0xf0;
    gbr = vbr = pr = mach = macl = clocks = lastOpcode = 0;
    _irl = 0;
    _nmi = false;
    delayTarget = restoreSr = -1;
    sleeping = inDelay = false;
  }

  /// Saves registers, delay and idle-detector state and the on-chip
  /// modules. Register views shared with the JIT context are written in
  /// place on load, after resetting compiled code.
  void saveState(StateWriter w) {
    w.section(onchip.master ? 'sh2-master' : 'sh2-slave');
    w.ints(r);
    // Native and interpreted writes are counted apart and only their sum
    // matters; the split depends on which code happened to be compiled.
    w.ints([...state.sublist(0, 7), 0]);
    final writes = _mem.writes + state[7];
    w.ints([pc, clocks, _irl, delayTarget, restoreSr, writes]);
    final snap = _idle.snapshot;
    w.ints([_idle.pc, _idle.writes, snap[16], snap[17], snap[20]]);
    w.ints([snap[21], snap[19]]);
    w.ints(snap.sublist(0, 16));
    for (final b in [_nmi, sleeping, inDelay]) {
      w.boolean(b);
    }
    onchip.saveState(w);
  }

  void loadState(StateReader s) {
    s.section(onchip.master ? 'sh2-master' : 'sh2-slave');
    jit?.reset();
    s.intsInto(r);
    s.intsInto(state);
    final v = s.ints(), idle = s.ints(), idle2 = s.ints();
    if (v.length != 6 || idle.length != 5 || idle2.length != 2) {
      throw const StateMismatch('sh2 state layout');
    }
    pc = v[0];
    clocks = v[1];
    _irl = v[2];
    delayTarget = v[3];
    restoreSr = v[4];
    _mem.writes = v[5];
    final snap = _idle.snapshot;
    _idle.pc = idle[0];
    _idle.writes = idle[1];
    snap[16] = idle[2];
    snap[17] = idle[3];
    snap[20] = idle[4];
    snap[21] = idle2[0];
    snap[19] = idle2[1];
    final regs = Uint32List(16);
    s.intsInto(regs);
    snap.setRange(0, 16, regs);
    _nmi = s.boolean();
    sleeping = s.boolean();
    inDelay = s.boolean();
    onchip.loadState(s);
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
    final jit = this.jit, status = _jitFtcsr;
    bool ok = true;
    while (clocks < targetClocks) {
      final prev = pc;
      (int, int)? compiled;
      if (jit != null &&
          !jit.suspended &&
          delayTarget < 0 &&
          !sleeping &&
          !_interruptRequested) {
        // On-chip time advances at the run boundary.
        // Refresh after CPU instructions too, including FTCSR writes and input capture.
        if (status != null) status[0] = onchip.ftcsr;
        compiled = jit.run(pc, targetClocks - clocks);
      }
      if (compiled != null) {
        pc = compiled.$1;
        clocks += compiled.$2;
        if (idleSkip && jit!.idleDetected) {
          _idle.reset();
          // A compiled block may already have overshot the target.
          if (clocks < targetClocks) {
            executionStats?.recordIdle(targetClocks - clocks);
            clocks = targetClocks;
          }
          break;
        }
      } else if (!exec()) {
        ok = false;
        break;
      }
      final idleFrom = compiled == null ? prev : jit!.idleCheckPc;
      if (idleSkip &&
          (sleeping ||
              (idleFrom != null &&
                  Sh2IdleDetector.isBackEdge(pc, idleFrom,
                      compiled: compiled != null) &&
                  _idle.check(pc, _mem.writes + state[7])))) {
        if (clocks < targetClocks) {
          executionStats?.recordIdle(targetClocks - clocks);
          clocks = targetClocks;
        }
        break;
      }
    }
    onchip.tick(clocks - before);
    return ok;
  }

  late final _idle = Sh2IdleDetector(r, state);

  // cheap check whether any interrupt may be accepted now
  @pragma('vm:prefer-inline')
  bool get _interruptRequested =>
      _nmi || _irl > sr.shr4.mask4 || onchip.anyPending;

  // accepts the highest priority interrupt, returns true when accepted
  bool _acceptInterrupt() {
    if (_nmi) {
      _nmi = false;
      raiseException(11, pc, level: 15);
      return true;
    }

    final (onchipLevel, onchipVector) = onchip.pendingInterrupt();
    final mask = interruptMask;

    if (_irl > mask && _irl >= onchipLevel) {
      final level = _irl;
      final vector = onIrlAck();
      raiseException(onchip.externalVector ? vector : 64 + level.shr1, pc,
          level: level);
      return true;
    }

    if (onchipLevel > mask) {
      raiseException(onchipVector, pc, level: onchipLevel);
      return true;
    }

    return false;
  }

  @pragma('vm:prefer-inline')
  bool exec() {
    final stats = executionStats;
    return stats == null ? _exec() : _execObserved(stats);
  }

  // the instruction fetch is counted for each step that is not sleeping,
  // so an accepted interrupt or an address error also counts one fetch
  bool _execObserved(JitExecutionStats stats) {
    final at = pc, before = clocks, wasSleeping = sleeping;
    final opcode = stats.opcodeAt(at);
    stats.beginCpuStep();
    if (!sleeping) stats.recordMemory(at, 2, fetch: true);
    try {
      return _exec();
    } finally {
      stats.endCpuStep();
      if (wasSleeping && sleeping) {
        stats.recordIdle(clocks - before);
      } else {
        stats.recordCpuStep(at, opcode, clocks - before);
      }
    }
  }

  static String _memoryRegion(int address) {
    final a = address & 0xffffffff, area = (address & 0xffffffff) >>> 29;
    if (area == 6) return 'cacheData';
    if (area == 7) return 'onchip';
    if (area > 1) return 'cacheControl';
    final p = a & 0x07ffffff;
    if (p >= 0x06000000) return 'workRamHigh';
    if (p >= 0x00200000 && p < 0x00300000) return 'workRamLow';
    if (p < 0x00100000) return 'bios';
    return 'device';
  }

  @pragma('vm:prefer-inline')
  bool _exec() {
    if (delayTarget < 0 && _interruptRequested && _acceptInterrupt()) {
      return true;
    }
    return execInterpreted(_fetch);
  }

  @override
  void div1(int n, int rm) {
    final oldQ = _q;
    final msb = r[n].bit31;
    int rn = (r[n].shl1 | (t ? 1 : 0)).mask32;
    final tmp0 = rn;
    bool carry;
    if (oldQ == _m) {
      rn = (rn - rm).mask32;
      carry = rn > tmp0; // borrow
    } else {
      rn = (rn + rm).mask32;
      carry = rn < tmp0;
    }
    r[n] = rn;
    _q = (msb != carry) != _m;
    t = _q == _m;
  }

  @override
  void macL(int n, int m) {
    final rn = bus.read32(r[n]).rel32;
    r[n] = (r[n] + 4).mask32;
    final rm = bus.read32(r[m]).rel32;
    r[m] = (r[m] + 4).mask32;

    final product = rn * rm;
    int result;
    if (_s) {
      // 48-bit saturation
      final acc = ((mach.mask16 << 32) | macl).shl16.shr16;
      result = acc + product;
      const max = 0x7fffffffffff, min = -0x800000000000;
      if (result > max) result = max;
      if (result < min) result = min;
    } else {
      result = ((mach << 32) | macl) + product;
    }
    mach = (result >> 32).mask32;
    macl = result.mask32;
  }

  @override
  void macW(int n, int m) {
    final rn = bus.read16(r[n]).rel16;
    r[n] = (r[n] + 2).mask32;
    final rm = bus.read16(r[m]).rel16;
    r[m] = (r[m] + 2).mask32;

    final product = rn * rm;
    if (_s) {
      // 32-bit saturation, MACH bit 0 flags an overflow
      int result = macl.rel32 + product;
      if (result > 0x7fffffff) {
        result = 0x7fffffff;
        mach |= 1;
      } else if (result < -0x80000000) {
        result = -0x80000000;
        mach |= 1;
      }
      macl = result.mask32;
    } else {
      final result = ((mach << 32) | macl) + product;
      mach = (result >> 32).mask32;
      macl = result.mask32;
    }
  }

  @override
  (String, int) disasm(int addr) {
    final op = bus.read16(addr);
    return (
      formatDisasm(addr.x8, op.x4, Sh2Disasm.disasm(op, addr), codeWidth: 4),
      2
    );
  }

  @override
  String dump() {
    String h(int v) => v.mask32.toRadixString(16).padLeft(8, '0');
    return 'pc:${h(pc)} sr:${(sr & 0x3f3).toRadixString(16).padLeft(3, '0')} gbr:${h(gbr)} vbr:${h(vbr)} pr:${h(pr)} mach:${h(mach)} macl:${h(macl)}\n'
        '${registerRows([
          for (var i = 0; i < 16; i++) ('r$i', r[i])
        ])}\n${onchip.dump()}';
  }
}
