# Runtime

`JitRuntime` installs and runs `IrBlock`s. This document describes its memory model, linking, dispatch and lifecycle. The IR itself is described in [IR](ir.md), and the code generators in [Backends](backends.md).

## Memory mappings

Guest memory is mapped in pages of `1 << pageShift` bytes (4KiB by default) to buffers from `JitRuntime.alloc`, separately for reads and writes. Unmapped accesses call the host read and write functions. The callbacks exchange raw little-endian packed bytes; the IR applies the access byte order. An 8-byte callback access is split into two 4-byte calls in address order.

A load or store built with `unmapped:` exits at an unmapped read or write page instead of calling the host, with the address in `JitCtx.faultAddr`. The page lookup is shared with the access. `IrBuilder.guardMapped` checks a page without accessing it. A core can then synchronize clocks and CPU state and execute the instruction in its interpreter. An exit's `stores` write guest registers held in values only on that exit path.

## Code protection

Guards compare code words at block entry to detect modified code. `JitCodeMemory` additionally owns write protection for translated code pages.

- A core declares its guest mappings with `map`.
- `protect` removes the write mappings of every writable alias of the same host page and records the blocks translated from it. A store to an upcoming instruction then leaves the block before changing it. The core must protect every writable alias of those pages.
- `release` drops those blocks and stops protecting a page that compiled code keeps writing.
- `reset` restores all write mappings.

Writes outside compiled code are still detected by block guards. Entry guards cannot repair a write that already changed the active native block. PS1, N64 and the SH-2 component use `JitCodeMemory`.

## Execution, links and dispatch

A run continues from block to block through link slots and a dynamic jump table, and returns to the host only when a block exits, a target is missing, the budget runs out or the stop word is set.

- A block entered with a positive budget runs completely, so the budget may end negative by up to one block. The host carries that overshoot. Side exits refund only the unexecuted part of the block cost.
- An `IrExit` with `link: true` applies its snapshot stores and unused-clock refund, then chains to its `(pc, tag)` target. It keeps the normal target budget, stop and code guards and returns `JitReason.miss` if the target is absent. All backends and the reference executor share this behavior. This supports conditional continuation without a host round trip, including an annulled delay slot. The host reason of a linked exit is ignored.
- Static targets use link slots, which are filled when the target is installed. Dynamic targets search a direct-mapped table of 4,096 entries indexed by `(pc >>> 2) ^ tag`. A cold installation can evict a hot indirect target, so a native miss to an installed block refreshes its table entry without recompiling; code guards and invalidation still apply.
- The installed-block map, and the driver's miss and fallback caches, are `IntMap` open-addressing tables, so hot lookups neither hash through a generic map nor allocate. `IntMap` keeps its multiplications below 2^53 and works where an int is a JavaScript number.

`JitRuntime.compileThreshold` supplies a backend hotness suggestion; adapters choose the cold-execution and specialization policy. Measure compilation amortization on the workload rather than treating a threshold as proof of profitability.

## JitDriver

`JitDriver` runs the shared dispatch loop for PS1, N64 and SH-2. It translates missing successors at the selected threshold and caches untranslatable code words.

- `runBudgeted(pc, tag, budget)` initializes the batch budget and clears the stop flag, dispatches through warmup and fallback handling, and records the elapsed guest clocks in `lastClocks` from the signed remaining-budget word. `executedClocks` accumulates this work for both compiled and reference IR runtimes; adapters expose it as native usage only when their runtime is compiled. Idle skipping and CPU fallback never enter this total. `run` is the lower-level entry for callers that manage their own context and accounting.
- Adapters may prepare cold entries before runtime entry, observe live registers during warmup, bound host dispatch retries, and stop on device or idle returns. Invalidation clears observations. A guarded specialization miss may mark its next translation hot. Counters and fallbacks are bounded together.
- A driver can receive its runtime's `JitCodeMemory`. `reset` then drops runtime blocks, restores protected write mappings, clears warmup and fallback profiles through their lifecycle hooks, and resets batch accounting. Guest register views, memory mappings, buffers and registered helpers stay wired. `clear` only forgets dispatch profiles and preserves runtime blocks and accounting, including when bounded cold-entry caches fill.

The adapter keeps entry conditions, translation, budgets, interrupts, device deadlines and interpreter execution.

## Cold-entry profiles

`JitEntryProfiles<T>` manages bounded cold-entry observations by PC, mode tag and a frontend-defined version token. A changed token discards stale data. Capacity clears, removal and reset affect observations only. `JitEntrySamples` copies unsigned-word values, tracks values that remain stable, supports count-only observations and lets the frontend disable candidate specialization.

These utilities provide neither memory permissions nor replacements for instruction and value guards. The frontend owns candidate selection, token coverage and precise exits; see [Guarded specialization](frontends.md#guarded-specialization).

## Sharing buffers

`shareBuffer(owner, buffer)` permits separately executing native runtimes to map guest RAM allocated by another runtime while keeping their contexts separate. The owner must remain alive until all borrowers have finished executing and removed their mappings. This does not provide concurrent code publication or guest-memory synchronization, and the same runtime must not execute from several threads. Wasm runtimes share their linear memory, and the reference executor accepts the buffer directly.

## Failures

Allocation and native code-publication failures throw. Construction releases partially allocated native resources, and a runtime whose code-protection update fails cannot run again. Shared guest buffers remain valid until the owner calls `dispose`.
