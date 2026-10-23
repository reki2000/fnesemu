# SH-2 JIT configuration and tools

SS and 32X use the common integer frontend under `components/sh2/jit`, with register views and ordinary memory shared with their CPU interpreters. `JitDriver` handles dispatch, cold-entry observations, fallback, batch accounting and reset. Core adapters retain memory maps, interrupt handling, on-chip ticks, CPU ordering and device deadlines.

## Cold-entry value specialization

Repeated cold entries can select stable first-use register values as memory bases. These observations select candidates; runtime guards establish safety. A profile miss restores the precise instruction boundary and disables unstable specialization. Unknown addresses retain ordinary page checks and CPU exits.

Approved read helpers can enable guarded pointer-literal folding. The adapter decides which addresses and widths have safe read semantics, and helper values remain live. Code and literal guards cover changes through mapped aliases. SS can also declare side-effect-free context reads for on-chip registers.

## CPU quantum experiment

SS uses a default 64-clock quantum and opt-in JIT. 32X enables JIT by default with bounded 32-clock quanta clipped to the main CPU deadline; quantum 1 selects instruction alternation. Changing these values changes CPU/device interleaving and requires independent synchronization checks.

`sh2_slice_compare.dart --case FILE --warmup N --frames N [--out DIR]` compares supported quantum and interpreter/JIT variants. The case JSON contains media/input arguments without mode or quantum options. `ss_slice_compare.dart` is a compatibility entry point. Output capture includes periodic PNGs and continuous audio.

## Instruction and idle policies

SS enables MAC.L and MAC.W using its CPU model's saturation, aliasing and access-order semantics. 32X retains CPU execution where instruction timing differs. Read faults and unsupported delay slots exit before effects so the CPU can replay the branch precisely.

SS uses selected backward-edge yields and guarded unchanged-self-loop checks with its adapter-owned idle detector. 32X disables those yields because it has no idle detector. SDRAM code can compile in 32X; private-cache and other excluded code regions remain on the CPU path. Banked ROM compilation requires a separate mapping and invalidation contract.

## Synthetic benchmark

`tool/sh2_jit_bench.dart` creates an in-memory program and compares interpretation with native execution without external media. It checks CPU state, clocks and work RAM outside timing. Synthetic instruction throughput does not predict whole-core or GUI throughput.

See the [frontend contract](../../mp_jit_recompiler/FRONTENDS.md), [measurement guide](../../mp_jit_recompiler/OPTIMIZATION.md) and [current defaults](README.md#current-jit-status).
