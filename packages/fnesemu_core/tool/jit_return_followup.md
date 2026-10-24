# JIT continuation and return diagnostics

PS1, N64 and SH-2 use the shared dispatch driver for warmup, fallback, batch accounting and reset. The runtime chains installed static and dynamic targets while the budget and stop conditions allow it. Missing dynamic targets refresh the dispatch table when an installed successor becomes available.

## Return boundaries

A native invocation may execute several linked blocks or no guest instructions. Distinguish runtime entry counts, positive block spans, installation counts and CPU fallback selections. Use `core_headless bench --profile-exits` to locate budget, mapping, code-guard, unsupported-instruction and adapter-yield boundaries; use uninstrumented execution for timing.

Budget preparation avoids entering with exhausted work. A positive budget permits the final block to complete or take a precise exit, so adapters must account for deadline overshoot. Linked precise exits preserve snapshots and refund only unexecuted block cost.

## Adapter responsibilities

N64 mode tags preserve FPU register layout and availability. Unsupported operations and exceptional operands return to the CPU before effects. SH-2 cold-entry observations select guarded constants; profile misses disable unstable specialization and request generic recompilation.

SS can yield selected short backward edges to its adapter's idle detector. Unchanged native self-loops may report an idle result only under the adapter's stability contract. 32X has no equivalent idle detector and disables those yields. Communication-register helpers require explicit adapter approval; FIFO, control and other synchronization-sensitive accesses retain CPU handling.

See the [frontend contracts](../../mp_jit_recompiler/FRONTENDS.md), [measurement guide](../../mp_jit_recompiler/OPTIMIZATION.md) and [pending improvements](../../mp_jit_recompiler/ROADMAP.md).
