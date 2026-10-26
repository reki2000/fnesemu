# Performance guide

Optimize representative `runFrame` execution on the target native host. The useful objective is less host time for equivalent emulated work, not a larger installed block or a higher native percentage by itself. The metric definitions and diagnostics are in [Diagnostics](diagnostics.md), the implementation rules in the [frontend guide](frontends.md), and pending proposals in the [roadmap](roadmap.md). General Dart AOT guidance is in `packages/fnesemu_core/tool/dart_aot_tips.md`, and sampling requirements in `packages/fnesemu_core/tool/cpu_profile_notes.md`.

## Improvement cycle

1. Establish a native AOT baseline with deterministic input and a specified scene, warmup and measured frame interval. Measure host CPU cost before assuming guest CPU execution dominates rendering, audio or device work.
2. Collect a separate dynamic exit profile. Rank actual native returns by count, zero-work count, consumed cycles and entry budget, and locate the hot PCs and instructions. Determine whether the constraint is instruction coverage, device synchronization, code protection, idle detection, missing links or a short deadline.
3. Select one small change with an explicit hypothesis. Examples are skipping a provably empty FFI entry, linking an existing continuation, handling a proven side-effect-free register read inside native execution, or implementing a frequently interpreted opcode. Change scheduling separately from instruction lowering and runtime refactoring.
4. For specialization, observe cold execution before compiling. Repeated observations select likely constants or regions, and guards and invalidation establish safety. Keep a generic path for unstable sites and bound profile storage and variants.
5. Compare uninstrumented variants over equivalent frames, check execution and media output, and report both elapsed time and native execution metrics. Keep the change only if the reproducible benefit justifies its code, compilation and maintenance costs.

A native entry is cheap: removing a third of them by translating more instructions did not change host time measurably on a 3D scene. Translation and installation work, by contrast, showed up directly, so check `repeatInstallsAtRetainedSites` in the compilation statistics before looking at generated code.

Increasing a translation limit cannot remove MMIO, unsupported-slot or scheduler exits. A target such as 20-50 guest instructions per block is a hypothesis, not a correctness rule or a substitute for measuring useful work per native invocation. Native links can amortize many short blocks within one invocation without enlarging each block.

## Observe first, specialize with guards

A single-pass decoder can combine ordinary instruction semantics with entry-value observations; a tracing engine is not required. A threshold such as ten entries avoids compiling the coldest code and supplies several observations, but does not prove a pointer will always address RAM. Distinguish entry samples from complete interpreted-block or per-access traces.

Profile by instruction address, code version and relevant mode. Track whether the effective address, region, alignment and entry-register-relative interval are stable. A function such as a memory copier can use the same instruction address for RAM and devices on different calls. Repeated code loading and private-cache changes invalidate instruction assumptions independently of data-address stability.

Generate checks before effects for every assumption not established statically: address interval, alignment, alias and mapping lifetime, and code and literal version. Hoist or fold only the checks that those facts make redundant. Stores sharing a protected code page need a separate proof that they cannot modify executing or upcoming instructions; stable RAM classification alone is insufficient.

On failure, restore the precise guest instruction boundary, registers, delay state and elapsed clocks, then use ordinary CPU execution. Limit variants and switch repeatedly unstable blocks to generic code. Preserve CPU, DMA, other-CPU and host write handling, all aliases and remapping. Removing code guards requires an independently complete invalidation design.

This is value profiling followed by speculative specialization. Recording the executed control-flow path as well would make it a tracing JIT, and moving necessary guards before proven-safe uses is guard hoisting. See [Value Profiling and Optimization](https://cseweb.ucsd.edu/~calder/papers/JILP-99-VP.pdf), [Trace-based Just-in-Time Type Specialization](https://mozilla.github.io/pdf.js/web/compressed.tracemonkey-pldi-09.pdf) and [Correctness of Speculative Optimizations with Dynamic Deoptimization](https://arxiv.org/abs/1711.03050).

## Measurement and acceptance

Use native AOT for native AOT conclusions. Prefer variants in one executable, rotate or reverse timed batches, pin the same CPU where practical and hold the shared benchmark lock. Keep builds, tests and other emulator runs outside timed intervals. Use the same input, warmup, frame ranges, boot options and disc settling. Repeat enough equivalent intervals to identify drift, and report scene dependence and inconclusive results rather than averaging unlike workloads.

Exclude capture and state encoding from timing and disclose any timed hashing or PCM collection. Report compilation and startup separately from steady state. GUI FPS, headless frame time, synthetic arithmetic and browser or Wasm throughput answer different questions. QEMU is useful for correctness, not target-host speed. Use AOT sampling with resolved call chains, an appropriate core-only denominator and checked sample loss for host attribution. Sparse stopwatch durations must not be extrapolated into CPU shares.

Validate the CPU interpreter, reference IR and compiled path for instruction semantics, full-width values, endianness, high register pressure, callbacks, snapshots, budgets and overshoot, modes, exceptions and code writes through all aliases. For game acceptance, follow the [acceptance rule](../../../ARCHITECTURE.md#performance-evidence): the game must not break, and exact screen, audio or state equality with the previous build is not required. Replay input and check that the game progresses, responds to input, and shows intact graphics and audio at several points; a single final screenshot is insufficient. Record differences as diagnostic evidence with their scope. Keep fallback, and test device activation, deadlines, IRQ ordering and inter-CPU communication separately when changing scheduling.

### Changing a default

Enabling a JIT by default, keeping it enabled, or changing a CPU quantum needs evidence beyond a single fixture. Compare the CPU interpreter and the proposed default in one executable for at least two game scenes with different workloads. The proposed default must not be slower in any measured scene, and the reported gain must exceed the variation between repeated batches. Replay input for each scene and confirm under the acceptance rule that the game does not break. Update the [current status](cores.md#current-status) to describe the selected default and supported options.

## Evidence and complexity budget

A change to instruction coverage, helper placement or dispatch policy can alter compiled entry counts without reducing host execution time. Evaluate useful work per invocation, compilation cost, generated bytes and maintenance cost together. Additional native coverage is insufficient justification for a change that reduces throughput or weakens synchronization.

Keep speculative optimizations independently selectable and remove prototypes whose benefit does not justify their complexity. Keep instruction guards and CPU fallback until the replacement behavior has its own complete correctness contract.

## Synthetic x64 measurements

This is a historical record of the backend work that added immediate operands, block-local register allocation and i32 IR simplification. It was measured with Dart 3.13 AOT on Linux x64 under WSL2. Timed processes were pinned to one logical CPU and serialized with the shared benchmark lock. GUI FPS is not used.

The instruction sequence comes from `packages/fnesemu_core/tool/ps_jit_bench.dart`, with 30,000 outer iterations. Only the native backend is measured, with compile threshold 1. Each process executes four identical runs without clearing the compiled cache and the first is excluded. Five process pairs alternate version order, giving 15 warm observations per version and slice. The times are elapsed wall times of the whole loop, not frame times.

| CPU slice (guest clocks) | Before (ms) | After (ms) | Time reduction |
| ---: | ---: | ---: | ---: |
| 100 | 279.417 | 228.895 | 18.1% |
| 1,000 | 161.176 | 108.929 | 32.4% |
| 100,000 | 134.112 | 87.258 | 34.9% |

Checksums and emulated clocks match between versions. Slice lengths change block overshoot and the cost of returning to Dart, and the results do not predict whole-emulator speedup.

A 31-instruction IR fixture that chains eight add, xor and shift triples reduces to 29 IR instructions, and its x64 code shrinks from 470 to 202 bytes. This is one fixture, not an aggregate code size. Median generation time rose from 3.3 to 17.4 microseconds per block, so the demonstrated benefit is faster repeated execution and smaller code. Revisit this tradeoff for workloads dominated by cold or frequently replaced code.

Later changes sped up the compile path and replaced generic maps in the driver and native block table with `IntMap`; see `packages/fnesemu_core/tool/jit_compile_bench.dart` for the compile-path benchmark.
