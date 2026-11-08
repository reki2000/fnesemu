import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../../components/arm7/jit/translator.dart';
import '../../util/jit_adapter.dart';
import 'arm7di.dart';

/// Compiled AICA ARM execution over sound RAM, which this runtime owns.
/// Registers live in the runtime context and the interpreter shares them.
final class DcArmJit extends JitAdapter {
  // Only a native runtime is created, so the adapter is always native.
  DcArmJit._(JitRuntime rt, this.memory) : super(rt, true);

  @override
  JitDriver get driver => _driver;

  final Uint8List memory;
  late final diagnostics =
      JitDiagnostics(rt, instructionBytes: 4, byteOrder: Endian.little);
  late final _code = JitCodeMemory(rt);
  late final _translator = ArmTranslator(
      fetch: _fetch, protect: _code.protect, policy: ArmTranslatorPolicy.dc);
  late final _driver = JitDriver(rt,
      translate: (pc, tag) => _translator.translate(pc, tag: tag),
      codeWord: _fetch,
      codeMemory: _code,
      threshold: 4,
      prepareFirst: true,
      maxDispatches: 64,
      continueAfterExit: (reason) =>
          reason == JitReason.invalid ||
          reason == JitReason.miss &&
              rt.ctx[JitCtx.stop] == 0 &&
              rt.ctx[JitCtx.budget].toSigned(32) > 0);

  /// The ARM registers, shared with the interpreter.
  late final Uint32List registers = Uint32List.view(
      rt.ctx.buffer, rt.ctx.offsetInBytes + ArmTranslator.regs * 4, 16);

  static DcArmJit? create(int memorySize) {
    final rt = JitRuntime.native(
        ctxWords: ArmTranslator.ctxWords,
        addrMask: 0x00ffffff,
        read: (_, __) => throw StateError('Unmapped ARM read'),
        write: (_, __, ___) => throw StateError('Unmapped ARM write'));
    if (rt == null) return null;
    // No pool claim here: Dc initializes its SH-4 runtime first, which
    // claims the shared pool for the whole core (see Sh4Jit.create).
    final Uint8List memory;
    try {
      memory = rt.alloc(memorySize);
    } on StateError {
      rt.dispose();
      return null;
    }
    final jit = DcArmJit._(rt, memory);
    jit._code.map(0, memorySize, jit.memory);
    return jit;
  }

  int? _fetch(int pc) {
    if (pc & 3 != 0 || pc + 4 > memory.length) return null;
    return memory[pc] |
        (memory[pc + 1] << 8) |
        (memory[pc + 2] << 16) |
        (memory[pc + 3] << 24);
  }

  /// Runs compiled blocks from the ARM state for up to [budget] cycles and
  /// returns the cycles they took.
  int run(DcArm7di arm, int budget) {
    if (suspended) return 0;
    final ctx = rt.ctx;
    if (_driver.isFallback(arm.pc, 0)) return 0;
    ctx[ArmTranslator.cpsr] = arm.cpsr;
    ctx[ArmTranslator.pending] = (arm.irq ? 0x80 : 0) | (arm.fiq ? 0x40 : 0);
    ctx[JitCtx.faultAddr] = 0;
    final reason = _driver.runBudgeted(arm.pc, 0, budget);
    final cycles = _driver.lastClocks;
    if (cycles > 0) {
      // Blocks change the flags, and the interrupt masks through MSR; the
      // mode stays, so no register bank switches.
      arm.cpsr = ctx[ArmTranslator.cpsr];
      arm.pc = rt.exitPc;
    }
    if (reason == ArmTranslator.interpret) {
      // A store into a code page: leave later stores to the entry guards.
      final fault = ctx[JitCtx.faultAddr];
      if (fault != 0 && _code.isProtected(fault)) _code.release(fault);
    }
    return cycles;
  }
}
