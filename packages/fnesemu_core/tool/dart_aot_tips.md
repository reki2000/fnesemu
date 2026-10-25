# Dart AOT performance notes

Findings from profiling hot paths and reading their x64 AOT output. The N64 color combiner (`_combine`) and rasterizer were the subjects.

## Profiling

perf is not required. The Dart VM sampler works on a JIT run of the tool and needs the VM service.

```sh
dart --profiler --profile-period=250 --enable-vm-service=8181 \
  --disable-service-auth-codes tool/core_headless.dart bench n64 <rom> \
  --frame-runner --warmup 1800 --measure 1800
```

- Connect to `ws://127.0.0.1:8181/ws`, call `clearCpuSamples`, wait for the window, then call `getCpuSamples` with `timeOriginMicros: 0` and a very large `timeExtentMicros`. The timestamps are monotonic clock values, so a small extent returns no samples.
- `dart run` rejects `--profiler`. Pass the VM flags to `dart <file>` instead. Build hooks still run.
- Count the inclusive and the exclusive samples per function from the stacks. Look at the callers of a surprising leaf, such as string interpolation or a Map lookup.
- A JIT run does not inline like AOT. A small helper such as a clamp shows as its own function. Treat the numbers as a guide to where to read the AOT output.
- Profile the path the application uses. `--frame-runner` runs compiled blocks, and the share of the interpreter and of the device code differs from the exec loop.
- The window includes block compilation when the scene changes. Take a second window to see the steady state.

## Getting the assembly

The release `gen_snapshot` rejects `--disassemble`. Build an AOT snapshot ELF and read it with `nm` and `objdump`.

```sh
dart compile aot-snapshot probe.dart -o probe.aot
nm -n -S probe.aot | grep 'N64Graphics._combine'
objdump -d -M intel --no-show-raw-insn \
  --start-address=0x<addr> --stop-address=<addr+size> probe.aot
```

- Write a small `probe.dart` that calls the target function. For private members, use a copy of the package with a public wrapper.
- `dart compile` refuses packages with build hooks such as `mp_jit_recompiler`. Remove that dependency from the probe copy.
- Type flow analysis narrows field values and concrete types using only reachable writes. A probe simpler than the real program can fold fields to constants or make calls look monomorphic. Call the function with the same types and value kinds as the real program.

## Compiler behavior

1. `double.clamp(a, b)` returns `num`. It allocates a boxed double, calls `compareTo` twice and converts back with a dynamic dispatch. One clamp costs over 30 instructions plus an allocation.
2. Indexing a `List<double>` parameter whose concrete type is unknown is an indirect call dispatched on the class id. A declared `Float64List` is one `movsd`.
3. A growable `List<double>` needs two pointer loads and a boxed double read per element. Use `Float64List` for numeric arrays.
4. `switch` and `if` chains are compare chains, not jump tables. Inlining them with `prefer-inline` duplicates the chain at every use.
5. Every index is bounds checked. A constant index still gets `cmp` and `jae` unless the length is a known constant.
6. Each loop back-edge has a stack overflow check. Values live across calls are spilled to the stack.
7. `setAll` and `fillRange` are not inlined and cost a call. Assign small fixed counts by hand.
8. `x / 255` stays a `divsd`. Replacing it with `* (1 / 255)` changes rounding, so the compiler does not do it.

## Guidelines

- Declare hot numeric arrays as concrete `Float64List` or `Int32List`. Build constant tables with `Float64List.fromList` in a `static final` instead of `const [...]`.
- Resolve branches that depend only on configuration into indices when the configuration changes. Keep per-pixel work to index loads.
- When a function reads from several buffers, put them in one `Float64List` and expose parts with `Float64List.view`. A selector then becomes an index.
- Write clamps as `v < 0 ? 0.0 : (v > 255 ? 255.0 : v)` on `double`.
- To keep views in `final` fields, delegate to a private constructor that receives the buffer and builds the views in its initializer list. `late final` adds an initialization check on every read.
- Replace `List.generate` with closures, `reduce` and `map(...).toList()` on small fixed-size math (matrix multiply, vertex transform) by loops or straight-line expressions into a `Float64List`. Left-to-right sums give the same results as `reduce`, so the output stays bit-identical.
- Hoist loop-invariant field reads and flag tests (`geometry.bit0 && ...`) into locals before a per-pixel loop. Fields are reloaded every iteration when the loop body contains calls.
- Replace a local closure that captures nothing with a static method, and `int.clamp` with a comparison.
- Do not build error messages eagerly. A `check(ok, 'v$i ...')` helper interpolates the string on every call, even when `ok` is true. Test the condition first and build the message only in the failing branch.
- Do not use records as map keys on a hot path. Each lookup allocates the record and hashes it through the generic record hash. Pack small integers into one int key.
- Avoid a `static final` table in a hot loop. It is initialized lazily and every read checks the initialization. Use an instance field.
- `double.round()` and `int.toDouble()` can be calls. For a value known to be in range, use `(v + 0.5).toInt()` and a lookup table of doubles.
- A divide by a power of two can be a multiply by its exact reciprocal, from a small table. Other divides must stay, because the rounding changes.
- Write the highest index of a small fixed-size buffer first, so that the later constant-index bounds checks are redundant.
- Mixing `int` and `double` in a ternary gives `num`, and the arithmetic on it is dynamic. Keep each branch in one type.
- After a rewrite, compare the function size from `nm -S`, the list of `call` targets and the presence of `AllocateDouble`.

## Ideas to consider

- Give fixed-size groups of doubles a purpose-built type instead of a `Float64List` or `List<double>`. The N64 graphics code now uses `Rgba`, `Vec3`, `Vec4` and `Light`. Field access has no bounds check, a wrong index cannot happen, and the code says what each value is. The combiner resolves its input colors to references when its registers change, so it reads fields only, and its code is about half the size (769 bytes against 1,429). The frame rate did not change measurably, because the checks were cheap and predictable, so do this for clarity and expect little speed. The listing showed no allocation for the double fields. Keep a list where the data is an array by nature, such as a 4x4 matrix indexed by arithmetic, and convert only at the boundary of a codec.
- In a hot spot, pass arguments and return values through shared variables (fields of the owner) instead of creating a list or a record per call. The scratch colors `_shade` and `_textureColor` do this. A trial that kept the interpolants `s`, `t`, `1/w` and depth in a shared buffer across the calls of the pixel loop, to cut the live doubles, gave no gain. The loads from the stack were cheap next to the work of the calls.
- A loop with calls keeps its doubles on the stack, because Dart has no callee-saved floating-point registers. Reduce the number of live doubles across a call, for example by moving the per-pixel state into fields or by splitting the loop at the call.

## Reading the hot spots of the rasterizer

The listing of the triangle loop, the texel fetch and the pixel write showed these points. Several are fixed in the source.

- The loop carries 11 doubles and 11 steps, which is more than the 16 SSE registers, and the calls inside it force a reload of about 20 values per pixel.
- Four bounds checks for the four stores of the shade buffer, each with a reloaded length.
- Two divides per pixel for the perspective texture coordinates. They are needed to keep the output exact.
- `floor()` is `roundsd` plus `cvttsd2si`, with a CPU feature check and an overflow fallback call. Calling it twice per texel coordinate is acceptable.
- Local functions that capture variables allocate closures per call of the enclosing function. Use static helpers for the per-triangle math.
- `ListBase.map`, `reduce` and `toList` on three-element lists were calls and allocations for each triangle.

## Measuring

- The host load changes the frame rate by 10% or more from run to run, and sometimes by 2x between sessions. Build the compared versions into separate bundles and run them alternately, several rounds each. Compare medians of the process CPU frame rate (`cpuFps`), and never compare numbers from different sessions.
- Check the hashes of the frame images and of the audio (`--checksum`) in every round. A rewrite that keeps the arithmetic order keeps the hashes equal.
- Measure the path the application runs (`--frame-runner`) as well as the plain exec loop. They can differ by 2x.
- A change that the profile does not explain, and that gains less than the noise, is not worth keeping for speed. Keep it only if it makes the code clearer.

## Practical notes

- `dart format` takes the language version of the package. A file formatted by an older style shows hundreds of changed lines when it is formatted again by a package of a newer language version. Format a copy inside the same package with `--output=none` to see whether the file is clean before running the formatter, and do not format a package that is not clean.
- To disassemble code of a package with a build hook, copy the package to a scratch directory and cut the hook and the calls that need it. Call the function with the same types and values as the application.

## Result: N64 `_combine`

| Item | Before | After |
|---|---|---|
| Function size | 4,876 bytes | 856 bytes |
| Calls | `compareTo`, `AllocateDouble`, 20 class-id dispatches and others | stack checks, error paths and the decode on a cache miss |
| `divsd` | 2 | 1, inside the loop |

The inputs are gathered in one `Float64List`, selectors are looked up as cached indices and the clamp is a plain comparison.

## Result: N64 rasterizer and compile path

SM64 frame time, whole-frame runner, same machine. The image and audio hashes of every checked frame stay equal.

| Change | Effect |
|---|---|
| Typed numeric arrays, `_combine` with decoded selectors | about 2x |
| No closures or list math in the triangle setup, instance tables, table conversions, `toInt` rounding, a faster scanout | about 1.2x more |

The same profile found two compile-path costs outside the graphics code: eager message strings in `IrBlock.verify` and record keys in the dispatch maps. Both are fixed with the rules above. Their gain was not measured separately.
