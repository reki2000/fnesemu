import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../bus.dart';
import '../cpu.dart';
import '../fpu.dart';
import '../registers.dart';
import 'vr4300_translator.dart';

/// Compiled blocks share RAM and complete integer/FPU register files with the
/// interpreter. Memory faults and unsupported instructions exit before effects.
final class N64Jit {
  final JitRuntime rt;
  late final diagnostics =
      JitDiagnostics(rt, instructionBytes: 4, byteOrder: Endian.big)
        ..memoryRegion = _memoryRegion;
  final bool native;
  final int compileThreshold;
  final int maxBlockInstructions;
  final bool fpuHelpers;
  final bool cop1;
  final bool nativeFpu;
  final bool inlineJumps;
  late final Uint8List ram = rt.alloc(0x800000);
  late final regs = N64Registers(
      values: Int64List.view(
          rt.ctx.buffer,
          rt.ctx.offsetInBytes + Vr4300Translator.ctxRegs * 4,
          N64Registers.storage));
  late final fpu = N64Fpu(
      data: ByteData.view(rt.ctx.buffer,
          rt.ctx.offsetInBytes + Vr4300Translator.ctxFpu * 4, 256));
  late final Vr4300 cpu;
  late final N64Bus bus;
  late final Vr4300Translator _translator;
  late final _code = JitCodeMemory(rt);
  late final _driver = JitDriver(rt,
      translate: (pc, tag) => _translator.translate(pc, tag: tag),
      codeWord: _fetch,
      codeMemory: _code,
      threshold: compileThreshold);

  /// Runs the CPU interpreter instead while keeping compiled blocks and the
  /// shared guest state, for tools that warm up with compiled code.
  bool suspended = false;
  int get compiledClocks => native ? _driver.executedClocks : 0;

  /// Optional compilation counts by guest instruction count, not execution hits.
  final Map<int, int>? blockSizes;

  final Map<String, int>? blockEnds;
  final Map<int, int>? cpuFallbackOps;
  final Map<(int, int), int>? runtimeExits;
  int idleClocks = 0;

  void recordCpuFallback() {
    final counts = cpuFallbackOps;
    if (counts == null) return;
    final op = _fetch(cpu.pc) ?? -1;
    counts.update(op, (n) => n + 1, ifAbsent: () => 1);
  }

  void recordIdle(int clocks) {
    if (cpuFallbackOps != null) idleClocks += clocks;
    diagnostics.executionStats?.recordIdle(clocks);
  }

  N64Jit._(
      this.rt,
      this.native,
      int? threshold,
      this.maxBlockInstructions,
      this.fpuHelpers,
      this.cop1,
      this.nativeFpu,
      this.inlineJumps,
      bool statistics)
      : compileThreshold = threshold ?? rt.compileThreshold,
        blockSizes = statistics ? <int, int>{} : null,
        blockEnds = statistics ? <String, int>{} : null,
        cpuFallbackOps = statistics ? <int, int>{} : null,
        runtimeExits = statistics ? <(int, int), int>{} : null;

  static N64Jit? create(
      {bool native = true,
      bool statistics = const bool.fromEnvironment('N64_JIT_STATS'),
      int? compileThreshold,
      int? maxBlockInstructions,
      bool fpuHelpers = true,
      bool cop1 = false,
      bool nativeFpu = false,
      bool inlineJumps = false}) {
    if (Endian.host != Endian.little) return null;
    int read(int a, int s) => throw StateError('Unmapped compiled read');
    void write(int a, int s, int v) =>
        throw StateError('Unmapped compiled write');
    final runtime = native
        ? JitRuntime.native(
            ctxWords: Vr4300Translator.ctxFpuControl + 1,
            addrMask: 0x1fffffff,
            read: read,
            write: write)
        : JitRuntime.interpreter(
            ctxWords: Vr4300Translator.ctxFpuControl + 1,
            addrMask: 0x1fffffff,
            read: read,
            write: write);
    return runtime == null
        ? null
        : N64Jit._(
            runtime,
            native,
            compileThreshold,
            maxBlockInstructions ?? Vr4300Translator.defaultMaxInstructions,
            fpuHelpers,
            cop1 || fpuHelpers || nativeFpu,
            nativeFpu,
            inlineJumps,
            statistics);
  }

  void attach(Vr4300 cpu, N64Bus bus) {
    this.cpu = cpu;
    this.bus = bus;
    diagnostics.bindExecutionStats((stats) => cpu.executionStats = stats);
    _code.map(0, ram.length, ram);
    final fp = rt.addHelper((op, _, __) {
      fpu.control = rt.ctx[Vr4300Translator.ctxFpuControl];
      fpu.execute((op >>> 21) & 31, (op >>> 16) & 31, (op >>> 11) & 31,
          (op >>> 6) & 31, op & 63);
      rt.ctx[Vr4300Translator.ctxFpuControl] = fpu.control;
      return 0;
    });
    _translator = Vr4300Translator(
        fetch: _fetch,
        protect: _code.protect,
        maxInstructions: maxBlockInstructions,
        fpuHelper: fpuHelpers ? fp : null,
        cop1: cop1,
        nativeFpu: nativeFpu,
        inlineJumps: inlineJumps);

    if (runtimeExits case final counts?) {
      _driver.onExit = (reason, pc) => counts
          .update((reason, _fetch(pc) ?? -1), (n) => n + 1, ifAbsent: () => 1);
    }
    if (blockEnds != null || blockSizes != null) {
      _driver.onInstall = _recordInstall;
    }
  }

  void _recordInstall(IrBlock block) {
    if (blockEnds case final ends?) {
      final term = block.term;
      final String name;
      if (term is IrExitTerm) {
        final op = _fetch(term.exit.pc);
        final code = op == null ? -1 : op >>> 26;
        name = code == 0 ? 'special:${op! & 63}' : 'opcode:$code';
      } else if (term is IrJumpDyn) {
        name = 'indirect';
      } else if (term is IrBranch) {
        name = 'branch';
      } else {
        final branch = block.guards.length < 2
            ? null
            : _fetch(block.guards[block.guards.length - 2].addr);
        name = switch (branch == null ? -1 : branch >>> 26) {
          2 => 'jump',
          3 => 'call',
          _ => 'limit',
        };
      }
      ends[name] = (ends[name] ?? 0) + 1;
    }
    if (blockSizes case final sizes?) {
      sizes[block.cost] = (sizes[block.cost] ?? 0) + 1;
    }
  }

  String _memoryRegion(int address) {
    if (address & 0xc0000000 != 0x80000000) return 'tlb';
    final p = address & 0x1fffffff;
    if (p < ram.length) return 'ram';
    if (p >= 0x04000000 && p < 0x04002000) return 'spMemory';
    if (p >= 0x10000000 && p < 0x1fc00000) return 'rom';
    if (p >= 0x04000000 && p < 0x10000000) return 'device';
    return 'unmapped';
  }

  bool _canFetch(int pc) =>
      (pc & 0xc0000000) == 0x80000000 &&
      pc & 3 == 0 &&
      (pc & 0x1fffffff) + 4 <= ram.length;

  int? _fetch(int pc) =>
      _canFetch(pc) ? bus.ramData.getUint32(pc & 0x1fffffff) : null;

  void reset() {
    _driver.reset();
    blockSizes?.clear();
    blockEnds?.clear();
    cpuFallbackOps?.clear();
    runtimeExits?.clear();
    idleClocks = 0;
  }

  /// Run up to the device deadline, without interpreting any instruction.
  /// Returning false leaves the next instruction to the normal CPU/bus path.
  bool run(int budget) {
    if (budget <= 0) return false;
    final originalPc = cpu.pc;
    if (!_canFetch(originalPc)) return false;
    final tag = cop1
        ? (fpu.wide ? 1 : 0) | ((cpu.cop0[12] & (1 << 29)) != 0 ? 2 : 0)
        : 0;
    if (_driver.isFallback(originalPc, tag)) return false;
    if (!cpu.prepareCompiled()) return false;
    final ctx = rt.ctx;
    if (cop1) ctx[Vr4300Translator.ctxFpuControl] = fpu.control;
    _driver.runBudgeted(originalPc, tag, budget);
    final pc = rt.exitPc;
    final spent = _driver.lastClocks;
    if (spent == 0) return false;
    if (cop1) fpu.control = ctx[Vr4300Translator.ctxFpuControl];
    cpu.clocks += spent;
    cpu.pc = pc;
    cpu.nextPc = (pc + 4) & 0xffffffff;
    return true;
  }

  void dispose() => rt.dispose();
}
