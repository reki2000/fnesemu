part of 'sh4.dart';

/// Compiled SH-4 execution sharing registers and main RAM with [Sh4].
/// Main RAM is mapped at each physical mirror; any other access, and every
/// instruction the translator rejects, returns to the interpreter. The bus
/// cache must stay coherent so that RAM always holds current data.
final class Sh4Jit {
  Sh4Jit._(this.rt, this.compileThreshold);

  final JitRuntime rt;
  final int compileThreshold;
  late final Uint8List ram = rt.alloc(DcBus.ramSize);
  late final _queuePage = rt.alloc(rt.pageBytes);
  late final storeQueues = Uint8List.sublistView(_queuePage, 0, 64);
  late final Sh4 _cpu;
  late final _code = JitCodeMemory(rt);
  late final _translator = Sh4Translator(
      fetch: _fetch,
      protect: _code.protect,
      fpuHelper: rt.addHelper(_floatingPoint));
  late final _driver = JitDriver(rt,
      translate: _translator.translate,
      codeWord: _fetch,
      codeMemory: _code,
      threshold: compileThreshold,
      prepareFirst: true,
      maxDispatches: 64,
      continueAfterExit: (reason) =>
          reason == JitReason.invalid ||
          reason == JitReason.miss &&
              rt.ctx[JitCtx.stop] == 0 &&
              rt.ctx[JitCtx.budget].toSigned(32) > 0);
  late final diagnostics = JitDiagnostics(rt,
      instructionBytes: 2, byteOrder: Endian.little, guestExit: (pc, reason) {
    if (reason != Sh4Translator.interpret) return null;
    final opcode = _fetch(pc);
    return opcode != null && !Sh4Translator.supported(opcode, _tag)
        ? 'unsupportedInstruction'
        : null;
  });

  /// Runs the interpreter instead while keeping compiled blocks.
  bool suspended = false;

  static Sh4Jit? create({int compileThreshold = 4}) {
    final rt = JitRuntime.native(
        ctxWords: Sh4Translator.ctxWords,
        addrMask: 0x1fffffff,
        read: (_, __) => throw StateError('Unmapped SH-4 read'),
        write: (_, __, ___) => throw StateError('Unmapped SH-4 write'));
    if (rt == null) return null;
    final jit = Sh4Jit._(rt, compileThreshold);
    for (var mirror = 0; mirror < 4; mirror++) {
      jit._code
          .map(0x0c000000 + mirror * DcBus.ramSize, DcBus.ramSize, jit.ram);
    }
    rt.mapPages(Sh4Translator.queueAlias, rt.pageBytes, jit._queuePage);
    return jit;
  }

  Uint32List _view(int word) =>
      Uint32List.view(rt.ctx.buffer, rt.ctx.offsetInBytes + word * 4, 16);

  int get _tag => Sh4Translator.tagOf(_cpu._sr, _cpu._fpscr);

  int? _fetch(int pc) {
    if (pc & 1 != 0 || pc.mask32 >= 0xc0000000) return null;
    final page = rt.readPages[(pc & rt.addrMask) >>> rt.pageShift];
    if (page == null) return null;
    final offset = page.$2 + (pc & (rt.pageBytes - 1));
    return page.$1[offset] | (page.$1[offset + 1] << 8);
  }

  /// Drops compiled code; guest state stays.
  void reset() => _driver.reset();

  void dispose() => rt.dispose();

  int _run(int budget) {
    final cpu = _cpu, ctx = rt.ctx;
    final tag = _tag;
    if (_driver.isFallback(cpu.pc, tag)) return 0;
    ctx[Sh4Translator.sr] = cpu._sr;
    ctx[Sh4Translator.gbr] = cpu.gbr;
    ctx[Sh4Translator.pr] = cpu.pr;
    ctx[Sh4Translator.mach] = cpu.mach;
    ctx[Sh4Translator.macl] = cpu.macl;
    ctx[Sh4Translator.fpul] = cpu.fpul;
    ctx[Sh4Translator.fpscr] = cpu._fpscr;
    ctx[JitCtx.faultAddr] = 0;
    final reason = _driver.runBudgeted(cpu.pc, tag, budget);
    // Blocks never change the register bank or FPU mode bits.
    cpu._sr = ctx[Sh4Translator.sr];
    cpu.gbr = ctx[Sh4Translator.gbr];
    cpu.pr = ctx[Sh4Translator.pr];
    cpu.mach = ctx[Sh4Translator.mach];
    cpu.macl = ctx[Sh4Translator.macl];
    cpu.fpul = ctx[Sh4Translator.fpul];
    cpu._fpscr = ctx[Sh4Translator.fpscr];
    final steps = _driver.lastClocks;
    if (steps > 0) cpu.pc = rt.exitPc;
    if (reason == Sh4Translator.interpret) {
      // A store into a code page: leave later stores to the entry guards.
      final fault = ctx[JitCtx.faultAddr];
      if (fault != 0 && _code.isProtected(fault)) _code.release(fault);
    }
    return steps;
  }

  int _floatingPoint(int op, int pc, int _) {
    final cpu = _cpu, ctx = rt.ctx;
    cpu._sr = ctx[Sh4Translator.sr];
    cpu.fpul = ctx[Sh4Translator.fpul];
    final saved = cpu._fpscr = ctx[Sh4Translator.fpscr];
    cpu.pc = pc;
    try {
      cpu._fpuOp(op, (op >> 8) & 15, (op >> 4) & 15);
    } on DcCpuException {
      cpu._fpscr = saved;
      return 1;
    } on DcUnsupported {
      cpu._fpscr = saved;
      return 1;
    }
    ctx[Sh4Translator.sr] = cpu._sr;
    ctx[Sh4Translator.fpul] = cpu.fpul;
    ctx[Sh4Translator.fpscr] = cpu._fpscr;
    return 0;
  }
}
