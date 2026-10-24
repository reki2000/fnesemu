# Interpreter and JIT frame comparison

`core_headless bench` compares CPU interpretation and native execution through the frame runner. See the [tool options](README.md#benchmarks), [current defaults](README.md#current-jit-status) and [measurement guide](../../mp_jit_recompiler/OPTIMIZATION.md).

## Running

Build from the core package with `dart build cli -t tool/core_headless.dart -o /tmp/core-headless` and keep `bundle/lib` beside `bundle/bin`. Run `bundle/bin/core_headless bench <core> <media...> --frame-runner --jit off` and the corresponding `--jit on` command with matching input, warmup, frame intervals and lock options.

The timer includes frame execution and `imageBuffer()`. Disc settling, input updates and image encoding are outside it; audio callback work runs inside core execution. Process CPU time and elapsed time have different denominators. Headless frame throughput does not predict displayed GUI FPS.

## Diagnostics

`--profile-exits` counts actual compiled invocations and their return causes without clearing installed blocks after warmup. `--profile-blocks` inserts entry callbacks after clearing installed code and counts positive executed spans, including partial exits. Both perturb execution and need separate runs from throughput comparisons.

The block histogram's cycle sum must equal the compiled-clock delta. Its mean and percentiles are weighted by execution count rather than cycles. Installation histograms describe generated code, not execution frequency. Guest-clock coverage and cycles per invocation are distinct from host CPU-time share.
