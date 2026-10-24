import 'package:fnesemu_core/src/core.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';

Iterable<JitRuntime> jitRuntimes(Core core) =>
    core.jitDiagnostics.map((diagnostics) => diagnostics.rt);

/// Guest-clock coverage and native round-trip size over one measured interval.
final class JitCounters {
  final int cpuClocks, jitClocks, nativeEntries;
  JitCounters(Core core)
      : cpuClocks = core.cpuClocks,
        jitClocks = core.jitClocks,
        nativeEntries =
            jitRuntimes(core).fold(0, (total, rt) => total + rt.nativeEntries);

  Map<String, Object?> since(JitCounters start) {
    final cpu = cpuClocks - start.cpuClocks;
    final native = jitClocks - start.jitClocks;
    final entries = nativeEntries - start.nativeEntries;
    return {
      'cpuClocks': cpu,
      'jitClocks': native,
      'jitCyclePercent': cpu > 0 ? 100 * native / cpu : null,
      'nativeEntries': entries,
      'meanNativeExitCycles': entries > 0 ? native / entries : null,
    };
  }
}
