# N64 JIT configuration and validation

N64 blocks use native i64 values, big-endian memory and register/FPU views shared with the CPU interpreter. Entry tags distinguish FPU register layout and COP1 availability. Aligned ordinary-memory accesses can remain compiled; device/TLB accesses, faults and unsupported operations return before effects.

## COP1 coverage

The default native path supports transfers, aligned memory access, branches, ADD/SUB/MUL, finite C.EQ/C.LT/C.LE comparisons, supported word rounding/conversion, CVT.S from double and CVT.D from single. Nonfinite operands, out-of-range word conversions and unsupported rounding modes use CPU fallback. This does not implement additional architectural floating-point exceptions or rounding modes.

`--jit-cop1 off|transfers|native|helpers` selects coverage in `core_headless`; `helpers` uses Dart arithmetic callbacks. Block limits and optional direct-jump inlining are comparison settings, not substitutes for measuring actual invocation boundaries. Untaken branch-likely continuations use linked precise exits after snapshot stores and cost refunds.

## Tools

Build `tool/n64_jit_compare.dart` with `dart build cli` and retain its bundled native library. Pass a case JSON containing shared media/input arguments, plus `--warmup` and `--frames` to select the interval. Use `--cop1 --fpu` when comparing floating-point variants.

`--jit-stats` reports optional installation histograms, idle clocks, CPU fallback selections and runtime exits. A fallback selection may service an interrupt before executing that opcode. See the [tool README](README.md) for option details and the [measurement guide](../../mp_jit_recompiler/OPTIMIZATION.md) for metric definitions.

## Correctness checks

Differential tests compare CPU, reference IR and compiled execution for full-width integer values, FPU layouts/control, finite and special operands, delay slots, traps, precise memory faults, host writes and aliases. ARM64 QEMU checks exercise float arithmetic, conversion and N64 translation with compiled availability asserted and skipped tests rejected. QEMU establishes backend correctness rather than native ARM64 throughput.
