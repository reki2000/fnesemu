# Adding a recompiler frontend

These guidelines come from the PS1 and N64 frontend work and the shared x64 backend experiments. Use them when adding another guest CPU or extending a backend. Package responsibilities remain defined in [the architecture](../../ARCHITECTURE.md).

## Execution and state contracts

- Optimize the normal `runFrame` path first, and establish its CPU cost with AOT sampling before extending instruction coverage. Keep instruction-based debugger stepping correct, but measure its performance separately. Preserve existing idle-loop skipping and device batching when introducing compiled execution.
- Define the interpreter/compiled boundary before lowering instructions: shared register and memory layout, mode-dependent block tags, clock accounting, pending pipeline state, and the exact state restored on an exit before effects. A delay-slot fault may require replaying the branch as well as the slot. Unsupported instructions and device accesses must remain correct through CPU fallback.
- Emit one lowering for every runtime; all backends support the same widths, byte orders and floating-point operations. Use native i64 values for a 64-bit guest. Make word truncation, sign extension, shift-count masks and context-word layout explicit, and use exact constants and a BigInt reference for wide arithmetic.

## Compilation and register allocation

- Start with the existing SSA representation and simple block-local allocation. Reduce avoidable construction work by reusing tracking arrays, retaining unchanged immutable instructions, sharing exit descriptors and creating precise snapshots only where needed. Measure lowering time, optimization/installation time and IR size separately; infer neither allocation counts nor GC cost from elapsed time alone.
- Audit register expansion against every emitter temporary, pinned runtime pointer and host ABI. Values live across callbacks and operands consumed during argument setup need explicit protection. Exercise high register pressure, mixed widths, helper calls and side-exit snapshots together; testing arithmetic results alone misses allocation errors.

## Guarded specialization

The frontend owns value assumptions and precise exits; the adapter owns memory-region and helper semantics. The runtime supplies generic IR, guards, mappings and invalidation primitives. See the [performance guide](OPTIMIZATION.md) for candidate selection, measurement and acceptance.

The current SH-2 implementation records R0-R15 at cold entries and compiles native blocks after ten entry samples by default. Its one-pass decoder selects stable first-use memory bases in mapped memory or an adapter-approved helper region. Registers already read or written in the block retain ordinary SSA values. A guard before the first specialized memory use checks the entry value before substitution. A miss restores precise state and identifies the source block even after native linking, disables its specialization and leaves the next compilation generic. Profiles are bounded to 4096 cold entries and cleared on reset and code-guard invalidation.

These are exact entry values, not full per-access traces or range proofs. Page-table checks, protected-page exits and instruction-word guards remain. `Sh2Jit.create(profileMemory: false)` or `SH2_JIT_PROFILE_MEMORY=false` selects the ordinary path; `compileThreshold` or `SH2_JIT_COMPILE_THRESHOLD` controls native warmup. Reference IR defaults to one sample unless explicitly overridden.

Adapter-approved read helpers can opt into guarded PC-relative pointer-literal folding. Only pointers into an approved helper region are folded; device values and arbitrary mutable literals are not. Aligned literal-word guards and protection of every writable alias cover the literal bytes. Helpers opting in must not modify mapped guest memory. A changed pointer must be revalidated, including when it changes to a side-effectful device. This optimization does not permit unchecked stores into mixed code/data pages.

Frontends do not check the budget themselves. The runtime enters a block only with a positive budget and the block then runs to its end or a side exit, so the last block may overshoot the deadline. Side exits refund only the unexecuted part of the block cost. Adapters detect device events by range over the elapsed clocks.

## Shared adapter execution

PS1, N64 and SH-2 use `JitDriver.runBudgeted(pc, tag, budget)` to initialize the batch budget and clear the stop flag, dispatch through warmup and fallback handling, and record elapsed guest clocks in `lastClocks` from the signed remaining-budget word. `executedClocks` accumulates this work for both compiled and reference IR runtimes; adapters expose it as native usage only when their runtime is compiled. Idle skipping and CPU fallback never enter this total. `run` remains the lower-level dispatch entry for callers managing their own context and accounting.

A driver can receive its runtime's `JitCodeMemory`. `reset` then drops runtime blocks, restores protected write mappings, clears warmup/fallback profiles through their lifecycle hooks, and resets batch accounting. Guest register views, memory mappings, buffers and registered helpers stay wired. `clear` only forgets dispatch profiles and preserves runtime blocks and accounting, including when bounded cold-entry caches fill.

The adapter still selects deadlines, prepares guest state and mode tags, synchronizes registers and PC after a batch, handles precise exits and exceptions, and decides which instructions the CPU executes. SH-2 specialization and idle exit reasons remain frontend/adapter policy. This consolidation does not change block costs, budget overshoot or CPU scheduling.

## Diagnostics

Each frontend supplies a `JitDiagnostics` descriptor with its runtime, instruction width, byte order and optional custom exit classification. Core adapters enumerate these descriptors through `CoreDebug.jitDiagnostics`; collection tools need no concrete-core type tests. `NativeExitStats` applies shared runtime/mapping classification and bounded site aggregation. Instruction inspection uses existing read mappings only, respects buffer offsets and alignment, and never invokes bus callbacks.

Frontend exit classification must use the active translation options. An instruction enabled by an optional lowering must not be reported as unsupported merely because the decoder's default settings disable it. Diagnostics remain optional and separate from throughput measurements.

## Validation

Exercise CPU interpretation, reference IR and native execution, including unsupported capability paths, both widths and byte orders, callbacks under register pressure, precise exits, code/literal writes and aliases. Keep the CPU interpreter as an oracle and unsupported-instruction path until a replacement independently demonstrates equivalent behavior. See the [measurement and acceptance protocol](OPTIMIZATION.md#measurement-and-acceptance) and the [synthetic x64 measurements](PERFORMANCE.md), [N64 configuration](../fnesemu_core/tool/n64_jit_bench.md) and [SH-2 configuration](../fnesemu_core/tool/sh2_jit_bench.md).

## Idle observation boundaries

The SH-2 adapter checks short backward edges up to 32 bytes, including a compiled return to the same entry PC. Store-free translation records the source block PC and sets the stop word only when the selected destination meets that criterion. Calls, returns and forward instruction-limit continuations can chain otherwise. Dynamic targets and branch conditions are captured before delay slots. The adapter uses the recorded source for `_isIdle`, retaining register/control-state and write-counter comparisons; the native predicate selects an observation point rather than declaring the loop idle. Strict budgets, on-chip ticking and CPU ordering remain adapter-owned. The 32x adapter disables these yields because it has no idle detector.

## SH-2 read registers, MAC.L and native idle checks

`Sh2Jit.addReadRegister` allocates one of four context words and associates it with an adapter-supplied address/width predicate. The adapter updates the returned view before native execution and after CPU-side effects. A guarded stable base or guarded pointer literal may select a context load; all other addresses and widths retain ordinary memory/CPU handling. SS permits only the FTCSR byte at `0xfffffe11`, whose read has no side effect and whose value remains stable until CPU/on-chip processing resumes. It is refreshed before every native attempt rather than frozen as a compile-time device value. No hardware address appears in the shared runtime.

MAC.L is optional in the common frontend and uses i64 IR, which every backend supports. It sign-extends two ordinary word reads, preserves sequential post-increments when the address registers alias, adds to MACH:MACL and implements the current CPU model's optional signed 48-bit saturation. An exit on either read restores the complete pre-instruction snapshot; a slot exit replays the branch before effects. SS enables it with its existing one-clock instruction model. The 32x adapter retains CPU execution because its existing MAC.L timing differs. This optimization does not revise hardware timing.

With `idleGuards`, the frontend captures entry values for guest words it replaces. A store-free self-loop with unchanged guest state can return `idleDetected`; callbacks exclude that proof, and ordinary mapped reads/context registers require the adapter's stability contract. The SS adapter advances to its current deadline, ticks devices normally and excludes skipped clocks from the native counter. Self-loops whose state changes continue through native links instead of returning for a futile idle check. Multi-block loops retain the existing adapter detector. SS has a 64-clock default quantum and opt-in JIT; `jitMacLong`, `jitFtcsr` and `jitIdleGuards` permit comparisons without changing scheduling.
