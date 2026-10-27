# Frontend guide

These guidelines come from the PS1, N64 and SH-2 frontends and the x64 backend work. Use them when adding another guest CPU or extending a frontend. Package responsibilities are defined in the [architecture](../../../ARCHITECTURE.md). The per-core policies that currently apply are in [Core adapters](cores.md).

## Execution and state contracts

- Optimize the normal `runFrame` path first, and establish its CPU cost with AOT sampling before extending instruction coverage. Keep instruction-based debugger stepping correct, but measure its performance separately. Preserve existing idle-loop skipping and device batching when introducing compiled execution.
- Define the interpreter and compiled boundary before lowering instructions: shared register and memory layout, mode-dependent block tags, clock accounting, pending pipeline state, and the exact state restored on an exit before effects. A delay-slot fault may require replaying the branch as well as the slot. Unsupported instructions and device accesses must remain correct through CPU fallback.
- Emit one lowering for every runtime; all backends support the same widths, byte orders and floating-point operations. Use native i64 values for a 64-bit guest. Make word truncation, sign extension, shift-count masks and context-word layout explicit, and use exact constants and a BigInt reference for wide arithmetic.
- Frontends do not check the budget themselves. The runtime enters a block only with a positive budget and the block then runs to its end or a side exit, so the last block may overshoot the deadline. Side exits refund only the unexecuted part of the block cost. Adapters detect device events by range over the elapsed clocks.

## Compilation and register allocation

- Start with the existing SSA representation and simple block-local allocation. Reduce avoidable construction work by reusing tracking arrays, retaining unchanged immutable instructions, sharing exit descriptors and creating precise snapshots only where needed. Measure lowering time, optimization and installation time, and IR size separately; infer neither allocation counts nor GC cost from elapsed time alone.
- Audit register expansion against every emitter temporary, pinned runtime pointer and host ABI. Values live across callbacks and operands consumed during argument setup need explicit protection. Exercise high register pressure, mixed widths, helper calls and side-exit snapshots together; testing arithmetic results alone misses allocation errors.

## Adapter responsibilities

The adapter selects deadlines, prepares guest state and mode tags, synchronizes registers and PC after a batch, handles precise exits and exceptions, and decides which instructions the CPU executes. The dispatch loop itself is shared through `JitDriver`; see [Runtime](runtime.md#jitdriver).

Each frontend supplies a `JitDiagnostics` descriptor with its runtime, instruction width, byte order and optional custom exit classification. Core adapters enumerate these descriptors through `CoreDebug.jitDiagnostics`, so collection tools need no concrete-core type tests. Exit classification must use the active translation options: an instruction enabled by an optional lowering must not be reported as unsupported merely because the decoder's default settings disable it. See [Diagnostics](diagnostics.md).

## Guarded specialization

The frontend owns value assumptions and precise exits. The adapter owns memory-region and helper semantics. The runtime supplies generic IR, guards, mappings and invalidation primitives. The cold-entry storage is described in [Runtime](runtime.md#cold-entry-profiles), and the candidate selection method in the [performance guide](performance.md#observe-first-specialize-with-guards).

The SH-2 implementation is the reference:

- It records R0-R15 at cold entries and compiles native blocks after ten entry samples by default. Reference IR defaults to one sample unless overridden.
- Its one-pass decoder selects stable first-use memory bases in mapped memory or an adapter-approved helper region. Registers already read or written in the block keep ordinary SSA values.
- A guard before the first specialized memory use checks the entry value before substitution. A miss restores precise state and identifies the source block even after native linking, disables its specialization and leaves the next compilation generic.
- Profiles are keyed by PC, mode tag and a version token, bounded to 4,096 cold entries, and removed on installation, reset and code-guard invalidation. A full table clears only observations. SH-2 uses the entry instruction as its token. A changed entry drops earlier samples, and compilation with fewer than two fresh samples stays generic. The token is not a fingerprint of the whole block, so instruction guards still protect all compiled code words.
- These are exact entry values, not per-access traces or range proofs. Page-table checks, protected-page exits and instruction-word guards remain.
- Adapter-approved read helpers can opt into guarded PC-relative pointer-literal folding. Only pointers into an approved helper region are folded; device values and arbitrary mutable literals are not. Aligned literal-word guards and protection of every writable alias cover the literal bytes. Helpers that opt in must not modify mapped guest memory. A changed pointer must be revalidated, including when it changes to a side-effectful device. This does not permit unchecked stores into mixed code and data pages.

Specialization candidates, approved memory and helper regions and profile-miss policy remain frontend decisions. Observed stability does not establish hardware semantics.

## Idle detection boundaries

Idle recognition is adapter policy. A frontend can help by choosing observation points but must not declare a loop idle on its own: unchanged registers and the absence of stores do not prove idleness. Removing idle polling also requires a wake path.

The SH-2 frontend marks short backward edges of up to 32 bytes, including a compiled return to the same entry PC. A store-free translation records the source block PC and sets the stop word only when the selected destination meets that criterion. Calls, returns and forward instruction-limit continuations can chain otherwise. Dynamic targets and branch conditions are captured before delay slots. The adapter uses the recorded source for its idle check and keeps its register, control-state and write-counter comparisons; the native predicate selects an observation point only.

With `idleGuards`, the frontend captures the entry values of the guest words it replaces. A store-free self-loop with unchanged guest state can return `idleDetected`. Callbacks exclude that proof, and ordinary mapped reads and context registers require the adapter's stability contract. Self-loops whose state changes continue through native links instead of returning for a futile idle check. Multi-block loops keep the adapter's detector.

## SH-2 address space, read registers and MAC

`highMemory` lets accesses at 0xc0000000 and above reach the runtime pages when the adapter keeps bit 31 in the runtime mask; the range check biases the address by 0x40000000 so that one unsigned compare allows 0xc0000000 to 0x3fffffff. `endsAfterStore` lets the adapter end a block after a store into a page that was released from write protection.

`Sh2Jit.addReadRegister` allocates one of four context words and associates it with an adapter-supplied address and width predicate. The adapter updates the returned view before native execution and after CPU-side effects. A guarded stable base or guarded pointer literal may select a context load; all other addresses and widths keep ordinary memory and CPU handling. No hardware address appears in the shared runtime.

MAC.L is optional in the common frontend and uses i64 IR. It sign-extends two ordinary word reads, preserves sequential post-increments when the address registers alias, adds to MACH:MACL and implements the CPU model's optional signed 48-bit saturation. An exit on either read restores the complete pre-instruction snapshot, and a slot exit replays the branch before effects. MAC.W is optional in the same way. These options do not revise hardware timing.

## Validation

Exercise CPU interpretation, reference IR and native execution, including unsupported capability paths, both widths and byte orders, callbacks under register pressure, precise exits, code and literal writes and aliases. Keep the CPU interpreter as an oracle and unsupported-instruction path until a replacement independently demonstrates equivalent behavior. The acceptance protocol is in the [performance guide](performance.md#measurement-and-acceptance).
