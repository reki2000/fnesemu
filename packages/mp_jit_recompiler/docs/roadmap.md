# Roadmap

This document records queued proposals, not authorization to change scheduling. Measure each behavior change separately from structural refactoring. The implemented behavior is described in the other documents of this package. Select the next change from measurements rather than from the order of this list, and apply the [acceptance protocol](performance.md#measurement-and-acceptance) to each one. Avoid generic API surface solely for a speculative optimization.

The proposals below are grouped by the part of the execution path they change. Section "Candidates by expected benefit" ranks them. The ranking is an estimate from reading the generated code, not a measurement, and the measurement that decides each candidate is listed with it.

## Current cost structure

The following facts about the x86-64 code generator bound what a candidate can gain.

- **Block entry.** Each block compares the stop word and the budget in the context, runs one `cmp [mem], imm` per guarded code word, and subtracts its cost from the budget in memory.
- **Links.** A static link loads the target from a link slot, tests it and jumps through a register. The target is not patched into the jump. A dynamic jump searches a direct-mapped table of 4,096 entries and exits to the host on a miss. Two hot targets that share an entry miss on every transfer, and each miss costs a host round trip even though the driver now runs the installed block instead of translating it again.
- **Memory access.** Every load and store masks the address, indexes the page table and tests the entry. Two accesses to the same page repeat the lookup.
- **Comparisons.** A comparison used by a branch or exit is materialized with `setcc` and `movzx`, then compared with zero again.
- **Registers.** Values live in seven host registers within one block and in stack slots across helper calls. Nothing survives a block boundary. The ARM64 backend keeps every value in a stack slot.
- **Optimizer.** It folds i32 constants and identities and removes dead pure values. It has no common-subexpression elimination, no context load forwarding and no dead context store removal.
- **Compile path.** Median emission was 17 microseconds per block in the last synthetic measurement, and the Wasm backend instantiates one module per block.

## Candidates by expected benefit

| # | Candidate | Expected effect | Cost and risk | Measure first |
| --- | --- | --- | --- | --- |
| 1 | Compare and branch fusion (Optimizer and code generation) | Fewer instructions on every conditional exit and branch in every block | Low; local to the backends | Count `setcc` plus zero-compare pairs in generated code of a hot block |
| 2 | Page-lookup sharing within a block (Memory access) | Fewer table loads in blocks that touch one page repeatedly | Medium; must keep unmapped exits and precise snapshots | Share of memory operations whose base value and page match an earlier one |
| 3 | Context load forwarding and dead context store removal (Optimizer) | Fewer memory operations in blocks that keep guest state in the context | Medium; exits and snapshots observe stores | Count redundant context accesses per block in the frontends' output |
| 4 | Direct patched links (Dispatch) | Removes the slot load and indirect jump per chained block | Medium; invalidation must unpatch, and the macOS write-protection toggle applies | Link-slot share of block entry cost |
| 5 | Cheaper block entry (Dispatch) | Fewer memory compares per block; matters for short blocks | Medium; stop and budget semantics are shared by all runtimes | Mean executed block cycles from the block profile |
| 6 | Wider code guards (Memory access) | One compare for two or four code words | Low; x86-64 and ARM64 only | Guard count per block |
| 7 | Inline cache for dynamic jumps (Dispatch) | Fewer table searches and host exits for returns and indirect calls | Medium; adds per-site state | `linkMiss` and dynamic-table miss counts from the exit profile |
| 8 | ARM64 register allocation (Backends) | Likely the largest ARM64 gain | High; a second allocator | A native ARM64 host baseline |
| 9 | Wasm block batching (Backends) | Fewer module instantiations and dispatcher round trips | High | Compile-time and cache-clear counts on the Web |
| 10 | Frontend coverage (Frontends) | Fewer CPU fallbacks | Per instruction | Exit profile by opcode |
| 11 | Typed host accessors for the hot context words (Dispatch) | Fewer virtual calls and bounds checks per batch, one place for the signed budget | Low; host side only | Host time per batch outside the native call |

Candidates 1 to 3 change only generated code for a block, so they carry the least risk to scheduling. Candidates 4 to 7 change the dispatch contract and need the full acceptance protocol.

## Optimizer

1. Fuse a comparison with the branch or exit that consumes it. The backends would emit `cmp` and a conditional jump when the comparison result has no other use, instead of materializing a 0 or 1 value.
2. Add local common-subexpression elimination for pure values. Frontends that expand the same address arithmetic several times, such as an effective address used by both a check and an access, would benefit.
3. Forward a stored context word to a later load of the same word, and share repeated context loads, between barriers. A call, a guard or an exit that carries a snapshot is a barrier unless the pass proves that it does not read the word. Remove a context store that a later store overwrites before any barrier. Side exits snapshot registers through their `stores`, so a store that an exit does not cover must stay visible to it.
4. Fold a constant addend of an address into the displacement of the access. The backends can then skip an add and keep one value fewer live.
5. Measure each pass on the compile path as well. An optimization that costs more emission time than it saves in execution is a loss for cold or frequently replaced code.

## Memory access

1. Share the page lookup between accesses in one block when they use the same base value and offsets that stay within the page. The shared lookup must keep the unmapped exit for each access, and a store must not reuse a read lookup.
2. Combine adjacent code-word guards into one wider compare on the x86-64 and ARM64 backends. Byte order is handled when the expected value is built.
3. Let the adapter report interpreter, DMA and other host writes through a proposed `notifyWrite(address, length)` API. Preserve the existing instruction guards and behavior first. Removing guards is a separate change that requires auditing every write path, exposed mutable buffer and remapping operation. Define ownership when multiple runtimes share a buffer. Guard removal on chained blocks of a protected page is the main benefit.
4. Add optional region descriptions after the above. A candidate description contains a match mask and value, an offset mask, a buffer offset and length, access permissions and a priority. Backends can emit a direct-buffer fast path with a page-table fallback, and region hints on individual loads can narrow the candidates. The adapter supplies the hardware knowledge, and the runtime supplies generic checks. Start with read-only fast-path experiments and mapped RAM reads before code-protected writes. Validate alignment, bounds, aliases, banking and mapping lifetime. Disabling hints must preserve mapping semantics, and the reference executor may ignore them.
5. Consider per-region callbacks with an explicit consumed-clock and state contract. The adapter decides whether an access can use a callback or must exit for synchronization. The callback ABI and compiler must preserve all live state across the call.

## Dispatch and linking

1. Patch the jump of a static link to the target block once the target is installed, and unpatch it when the target is invalidated. This replaces the slot load and the indirect jump. The patching must work with the per-platform code publication rules, which include the macOS write-protection toggle and instruction-cache synchronization.
2. Reduce the work at block entry. Candidates are checking the stop word and the budget with one compare, and skipping the entry checks on a link whose source block has just checked them. Both change the shared stop and budget semantics, so they need all backends and the reference executor.
3. Reduce dynamic-table conflicts and add a per-site inline cache to dynamic jumps. A two-way table, or a table indexed by a better hash of the pc and tag, removes collision misses. Then: compare the target against the last target of the site before searching the table. Returns and indirect calls are mostly monomorphic. The table keeps serving polymorphic sites.
4. Before changing the `JitDriver` cache representations further or moving its counters into native code, measure allocation and lookup costs. The driver already uses `IntMap` tables.
5. Give the hot context words typed host accessors instead of indexing `rt.ctx` with `JitCtx` constants. The budget, stop word and exit pc, tag and fault address are read and written on every batch and every miss by `JitDriver`, the PS1 and SH-2 adapters and the native runtime. Each access goes through the abstract `ctx` getter and a bounds-checked `Uint32List` index, and each reader of the budget repeats `toSigned(32)`. A native runtime could hold `budget` and `stop` as fields backed by the same context memory, with a signed budget accessor, and the interpreter and Wasm runtimes would implement the same members. The context layout and the generated code do not change. The gain per batch is small next to an FFI entry, so measure the host time outside the native call before doing it; the readability gain from a single signed-budget accessor may justify it alone.
6. Direct trampoline lookup and a smaller result ABI are later dispatch experiments. Leaf FFI execution requires both the absence of callbacks and an acceptable bound on the native call duration; callback absence alone is insufficient. Keep portable behavior and platform ABI rules in the runtime.

## Backends

- x86-64: use callee-saved registers for values that span a helper call instead of spilling them, if the pinned runtime registers leave room. Revisit the pool of seven registers with a measured count of spills per block.
- ARM64: all throughput conclusions come from x64. The backend keeps SSA values in stack slots, so measure on a real ARM64 host before assuming the x64 gains carry over. A block-local linear scan like the x86-64 one, immediate forms for arithmetic and constants, and the same candidates as above are the first steps.
- Wasm: the code cache clears at 4,096 blocks and recompiles on demand, and each block is a separate module. Measure the clear rate on long sessions, and consider raising the limit or compiling a chain of hot blocks into one module so that the dispatcher is not entered between them.
- Cross-block register state is not planned. Larger blocks, through the frontend traces below, get most of the same benefit without a register-state contract at links.

## Compile path

- Measure translation, optimization, emission and publication separately on the cold start of each core, using `--profile-compile`. Reduce the first visible stall before any steady-state change.
- Consider replaying the list of hot `(pc, tag)` entries recorded in an earlier run after a state load, so that compilation happens during loading rather than as stutter. The entries still pass through the normal guards and thresholds.
- Raising the Wasm block limit or the native code size changes memory use. Measure resident size before changing it.

## CPU frontend candidates

- PS1: the divide and the coprocessor 2 commands run through helper calls. Count their share in the exit profile before translating them. The divide follows the IR division proposal below.
- N64: prioritize the remaining hot floating-point conversions and comparisons, preserving rounding and control state and nonfinite behavior. HI/LO with multiply and divide coverage, unaligned merge accesses and other floating-point operations remain workload-dependent candidates. Batch adjacent CPU fallback instructions where safe, preserving interpreter idle skipping, interrupts and device deadlines. Profile demanding scenes before attributing the remaining host time to HLE.
- SH-2: expand the measured hot coverage, such as procedure-register stack operations, carry arithmetic, divide steps and full multiply and MAC operations, keeping exact exceptions, memory order and clock accounting.
- Idle recognition: express register and state comparisons and exits in IR while retaining multi-block loop detection. The adapter must establish that observed memory and devices stay stable and that reads have no relevant side effects during the proposed skip.
- Specialization: frontend-owned mode and register tags or guarded literals can enable base-register and PC-relative constant folding. Mapping stability and literal and code invalidation remain explicit dependencies.
- Larger traces: frontend-owned fall-through chaining and limited branch or function inlining must preserve CPU-specific delay slots and snapshots. Establish entry amortization and scheduler capacity before targeting a nominal instruction count. The N64 direct-jump continuation exists but is off by default, and the SH-2 limit is 24 instructions.

### Interpreter-guided memory specialization

Remaining candidates are per-access region and range observations, entry-register-relative intervals and guarded data accesses sharing code pages. A runtime fast path must preserve alignment, bounds, aliases and code protection while distinguishing proven data from executable bytes. Unknown pointer loads and variable offsets keep ordinary checks.

Keep code-version validity separate from data-region stability. Entry guards remain until every CPU, DMA, other-CPU and host write, mutable buffer and remapping path has a complete invalidation contract. New code installation can invalidate a data-only assumption. These changes do not require a tracing or loop framework.

## IR extensions

1. Add integer division and remainder to the IR, for both widths and in signed and unsigned forms. The IR has `add`, `sub`, `mul`, `mulHiS` and `mulHiU` at both widths but no division, so the PS1 frontend divides through an i32 helper call, while the N64 and SH-2 frontends leave divide instructions to the CPU fallback. Decide the result for a zero divisor and for the signed overflow case (`INT_MIN / -1`) in the IR contract, or make the operation exit before effects so that the frontend keeps the guest-specific result. The x86-64 `div` instruction faults on both cases, so a backend needs an explicit check. The change is complete only when the reference executor and the x86-64, ARM64 and Wasm backends implement it. Start from measured hot divide sites rather than from instruction coverage alone.
2. Add a typed 64-bit helper ABI and further floating-point operations when a frontend needs them.

## Core adapter candidates

- SS: native execution is opt-in. Profile the host costs of CPU fallback, native guards and mapping, and dispatch before proposing another default change. Investigate timer, MMIO and inter-CPU synchronization as accuracy work, and preserve on-chip events and master and slave communication.
- 32X: recheck interpreter and native execution across varied workloads before changing the CPU quantum or the enabled default. Private-cache compilation stays excluded; revisit it only with explicit code and data protection and mapping contracts. Explore stable cartridge ROM windows with bank-aware invalidation. Validate communication before using longer blocks.
- N64 and SS: collect AOT host CPU samples with resolved call chains and a core-only denominator. Report idle, native and interpreted guest clocks separately. Changing the public JIT percentage denominator needs an explicit UI and API decision.

## Diagnostics backlog

Extend native diagnostics only when a measured hypothesis needs them. The measurements named in the ranking table need three that do not exist yet: counts of dynamic-table misses separate from other `linkMiss` exits, spill and redundant context-access counts per block from the compiler, and instruction counts or blocks per invocation when cycles cannot answer the question. Measure the instrumentation overhead separately.

## Order and acceptance

Do the measurements in the ranking table first, on the target host, and begin with the cheapest candidate whose measurement shows a share large enough to matter. Candidates 1 to 3 can be evaluated with synthetic blocks and generated-code inspection before any game scene. The remaining structural candidates are the `notifyWrite` contract, then region fast paths. Preserve behavior and guards during refactoring and test each later optimization independently. Do not complete a large abstraction before a smaller proven improvement.
