# Pending recompiler improvements

This document records queued proposals and explicitly identified implementation steps, not authorization to change scheduling. Measure each behavior change separately from structural refactoring.

Responsibilities are defined in the [architecture](../../ARCHITECTURE.md); implementation contracts are in [FRONTENDS.md](FRONTENDS.md), and the improvement workflow and metric definitions are in [OPTIMIZATION.md](OPTIMIZATION.md). This file contains pending work rather than the implemented-feature specification.

## Shared mechanisms

1. Let the adapter report interpreter, DMA and other host writes through a proposed `notifyWrite(address, length)` API. First preserve existing instruction guards and behavior; removing guards is a separate change that requires auditing every write path, exposed mutable buffer and remapping operation. Define ownership when multiple runtimes share a buffer.
2. Before changing `JitDriver` cache representations or moving its counters into native code, measure allocation and lookup costs.
3. Add optional region descriptions after the above refactoring. A candidate description contains a match mask/value, offset mask, buffer offset/length, access permissions and priority. Backends can emit a direct-buffer fast path with page-table fallback. Region hints on individual loads can narrow the candidates. The adapter supplies hardware knowledge; the runtime supplies generic checks. Start with read-only fast-path experiments and mapped RAM reads before code-protected writes. Validate alignment, bounds, aliases, banking and mapping lifetime. Disabling optimization hints must preserve mapping semantics; the reference executor may ignore hints.
4. Consider per-region callbacks with an explicit consumed-clock/state contract. The adapter decides whether an access can use a callback or must exit for synchronization. The callback ABI and compiler must preserve all live state across the call.
5. Extend optional native diagnostics only when needed by a measured hypothesis. Consider instruction counts or blocks per invocation if cycles cannot answer the question. Measure instrumentation overhead separately from throughput.

Direct trampoline lookup and a smaller result ABI are later dispatch experiments. Leaf FFI execution requires both absence of callbacks and an acceptable bound on the native call duration; callback absence alone is insufficient. Keep portable behavior and platform ABI rules in the runtime.

## CPU frontend candidates

- N64: prioritize remaining hot floating-point conversions/comparisons; preserve rounding/control state and nonfinite behavior. HI/LO with multiply/divide coverage, unaligned merge accesses and other floating-point operations remain workload-dependent candidates. Batch adjacent CPU fallback instructions where safe, preserving interpreter idle skipping, interrupts and device deadlines. Profile demanding scenes before attributing the remaining host time to HLE.
- SH-2: Expand measured hot coverage such as procedure-register stack operations, carry arithmetic, divide steps and full multiply/MAC operations. Keep exact exceptions, memory order and clock accounting.
- Idle recognition: express register/state comparisons and exits in IR while retaining multi-block loop detection. The adapter must establish that observed memory/devices remain stable and that reads have no relevant side effects during the proposed skip. No stores and unchanged registers alone are not a universal idle proof.
- Specialization: frontend-owned mode/register tags or guarded literals can enable base-register and PC-relative constant folding. Mapping stability and literal/code invalidation remain explicit dependencies.
- Larger traces: frontend-owned fall-through chaining and limited branch/function inlining must preserve CPU-specific delay slots and snapshots. Establish entry amortization and scheduler capacity before targeting a nominal instruction count.

## Interpreter-guided memory specialization

Remaining candidates are per-access region/range observations, entry-register-relative intervals and guarded data accesses sharing code pages. A runtime fast path must preserve alignment, bounds, aliases and code protection while distinguishing proven data from executable bytes. Unknown pointer loads and variable offsets retain ordinary checks.

Keep code-version validity separate from data-region stability. Entry guards remain until every CPU, DMA, other-CPU and host write, mutable buffer and remapping path has a complete invalidation contract. New code installation can invalidate a data-only assumption. These changes do not require introducing a tracing/loop framework.

## Core adapter candidates

- SS: the default CPU quantum is 64 clocks and native execution is opt-in. Investigate timer/MMIO/inter-CPU synchronization as accuracy work. Profile fallback, mapping and dispatch before changing idle behavior or CPU quanta. Preserve on-chip events and master/slave communication.
- 32X: Private-cache compilation remains excluded; revisit it only with explicit code/data protection and mapping contracts. Explore stable cartridge ROM windows with bank-aware invalidation. MMIO exits alone do not synchronize shared-RAM polling; validate communication before using longer blocks.
- N64 diagnostics/display: report idle/native/interpreted guest clocks separately. Changing the public JIT percentage denominator needs an explicit UI/API decision. These ratios do not establish host CPU-time shares or speedup ceilings.

## Order and acceptance

Select the next change from measurements rather than from this list's order. For each core, first establish host CPU cost, then profile native returns and remove the most frequent avoidable boundary.

Pending measurements:

- SS: native execution is opt-in. Profile host costs in CPU fallback, native guards/mapping and dispatch before proposing another default change. Record host-time evidence rather than inferring speed from coverage.
- 32X: recheck interpreter/native execution across varied workloads before changing CPU quantum or the enabled default.
- N64 and SS: collect AOT host CPU samples with resolved call chains and a core-only denominator. Separate idle/native/interpreted guest clocks from host CPU time.
- ARM64: all throughput conclusions come from x64. The ARM64 backend keeps SSA values in stack slots, so measure on a real ARM64 host before assuming x64 gains carry over, and consider host register allocation there.

The remaining structural candidates are the `notifyWrite` contract, then region fast paths. Preserve behavior and guards during refactoring and test each subsequent optimization independently. Do not complete a large abstraction before a smaller proven improvement.

Apply the [measurement and acceptance protocol](OPTIMIZATION.md#measurement-and-acceptance) to each change. Avoid generic API surface solely for a speculative optimization.
