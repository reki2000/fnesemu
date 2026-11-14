import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import '../../../util/jit_adapter.dart';
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
/// one to one ([Tlb.userIdentity]). The scratchpad is shared as well and
/// mapped at [R5900Translator.scratchAlias]. Accesses outside main memory
/// and the scratchpad, such as the device registers, exit to the
/// interpreter.
final class Ps2Jit extends JitAdapter {
  late final diagnostics =
      JitDiagnostics(rt, instructionBytes: 4, byteOrder: Endian.little)
        ..memoryRegion = _memoryRegion;
  final Uint8List ram, scratch;
  late final ByteData _ram = ByteData.sublistView(ram);
  late final Int64List gpr = Int64List.view(
      rt.ctx.buffer, rt.ctx.offsetInBytes + R5900Translator.ctxRegs * 4, 64);
  late final Uint32List fpr = Uint32List.view(rt.ctx.buffer,
      rt.ctx.offsetInBytes + R5900Translator.ctxFpr * 4, 32);

  /// HI, LO, HI1 and LO1 as compiled code keeps them, each in two words
  late final Int64List multiply = Int64List.view(
      rt.ctx.buffer, rt.ctx.offsetInBytes + R5900Translator.ctxHi * 4, 4);

  /// the COP1 accumulator and FCR31 as compiled code keeps them
  late final Uint32List fpuControl = Uint32List.view(rt.ctx.buffer,
      rt.ctx.offsetInBytes + R5900Translator.ctxFacc * 4, 2);
  late final R5900 cpu;
  late final R5900Translator _translator;
  late final _code = JitCodeMemory(rt);
  late final _driver = JitDriver(rt,
      translate: (pc, tag) => _translator.translate(pc, tag: tag),
      codeWord: _fetch,
      codeMemory: _code,
      threshold: compileThreshold)
    ..onClear = _forgetRefused
    ..onInvalidate = (pc, tag) => _refusedKey[(pc >> 2) & _refusedMask] = -1;

  // Recent entries that [JitDriver.isFallback] has refused, by the low bits
  // of their pc: the pc with the tag above it, and the code word. The
  // interpreter runs the instructions that do not translate one by one, so
  // a hit gives the answer of the driver without its lookup. The driver
  // hooks drop the entries that it forgets.
  static const _refusedMask = 1023;
  final _refusedKey = Int64List(_refusedMask + 1)..fillRange(0, 1024, -1);
  final _refusedWord = Int64List(_refusedMask + 1);

  void _forgetRefused() => _refusedKey.fillRange(0, _refusedMask + 1, -1);

  // A recent LW that exited before executing because its address was outside
  // the JIT's RAM mapping. The base register and instruction are rechecked
  // on every hit: the same instruction can later address RAM, and code can
  // be modified without going through the JIT.
  int _unmappedLoadPc = -1, _unmappedLoadWord = 0;
  int _unmappedLoadBase = 0, _unmappedLoadOffset = 0;

  Ps2Jit._(super.rt, super.native, int? threshold, this.ram, this.scratch)
      : super(compileThreshold: threshold);

  @override
  JitDriver get driver => _driver;

  static Ps2Jit? create({bool native = true, int? compileThreshold}) {
    if (Endian.host != Endian.little) return null;
    if (native) JitRuntime.resetPool();
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
    final Uint8List ram, scratch;
    try {
      ram = runtime.alloc(Ps2Bus.ramSize);
      scratch = runtime.alloc(Ps2Bus.scratchSize);
    } on StateError {
      runtime.dispose();
      return null;
    }
    return Ps2Jit._(runtime, native, compileThreshold, ram, scratch);
  }

  void attach(R5900 cpu) {
    this.cpu = cpu;
    _code.map(0, ram.length, ram);
    // The scratchpad holds no compiled code, so it needs no protection.
    rt.mapPages(R5900Translator.scratchAlias, scratch.length, scratch);
    _translator = R5900Translator(fetch: _fetch, protect: _code.protect);
  }

  String _memoryRegion(int address) {
    if (_isScratch(address)) return 'scratch';
    if (!_compiledSegment(address)) return 'tlb';
    return address & 0x1fffffff < ram.length ? 'ram' : 'unmapped';
  }

  /// the segments that compiled code reaches without the TLB
  static bool _compiledSegment(int address) =>
      (0x33 >> ((address & 0xffffffff) >>> 29)) & 1 != 0;

  static bool _isScratch(int address) =>
      (address & 0xffffffff) & ~(Ps2Bus.scratchSize - 1) == Ps2Bus.scratchBase;

  bool _canFetch(int pc) =>
      _compiledSegment(pc) &&
      pc & 3 == 0 &&
      (pc & 0x1fffffff) + 4 <= ram.length;

  int? _fetch(int pc) =>
      _canFetch(pc) ? _ram.getUint32(pc & 0x1fffffff, Endian.little) : null;

  @override
  void reset() {
    _unmappedLoadPc = -1;
    super.reset();
  }

  bool _outsideRam(int base, int offset) {
    final address = cpu.reg(base) + offset;
    return !_isScratch(address) && (address & 0x1fffffff) >= ram.length;
  }

  void _rememberUnmappedLoad(int pc) {
    final word = _fetch(pc);
    if (word == null || word >>> 26 != 35) return; // LW
    final base = (word >>> 21) & 31;
    final offset = (word & 0xffff).toSigned(16);
    if (!_outsideRam(base, offset)) return;
    _unmappedLoadPc = pc;
    _unmappedLoadWord = word;
    _unmappedLoadBase = base;
    _unmappedLoadOffset = offset;
  }

  /// Runs compiled code for about [budget] clocks. Returns false when the
  /// next instruction is left to the interpreter.
  bool run(int budget) {
    if (budget <= 0 || suspended) return false;
    final cpu = this.cpu;
    final pc = cpu.pc;
    // The tag records whether COP1 is usable: blocks compiled with it
    // clear translate no COP1 instructions, so a usable exception is
    // never skipped, and blocks compiled with it set keep working when
    // the bit later clears.
    final tag = cpu.cop1Usable ? 1 : 0;
    final slot = (pc >> 2) & _refusedMask;
    if (_refusedKey[slot] == pc | tag << 32 &&
        _ram.getUint32(pc & 0x1fffffff, Endian.little) == _refusedWord[slot]) {
      return false;
    }
    if (!_canFetch(pc)) return false;
    if (!cpu.bus.tlb!.userIdentity) return false;
    if (pc == _unmappedLoadPc &&
        _ram.getUint32(pc & 0x1fffffff, Endian.little) == _unmappedLoadWord &&
        _outsideRam(_unmappedLoadBase, _unmappedLoadOffset)) {
      return false;
    }
    if (_driver.isFallback(pc, tag)) {
      _refusedKey[slot] = pc | tag << 32;
      _refusedWord[slot] = _ram.getUint32(pc & 0x1fffffff, Endian.little);
      return false;
    }
    if (!cpu.prepareCompiled()) return false;
    final untilCompare = cpu.instructionsUntilCompare;
    if (untilCompare != 0 && untilCompare < budget) budget = untilCompare;
    final reason = _driver.runBudgeted(pc, tag, budget);
    final spent = _driver.lastClocks;
    if (spent == 0) {
      if (reason == R5900Translator.interpret && rt.exitPc == pc) {
        _rememberUnmappedLoad(pc);
      }
      return false;
    }
    cpu.finishCompiled(spent, rt.exitPc);
    return true;
  }

}
