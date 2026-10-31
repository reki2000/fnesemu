import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../bus.dart';
import '../r5900/r5900.dart';
import 'r5900_translator.dart';

/// Runs EE code compiled by [R5900Translator].
///
/// Compiled blocks share main memory and the general registers with the
/// interpreter. Main memory is mapped at 0 with the top three address bits
/// masked off, so the unmapped kernel segments and the user addresses below
/// 0x20000000 reach it; [R5900Translator] lets only those through. The
/// adapter runs compiled code only while the TLB maps the user addresses
/// one to one ([Tlb.userIdentity]). Accesses outside main memory, such as
/// the scratchpad and the device registers, exit to the interpreter.
final class Ps2Jit {
  final JitRuntime rt;
  late final diagnostics =
      JitDiagnostics(rt, instructionBytes: 4, byteOrder: Endian.little)
        ..memoryRegion = _memoryRegion;
  final bool native;
  final int compileThreshold;
  final Uint8List ram;
  late final ByteData _ram = ByteData.sublistView(ram);
  late final Int64List gpr = Int64List.view(
      rt.ctx.buffer, rt.ctx.offsetInBytes + R5900Translator.ctxRegs * 4, 64);
  late final R5900 cpu;
  late final R5900Translator _translator;
  late final _code = JitCodeMemory(rt);
  late final _driver = JitDriver(rt,
      translate: (pc, tag) => _translator.translate(pc, tag: tag),
      codeWord: _fetch,
      codeMemory: _code,
      threshold: compileThreshold);

  /// Runs the interpreter instead while keeping the compiled blocks and the
  /// shared state.
  bool suspended = false;

  int get compiledClocks => native ? _driver.executedClocks : 0;

  Ps2Jit._(this.rt, this.native, int? threshold, this.ram)
      : compileThreshold = threshold ?? rt.compileThreshold;

  static Ps2Jit? create({bool native = true, int? compileThreshold}) {
    if (Endian.host != Endian.little) return null;
    int read(int a, int s) => throw StateError('Unmapped compiled read');
    void write(int a, int s, int v) =>
        throw StateError('Unmapped compiled write');
    final runtime = native
        ? JitRuntime.native(
            ctxWords: R5900Translator.ctxWords,
            addrMask: 0x1fffffff,
            read: read,
            write: write)
        : JitRuntime.interpreter(
            ctxWords: R5900Translator.ctxWords,
            addrMask: 0x1fffffff,
            read: read,
            write: write);
    if (runtime == null) return null;
    // The guest memory comes out of the runtime's memory pool, which the
    // Wasm runtime shares between every live runtime. A pool with no room
    // for it leaves this host without a recompiler, as a runtime that
    // cannot be created does, instead of failing the construction of the
    // core when the memory is first touched.
    final Uint8List ram;
    try {
      ram = runtime.alloc(Ps2Bus.ramSize);
    } on StateError {
      runtime.dispose();
      return null;
    }
    return Ps2Jit._(runtime, native, compileThreshold, ram);
  }

  void attach(R5900 cpu) {
    this.cpu = cpu;
    _code.map(0, ram.length, ram);
    _translator = R5900Translator(fetch: _fetch, protect: _code.protect);
  }

  String _memoryRegion(int address) {
    if (!_compiledSegment(address)) return 'tlb';
    return address & 0x1fffffff < ram.length ? 'ram' : 'unmapped';
  }

  /// the segments that compiled code reaches without the TLB
  static bool _compiledSegment(int address) =>
      (0x33 >> ((address & 0xffffffff) >>> 29)) & 1 != 0;

  bool _canFetch(int pc) =>
      _compiledSegment(pc) &&
      pc & 3 == 0 &&
      (pc & 0x1fffffff) + 4 <= ram.length;

  int? _fetch(int pc) =>
      _canFetch(pc) ? _ram.getUint32(pc & 0x1fffffff, Endian.little) : null;

  void reset() => _driver.reset();

  /// Runs compiled code for about [budget] clocks. Returns false when the
  /// next instruction is left to the interpreter.
  bool run(int budget) {
    if (budget <= 0 || suspended) return false;
    final cpu = this.cpu;
    final pc = cpu.pc;
    if (!_canFetch(pc)) return false;
    if (!cpu.bus.tlb!.userIdentity) return false;
    if (_driver.isFallback(pc, 0)) return false;
    if (!cpu.prepareCompiled()) return false;
    final untilCompare = cpu.instructionsUntilCompare;
    if (untilCompare != 0 && untilCompare < budget) budget = untilCompare;
    _driver.runBudgeted(pc, 0, budget);
    final spent = _driver.lastClocks;
    if (spent == 0) return false;
    cpu.finishCompiled(spent, rt.exitPc);
    return true;
  }

  void dispose() => rt.dispose();
}
