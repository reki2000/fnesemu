import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

import 'translator.dart';

/// State and cache for one SH-2. The owning CPU supplies side-effect-free fetch
/// and maps ordinary RAM/ROM. Other reads return to the CPU unless the adapter
/// explicitly registers a helper for native continuation.
final class Sh2Jit {
  static const idleBranchDistance = Sh2Translator.idleBranchDistance;
  final JitRuntime rt;
  late final diagnostics = JitDiagnostics(rt,
      instructionBytes: 2, byteOrder: Endian.big, guestExit: _diagnosticExit);

  String? _diagnosticExit(int pc, int reason) {
    if (reason == Sh2Translator.profileMiss) return 'profileGuard';
    if (reason == Sh2Translator.idleDetected) return 'idleSkip';
    if (reason == Sh2Translator.interpret) {
      final opcode = diagnostics.opcodeAt(pc);
      if (opcode != null &&
          !Sh2Translator.supported(opcode,
              macLong: macLong, macWord: macWord)) {
        return 'unsupportedInstructionOrSlot';
      }
    }
    return null;
  }

  final bool native;

  /// Number of cold-entry samples required before compilation.
  final int compileThreshold;
  final int maxInstructions;
  final bool alignMemory;

  /// Select guarded address constants from stable cold-entry registers.
  final bool profileMemory;
  final bool macLong;

  /// Enables MAC.W translation. See [Sh2Translator.macWord].
  final bool macWord;
  final bool idleGuards;
  bool idleDetected = false;
  final _readRegisters = <(bool Function(int, int), int)>[];

  /// Yield short back edges without stores to an adapter's idle detector.
  final bool stopOnNoStore;
  late final regs = Uint32List.view(
      rt.ctx.buffer, rt.ctx.offsetInBytes + Sh2Translator.regs * 4, 16);
  late final state = Uint32List.view(
      rt.ctx.buffer, rt.ctx.offsetInBytes + Sh2Translator.sr * 4, 8);
  late Sh2Translator _translator;
  late int? Function(int) _fetch;
  late final _code = JitCodeMemory(rt);
  late final _driver = JitDriver(rt,
      translate: _translate,
      codeWord: (pc) => _fetch(pc),
      codeMemory: _code,
      threshold: compileThreshold,
      capacity: _profiles.capacity,
      prepareFirst: true,
      maxDispatches: 64,
      continueAfterExit: (reason) =>
          reason == JitReason.invalid ||
          reason == JitReason.miss &&
              rt.ctx[JitCtx.stop] == 0 &&
              rt.ctx[JitCtx.budget].toSigned(32) > 0)
    ..onObserve = (pc, tag) {
      _profiles
          .obtain(pc, tag, _fetch(pc), () => JitEntrySamples(16))
          .observe(profileMemory ? regs : null);
    }
    ..onInstall = (block) {
      _profiles.remove(block.pc, block.tag);
    }
    ..onInvalidate = (pc, tag) {
      _profiles.remove(pc, tag);
    }
    ..onClear = _profiles.clear;
  final _profiles = JitEntryProfiles<JitEntrySamples>();
  final _readHelpers = <(bool Function(int, int), int)>[];
  bool _foldHelperLiterals = false;

  /// Runs the CPU interpreter instead while keeping compiled blocks and the
  /// shared guest state, for tools that warm up with compiled code.
  bool suspended = false;
  int get compiledClocks => native ? _driver.executedClocks : 0;
  Sh2Jit._(
      this.rt,
      this.native,
      this.compileThreshold,
      this.maxInstructions,
      this.alignMemory,
      this.stopOnNoStore,
      this.profileMemory,
      this.macLong,
      this.macWord,
      this.idleGuards);

  static Sh2Jit? create(
      {bool native = true,
      int? compileThreshold,
      int maxInstructions = 24,
      int addrMask = 0x07ffffff,
      bool alignMemory = true,
      bool profileMemory = const bool.fromEnvironment('SH2_JIT_PROFILE_MEMORY',
          defaultValue: true),
      bool macLong = false,
      bool macWord = false,
      bool idleGuards = false,
      bool stopOnNoStore = true}) {
    final rt = native
        ? JitRuntime.native(
            ctxWords: Sh2Translator.ctxWords,
            addrMask: addrMask,
            read: (_, __) => throw StateError('Unmapped SH-2 read'),
            write: (_, __, ___) => throw StateError('Unmapped SH-2 write'))
        : JitRuntime.interpreter(
            ctxWords: Sh2Translator.ctxWords,
            addrMask: addrMask,
            read: (_, __) => throw StateError('Unmapped SH-2 read'),
            write: (_, __, ___) => throw StateError('Unmapped SH-2 write'));
    if (rt == null) return null;
    return Sh2Jit._(
        rt,
        native,
        compileThreshold ??
            (native
                ? const int.fromEnvironment('SH2_JIT_COMPILE_THRESHOLD',
                    defaultValue: 10)
                : 1),
        maxInstructions,
        alignMemory,
        stopOnNoStore,
        profileMemory,
        macLong,
        macWord,
        idleGuards);
  }

  void attach(int? Function(int) fetch) {
    _fetch = (address) {
      final page = (address & rt.addrMask) >>> rt.pageShift;
      return rt.readPages[page] == null ? null : fetch(address);
    };
    _translator = Sh2Translator(
        fetch: _fetch,
        protect: _code.protect,
        maxInstructions: maxInstructions,
        alignMemory: alignMemory,
        stopOnNoStore: stopOnNoStore,
        macLong: macLong,
        macWord: macWord,
        idleGuards: idleGuards,
        readContextFor: _readContextFor,
        readHelperFor: _readHelperFor);
  }

  /// Declares adapter-approved reads that may continue within a native batch.
  /// The adapter must preserve access semantics and the existing CPU deadline.
  /// Configure before execution; registration clears compiled state.
  /// Literal-folding helpers must not modify mapped guest memory.
  void addReadHelper(bool Function(int address, int size) accepts,
      int Function(int address, int size) read,
      {bool guardedLiterals = false}) {
    final id = rt.addHelper((address, size, _) => read(address, size));
    _readHelpers.add((accepts, id));
    _foldHelperLiterals |= guardedLiterals;
    reset();
  }

  /// Declares a side-effect-free register read from adapter-maintained context.
  /// The adapter refreshes the word before execution and after CPU-side effects.
  Uint32List addReadRegister(bool Function(int address, int size) accepts) {
    if (_readRegisters.length == Sh2Translator.readRegisterCount) {
      throw StateError('SH-2 read-register context is full');
    }
    final word = Sh2Translator.readRegisters + _readRegisters.length;
    _readRegisters.add((accepts, word));
    _foldHelperLiterals = true;
    reset();
    return Uint32List.view(rt.ctx.buffer, rt.ctx.offsetInBytes + word * 4, 1);
  }

  int? _readContextFor(int address, int size) {
    for (final (accepts, word) in _readRegisters) {
      if (accepts(address, size)) return word;
    }
    return null;
  }

  int? _readHelperFor(int address, int size) {
    for (final (accepts, helper) in _readHelpers) {
      if (accepts(address, size)) return helper;
    }
    return null;
  }

  void map(int at, int size, Uint8List buffer,
      {int offset = 0, bool writable = true, JitRuntime? owner}) {
    if (owner != null && owner != rt) rt.shareBuffer(owner, buffer);
    _code.map(at, size, buffer, offset: offset, writable: writable);
  }

  void reset() {
    _driver.reset();
    rt.ctx[JitCtx.stop] = 0;
  }

  /// Source of the last native edge requesting the adapter's idle check.
  int? get idleCheckPc =>
      rt.ctx[JitCtx.stop] == 0 ? null : rt.ctx[Sh2Translator.idleFromPc];

  /// Returns the next PC and elapsed clocks, or null when CPU execution is due.
  (int, int)? run(int pc, int budget) {
    idleDetected = false;
    if (budget <= 0 || pc.isOdd) return null;
    if (_driver.isFallback(pc, 0)) return null;
    final reason = _driver.runBudgeted(pc, 0, budget);
    if (reason == Sh2Translator.idleDetected) {
      idleDetected = true;
    } else if (reason == Sh2Translator.profileMiss) {
      // Native links carry the failed block's entry PC in the exit tag.
      final at = rt.exitTag;
      _driver.invalidate(at, 0, warm: true);
      _profiles
          .obtain(at, 0, _fetch(at), () => JitEntrySamples(16))
          .disableSpecialization();
    }
    final elapsed = _driver.lastClocks;
    if (elapsed == 0) return null;
    return (rt.exitPc, elapsed);
  }

  IrBlock? _translate(int pc, int tag) {
    final profile = _profiles.lookup(pc, tag, _fetch(pc));
    final constants = <int, int>{};
    // Observations select candidates, never permission to bypass a guard.
    if (profileMemory && profile != null && profile.samples >= 2) {
      for (var n = 0; n < 16; n++) {
        final value = profile.stableValue(n);
        if (value != null &&
            ((value <= 0x3fffffff &&
                    (rt.readPages[(value & rt.addrMask) >>> rt.pageShift] !=
                            null ||
                        _readHelpers.isNotEmpty)) ||
                _readContextFor(value, 1) != null)) {
          constants[n] = value;
        }
      }
    }
    _translator.foldLiterals = _foldHelperLiterals;
    return _translator.translate(pc, memoryBases: constants);
  }

  void dispose() => rt.dispose();
}
