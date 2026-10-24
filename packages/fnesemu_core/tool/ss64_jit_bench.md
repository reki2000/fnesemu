# SS execution configuration

SS uses a default 64-clock CPU quantum and opt-in native compilation through `--jit on` or `Ss(jit: true)`. CPU slices are clipped at scanline boundaries; the last block may overshoot its deadline. Master/slave ordering and on-chip updates remain adapter-owned.

## Optional native paths

The shared SH-2 frontend supports MAC.L/MAC.W, guarded FTCSR context reads and native checks for unchanged pure self-loops. `jitMacLong`, `jitMacWord`, `jitFtcsr` and `jitIdleGuards` select comparison variants without replacing device scheduling. Multi-block waits retain the CPU detector and its wake path.

The no-store condition alone is insufficient for an idle proof. Native checks compare relevant entry/final guest state, exclude callbacks and require adapter-established memory/device stability. Idle-skipped clocks are excluded from compiled execution totals.

## Running comparisons

Build `tool/core_headless.dart` with `dart build cli` and keep `bundle/lib`. Use `core_headless bench ss <media...> --frame-runner --jit on|off --ss-slice-clocks N --fixed-clock` with identical input and interval settings. Collect return diagnostics separately with `--profile-exits`.

Tests cover unchanged/changing loops, wakeups, device ticks, memory changes, callback exclusion, saturation, aliased operands, two-read exits and branch-slot replay. Timing and inter-CPU synchronization remain distinct from instruction-level equivalence.

See the [SH-2 configuration](sh2_jit_bench.md), [architecture](../../../ARCHITECTURE.md#sh-2-state-and-timing-boundaries) and [measurement guide](../../mp_jit_recompiler/OPTIMIZATION.md).
