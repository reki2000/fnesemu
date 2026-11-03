import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

// The skeleton every core's JIT adapter shares: a runtime, the driver that
// translates and runs its blocks, and the suspend, compiled-clock, reset
// and dispose plumbing around them. Each adapter supplies its own driver,
// translator, fetch, code memory and guest-state views, and adds the run
// loop of its CPU.

/// A core's JIT adapter over one runtime.
abstract class JitAdapter {
  JitAdapter(this.rt, this.native, {int? compileThreshold})
      : compileThreshold = compileThreshold ?? rt.compileThreshold;

  /// The runtime that owns the compiled code, the context and the guest memory this adapter allocated from it.
  final JitRuntime rt;

  /// Whether this runtime executes compiled host code rather than reference IR.
  final bool native;

  /// Blocks are translated once they would have run this often; until then the interpreter runs them, as most code runs only a few times.
  final int compileThreshold;

  /// Runs the CPU interpreter instead while keeping the compiled blocks and the shared guest state.
  bool suspended = false;

  /// The driver that translates and runs the blocks of this adapter.
  JitDriver get driver;

  /// Guest clocks executed by compiled code, excluding interpreter fallbacks.
  int get compiledClocks => native ? driver.executedClocks : 0;

  /// Drops every compiled block; guest state stays.
  void reset() => driver.reset();

  /// Frees the runtime with its memory; nothing runs afterwards.
  void dispose() => rt.dispose();
}
