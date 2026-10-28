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
  late final diagnostics =
      JitDiagnostics(rt, instructionBytes: 4, byteOrder: Endian.little)
        ..memoryRegion = _memoryRegion;

  /// Whether this runtime executes compiled host code rather than reference IR.
  final bool native;

  /// Runs the CPU interpreter instead while keeping compiled blocks and the
  /// shared guest state, for tools that warm up with compiled code.
  bool suspended = false;

  /// Guest clocks executed by compiled code, excluding interpreter fallbacks.
  int get compiledClocks => native ? _driver.executedClocks : 0;
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

  late final Uint8List ram = rt.alloc(2 * 1024 * 1024);
  late final Uint8List rom = rt.alloc(512 * 1024);

  /// The scratchpad occupies exactly one 1KiB guest mapping page.
  late final Uint8List scratchPad = rt.alloc(1024);
  bool _scratchPadMapped = false;
  late final Uint32List regs = Uint32List.sublistView(rt.ctx, ctxRegs, ctxHi);

  /// RAM pages with translated code, whose writes leave the blocks; a page
  /// which blocks keep writing is released, see [JitCodeMemory.release]
  late final _code = JitCodeMemory(rt);
  (int, int) _translating = (0, 0);

  /// blocks are translated once they would have run this often; until
  /// then the interpreter runs them, as most code runs only a few times
  final int compileThreshold;
  late final _driver = JitDriver(rt, translate: (pc, tag) {
    _translating = (pc, tag);
    return _translator.translate(pc, tag);
  },
      codeWord: _codeWord,
      codeMemory: _code,
      threshold: compileThreshold,
      recompileInvalid: true);

  PsJit._(this.rt, this.native, int? compileThreshold)
      : compileThreshold = compileThreshold ?? rt.compileThreshold;

  /// the recompiler of this host, or null if it has none; [native] false
  /// interprets the blocks instead, for tests. [compileThreshold] replaces
  /// the estimate of the runtime
  static PsJit? create({bool native = true, int? compileThreshold}) {
    late final PsJit jit;
    int read(int addr, int size) => jit._read(addr, size);
    void write(int addr, int size, int value) => jit._write(addr, size, value);
    // Only bit 31 aliases KSEG0 to KUSEG; other scratchpad aliases stay unmapped.
    const mask = 0x7fffffff;
    final rt = native
        ? JitRuntime.native(
            ctxWords: _ctxWords,
            addrMask: mask,
            read: read,
            write: write,
            pageShift: 10)
        : JitRuntime.interpreter(
            ctxWords: _ctxWords,
            addrMask: mask,
            read: read,
            write: write,
            pageShift: 10);
    if (rt == null) return null;
    return jit = PsJit._(rt, native, compileThreshold);
  }

  /// connects the cpu and the bus created on [regs], [ram], [rom] and
  /// [scratchPad]
  void attach(R3000 cpu, Bus bus) {
    this.cpu = cpu;
    this.bus = bus;
    diagnostics.bindExecutionStats((stats) => cpu.executionStats = stats);

    // Bit 29 distinguishes uncached aliases in the runtime's address mask.
    for (final alias in [0, 0x20000000]) {
      // The default RAM bank mirrors 2MiB over 8MiB, as in Bus.
      for (int a = 0; a < 0x800000; a += ram.length) {
        _code.map(alias + a, ram.length, ram);
      }
      for (int a = 0x1fc00000; a < 0x1fe00000; a += rom.length) {
        _code.map(alias + a, rom.length, rom, writable: false);
      }
    }
    _syncScratchPad();

    final cop2 = cpu.cop2;
    _translator = R3000Translator(
      fetch: _fetch,
      mfc0: rt.addHelper((reg, _, __) => cpu.readCop0(reg)),
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

  static String _memoryRegion(int address) {
    final p = address & 0x1fffffff;
    if (p < 0x800000) return 'ram';
    if (p >= 0x1f800000 && p < 0x1f800400) return 'scratchpad';
    if (p >= 0x1fc00000 && p < 0x1fe00000) return 'rom';
    if (p >= 0x1f801000 && p < 0x1f803000) return 'device';
    return 'unmapped';
  }

  /// the code word at [pc] without protecting it, or null outside the ram
  /// and the rom
  int? _codeWord(int pc) {
    final offset = pc & 0x1fffffff;
    return offset < 0x800000 || (offset >= 0x1fc00000 && offset < 0x1fc80000)
        ? bus.read32(pc)
        : null;
  }

  /// the code word at [pc], or null outside the ram and the rom; a ram word
  /// is guarded against modification
  (int, bool)? _fetch(int pc) {
    final offset = pc & 0x1fffffff;
    if (offset < 0x800000) {
      // Writes to translated RAM must leave the current block before they
      // can change an upcoming instruction, including RAM aliases.
      _code.protect(pc, block: _translating);
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

  /// an I/O access may raise an interrupt or change cache isolation
  void _afterIo() {
    rt.ctx[JitCtx.stop] = _stop;
  }

  /// whether the interpreter must run: an interrupt is taken, or the cache
  /// is isolated
  int get _stop {
    final cpu = this.cpu;
    final sr = cpu.sr;
    return ((cpu.cause & sr & 0xff00) != 0 && sr.bit0) || sr.bit16 ? 1 : 0;
  }

  /// Only KUSEG and KSEG0 can access scratchpad, and only when enabled.
  void _syncScratchPad() {
    final enabled = bus.useScratchPad;
    if (enabled == _scratchPadMapped) return;
    if (enabled) {
      rt.mapPages(0x1f800000, scratchPad.length, scratchPad);
    } else {
      rt.unmapPages(0x1f800000, scratchPad.length);
    }
    _scratchPadMapped = enabled;
  }

  /// Stores in released RAM pages end their block so the next block's guards observe code changes.
  bool _endsAfterStore(int pc) =>
      (pc & 0x1fffffff) < 0x800000 && _code.isReleased(pc);

  /// drops every block, after the rom or the whole memory changes
  void reset() {
    _driver.reset();
  }

  /// frees the runtime with the memory; nothing runs afterwards
  void dispose() => rt.dispose();

  bool _yieldRequested = false;

  /// Returns to the device scheduler after an interpreted register write.
  void yieldForDevice() => _yieldRequested = true;

  /// runs until [R3000.clocks] passes [limit], like repeating
  /// [R3000.step]; the last block may pass it by a block
  void run(int limit) {
    final cpu = this.cpu, rt = this.rt, ctx = rt.ctx;
    _yieldRequested = false;
    while (cpu.clocks <= limit && !_yieldRequested) {
      _syncScratchPad();
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
      final reason = _driver.runBudgeted(pc, tag, budget);
      final spent = _driver.lastClocks;
      cpu.clocks += spent;
      // Executed blocks finish outside a branch delay slot, as after the interpreter steps the slot.
      // An exit before the first instruction must retain any branch state from the interpreter.
      if (spent > 0) {
        cpu.inBranchDelay = false;
        cpu.inBranchTaken = false;
      }
      cpu.pc = rt.exitPc;
      cpu.nextPc = cpu.pc.inc4.mask32;
      cpu.nextDelayReg = rt.exitTag;
      cpu.nextDelayVal = ctx[ctxPendingValue];
      cpu.hi = ctx[ctxHi];
      cpu.lo = ctx[ctxLo];

      if (reason == reasonStore) {
        _code.noteStoreExit(ctx[JitCtx.faultAddr]);
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

  /// steps the interpreter over a block not translated yet, up to the end
  /// of a taken branch
  void _interpretBlock() {
    final cpu = this.cpu;
    for (int n = 0; n < R3000Translator.maxInstructions; n++) {
      final slot = cpu.nextPc != cpu.pc.inc4.mask32;
      cpu.step();
      if (_yieldRequested || (slot && cpu.nextPc == cpu.pc.inc4.mask32)) break;
    }
    while (cpu.nextPc != cpu.pc.inc4.mask32) {
      cpu.step();
    }
  }

  /// steps the interpreter to the next instruction outside a delay slot
  void _interpret() {
    final cpu = this.cpu;
    do {
      cpu.step();
    } while (cpu.nextPc != cpu.pc.inc4.mask32);
  }
}
