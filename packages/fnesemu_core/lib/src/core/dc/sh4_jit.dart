part of 'sh4.dart';

/// Compiled SH-4 execution sharing registers and main RAM with [Sh4].
/// Main RAM is mapped at each physical mirror; any other access, and every
/// instruction the translator rejects, returns to the interpreter. The bus
/// cache must stay coherent so that RAM always holds current data.
/// The MMU observers keep the translation tables of [Sh4Translator] in step
/// with the TLB.
final class Sh4Jit extends JitAdapter {
  // Only a native runtime is created, so the adapter is always native.
  Sh4Jit._(JitRuntime rt, int compileThreshold)
      : super(rt, true, compileThreshold: compileThreshold);

  @override
  JitDriver get driver => _driver;
  late final Uint8List ram = rt.alloc(DcBus.ramSize);
  late final _queuePage = rt.alloc(rt.pageBytes);
  late final storeQueues = Uint8List.sublistView(_queuePage, 0, 64);
  static const _tableBytes = Sh4Translator.tableSlots * 8;
  late final _readTable = rt.alloc(_tableBytes);
  late final _writeTable = rt.alloc(_tableBytes);
  late final _readSlots = Uint32List.view(_readTable.buffer,
      _readTable.offsetInBytes, Sh4Translator.tableSlots * 2);
  late final _writeSlots = Uint32List.view(_writeTable.buffer,
      _writeTable.offsetInBytes, Sh4Translator.tableSlots * 2);
  late final Sh4 _cpu;
  late final _code = JitCodeMemory(rt);
  late final _translator = Sh4Translator(
      fetch: _fetch,
      protect: _code.protect,
      codePage: _codePage,
      fpuHelper: rt.addHelper(_floatingPoint),
      prefetchHelper: rt.addHelper(_prefetch));
  late final _driver = JitDriver(rt,
      translate: (pc, tag) => _translator.translate(pc, tag: tag),
      codeWord: _codeWord,
      codeMemory: _code,
      threshold: compileThreshold,
      prepareFirst: true,
      maxDispatches: 64,
      continueAfterExit: (reason) =>
          reason == JitReason.invalid ||
          reason == JitReason.miss &&
              rt.ctx[JitCtx.stop] == 0 &&
              rt.ctx[JitCtx.budget].toSigned(32) > 0);
  // Blocks never change the mode, the MMU or the address space, so the
  // tag found at entry holds for every block of a run.
  late final diagnostics = JitDiagnostics(rt,
      instructionBytes: 2, byteOrder: Endian.little, guestExit: (pc, reason) {
    if (reason != Sh4Translator.interpret) return null;
    final opcode = _codeWord(pc);
    return opcode != null && !Sh4Translator.supported(opcode, _tag)
        ? 'unsupportedInstruction'
        : null;
  });

  static Sh4Jit? create({int compileThreshold = 4}) {
    // Dc creates its SH-4 runtime first when it initializes, so claiming
    // the shared pool here covers the ARM runtime it creates next.
    JitRuntime.resetPool();
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
    rt.mapPages(Sh4Translator.readTable, _tableBytes, jit._readTable,
        write: false);
    rt.mapPages(Sh4Translator.writeTable, _tableBytes, jit._writeTable,
        write: false);
    return jit;
  }

  void _attach(Sh4 cpu) {
    _cpu = cpu;
    cpu.bus.mmu
      ..onTranslate = _record
      ..onEntryChange = _forget
      ..onFlush = _flush;
  }

  /// Records a translation of a 4 KiB or larger page to main RAM.
  void _record(
      int address, int physical, int offsetMask, bool write, bool privileged) {
    if (offsetMask < 0xfff || address >= 0x80000000) return;
    physical &= 0x1fffffff;
    if (physical < 0x0c000000 || physical >= 0x10000000) return;
    final mmu = _cpu.bus.mmu;
    final tag = Sh4Translator.mmuTag(0, 0,
        user: !privileged, space: _space(mmu.control, mmu.pteh, privileged));
    final slots = write ? _writeSlots : _readSlots;
    final slot = ((address >>> 12) & (Sh4Translator.tableSlots - 1)) * 2;
    slots[slot] = Sh4Translator.key(address, tag);
    slots[slot + 1] = physical & 0x1ffff000;
  }

  /// Drops the slots of an entry's old range.
  void _forget(int high, int offsetMask) {
    if (offsetMask < 0xfff) return;
    final base = high & ~offsetMask & 0xfffff000;
    final pages = (offsetMask + 1) >>> 12;
    for (var i = 0; i < pages && i < Sh4Translator.tableSlots; i++) {
      final page = (base + (i << 12)) & 0xffffffff;
      final slot = ((page >>> 12) & (Sh4Translator.tableSlots - 1)) * 2;
      for (final slots in [_readSlots, _writeSlots]) {
        if (slots[slot] & 0xfffff000 == page) slots[slot] = 0;
      }
    }
  }

  void _flush() {
    _readSlots.fillRange(0, _readSlots.length, 0);
    _writeSlots.fillRange(0, _writeSlots.length, 0);
  }

  static int _space(int control, int pteh, bool privileged) =>
      privileged && control & 0x100 != 0 ? 256 : pteh & 255;

  int? _codePage(int address, int tag) {
    final slot = ((address >>> 12) & (Sh4Translator.tableSlots - 1)) * 2;
    return _readSlots[slot] == Sh4Translator.key(address, tag)
        ? _readSlots[slot + 1]
        : null;
  }

  /// The instruction word at a virtual [pc] under the current mode.
  int? _codeWord(int pc) {
    pc &= 0xffffffff;
    final mmu = _cpu.bus.mmu;
    if (!mmu.enabled) return _fetch(pc);
    if (pc >= 0x80000000) {
      return _cpu.privileged && Sh4Translator.untranslated(pc)
          ? _fetch(pc)
          : null;
    }
    final page = _codePage(pc, _tag);
    return page == null ? null : _fetch(page | (pc & 0xfff));
  }

  Uint32List _view(int word) =>
      Uint32List.view(rt.ctx.buffer, rt.ctx.offsetInBytes + word * 4, 16);

  int get _tag {
    final cpu = _cpu, mmu = cpu.bus.mmu;
    if (!mmu.enabled) return Sh4Translator.tagOf(cpu._sr, cpu._fpscr);
    final privileged = cpu.privileged;
    return Sh4Translator.mmuTag(cpu._sr, cpu._fpscr,
        user: !privileged, space: _space(mmu.control, mmu.pteh, privileged));
  }

  int? _fetch(int pc) {
    if (pc & 1 != 0 || pc.mask32 >= 0xc0000000) return null;
    final page = rt.readPages[(pc & rt.addrMask) >>> rt.pageShift];
    if (page == null) return null;
    final offset = page.$2 + (pc & (rt.pageBytes - 1));
    return page.$1[offset] | (page.$1[offset + 1] << 8);
  }

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
    if (reason == Sh4Translator.remapped) {
      _driver.invalidate(rt.exitPc, rt.exitTag);
    }
    if (reason == Sh4Translator.interpret) {
      // A store into a code page: leave later stores to the entry guards.
      final fault = ctx[JitCtx.faultAddr];
      if (fault != 0 && _code.isProtected(fault)) _code.release(fault);
    }
    return steps;
  }

  int _prefetch(int address, int _, int __) {
    if (!DcBus.isStoreQueue(address)) return 0;
    try {
      _cpu.bus.transferStoreQueue(address, privileged: _cpu.privileged);
    } on DcCpuException {
      return 1;
    } on DcUnsupported {
      return 1;
    }
    return 0;
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
