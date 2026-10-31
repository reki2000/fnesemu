# CPU profiling and frontend considerations

Use native AOT sampling with resolved call chains and inline frames. Restrict the denominator to core execution, excluding harness work, captures and disc settling. Repeat equivalent workloads and check lost samples. Inclusive CPU functions may include bus and device work that compilation cannot remove.

Sparse stopwatch sampling with extrapolated durations does not establish a CPU-time share. Empty-path calibration cannot prove that instrumentation, code layout or scheduling effects are negligible. Validate observed output separately from timing methodology.

Amdahl's law estimates overall speedup from a measured component fraction and a proposed component improvement. It does not establish the JIT's speedup or transfer a CPU share between workloads. Guest-clock coverage is not a host CPU-time fraction.

## Frontend considerations

- ARM7TDMI translation must preserve ARM/Thumb state, conditions, flags, pipeline-visible PC, memory timing, timers, DMA and IRQ boundaries.
- SH-2 translation must preserve big-endian memory, delay slots, on-chip updates, master/slave synchronization and adapter idle handling.
- M68000 translation must preserve partial registers, flags, addressing side effects, access order, exceptions, banking and shared-memory invalidation.
- VR4300 translation must preserve full-width integer values, COP1 control/layout, precise exits and device deadlines.
- Other frontends need explicit mode, bank and device synchronization contracts before increasing execution batches.

Use the [diagnostics guide](../../mp_jit_recompiler/docs/diagnostics.md) for metric definitions, the [performance guide](../../mp_jit_recompiler/docs/performance.md) for the workflow and the [roadmap](../../mp_jit_recompiler/docs/roadmap.md) for pending implementation work.
