import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../../../util/int.dart';
import '../bus.dart';
import '../r3000/r3000.dart';
import 'r3000_translator.dart';

/// Runs the R3000 with [JitRuntime] blocks and falls back to the
/// interpreter for what the blocks leave out.
///
/// The registers and the memory accessed by the blocks live in the buffers
/// of the runtime, so the interpreter and the blocks share them. The
/// interpreter runs the instructions which need its full state: exceptions,
/// interrupts, COP0, cache isolation and the BIOS hooks. It is entered and
/// left only at instruction boundaries outside a branch delay slot; a load
/// still in its delay is carried as the block tag, see [R3000Translator].
final class PsJit {
  final JitRuntime rt;
  late final R3000 cpu;
  late final Bus bus;
  late final R3000Translator _translator;

  static const ctxRegs = JitCtx.user;
  static const ctxHi = ctxRegs + 32, ctxLo = ctxHi + 1;
  static const ctxPendingValue = ctxLo + 1;
  static const _ctxWords = ctxPendingValue + 1;

  /// the exit of an instruction run by the interpreter
  static const reasonInterpret = JitReason.user;

  /// the exit of a store to an unmapped page: a device or a page with
  /// translated code, which the interpreter runs
  static const reasonStore = JitReason.user + 1;

  /// stores to a code page after which it is no longer protected
  static const _maxCodeStores = 16;

  late final Uint8List ram = rt.alloc(2 * 1024 * 1024);
  late final Uint8List rom = rt.alloc(512 * 1024);

  /// a page, of which the scratchpad uses the first 1KiB
  late final Uint8List scratchPad = rt.alloc(JitRuntime.pageSize);
  late final Uint32List regs = Uint32List.sublistView(rt.ctx, ctxRegs, ctxHi);

  bool _scratchPadMapped = false;

  /// RAM pages with translated code, whose writes leave the blocks
  final _codePages = <int>{};

  /// the blocks translated from each RAM page
  final _pageBlocks = <int, Set<(int, int)>>{};
  final _codeStores = <int, int>{};

  /// pages where code and written data meet, see [_release]
  final _volatilePages = <int>{};
  (int, int) _translating = (0, 0);

  /// blocks are translated once they would have run this often; until
  /// then the interpreter runs them, as most code runs only a few times
  final int compileThreshold;
  final _misses = <(int, int), int>{};

  PsJit._(this.rt, int? compileThreshold)
      : compileThreshold = compileThreshold ?? rt.compileThreshold;

  /// the recompiler of this host, or null if it has none; [native] false
  /// interprets the blocks instead, for tests. [compileThreshold] replaces
  /// the estimate of the runtime
  static PsJit? create({bool native = true, int? compileThreshold}) {
    late final PsJit jit;
    int read(int addr, int size) => jit._read(addr, size);
    void write(int addr, int size, int value) => jit._write(addr, size, value);
    const mask = 0x1fffffff;
    final rt = native
        ? JitRuntime.native(
            ctxWords: _ctxWords, addrMask: mask, read: read, write: write)
        : JitRuntime.interpreter(
            ctxWords: _ctxWords, addrMask: mask, read: read, write: write);
    if (rt == null) return null;
    return jit = PsJit._(rt, compileThreshold);
  }

  /// connects the cpu and the bus created on [regs], [ram], [rom] and
  /// [scratchPad]
  void attach(R3000 cpu, Bus bus) {
    this.cpu = cpu;
    this.bus = bus;

    // reads mirror the ram over 128MiB and the rom over 2MiB, writes the
    // ram over 8MiB, like the fast paths of Bus
    for (int a = 0; a < 0x8000000; a += ram.length) {
      rt.mapPages(a, ram.length, ram, write: a < 0x800000);
    }
    for (int a = 0x1fc00000; a < 0x1fe00000; a += rom.length) {
      rt.mapPages(a, rom.length, rom, write: false);
    }

    final cop2 = cpu.cop2;
    _translator = R3000Translator(
      fetch: _fetch,
      endsAfterStore: _endsAfterStore,
      cop2Cmd: rt.addHelper((inst, _, __) {
        cop2.execCmd(inst);
        return 0;
      }),
      mfc2: rt.addHelper((reg, _, __) => cop2.readReg(reg)),
      cfc2: rt.addHelper((reg, _, __) => cop2.readCtrl(reg)),
      mtc2: rt.addHelper((reg, value, _) {
        cop2.writeReg(reg, value);
        return 0;
      }),
      ctc2: rt.addHelper((reg, value, _) {
        cop2.writeCtrl(reg, value);
        return 0;
      }),
      div: rt.addHelper((a, b, signed) {
        signed != 0 ? cpu.div(a, b) : cpu.divu(a, b);
        rt.ctx[ctxHi] = cpu.hi;
        rt.ctx[ctxLo] = cpu.lo;
        return 0;
      }),
    );
  }

  /// the code word at [pc], or null outside the ram and the rom; a ram word
  /// is guarded against modification
  (int, bool)? _fetch(int pc) {
    final offset = pc & 0x1fffffff;
    if (offset < 0x800000) {
      final page = offset & (ram.length - JitRuntime.pageSize);
      (_pageBlocks[page] ??= {}).add(_translating);
      if (!_volatilePages.contains(page) && _codePages.add(page)) {
        // Writes to translated RAM must leave the current block before
        // they can change an upcoming instruction, including RAM aliases.
        for (int a = page; a < 0x800000; a += ram.length) {
          rt.unmapPages(a, JitRuntime.pageSize, read: false);
        }
      }
      return (bus.read32(pc), true);
    }
    if (offset >= 0x1fc00000 && offset < 0x1fc80000) {
      return (bus.read32(pc), false);
    }
    return null;
  }

  int _read(int addr, int size) {
    final v = switch (size) {
      1 => cpu.read8(addr),
      2 => cpu.read16(addr),
      _ => cpu.read32(addr),
    };
    _afterIo();
    return v;
  }

  void _write(int addr, int size, int value) {
    switch (size) {
      case 1:
        cpu.write8(addr, value);
      case 2:
        cpu.write16(addr, value);
      default:
        cpu.write32(addr, value);
    }
    _afterIo();
  }

  /// an I/O access may raise an interrupt or toggle the scratchpad
  void _afterIo() {
    rt.ctx[JitCtx.stop] = _stop;
    _syncScratchPad();
  }

  void _syncScratchPad() {
    if (bus.useScratchPad == _scratchPadMapped) return;
    _scratchPadMapped = bus.useScratchPad;
    // the 3KiB after the scratchpad, unused by the hardware, are mapped too
    if (_scratchPadMapped) {
      rt.mapPages(0x1f800000, JitRuntime.pageSize, scratchPad);
    } else {
      rt.unmapPages(0x1f800000, JitRuntime.pageSize);
    }
  }

  /// whether the interpreter must run: an interrupt is taken, or the cache
  /// is isolated
  int get _stop {
    final cpu = this.cpu;
    final sr = cpu.sr;
    return ((cpu.cause & sr & 0xff00) != 0 && sr.bit0) || sr.bit16 ? 1 : 0;
  }

  /// makes [page] writable again for every RAM alias
  void _mapWrites(int page) {
    for (int a = page; a < 0x800000; a += ram.length) {
      rt.mapPages(a, JitRuntime.pageSize, ram, offset: page, read: false);
    }
  }

  /// Stops protecting a code page which blocks keep writing, such as data
  /// next to code or code replaced by data. Its blocks are translated
  /// again to end after each store, so that the guards of the next block
  /// see an instruction changed by the store.
  void _release(int page) {
    for (final (pc, tag) in _pageBlocks.remove(page) ?? const <(int, int)>{}) {
      rt.invalidate(pc, tag);
    }
    _codePages.remove(page);
    _volatilePages.add(page);
    _mapWrites(page);
  }

  /// whether a store at [pc] ends its block, see [_release]
  bool _endsAfterStore(int pc) =>
      _volatilePages
          .contains(pc & 0x1fffffff & (ram.length - JitRuntime.pageSize)) &&
      (pc & 0x1fffffff) < 0x800000;

  /// drops every block, after the rom or the whole memory changes
  void reset() {
    rt.clear();
    _codePages.forEach(_mapWrites);
    _codePages.clear();
    _pageBlocks.clear();
    _codeStores.clear();
    _volatilePages.clear();
    _misses.clear();
  }

  /// frees the runtime with the memory; nothing runs afterwards
  void dispose() => rt.dispose();

  /// runs until [R3000.clocks] passes [limit], like repeating
  /// [R3000.step]; the last block may pass it by a block
  void run(int limit) {
    final cpu = this.cpu, rt = this.rt, ctx = rt.ctx;
    _syncScratchPad();
    while (cpu.clocks <= limit) {
      // A debugger step may have left a taken branch's slot unexecuted.
      // Blocks only accept a sequential nextPc at their entry.
      if (_stop != 0 || cpu.nextPc != cpu.pc.inc4.mask32) {
        _interpret();
        continue;
      }

      int pc = cpu.pc, tag = cpu.nextDelayReg;
      ctx[ctxPendingValue] = cpu.nextDelayVal;
      ctx[ctxHi] = cpu.hi;
      ctx[ctxLo] = cpu.lo;
      final budget = limit - cpu.clocks + 1;
      ctx[JitCtx.budget] = budget;
      ctx[JitCtx.stop] = 0;

      int reason;
      for (;;) {
        reason = rt.run(pc, tag);
        if (reason == JitReason.invalid) {
          rt.invalidate(rt.exitPc, rt.exitTag);
        } else if (reason != JitReason.miss || !_hot(rt.exitPc, rt.exitTag)) {
          break;
        }
        pc = rt.exitPc;
        tag = rt.exitTag;
        _translating = (pc, tag);
        rt.install(_translator.translate(pc, tag));
      }

      cpu.clocks += budget - ctx[JitCtx.budget].toSigned(32);
      cpu.pc = rt.exitPc;
      cpu.nextPc = cpu.pc.inc4.mask32;
      cpu.nextDelayReg = rt.exitTag;
      cpu.nextDelayVal = ctx[ctxPendingValue];
      cpu.hi = ctx[ctxHi];
      cpu.lo = ctx[ctxLo];

      if (reason == reasonStore) {
        final offset = ctx[JitCtx.faultAddr] & 0x1fffffff;
        final page = offset & (ram.length - JitRuntime.pageSize);
        if (offset < 0x800000 &&
            _codePages.contains(page) &&
            (_codeStores[page] = (_codeStores[page] ?? 0) + 1) >=
                _maxCodeStores) {
          _release(page);
        }
      }
      if (reason == JitReason.miss) {
        _interpretBlock();
      } else if (reason == reasonInterpret ||
          reason == reasonStore ||
          ctx[JitCtx.stop] != 0) {
        _interpret();
      }
    }
  }

  /// whether the missing block (pc, tag) has been seen often enough to be
  /// translated
  bool _hot(int pc, int tag) {
    final key = (pc, tag);
    final seen = (_misses[key] ?? 0) + 1;
    if (seen >= compileThreshold) {
      _misses.remove(key);
      return true;
    }
    if (_misses.length >= 1 << 16) _misses.clear();
    _misses[key] = seen;
    return false;
  }

  /// steps the interpreter over a block not translated yet, up to the end
  /// of a taken branch
  void _interpretBlock() {
    final cpu = this.cpu;
    for (int n = 0; n < R3000Translator.maxInstructions; n++) {
      final slot = cpu.nextPc != cpu.pc.inc4.mask32;
      cpu.step();
      if (slot && cpu.nextPc == cpu.pc.inc4.mask32) break;
    }
    while (cpu.nextPc != cpu.pc.inc4.mask32) {
      cpu.step();
    }
    _syncScratchPad();
  }

  /// steps the interpreter to the next instruction outside a delay slot
  void _interpret() {
    final cpu = this.cpu;
    do {
      cpu.step();
    } while (cpu.nextPc != cpu.pc.inc4.mask32);
    _syncScratchPad();
  }
}
