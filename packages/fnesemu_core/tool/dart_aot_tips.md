# Dart AOT performance notes

Findings from profiling hot paths and reading their x64 AOT output. The N64 color combiner (`_combine`) and rasterizer were the first subjects. The SH-2 interpreter, the JIT dispatch tables and the Saturn VDPs followed.

## Rule: decide speed in the AOT build

The application ships as an AOT build. The JIT VM, which runs `core_headless.dart bench` and the sampler below, inlines, unboxes and guards differently, so its frame times and its profile do not tell whether a change is faster in the application. A speed result from a JIT run is not evidence. Use the JIT run to find hot functions, then confirm every change in the AOT build twice: by the x64 listing (instruction counts, packed or scalar operations, allocations, calls) and by the time of a probe that is compiled with `dart compile exe`. See "AOT probe". The sections below that report frame rates or frame times from `core_headless.dart bench` are JIT numbers, unless a line says AOT. Treat them as hints and recheck a result in the AOT build before building on it.

## Profiling

perf is not required. The Dart VM sampler works on a JIT run of the tool and needs the VM service. It finds hot functions. It does not rank changes by speed (see the rule above).

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

## AOT probe

`dart compile exe` rejects a package with a build hook, so a probe takes a copy of the pure Dart files it needs, not the package.

- Copy `lib/src/util`, `lib/src/state.dart` and the files of the component, give the copy a `pubspec.yaml` with `meta`, and replace a bus that imports `mp_jit_recompiler` by a small stub with the members that the component calls.
- For a component that needs a real scene (the Saturn VDP2), write a temporary tool in `tool/` that loads a saved bench state through `Session`, saves the component with its own `saveState` into a `StateWriter` and writes the bytes to a file. The probe reads the file with `StateReader`, calls `loadState` and times the real entry point (`renderLine` for every line) over several rounds. Delete the temporary tool afterwards.
- For the N64 graphics, replay a real task. Add a temporary static hook at the start of `N64Graphics.task`, load a saved bench state in a temporary tool, and at the k-th task write the arguments, `graphics.saveState` and the whole RAM (8 MB) to a file. The probe loads the RAM into the stub bus, calls `loadState` and then `task(...)` again for several rounds, and hashes the color image after the first call. Remove the hook and the tool afterwards. A scene of the real game has small triangles, and its result differs from a synthetic probe of a few large triangles (see below).
- For a synthetic probe of `triangle`, feed vertices and a state that reaches the pixel write. Check that the output hash of the probe is not that of an empty buffer. A probe whose alpha is zero rejects every pixel early and measures a different loop.
- Build the compared versions as separate executables, run them alternately several times and compare the minimum and the median. Compare the output hashes first.
- Read the listing of the changed function with `nm -n -S` and `objdump` as in "Getting the assembly". Count the instructions by name.

## Compiler behavior

1. `double.clamp(a, b)` returns `num`. It allocates a boxed double, calls `compareTo` twice and converts back with a dynamic dispatch. One clamp costs over 30 instructions plus an allocation.
2. Indexing a `List<double>` parameter whose concrete type is unknown is an indirect call dispatched on the class id. A declared `Float64List` is one `movsd`.
3. A growable `List<double>` needs two pointer loads and a boxed double read per element. Use `Float64List` for numeric arrays.
4. `switch` and `if` chains are compare chains, not jump tables. Inlining them with `prefer-inline` duplicates the chain at every use.
5. Every index is bounds checked. A constant index still gets `cmp` and `jae` unless the length is a known constant.
6. Each loop back-edge has a stack overflow check. Values live across calls are spilled to the stack.
7. `setAll` and `fillRange` are not inlined and cost a call. Assign small fixed counts by hand.
8. `x / 255` stays a `divsd`. Replacing it with `* (1 / 255)` changes rounding, so the compiler does not do it.
   The project allows the changed rounding, so write the reciprocal by hand: a `static const _inv255 = 1 / 255` in the combiner, `1 / area` and `1 / w` once per triangle, and the reciprocals of the edge steps once per triangle for the row narrowing. A division by a power of two is already exact as a multiply.
   - The x64 listing of the N64 triangle loop shows what changes. `_combine` goes from 2 `divpd` to none, and `triangle` from 26 `divsd` to 7, with the instruction counts about equal (1,769 to 1,789 and 326 to 328). A `divpd` costs about 4 to 5 cycles of throughput against 1 or less for a `mulpd`, so the saving is about 8 to 10 cycles per pixel, or 3% to 5% of the frame. The JIT frame times gave about 4% in one run and below the noise in another. Confirm such a change in the AOT listing and the AOT probe.
   - One division per pixel stays. The interpolated `st` is `(s / w, t / w)` and the interpolated `zi.y` is `1 / w`, so `st / zi.y` gives the perspective-correct `(s, t)`. The `w` of the pixel is `1 / zi.y`, which needs the same division, so there is nothing to precompute. Only an approximation (an exact divide every few pixels and a linear step between them) would remove it, and that changes the output.

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

## SIMD types

`dart:typed_data` has `Int32x4` and `Float64x2`. `Float32x4` rounds to float32, so it changes the output of code that computes in `double` (see the N64 result below). A probe built with `dart compile aot-snapshot` on x64 showed this.

- `Float64x2` operations compile to packed instructions (`subpd`, `mulpd`, `divpd`, `addpd`, `maxpd`, `minpd`). The lane rounding is the same as the scalar IEEE double operation, so a rewrite keeps the hashes equal when the order of operations is kept. Locals stay in registers and nothing is allocated inside a loop.
- `Int32x4` operations compile to `andps`, `orps` and `paddd`. A value that is returned from a function that is not inlined is allocated (`AllocateInt32x4`).
- Building a `Float64x2` from two list elements costs two scalar loads and two bounds checks. Store the data in a `Float64x2List` so that one element is one 16-byte load.
- `Int32x4` has no multiply, no shift, no `splat` and no compare. `Float64x2` has no compare, no `floor` and no conversion to integer. Pixel code that multiplies, shifts by a variable or compares per lane gets no help.
- There is no gather. Palette and table lookups (`cram`, `rgba[...]`, `_color(index)`) stay scalar.
- The types do not exist on every target. Check the web build before using them in `fnesemu_core`.
- A `Float64x2` field of an object is stored inline and unboxed. Assigning it is one 16-byte store, with no allocation.
- N64 triangle loop with the colour, the combiner registers and the interpolants as `Float64x2` (`Rgba` as two fields, the register file as a `Float64x2List`, s and t, depth and 1/w as vectors passed to the combiner and `_texel`), and the divisions written as reciprocal multiplies. The x64 listing of the combiner shows `subpd`, `mulpd`, `addpd`, `maxpd` and `minpd` and no allocation. The AOT probe, 150 large triangles with a texture, the combiner and pixel writes, the output hash equal to the scalar code: 18.0 to 18.7 ms per run for the scalar code and 17.4 to 18.0 ms for the vectors (the minimum of five alternating runs), a gain of 3% to 4%. A probe whose pixels were all rejected early (alpha zero, so the loop is the interpolation, the texel and the combiner only) ran at 55 to 58 ms against 46 to 54 ms, 10% to 15%. The JIT bench of a real scene gave 23.9 ms against 19.6 ms (20%), which is not evidence by the rule above. Passing the data as vectors matters. Packing and unpacking lanes around scalar code would cost the gain.
- Saturn VDP2 rotation (`_rotDot`) with `(xsp, ysp)`, `(dX, dY)`, `(kx, ky)` and `(xp, yp)` as `Float64x2` and one expression `kk * (sp + dd * x) + pp`. The output was equal. In the listing of the AOT build the two multiplies and two adds of the main path become 2 `mulpd` and 2 `addpd`, but the function grows from 1,165 to 1,179 instructions (more `movups` and `shufpd`), because the time of `_rotDot` is in the two `floor` conversions and the cell lookup. The AOT probe of a rotation scene (`renderLine` of all 448 lines, 704 wide) gave 14.0 to 14.8 ms per frame for the scalar code and 14.3 to 14.7 ms for the vectors: no gain. Do not do this one.
- The variants that were rejected on JIT numbers were measured again in the AOT build, first with a synthetic probe (150 large triangles, 5 alternating runs of 7 rounds, output hashes equal except for fixed point). Per run, the minimum, in ms: develop 11.9, `Float64x2` 11.2, `Float64x2` with reciprocals 11.1, one `Float32x4` per colour and per interpolant 11.5 to 12.2, fixed point 11.6 (a different output hash), and the whole per-pixel path in float32 7.8. The JIT bench had found the float32 path as slow as the others. The synthetic probe was misleading in the other direction, as the next item and the real scene show.
- The gain of the float32 path in the synthetic probe was the coverage test, not float32. A `Float32List` depth buffer (11.9 to 12.0), `Float32List` tables (11.9), and the float32 path with a `Float64List` depth buffer or `Float64List` tables (7.6) showed that those do not matter. The float32 path kept the edge weights in one `Float32x4` and tested the three lanes with `signMask`, where the scalar code did three compares, three `abs` compares and `1 - wa - wb` up to three times per pixel. A scalar test with a fast path for the common case gives the same 7.8 ms with `double`, the same hash and the same decisions:

  ```dart
  final wc = 1 - wa - wb;
  var inside = true;
  if (!(wa > 1e-10 && wb > 1e-10 && wc > 1e-10)) {
    inside = wa >= 0 && wb >= 0 && wc >= 0;
    if (wa.abs() < 1e-10 || wb.abs() < 1e-10 || wc.abs() < 1e-10) {
      // the exact test near the edge
    }
  }
  ```

  A pixel more than 1e-10 inside every edge needs no exact test, which is almost every pixel. With large triangles about 30% of the loop was this test. Look at the per-pixel tests of a loop before looking for wider data types.
- The same variants on one real scene (a race frame, one graphics task with 392 triangles, replayed 3 times per round, 5 alternating runs, equal output hashes except for float32). Per task, the minimum, in ms: develop 8.95, `Float64x2` 8.56, `Float64x2` with the reciprocals and the coverage fast path 7.94, a gain of 11% over develop. The whole float32 path ran at 12.3 ms and its output hash differs, so it is slower and changes the image on real triangles. The small triangles of a real scene spend their time in the setup, the row narrowing and the texel fetch, which is why the coverage test is worth 7% there and not 30%. Decide on a real scene, not on a synthetic probe.
- Fixed point (the colour in 16.16 integers, the texel, the combiner and the pixel write in 8-bit integers with `Int32List` registers, and the coordinates and edges in `double`): 11.6 ms against 11.2 ms for `Float64x2` in the synthetic AOT probe, so no gain, and the output hash differs. Not run on the real scene. The integer combiner reads and writes about 30 list elements per pixel, each with a bounds check, where the vector code does a handful of loads and packed operations. A JIT profile of the `Float64x2` build put 68% of the samples under `triangle`, with `_texel` and `_coordinate` (the `floor`) at 26% and `_put` at 14%.
- Not measured: the other candidates below.

### Candidates

| Core | Place | Type | Note |
|---|---|---|---|
| N64 | `_combine` (`(a - b) * c / 255 + d`, clamp) | `Float64x2` | Four channels are two vectors. The `divpd` keeps the rounding of `/ 255`. Needs the register file as a `Float64x2List`, and the alpha selectors may differ from the color selectors. |
| N64 | `multiply`, `transform` | `Float64x2` | Vectorize across the output columns and keep the left-to-right sum, so the result is bit-identical. Needs the matrices as a `Float64x2List`. |
| N64 | Interpolants in `triangle` (`red`, `green`, `blue`, `alpha`, `ss`, `tt`, `divisor`, `dz`) | `Float64x2` | Pairs with their steps halve the live registers of the pixel loop, which the notes above show spilled. `wa` and `wb` and the coverage tests stay scalar. |
| N64 | `Rgba`, `Vec4` fields | `Float64x2` | Only if the combiner and the interpolation take the vectors. A conversion at every use costs more than it saves. |
| Saturn | VDP1 `_half`, `_avg` and VDP2 `_add` (saturating add per channel) | scalar SWAR on `int` first | The shift and the compare are missing in `Int32x4`. Several 16-bit or 8-bit fields in one 64-bit `int` with mask and add do the same work without a SIMD type, and the saturation can use the carry bits. Do not use this on a target where `int` is a JavaScript number. |
| Saturn | VDP2 `_blend`, VDP1 `_gouraud` | none | Multiply by a variable ratio and clamp per channel. Keep scalar. |
| Saturn | VDP2 rotation (`_rotDot`) | `Float64x2` | Tried: no gain in the AOT probe. The time is in the `floor` and the cell lookup, not in the six floating point operations. |
| 32X | `ExpansionVideo.renderLine`, `color` | none | A lookup in the palette, a switch on the bitmap mode and the priority test per pixel. The 5-bit to 8-bit expansion needs shifts. |
| MD | `vdp_renderer` pixel loop | none | Priority selection and lookups in `cram`. No arithmetic to vectorize. |
| PS1 | `Color.mix`, `_span`, textured and Gouraud pixel loops | none | Integer multiply and `~/ width` per channel. Replace the divide by a per-span step (fixed-point stepping) first. That changes the rounding and needs a check of the images. |
| Audio (N64 RSP audio, SCSP, YM2612) | Mixing and filter loops | none | Gain multiply and clamp per sample. |
| SH-2, M68000, Z80 and the JIT | Interpreters and dispatch | none | Scalar integer control flow. |

N64 `_combine` and `triangle` are the only places where the type matches the data. Try them first, one at a time, with the checks under "Measuring".

## Reading the hot spots of the rasterizer

The listing of the triangle loop, the texel fetch and the pixel write showed these points. Several are fixed in the source.

- The loop carries 11 doubles and 11 steps, which is more than the 16 SSE registers, and the calls inside it force a reload of about 20 values per pixel.
- Four bounds checks for the four stores of the shade buffer, each with a reloaded length.
- Two divides per pixel for the perspective texture coordinates. They are needed to keep the output exact.
- `floor()` is `roundsd` plus `cvttsd2si`, with a CPU feature check and an overflow fallback call. Calling it twice per texel coordinate is acceptable.
- Local functions that capture variables allocate closures per call of the enclosing function. Use static helpers for the per-triangle math.
- `ListBase.map`, `reduce` and `toList` on three-element lists were calls and allocations for each triangle.

## Measuring

- Frame rates from `core_headless.dart bench` are JIT numbers. Use them to check that the output hashes are equal and that the application still runs, and decide the speed in the AOT probe.
- The host load changes the frame rate by 10% or more from run to run, and sometimes by 2x between sessions. Build the compared versions into separate bundles and run them alternately, several rounds each. Compare medians of the process CPU frame rate (`cpuFps`), and never compare numbers from different sessions.
- Check the hashes of the frame images and of the audio (`--checksum`) in every round. A rewrite that keeps the arithmetic order keeps the hashes equal.
- Measure the path the application runs (`--frame-runner`) as well as the plain exec loop. They can differ by 2x.
- A change that the profile does not explain, and that gains less than the noise, is not worth keeping for speed. Keep it only if it makes the code clearer.

## Where to profile

- Profile a scene of the real workload, not the boot. A state saved after the warmup (`--save-state`, then `--load-state` with the same `--warmup`) gives the same scene for every run, for the sampler and for the A/B runs. In the boot and the BIOS wait loops of two cores, the interpreter and the BIOS reads dominated. In the game scene the hot spots were the JIT dispatch bookkeeping and the VDP2 renderer, which the boot profile did not show at all.
- Check the scene on a screenshot (`--out`) before trusting a profile.
- Hash files of the frames from two runs of the same build can differ in the first frames. Compare the frames after them and the audio hash.
- Start the profiled process from a script and kill it by its pid. `pkill -f <name>` also kills the shell whose command line contains the name.

## Result: interpreter, JIT dispatch and VDP

| Finding | Fix |
|---|---|
| A `(int, int)` record returned or built per instruction is allocated even for the constant `(0, 0)` branch, and its fields are read as `dynamic`. | Return through two fields of the owner. |
| A loop of 16 `r[i] &= 0xffffffff` per instruction on a `Uint32List` that already truncates on store. | Remove it. |
| A `late final` field read is a call when the function is large (`Sh2.r` was called 171 times in one function), and a `late final` view needs an initialization check. | Build the buffers and views in the initializer list through a private constructor. |
| Small getters and setters (`sr`, `pr`, `t`) were calls inside a 22 KB switch function, although the callee is tiny. | `@pragma('vm:prefer-inline')` on them. The caller shrank from 1,590 to 1,162 bytes, and the frame rate rose by about 10%. |
| A 16-bit or 32-bit read built from byte reads walks the whole region chain twice or four times. | A direct path for the common areas at the top of the 16-bit and 32-bit accessors, taken only when all bytes are inside the area. |
| `Map<int, int>` lookups (and `containsKey`) on the dispatch path, and records as keys of the profile map. | `IntMap`, an open-addressing table over `Int64List`, and packed int keys. The direct-mapped table that the native code searches answers first. |
| The driver tables were cleared at 4,096 entries together with the profile table, so the miss counters and the fallback entries were lost several times per frame and the same blocks were counted and translated again. | Give the driver its own capacity (65,536). This was the largest gain of the Saturn game scene, about 30%. |
| A list and a closure allocated per scheduling step (`[false, false]`, `cpus.any(...)`). | Locals. |

The profile of a JIT run shows the time inside the native code under the callback entry (`ffiClosure0`). Read it as the cost of the compiled code plus the callbacks, and count the callbacks (read helpers and exits) before trying to speed it up.

Code that runs from an area the JIT does not map (the on-chip cache data array, the boot ROM) goes through the interpreter, so the interpreter and the bus stay on the profile of such a scene.

## Result: Saturn VDP2

In a game scene the VDP2 renderer took about half of the frame. The hot functions were the rotation dot (`_rotDot`), the dot fetch (`_dot`), the cell setup and the layer composition.

- Per dot, `_rotDot` does two `floor` calls (`roundsd`, `cvttsd2si` and an overflow branch each), loads about eight `double` fields and, with a coefficient table, one more `divsd`. `_dot` switches on the color mode for every dot, reads 16-bit and 32-bit words through the big-endian `ByteData` getters (a byte swap each) and bounds checks every array access.
- `late final` views in the renderer cost an initialization check on every read. They are built with the buffers now. The frame rate did not change measurably, so this is for the shape of the code.
- The divisions by the plane size in the cell setup are shifts, because a plane is 1 or 2 pages of 512 dots. The result is the same. The gain is small and within the noise of some runs.
- Splitting the composition by layer (a loop per layer that keeps the top and the second dot of every x in line arrays) is slower by about 8%, although the image hash is the same. The inner loop of the one-pass version spills many values, but the extra reads and writes of six line arrays cost more. Measure such a split before keeping it.
- Ideas not tried: a loop per color mode with the per-line constants hoisted, and fixed-point rotation. The second changes the output and needs a check of the images.

## Practical notes

- A new worktree has empty submodule directories. Run `git submodule update --init` for the submodules the package needs (`cdrom_image`, `mp_bigfile_picker`), then `dart pub get` in `packages/fnesemu_core`. Without them the tools fail on `package:image` or on a missing path dependency.
- To sample a bench run, start it with `--enable-vm-service`, wait until the state is loaded (about 8 seconds), then call `getVM`, `clearCpuSamples` and `getCpuSamples` over the web socket and read `exclusiveTicks` and `inclusiveTicks` of each function from the result. A window of 20 seconds on a run of 2,500 frames was enough. Start the bench as a background job, keep its pid and stop it with `kill <pid>`.
- Compare builds by the median of several alternating rounds of `msPerFrame` from `--load-state`. The first rounds after a build are often 1.5x to 2x slower than the rest, so a round count under four can show the wrong order.
- Keep the build under test and the reference as two copies of one file and swap them between rounds. This is cheaper than two checkouts, and both builds run on the same tool code.
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
