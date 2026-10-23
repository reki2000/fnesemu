# Recompiler performance improvement guide

Optimize representative `runFrame` execution on the target native host. The useful objective is less host time for equivalent emulated work, not a larger installed block or a higher native percentage by itself. Use the [architecture](../../ARCHITECTURE.md) for responsibilities, [frontend contracts](FRONTENDS.md) for implementation rules, and [pending work](ROADMAP.md) for proposals.

## Improvement cycle

1. Establish a native AOT baseline with deterministic input and a specified scene, warmup and measured frame interval. Measure host CPU cost before assuming guest CPU execution dominates rendering, audio or device work.
2. Collect a separate dynamic exit profile. Rank actual native returns by count, zero-work count, consumed cycles and entry budget; locate the hot PCs and instructions. Determine whether the constraint is instruction coverage, device synchronization, code protection, idle detection, missing links or a short deadline.
3. Select one small change with an explicit hypothesis. Examples are skipping a provably empty FFI entry, linking an existing continuation, handling a proven side-effect-free register read inside native execution, or implementing a frequently interpreted opcode. Change scheduling separately from instruction lowering and runtime refactoring.
4. For specialization, observe cold execution before compiling. Repeated observations select likely constants or regions; guards and invalidation establish safety. Keep a generic path for unstable sites and bound profile storage and variants.
5. Compare uninstrumented variants over equivalent frames, check execution and media output, and report both elapsed time and native execution metrics. Retain the change only if the reproducible benefit justifies its code, compilation and maintenance costs.

Increasing a translation limit cannot remove MMIO, unsupported-slot or scheduler exits. A typical target such as 20–50 guest instructions is a hypothesis, not a correctness rule or a substitute for measuring useful work per native invocation. Native links can amortize many short blocks within one invocation without enlarging each block.

## Observe first, specialize with guards

A single-pass decoder can combine ordinary instruction semantics with entry-value observations; a tracing engine is not required. A configurable threshold such as ten entries avoids compiling the coldest code and supplies several observations, but does not prove a pointer will always address RAM. Distinguish entry samples from complete interpreted-block or per-access traces.

Profile by instruction address, code version and relevant mode. Track whether the effective address, region, alignment and entry-register-relative interval are stable. A function such as a memory copier can use the same instruction address for RAM and devices on different calls. Repeated code loading and private-cache changes invalidate instruction assumptions independently of data-address stability.

Generate checks before effects for every assumption not established statically: address interval, alignment, alias/mapping lifetime and code/literal version. Hoist or fold only checks those facts make redundant. Stores sharing a protected code page need a separate proof that they cannot modify executing or upcoming instructions; stable RAM classification alone is insufficient. Entry code guards cannot repair a write that already changed the active native block.

On failure, restore the precise guest instruction boundary, registers, delay state and elapsed clocks, then use ordinary CPU execution. Limit variants and switch repeatedly unstable blocks to generic code. Preserve CPU, DMA, other-CPU and host write handling, all aliases and remapping. Removing code guards requires an independently complete invalidation design.

This is value profiling followed by speculative specialization; recording the executed control-flow path additionally makes it tracing JIT. Moving necessary guards before proven-safe uses is guard hoisting/check elimination. See [Value Profiling and Optimization](https://cseweb.ucsd.edu/~calder/papers/JILP-99-VP.pdf), [Trace-based Just-in-Time Type Specialization](https://mozilla.github.io/pdf.js/web/compressed.tracemonkey-pldi-09.pdf), and [Correctness of Speculative Optimizations with Dynamic Deoptimization](https://arxiv.org/abs/1711.03050).

## Diagnose native returns

An invocation starts at an actual Dart-to-native FFI entry and ends when native execution returns to Dart. The tools also call this unit a native entry, return or exit; distinguish it from an individual block. It may execute several linked blocks or no guest instructions. A compiled block, a native invocation and an interpreted instruction are different units.

| Observation | Investigation |
| --- | --- |
| Zero-work budget returns | Check why the host enters with a zero or negative budget; blocks entered with a positive budget always run |
| Short positive spans despite ample budget | Inspect the exact exit instruction, branch slot, fault address and mapping |
| Device/unmapped returns | Determine hardware semantics in the adapter; distinguish ordinary unmapped memory from real MMIO before adding a mapping or helper |
| Protected/read-only returns | Distinguish ROM, active code and ordinary data sharing a protected page; audit aliases and writes |
| Stop/idle returns | Preserve existing multi-block idle recognition and wake paths; unchanged registers and no stores alone do not prove an idle loop |
| Unsupported instructions | Implement measured hot operations or batch fallback safely; static opcode coverage alone does not establish benefit |
| Missing links | Inspect hotness, invalidation and successor compilation; avoid repeatedly probing known unsupported PCs |
| Frequent scheduler entries | Count useful wakeups and next-device deadlines before optimizing device methods; retain IRQ, communication and timer ordering |

Read helpers must preserve live values and the host ABI. Only the adapter can establish that a register read is safe without synchronization. A guarded pointer literal can be constant while the value read through that pointer must remain live. Helpers can extend native coverage yet lose throughput through callback costs.

## Required interval metrics

Exclude warmup from every delta and state the unit and denominator explicitly.

| JSON field or statistic | Definition |
| --- | --- |
| `msPerFrame` | Elapsed core execution and `imageBuffer()` time divided by measured frames; document any audio callback work included |
| `cpuMsPerFrame` | Process CPU time per frame when supported; distinguishes execution work from descheduling |
| `cpuClocks` | Total guest CPU clocks, including idle/sleep; sum both CPUs for SS/32x |
| `jitClocks` | Guest clocks actually consumed by the compiled backend |
| `jitCyclePercent` | `100 * jitClocks / cpuClocks`; null when no CPU clocks elapsed |
| `nativeEntries` | Actual FFI entries, including zero-work returns; excludes missing-block lookups before entry |
| `meanNativeExitCycles` | `jitClocks / nativeEntries`; null when there were no entries; includes zero-work returns |
| Executed block mean/p90 | Execution-weighted consumed cycles of individual positive block spans, including partial side exits; excludes fully refunded entries |

The ordinary native-entry counter is one integer increment per compiled-code invocation (an FFI call on native hosts, a dispatcher call on Wasm) and requires no per-block callback. Reference IR execution does not count entries. The current tools report cycles per invocation and per block, not guest instruction counts or blocks per invocation. Collect those separately if needed; do not relabel cycles as instructions. An installation histogram describes compiled code, not dynamic execution.

Guest-clock coverage is neither host CPU-time share nor a speedup estimate. If idle dominates, additionally report idle/native/interpreted clocks and an explicitly named idle-excluded native ratio; retain the original denominator for comparisons. Mean cycles can rise solely because zero-work calls disappear, so also report zero-work rate and positive-span distributions. Entry counts per second, entry-budget distributions, compile time, generated bytes, profile memory and GC are useful follow-up metrics when the hypothesis requires them.

### Exit diagnostics

`core_headless bench --profile-exits` attaches after warmup without clearing compiled blocks. `nativeExits` reports each runtime in CPU order, including master/slave for SH-2. It groups count, cycles, zero-work returns and mean entry budget by cause and by entry PC, exit PC, mapped exit opcode and fault page. At most 4096 sites are retained per runtime and the top 40 are printed; totals include overflow and must equal the interval native-entry/JIT-clock deltas.

`unmappedOrDevice` and `protectedOrReadOnly` describe current mappings rather than hardware proofs. `stopYield`, `codeGuard`, `linkMiss`, SH-2 `profileGuard` and `unsupportedInstructionOrSlot` identify other boundaries. Opcode bytes are read only from existing mappings, without MMIO, and separate code versions with different exit instructions. Sites include the first exact fault address and varying address bits where available. A temporary `0xffffffff` fault sentinel means that exact fault address is reported as unknown. This diagnostic aggregates synchronously at native return, perturbs throughput and does not observe individual linked blocks.

### Block diagnostics

`--profile-blocks` clears installed blocks after warmup to add entry callbacks. Remaining-budget differences and refunds determine positive consumed spans; the histogram cycle sum must equal the compiled-clock delta. Mean and p90 are weighted by execution count, not by cycles. Clearing code can change early fallback and coverage relative to a warm-cache run. Collect this diagnostic separately from both exit profiling and uninstrumented throughput.

## Measurement and acceptance

Use native AOT for native AOT conclusions. Prefer variants in one executable, rotate or reverse timed batches, pin the same CPU where practical and hold the shared benchmark lock. Keep builds, tests and other emulator runs outside timed intervals. Use the same input, warmup, frame ranges, boot options and disc settling. Repeat enough equivalent intervals to identify drift; report scene dependence and inconclusive results rather than averaging unlike workloads.

Exclude capture/state encoding from timing and disclose any timed hashing or PCM collection. Report compilation/startup separately from steady state. GUI FPS, headless frame time, synthetic arithmetic and browser/Wasm throughput answer different questions. QEMU is useful for correctness, not target-host speed. Use AOT sampling with resolved call chains, an appropriate core-only denominator and checked sample loss for host attribution; sparse stopwatch durations must not be extrapolated into CPU shares.

Validate the CPU interpreter, reference IR and compiled path for instruction semantics, full-width values, endianness, high register pressure, callbacks, snapshots, budgets and overshoot, modes, exceptions and code writes through all aliases. For game acceptance, follow the [acceptance rule](../../ARCHITECTURE.md#performance-evidence): the game must not break, and exact screen, audio or state equality with the previous build is not required. Replay input and check that the game progresses, responds to input, and shows intact graphics and audio at several points; a single final screenshot is insufficient. Record differences as diagnostic evidence with their scope. Preserve fallback and test device activation, deadlines, IRQ ordering and inter-CPU communication separately when changing scheduling.

### Changing a default

Enabling a JIT by default, keeping it enabled, or changing a CPU quantum needs evidence beyond a single fixture. Compare the CPU interpreter and the proposed default in one executable for at least two game scenes with different workloads. The proposed default must not be slower in any measured scene, and the reported gain must exceed the variation between repeated batches. Replay input for each scene and confirm under the acceptance rule that the game does not break. Update the [current JIT status](../fnesemu_core/tool/README.md#current-jit-status) to describe the selected default and supported options.

## Evidence and complexity budget

A change to instruction coverage, helper placement or dispatch policy can alter compiled entry counts without reducing host execution time. Evaluate useful work per invocation, compilation cost, generated bytes and maintenance cost together. Additional native coverage is insufficient justification for a change that reduces throughput or weakens synchronization.

Keep speculative optimizations independently selectable and remove prototypes whose benefit does not justify their complexity. Preserve instruction guards and CPU fallback until replacement behavior has its own complete correctness contract. Synthetic backend measurements are described in [PERFORMANCE.md](PERFORMANCE.md), and pending implementation work in [ROADMAP.md](ROADMAP.md).
