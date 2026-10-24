# x64 JIT optimization measurements

This is a historical backend measurement report. Use the [performance guide](OPTIMIZATION.md) for the current workflow and metric definitions.


Date: 2026-10-21. Baseline: `f5517a1`. The optimized build adds immediate operands, block-local register allocation and i32 IR simplification.

Environment: Dart 3.13.4 AOT on Linux x64 under WSL2, Intel Core i7-13700H. Timed processes were pinned to logical CPU 2 and serialized with the shared benchmark lock. Tests and builds finished before the final timed runs. GUI FPS is not used.

## Synthetic CPU execution

The instruction sequence comes from `packages/fnesemu_core/tool/ps_jit_bench.dart`, with 30,000 outer iterations and source words initialized to `i * 17`. Only the native backend is measured, with compile threshold 1. Each process executes four identical runs without clearing the compiled cache; the first is excluded. Five process pairs alternate version order, producing 15 warm observations per version and slice. These are Stopwatch elapsed wall times for the whole loop, not frame times.

| CPU slice (guest clocks) | Baseline (ms) | Optimized (ms) | Time reduction |
| ---: | ---: | ---: | ---: |
| 100 | 279.417 | 228.895 | 18.1% |
| 1,000 | 161.176 | 108.929 | 32.4% |
| 100,000 | 134.112 | 87.258 | 34.9% |

Checksums match across all runs; emulated clocks match between versions for each slice. Slice lengths change block overshoot and the cost of returning to Dart. These results do not predict whole-emulator speedup.

## Generated code and compilation cost

A 31-instruction IR fixture chains eight add/xor/shift triples and stores the result to the context. Optimization reduces it to 29 IR instructions and 470 to 202 x64 bytes. Disassembly confirms immediate arithmetic and consecutive operations in `r9d` without stack round trips for this chain. This is one fixture, not aggregate code size.

Generation was timed within one AOT executable using the original and optimized emitters, a fixed mock environment and the same fixture. Seven rounds alternate emitter order, 2,000 blocks per batch; the first round is excluded. The optimized path includes the IR pass and allocation. It excludes guest decoding, OS code-page protection and cache publication.

Median generation time: 3.317 to 17.435 microseconds per block. Generation is slower; the demonstrated benefit is faster repeated execution and smaller generated code. Revisit this tradeoff for workloads dominated by cold or frequently replaced code.

## Correctness checks

- Recompiler VM suite: 51 tests, including 2,000 randomized IR programs compared with the unoptimized IR interpreter, overflow/shift edge cases, helper barriers, register pressure and side-exit snapshots.
- Node dart2js and dart2wasm: 30 tests each covering the optimizer, runtime and mandatory Wasm backend execution.
- Quick regression: disc-image, core and app suites pass, including PS1 random CPU, JIT, DMA, timer and renderer tests.
- Linux release application builds successfully.
