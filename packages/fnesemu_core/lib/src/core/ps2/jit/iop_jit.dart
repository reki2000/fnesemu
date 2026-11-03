import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../../../components/r3000/jit/r3000_translator.dart';
import '../../../util/jit_adapter.dart';
import '../iop/iop.dart';
import '../iop/iop_memory.dart';

/// Runs IOP code compiled by [R3000Translator].
///
/// Compiled blocks share RAM and the registers with the interpreter:
/// the RAM is the runtime's buffer, mapped at its physical address, and
/// the registers are a view of the context. Accesses outside RAM leave
/// to the interpreter before the instruction, as do the instructions
/// the translator leaves out, so the interpreter observes the exact
/// state at every boundary. A run starts only outside a branch delay
/// slot, with no interrupt ready and the cache not isolated
/// ([Iop.prepareCompiled]); hi, lo and the load in its delay are copied
/// through the context around the run, as the interpreter keeps them in
/// plain fields.
final class IopJit extends JitAdapter {
  late final diagnostics =
      JitDiagnostics(rt, instructionBytes: 4, byteOrder: Endian.little);
  final Uint8List ram;
  late final ByteData _ram = ByteData.sublistView(ram);
  late final Uint32List regs =
      Uint32List.sublistView(rt.ctx, ctxRegs, ctxRegs + 32);
  late final Iop cpu;
  late final IopMemory memory;
  late final R3000Translator _translator;
  late final _code = JitCodeMemory(rt);
  late final _driver = JitDriver(rt,
      translate: (pc, tag) {
        _translating = (pc, tag);
        return _translator.translate(pc, tag: tag);
      },
      codeWord: _codeWord,
      codeMemory: _code,
      threshold: compileThreshold,
      recompileInvalid: true);
  (int, int) _translating = (0, 0);

  static const ctxRegs = R3000Translator.ctxRegs;
  static const ctxHi = R3000Translator.ctxHi, ctxLo = R3000Translator.ctxLo;
  static const ctxPendingValue = R3000Translator.ctxPendingValue;
  static const _ctxWords = ctxPendingValue + 1;
  static const reasonInterpret = R3000Translator.reasonInterpret;
  static const reasonStore = R3000Translator.reasonStore;

  IopJit._(super.rt, super.native, int? threshold, this.ram)
      : super(compileThreshold: threshold);

  @override
  JitDriver get driver => _driver;

  /// The recompiler of this host, or null when it has none (or no room
  /// for the RAM). Unlike the EE recompiler this does not reset the
  /// shared runtime pool: the EE one already did for this machine, and
  /// a second reset would retire its runtime on the web.
  static IopJit? create({bool native = true, int? compileThreshold}) {
    if (Endian.host != Endian.little) return null;
    int read(int a, int s) => throw StateError('Unmapped compiled read');
    void write(int a, int s, int v) =>
        throw StateError('Unmapped compiled write');
    final runtime = native
        ? JitRuntime.native(
            ctxWords: _ctxWords, addrMask: 0x1fffffff, read: read, write: write)
        : JitRuntime.interpreter(
            ctxWords: _ctxWords, addrMask: 0x1fffffff, read: read, write: write);
    if (runtime == null) return null;
    final Uint8List ram;
    try {
      ram = runtime.alloc(IopMemory.ramSize);
    } on StateError {
      runtime.dispose();
      return null;
    }
    return IopJit._(runtime, native, compileThreshold, ram);
  }

  void attach(Iop cpu, IopMemory memory) {
    this.cpu = cpu;
    this.memory = memory;
    _code.map(0, ram.length, ram);
    _translator = R3000Translator(
      fetch: _fetch,
      endsAfterStore: _endsAfterStore,
      mfc0: rt.addHelper((reg, _, __) {
        // The interpreter mirrors the interrupt line into Cause.IP2 at
        // the start of every step; apply the same mirror to the read.
        if (reg == Iop.cop0Cause) {
          return (cpu.cop0[Iop.cop0Cause] & ~0x400) |
              (cpu.interruptAsserted ? 0x400 : 0);
        }
        return cpu.cop0[reg];
      }),
      div: rt.addHelper((a, b, signed) {
        final (lo, hi) = signed != 0 ? _div(a, b) : _divu(a, b);
        rt.ctx[ctxHi] = hi;
        rt.ctx[ctxLo] = lo;
        return 0;
      }),
      ramSize: IopMemory.ramSize,
      maxInstructions: 32,
      clocksPerInstruction: 1,
    );
  }

  /// The signed divide of the interpreter, including its results for a
  /// zero divisor and the overflowing pair.
  static (int, int) _div(int a, int b) {
    final sa = a.toSigned(32), sb = b.toSigned(32);
    if (sb == 0) return (sa < 0 ? 1 : 0xffffffff, a);
    if (sa == -0x80000000 && sb == -1) return (0x80000000, 0);
    return ((sa ~/ sb).toUnsigned(32), sa.remainder(sb).toUnsigned(32));
  }

  static (int, int) _divu(int a, int b) =>
      b == 0 ? (0xffffffff, a) : (a ~/ b, a % b);

  late final ByteData _bios = ByteData.sublistView(memory.bios);

  /// The code word at [pc] without protecting it, or null outside RAM
  /// and the BIOS.
  int? _codeWord(int pc) {
    final phys = pc & 0x1fffffff;
    if (phys < 0x800000) {
      return _ram.getUint32(phys & (IopMemory.ramSize - 1), Endian.little);
    }
    if (phys >= IopMemory.biosBase &&
        phys < IopMemory.biosBase + memory.bios.length) {
      return _bios.getUint32(phys - IopMemory.biosBase, Endian.little);
    }
    return null;
  }

  /// The code word at [pc], or null outside RAM and the BIOS; a RAM word
  /// is guarded against modification.
  (int, bool)? _fetch(int pc) {
    final word = _codeWord(pc);
    if (word == null) return null;
    if ((pc & 0x1fffffff) < 0x800000) {
      _code.protect(pc, block: _translating);
      return (word, true);
    }
    return (word, false);
  }

  /// Stores in released RAM pages end their block so the next block's
  /// guards observe code changes.
  bool _endsAfterStore(int pc) =>
      (pc & 0x1fffffff) < 0x800000 && _code.isReleased(pc);


  /// Runs compiled code for up to [budget] instructions and returns how
  /// many ran; zero means the next instruction is the interpreter's.
  int run(int budget) {
    if (budget <= 0 || suspended) return 0;
    final cpu = this.cpu;
    if (!cpu.prepareCompiled()) return 0;
    final (tag, pendingValue) = cpu.pendingLoad();
    final ctx = rt.ctx;
    ctx[ctxPendingValue] = pendingValue;
    ctx[ctxHi] = cpu.hi;
    ctx[ctxLo] = cpu.lo;
    final reason = _driver.runBudgeted(cpu.pc, tag, budget);
    final spent = _driver.lastClocks;
    cpu.clocks += spent;
    if (spent > 0) {
      cpu.pc = rt.exitPc;
      cpu.nextPc = (rt.exitPc + 4) & 0xffffffff;
    }
    cpu.setPendingLoad(rt.exitTag, ctx[ctxPendingValue]);
    cpu.hi = ctx[ctxHi];
    cpu.lo = ctx[ctxLo];
    if (reason == reasonStore) _code.noteStoreExit(ctx[JitCtx.faultAddr]);
    return spent;
  }
}
