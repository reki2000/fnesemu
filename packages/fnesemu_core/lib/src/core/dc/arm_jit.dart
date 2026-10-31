import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import 'arm7di.dart';
import 'arm_translator.dart';

/// Compiled AICA ARM execution over sound RAM, which this runtime owns.
/// Registers live in the runtime context and the interpreter shares them.
final class DcArmJit {
  DcArmJit._(this.rt, this.memory);

  final JitRuntime rt;
  final Uint8List memory;
  late final _code = JitCodeMemory(rt);
  late final _translator =
      DcArmTranslator(fetch: _fetch, protect: _code.protect);
  late final _driver = JitDriver(rt,
      translate: _translator.translate,
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
      rt.ctx.buffer, rt.ctx.offsetInBytes + DcArmTranslator.regs * 4, 16);

  static DcArmJit? create(int memorySize) {
    final rt = JitRuntime.native(
        ctxWords: DcArmTranslator.ctxWords,
        addrMask: 0x00ffffff,
        read: (_, __) => throw StateError('Unmapped ARM read'),
        write: (_, __, ___) => throw StateError('Unmapped ARM write'));
    if (rt == null) return null;
    final jit = DcArmJit._(rt, rt.alloc(memorySize));
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

  /// Drops compiled code.
  void reset() => _driver.reset();

  void dispose() => rt.dispose();

  /// Runs compiled blocks from the ARM state for up to [budget] cycles and
  /// returns the cycles they took.
  int run(DcArm7di arm, int budget) {
    final ctx = rt.ctx;
    if (_driver.isFallback(arm.pc, 0)) return 0;
    ctx[DcArmTranslator.cpsr] = arm.cpsr;
    ctx[JitCtx.faultAddr] = 0;
    final reason = _driver.runBudgeted(arm.pc, 0, budget);
    final cycles = _driver.lastClocks;
    if (cycles > 0) {
      arm.flags = ctx[DcArmTranslator.cpsr];
      arm.pc = rt.exitPc;
    }
    if (reason == DcArmTranslator.interpret) {
      // A store into a code page: leave later stores to the entry guards.
      final fault = ctx[JitCtx.faultAddr];
      if (fault != 0 && _code.isProtected(fault)) _code.release(fault);
    }
    return cycles;
  }
}
