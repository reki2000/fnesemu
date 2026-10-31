import 'code_memory.dart';
import 'ir.dart';
import 'runtime.dart';

/// Shared dispatch, warmup and fallback policy for a core adapter.
///
/// [run] enters compiled code and keeps going while missing successors
/// become hot and translate. A missing block is translated once it has been
/// reached [threshold] times; until then the adapter executes it with its
/// interpreter. A block that does not translate is remembered with its code
/// word, so later entries go straight to the interpreter until that word
/// changes. Counters and the fallback cache are bounded by [capacity]
/// entries together and cleared when full.
///
/// The adapter keeps guest-specific policy: when to enter, how to translate,
/// the budget, interrupts, timing and interpreter execution.
final class JitDriver {
  final JitRuntime rt;
  final JitCodeMemory? _codeMemory;

  /// Guest clocks consumed by [runBudgeted], including reference IR execution.
  /// Adapters expose these as compiled clocks only for compiled runtimes.
  int get executedClocks => _executedClocks;
  int _executedClocks = 0;

  /// Guest clocks consumed by the latest [runBudgeted] call.
  int get lastClocks => _lastClocks;
  int _lastClocks = 0;

  /// Translates the block at (pc, tag), or returns null when it cannot.
  final IrBlock? Function(int pc, int tag) translate;

  /// The code word at pc whose change invalidates a fallback decision, or
  /// null when pc cannot hold translatable code.
  final int? Function(int pc) codeWord;

  final int threshold;
  final int capacity;

  /// Retranslates a block whose code guard failed at once instead of
  /// counting it as a new miss.
  final bool recompileInvalid;

  /// Prepare cold entries before entering the runtime, including successors.
  final bool prepareFirst;

  /// Bounds host dispatch retries, independently of the guest clock budget.
  final int? maxDispatches;

  /// Adapter policy for continuing after a runtime return.
  final bool Function(int reason)? continueAfterExit;

  /// Optional diagnostics: every runtime return, and every installed block.
  void Function(int reason, int pc)? onExit;
  void Function(IrBlock block)? onInstall;

  /// Cold-entry observations and lifecycle hooks for adapter-owned profiles.
  void Function(int pc, int tag)? onObserve;
  void Function(int pc, int tag)? onInvalidate;
  void Function()? onClear;

  // Keyed by pc | tag << 32.
  final _misses = <int, int>{};
  final _fallbacks = <int, int>{};

  JitDriver(
    this.rt, {
    required this.translate,
    required this.codeWord,
    JitCodeMemory? codeMemory,
    int? threshold,
    this.capacity = 1 << 16,
    this.recompileInvalid = false,
    this.prepareFirst = false,
    this.maxDispatches,
    this.continueAfterExit,
  }) : threshold = threshold ?? rt.compileThreshold,
       _codeMemory = codeMemory {
    if (codeMemory != null && !identical(codeMemory.rt, rt)) {
      throw ArgumentError('Code memory belongs to a different runtime');
    }
  }

  /// Starts a batch with a fresh budget and stop flag, returning its reason and recording consumed guest clocks in [lastClocks].
  /// The last block may overshoot the budget; the remaining context word is signed even though its storage is unsigned.
  /// Adapter state preparation and synchronization remain outside this method.
  int runBudgeted(int pc, int tag, int budget) {
    rt.ctx[JitCtx.budget] = budget;
    rt.ctx[JitCtx.stop] = 0;
    final reason = run(pc, tag);
    _lastClocks = budget - rt.ctx[JitCtx.budget].toSigned(32);
    _executedClocks += _lastClocks;
    return reason;
  }

  /// Drops compiled code, restores code-page mappings and forgets dispatch profiles and accounting.
  /// Guest registers, memory and helpers stay wired.
  void reset() {
    rt.clear();
    _codeMemory?.reset();
    clear();
    _executedClocks = 0;
    _lastClocks = 0;
  }

  /// Whether (pc, tag) failed to translate with its current code word.
  bool isFallback(int pc, int tag) {
    final word = _fallbacks[pc | tag << 32];
    final hit = word != null && word == codeWord(pc);
    if (hit) rt.compilationStats?.fallbackCacheHits++;
    return hit;
  }

  /// Runs compiled code from (pc, tag) and returns the last runtime reason.
  /// A miss means that the block at [JitRuntime.exitPc] is not hot yet or
  /// does not translate.
  int run(int pc, int tag) {
    var reason = JitReason.miss;
    for (
      var dispatch = 0;
      maxDispatches == null || dispatch < maxDispatches!;
      dispatch++
    ) {
      final stats = rt.compilationStats;
      final present = prepareFirst || stats != null ? rt.contains(pc, tag) : false;
      stats?.recordLookup(present);
      if (prepareFirst && !present) {
        rt.ctx[JitCtx.exitPc] = pc;
        rt.ctx[JitCtx.exitTag] = tag;
        if (!_hot(pc, tag) || !_compile(pc, tag)) return JitReason.miss;
      }
      reason = rt.run(pc, tag);
      pc = rt.exitPc;
      tag = rt.exitTag;
      onExit?.call(reason, pc);
      if (reason == JitReason.invalid) stats?.guardFailures++;
      if (continueAfterExit?.call(reason) == false) return reason;
      if (reason == JitReason.invalid) {
        invalidate(pc, tag);
        if (prepareFirst) continue;
        if (!recompileInvalid && !_hot(pc, tag)) return reason;
      } else if (reason != JitReason.miss) {
        return reason;
      } else if (prepareFirst) {
        continue;
      } else if (!_hot(pc, tag)) {
        return reason;
      }
      if (!_compile(pc, tag)) return reason;
    }
    return reason;
  }

  bool _compile(int pc, int tag) {
    final stats = rt.compilationStats;
    final block = stats == null ? translate(pc, tag) :
        stats.measureTranslation(pc, tag, () => translate(pc, tag));
    if (block == null) {
      final word = codeWord(pc);
      if (word != null) _fallbacks[pc | tag << 32] = word;
      return false;
    }
    rt.install(block);
    onInstall?.call(block);
    return true;
  }

  /// Invalidates a block and its observations. [warm] makes its next miss hot.
  void invalidate(int pc, int tag, {bool warm = false}) {
    rt.invalidate(pc, tag);
    final key = pc | tag << 32;
    _misses.remove(key);
    _fallbacks.remove(key);
    if (warm) _misses[key] = threshold - 1;
    onInvalidate?.call(pc, tag);
  }

  /// Counts a miss of (pc, tag); true once it should be translated.
  bool _hot(int pc, int tag) {
    final key = pc | tag << 32;
    final word = codeWord(pc);
    if (word == null) return false;
    if (_fallbacks[key] == word) {
      rt.compilationStats?.fallbackCacheHits++;
      return false;
    }
    if (_misses.length + _fallbacks.length >= capacity) {
      clear();
    }
    onObserve?.call(pc, tag);
    final seen = (_misses[key] ?? 0) + 1;
    if (seen < threshold) {
      _misses[key] = seen;
      return false;
    }
    _misses.remove(key);
    return true;
  }

  /// Forgets counters and fallbacks, for example after a reset.
  void clear() {
    rt.compilationStats?.dispatchProfileClears++;
    _misses.clear();
    _fallbacks.clear();
    onClear?.call();
  }
}
