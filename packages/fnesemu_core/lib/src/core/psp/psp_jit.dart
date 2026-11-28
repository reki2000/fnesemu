import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../../util/jit_adapter.dart';
import 'allegrex.dart';
import 'allegrex_translator.dart';
import 'memory.dart';

/// Runs Allegrex blocks using the interpreter's registers and memory.
final class PspJit extends JitAdapter {
  final PspMemory memory;
  late final regs = Int32List.sublistView(
      rt.ctx, AllegrexTranslator.ctxRegs, AllegrexTranslator.ctxHi);
  late final fpr = Uint32List.sublistView(
      rt.ctx, AllegrexTranslator.ctxFpr, AllegrexTranslator.ctxVfpr);
  late final vfpr = Uint32List.sublistView(
      rt.ctx, AllegrexTranslator.ctxVfpr, AllegrexTranslator.ctxWords);
  late final diagnostics =
      JitDiagnostics(rt, instructionBytes: 4, byteOrder: Endian.little);

  late final _code = JitCodeMemory(rt);
  late final _translator =
      AllegrexTranslator(_codeWord, rt.pageBytes, _code.isReleased);
  late final _driver = JitDriver(rt,
      translate: _translate,
      codeWord: _codeWord,
      codeMemory: _code,
      threshold: compileThreshold,
      recompileInvalid: true);

  PspJit._(super.rt, super.native, this.memory, int? threshold)
      : super(compileThreshold: threshold) {
    _code.map(PspMemory.ramAt, memory.ram.length, memory.ram);
    _code.map(PspMemory.scratchAt, memory.scratch.length, memory.scratch);
    for (var off = 0; off < PspMemory.vramMirrors; off += memory.vram.length) {
      _code.map(PspMemory.vramAt + off, memory.vram.length, memory.vram);
    }
  }

  @override
  JitDriver get driver => _driver;

  static PspJit? create({bool native = true, int? compileThreshold}) {
    if (Endian.host != Endian.little) return null;
    if (native) JitRuntime.resetPool();
    int read(int addr, int size) => throw StateError('Unmapped compiled read');
    void write(int addr, int size, int value) =>
        throw StateError('Unmapped compiled write');
    const words = AllegrexTranslator.ctxWords;
    const mask = 0x1fffffff;
    final rt = native
        ? JitRuntime.native(
            ctxWords: words, addrMask: mask, read: read, write: write)
        : JitRuntime.interpreter(
            ctxWords: words, addrMask: mask, read: read, write: write);
    if (rt == null) return null;

    try {
      final memory = PspMemory(
          ram: rt.alloc(PspMemory.ramSize),
          scratch: rt.alloc(PspMemory.scratchSize),
          vram: rt.alloc(PspMemory.vramSize));
      return PspJit._(rt, native, memory, compileThreshold);
    } on StateError {
      rt.dispose();
      return null;
    }
  }

  /// Maps video memory page [page] in all mirrors as its [state] of
  /// [PspVramGuard] allows: a synced page for reads, a page the CPU wrote
  /// for both, and a page the GPU wrote for neither. The accesses that miss
  /// leave compiled code, and the interpreter makes them through the guard.
  void setVramPage(int page, int state) {
    final offset = page << rt.pageShift;
    final bytes = rt.pageBytes;
    for (var m = 0; m < PspMemory.vramMirrors; m += PspMemory.vramSize) {
      final at = PspMemory.vramAt + m + offset;
      switch (state) {
        case PspVramGuard.synced:
          rt.mapPages(at, bytes, memory.vram, offset: offset, write: false);
          rt.unmapPages(at, bytes, read: false);
        case PspVramGuard.cpuDirty:
          rt.mapPages(at, bytes, memory.vram, offset: offset);
        default:
          rt.unmapPages(at, bytes);
      }
    }
  }

  int? _codeWord(int pc) {
    if (pc < 0 || pc > 0xffffffff || pc & 3 != 0) return null;
    final phys = PspMemory.physical(pc);
    // Code in video memory is not compiled while the GPU owns it, so that
    // the page mappings stay those of [setVramPage].
    if (phys >= PspMemory.ramAt && phys < PspMemory.ramEnd ||
        phys >= PspMemory.scratchAt &&
            phys < PspMemory.scratchAt + PspMemory.scratchSize ||
        memory.guard == null &&
            phys >= PspMemory.vramAt &&
            phys < PspMemory.vramAt + PspMemory.vramMirrors) {
      return memory.read32(pc);
    }
    return null;
  }

  IrBlock? _translate(int pc, int tag) {
    final block = _translator.translate(pc);
    if (block != null) {
      for (final guard in block.guards) {
        _code.protect(guard.addr, block: (pc, tag));
      }
    }
    return block;
  }

  /// Executes compiled clocks up to the caller's deadline. The caller
  /// interprets any instruction left at the returned PC.
  void run(Allegrex cpu, int clocksLeft) {
    // A runtime batch can overshoot its budget by one block minus one clock.
    // Reserve that many clocks so kernel wakeups and vblank stay exact.
    final budget = clocksLeft - AllegrexTranslator.maxInstructions + 1;
    if (budget <= 0 ||
        suspended ||
        !identical(cpu.r, regs) ||
        cpu.pc < 0 ||
        cpu.pc > 0xffffffff ||
        cpu.nextPc != cpu.pc + 4) {
      return;
    }
    final ctx = rt.ctx;
    ctx[AllegrexTranslator.ctxHi] = cpu.hi;
    ctx[AllegrexTranslator.ctxLo] = cpu.lo;
    ctx[AllegrexTranslator.ctxLinked] = cpu.linked ? 1 : 0;
    ctx[AllegrexTranslator.ctxFcc] = cpu.fcc;
    ctx[AllegrexTranslator.ctxVfpuZeroLanes] = cpu.vfpuZeroLanes;
    final reason = _driver.runBudgeted(cpu.pc, 0, budget);
    final spent = _driver.lastClocks;
    if (spent > 0) {
      cpu.jumpTo(rt.exitPc);
      cpu.clocks += spent;
      cpu.hi = ctx[AllegrexTranslator.ctxHi].toSigned(32);
      cpu.lo = ctx[AllegrexTranslator.ctxLo].toSigned(32);
      cpu.linked = ctx[AllegrexTranslator.ctxLinked] != 0;
      cpu.fcc = ctx[AllegrexTranslator.ctxFcc];
      cpu.vfpuZeroLanes = ctx[AllegrexTranslator.ctxVfpuZeroLanes];
    }
    if (reason == AllegrexTranslator.reasonStore) {
      _code.noteStoreExit(ctx[JitCtx.faultAddr]);
    }
  }
}
