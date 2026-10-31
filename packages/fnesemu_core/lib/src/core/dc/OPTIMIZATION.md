# DC performance work

Use `tool/core_headless.dart bench` with `--frame-runner` for performance work. The instruction-oriented `dc_probe.dart` includes diagnostic disassembly and must not be used as an FPS benchmark.

Follow the Dart AOT performance notes (`packages/fnesemu_core/tool/dart_aot_tips.md` in the main checkout) and the shared recompiler performance guide. Use fnesemu's N64 typed numeric storage, SS memory fast paths and SH-2 dispatch improvements as candidate implementations, subject to DC's memory, cache and device semantics.

## Measurement

Build the headless tool with `dart compile exe tool/core_headless.dart -o /tmp/dc-headless`. The current Dart 3.13.5 SDK accepts this build; retain native assets alongside a CLI bundle when benchmarking a core that uses the native recompiler.

The DC positional media is the boot ROM, `--bios` supplies the flash image, and the optional second positional media is the disc. For example:

```sh
/tmp/dc-headless bench dc BOOT_ROM DISC --bios FLASH \
  --load-state CHECKPOINT --frame-runner --warmup 2 --measure 5 --checksum
```

Checkpoints must match the boot profile, BIOS and media. Headless states have an eight-byte little-endian frame number before the core state; a raw probe checkpoint needs that header added in a temporary file. Do not change the core's media validation to make a mismatched checkpoint load.

Run baseline and candidate executables in alternating order, with no concurrent builds or profiling. Report the median headless `cpuMsPerFrame` for each variant as CPU ms/frame, its absolute difference and percentage change. Use process CPU time rather than wall time to reduce interference from other host workloads. Earlier FPS observations below retain their original measurement basis. Require matching frame/audio hashes, guest clocks and final PC. Build both variants with the same SDK version. Use JIT CPU samples only to locate work, then examine AOT code and measure native AOT execution.

## GPIO configuration decoding

The initial BIOS menu profile found GPIO pin sampling and output-mask reconstruction among the hot functions. The original implementation inspected all 20 pin control fields on each nonzero BCLK advance, and rebuilt the output mask on GPIO reads and interrupt checks.

Decode the output and pull-up masks when control registers change, and rebuild these derived masks after reset or state loading. Sample the external driver and pull-up masks with bitwise operations at the same BCLK boundary. The serialized state format and pin sampling policy stay unchanged.

The existing GPIO, INTC and public core-state scenarios pass (23 tests). AOT disassembly confirms that `DcGpio.tickBusClocks` has no per-pin loop. Four alternating native AOT runs per variant (two warmup frames, five measured frames, identical BIOS menu checkpoint) reduced median CPU time from 548 to 501 ms/frame, about 8.6%. All runs matched image hash `5dcc1ea`, audio hash `5dacbdc5`, guest clocks and final PC. Host timing remains noisy, and the BIOS menu alone does not establish a gameplay FPS improvement.

## Remaining candidates

- Confirm retained improvements with fresh baseline/candidate builds using the current Flutter/Dart SDK; do not compare executables built with different SDKs. Refresh hotspot samples before attempting larger CPU/device scheduling changes.
- If revisiting AICA deadline caching, investigate using its existing RTC phase to avoid per-tick cached-counter updates. A phase-based cached deadline must be invalidated on RTC phase wrap, including large advances, reset/load, ARM control and DMA changes. The decrementing-counter variants below were rejected.
- Consider skipping the complete TMU candidate loop when all three TMU priority nibbles are zero; preserve the retained source-priority guards and tie order.
- The control-only major-opcode gate was also rejected below. The FPU-only classification gate remains unmeasured independently of the control gate.
- Measure cache-location return costs before replacing return values; record syntax alone does not establish allocation.
- Examine GPU triangle interpolation closures, repeated parameter decoding and repeated translucent object traversal; preserve ordering, memory visibility and image hashes.
- Profile renderer buffer initialization checks before changing their ownership or initialization timing.
- Investigate caching the provisional board GPIO link until control/latch changes, while retaining its before-instruction timing and detecting external driver changes.
- The updated diagnostic gameplay sample (22,147 JIT samples, after warmup) places bus ticking and SH-4 stepping ahead of rasterization. Investigate repeated device deadline calculations and ordinary-memory store routing before assuming more texture work is valuable. This ranking locates work; it is not an AOT speed result.
- Establish representative gameplay checkpoints for the normal factory profile and validate improvements in more than the BIOS scene.

## Gameplay checkpoint support

Headless accepts `--dc-profile diagnostic` to reproduce legacy probe checkpoint identity and its provisional verification/audio policies. This selects one-clock CPU stepping without automatic GPIO wiring; it does not reproduce the probe's optional extra peripheral-clock multiplier. `--dc-drive-format 80` explicitly selects the diagnostic GD-format response used by the existing gameplay checkpoint. Leave these options unset for the normal factory profile.

The retained gameplay checkpoint loads with these explicit options. Its rendered scene shows game characters, and audio callbacks produce a deterministic hash. Initial native AOT measurement uses one warmup frame and two measured frames, with image hash `7801a726` and audio hash `b4cd3333`. This is a real game-program scene under a diagnostic timing profile, not evidence of normal BIOS authentication or physical timing accuracy.

## Rejected interrupt changes

The AOT `DcIntc.pending` listing returns the priority and event directly in two registers. It does not allocate a record on the ordinary return path. Do not replace this interface just because the source returns a record.

A trial moved delay-slot, BL and maximum-priority-mask rejection before interrupt candidate scanning, following the SH-2 early-eligibility pattern. All 78 existing interrupt/exception/GPIO/public-state tests passed, and hashes, guest clocks and final PC matched in the BIOS and gameplay comparisons. However, BIOS median CPU time regressed from 369 to 377 ms/frame. Gameplay medians were noisy (2502.5 versus 2200 ms/frame), with nearly identical minima (2185 versus 2175). The trial was reverted because a reproducible gain was not established.

## Ordinary-memory read routing

Like SS's early ordinary-memory branches, route 16-bit and 32-bit BIOS/main-RAM reads before the device-register chain. Use the translated physical address for classification when present, exclude direct P3/P4 addresses, and preserve the original cache lookup, fill/peek policy, alignment checks and 32-bit result mask. This only skips irrelevant device decoding; it does not read raw RAM around the MMU or cache.

All 106 existing bus/cache/MMU/exception/public-state tests pass. The AOT listing inlines the range checks and branches directly to `DcCache.readLocation` for ordinary memory.

Four alternating AOT runs per variant matched image/audio hashes, guest clocks and final PC in both scenes. BIOS median CPU time decreased from 383 to 354 ms/frame (7.6%). Diagnostic gameplay median CPU time decreased from 2395 to 2092.5 ms/frame (12.6%); minima decreased from 2175 to 2080 ms/frame (4.4%). Timing remains noisy, so treat the percentages as scene-specific observations rather than a universal gain.

## Rejected texture initialization changes

Two trials converted texture configuration from `late final` fields to ordinary `final` fields, first through a factory/private constructor and then through a normal constructor initializer list. This applies the same initialization-check reduction described in the Dart AOT notes. The `_texel` listing shrank from 3506 to 3182 bytes and removed 22 late-initialization guard/error references. However, fewer instructions did not establish a faster frame.

The factory trial regressed BIOS median CPU time from 348 to 353 ms/frame and gameplay from 2115 to 2420 ms/frame. The initializer-list trial regressed BIOS from 349 to 357 ms/frame; unpinned gameplay timing was inconsistent. A further alternating gameplay comparison pinned to CPU 2 still regressed the median from 2105 to 2362.5 ms/frame, with an unstable candidate distribution. Both trials matched image/audio hashes, guest clocks and final PC. Their seven selected texture suites had the same 78 passing and 31 failing cases as the baseline, with identical failure names and expected/actual diagnostics. Both implementations were reverted; the original constructor and field representation remain in place.

## SH-4 instruction classification

Move prohibited delay-slot instruction classification inside the existing delay-slot check. Replace constant-list searches in conditional branch, cache-operation and FPU system-register decoding with masked comparisons or switch patterns. This follows the same allocation and dispatch reduction used in the SH-2 interpreter; it does not change instruction semantics or scheduling.

All 65,536 opcodes give the same conditional-branch classification with the new mask. The existing SH-4 instruction, FPU, exception, interrupt and divide/MAC suites pass (185 tests). The AOT `Sh4._step` listing has no `contains` call or list-literal allocation.

Four alternating AOT runs per variant from the same BIOS menu checkpoint reduced median CPU time from 492 to 421 ms/frame (14.4%) relative to the GPIO-improved build. Image/audio hashes, guest clocks and final PC match in all eight runs. Gameplay validation remains required.

## Triangle scan bounds

Like the N64 rasterizer, intersect the triangle's coordinate bounds with the current tile before walking pixels. Keep conservative endpoint pixels and retain the original edge and top-left coverage tests, depth calculations and shading order. Derive the bounds from coverage vertices and the ISP pixel offset, including when the background uses a separate shading plane. Clamp floating bounds before integer conversion.

Four alternating native AOT runs per variant reduced median CPU time from 422 to 397 ms/frame (5.9%) relative to the instruction-classification build. Image/audio hashes, guest clocks and final PC match in all eight runs. The AOT listing contains bounded X/Y loop initialization and retains the original triangle arithmetic.

The selected existing rendering suites have 101 passing and 72 failing cases both before and after this change. The failing case names and expected/actual diagnostics match exactly; several failures concern TA record layout before rasterization. This comparison shows no additional failures in those scenarios, but does not establish a passing rendering suite. Keep these existing failures separate from performance claims and validate further gameplay scenes.

## Rejected clock ratio decoding and phase arithmetic

Decode CPU, bus, peripheral and watchdog periods when frequency/watchdog control changes. Rebuild the derived periods and power-of-two shifts after power-on reset and state loading; do not serialize them. Keep divider validation, phase normalization, PLL stabilization and watchdog reset behavior unchanged.

For power-of-two periods and nonnegative 31-bit phase totals, the trial computed the quotient and remainder with a shift and mask. It kept the existing division/modulo path for other periods and large or overflowed totals. The 31-bit guard preserved JavaScript arithmetic semantics. AOT inspection found real `AllocateRecord2` calls in an inlined helper trial, so another variant used local integer results and had none.

The existing clock/TMU/serial/public-state scenarios pass (43 tests). A temporary comparison against fnesemu's pre-optimization implementation matched results, periods and serialized state over 5,000 deterministic operations including divider changes, watchdog writes, resets and large clock values. A JavaScript comparison matched results, periods, public registers and deadlines over another 5,000 operations. JavaScript serialization was excluded because the existing state writer uses an unsupported dart2js Int64 accessor.

Four alternating AOT runs per variant matched image/audio hashes, guest clocks and final PC in both scenes. Diagnostic gameplay median CPU time decreased from 2515 to 2305 ms/frame (8.3%), with minima of 2210 and 2160 ms/frame (2.3%). BIOS median CPU time decreased from 516 to 478 ms/frame (7.4%), with minima of 482 and 474 ms/frame (1.7%). The wide distributions mean the medians overstate the certainty of the effect size; report the minima as well.

The longer comparison (five warmup frames, eight measured frames, four alternating runs per variant) did not reproduce a gameplay gain: median CPU time regressed from 2355.625 to 2395.625 ms/frame, and minima from 2125 to 2235 ms/frame. BIOS medians improved from 506.875 to 481.25 ms/frame. Hashes, guest clocks and final PC matched in both scenes. The inconsistent improvement did not justify the additional derived state and arithmetic branches, so the complete clock-ratio trial was reverted. The earlier short-window numbers remain exploratory observations, not retained performance claims.

A further one-clock-only increment/compare specialization was rejected: it regressed gameplay median CPU time from 2647.5 to 2940 ms/frame and BIOS from 430 to 472 ms/frame despite matching behavior. Fewer arithmetic operations alone were insufficient evidence of an improvement.

## Rejected core-owned execution results

The original frame runner calls `exec` for every instruction and allocates an `ExecResult` each time. A trial extracted the shared execution body into a void method, retained the five result values in private core fields and allocated the public result only at the `exec`/`runFrame` boundary. The 120 existing core/SPG/ARM-debug/state/clock/exception/interrupt scenarios passed, and AOT inspection confirmed no `ExecResult` construction in the instruction body. No execution-result fields were serialized.

However, a longer native comparison (five warmup frames, eight measured frames, four alternating runs per variant) did not establish a speedup. Gameplay median CPU time regressed from 2598.75 to 2618.125 ms/frame and BIOS from 441.875 to 472.5 ms/frame. Image/audio hashes, guest clocks and final PC matched in both scenes. The trial was reverted; allocation removal alone does not justify the additional persistent metadata fields.

## Direct store byte buffers and major-opcode gate trial

Build scalar store bytes directly in a fresh `Uint8List`, rather than constructing a growable integer list and copying it with `Uint8List.fromList`. Keep byte order, truncation and independent buffer ownership unchanged. AOT inlines the new helper; the old helper called both the growable-list constructor and `Uint8List.fromList`. The 106 existing bus/cache/MMU/exception/public-state scenarios pass.

Following the existing SH-2 major-opcode grouping, another trial gated control-transfer calls to SH-4 major groups 0/4 and skipped FPU system-transfer classification for ordinary F-group instructions. An exhaustive eligibility comparison covered all 65,536 encodings, including 928 recognized control encodings. All 185 existing SH-4 scenarios passed, preserving FD and illegal-instruction priority.

The three native AOT variants ran in order A/B/C/C/B/A twice per scene, with five warmup frames and eight measured frames. Values below are medians of the headless tool's measured `fps`, not reciprocals of CPU-time statistics.

| Scene | A: baseline FPS | B: direct store buffer FPS | C: buffer plus opcode gates FPS |
| --- | ---: | ---: | ---: |
| Diagnostic gameplay | 0.424203 | 0.439509 | 0.442000 |
| Normal-profile BIOS menu | 2.480974 | 2.502992 | 2.348154 |

Retain B: gameplay improves by 0.015306 FPS (3.61%), and BIOS by 0.022018 FPS (0.89%). All three variants match image/audio hashes, guest clocks and final PC in both scenes. Reject the combined opcode gates: relative to B, the gameplay change is only +0.002491 FPS (0.57%), while BIOS loses 0.154838 FPS (6.19%). The opcode-gate changes were reverted. Timing remains host-dependent; these are observations for the stated scenes and profiles.

## RAM write routing and zero-clock board calls

Route 8/16/32-bit main-RAM stores before the device-register chain. Classify translated physical addresses when supplied, and exclude direct P3/P4 addresses. Continue to call the existing cache writer with the same allocation, cacheability and write-through arguments; do not bypass the MMU, cache, store queues or byte-buffer ownership rules. The 106 existing bus/cache/MMU/exception/public-state scenarios pass.

A second variant skips BSC/GPIO bus-clock calls and TMU peripheral-clock calls when the supplied count is zero. GPIO already returns immediately for zero. Valid BSC phases are below the selected divisor, and valid TMU phases are below 1024, so zero clocks do not change their phases, counters or flags. Keep GPIO enable updates unconditional. Preserve SCI/SCIF zero-clock calls because they may start queued transfers. Negative clock counts still reach the original error checks. All 60 selected clock/BSC/TMU/GPIO/serial/public-state scenarios pass.

The first comparison used A/B/C/C/B/A twice per scene, five warmup frames and eight measured frames, without affinity restrictions:

| Scene | Baseline FPS | RAM routing FPS | RAM routing plus zero-clock guards FPS |
| --- | ---: | ---: | ---: |
| Diagnostic gameplay | 0.333362 | 0.445320 | 0.440386 |
| Normal-profile BIOS menu | 2.572200 | 2.349262 | 2.551626 |

The combined difference is +0.107024 FPS (+32.10%) for gameplay and -0.020573 FPS (-0.80%) for BIOS. All variants match image/audio hashes, guest clocks and final PC. Individual runs have wide distributions, so an additional comparison pinned both variants to Linux CPU 2, with the same warmup/measurement interval and four alternating runs per variant. Under the host hypervisor this controls guest affinity, not physical host placement.

| Scene, Linux CPU 2 | Baseline FPS | Combined FPS | Difference |
| --- | ---: | ---: | ---: |
| Diagnostic gameplay | 0.422324 | 0.472701 | +0.050378 (+11.93%) |
| Normal-profile BIOS menu | 1.336009 | 1.527362 | +0.191353 (+14.32%) |

Hashes, guest clocks and final PC match in both affinity-controlled scenes. Retain the combined routing and zero-clock guards: gameplay improves in both comparisons, and BIOS improves under controlled guest affinity while remaining nearly unchanged without it. Report results within each run configuration rather than comparing absolute FPS between different affinity settings or host-load windows.

## Rejected early RAM/BIOS resolution

A trial moved the existing RAM and read-only BIOS cases before FIFO, AICA and VRAM decoding in `_resolve`, retaining alignment, store-queue and segment guards. All 106 existing bus/cache/MMU/exception/public-state tests passed. Four alternating AOT runs per variant used Dart 3.13.5, Linux CPU 2, five warmup frames and eight measured frames. Gameplay median FPS changed from 0.476532 to 0.502107 (+0.025575, +5.37%); BIOS changed from 2.638384 to 2.571010 (-0.067374, -2.55%). All image/audio hashes, guest clocks and final PCs matched. The wide distributions and BIOS regression did not justify retaining the reordered dispatch; the trial was reverted.

## Rejected texture sample-position reuse

A trial reused the shading barycentric weights and depth for texture coordinates when their HALF_OFFSET positions matched. Distinct sample positions retained the original calculations, including separate background shading planes and supersampling. Four alternating Dart 3.13.5 AOT runs per variant on Linux CPU 2 used five warmup frames and eight measured frames. Gameplay median FPS fell from 0.512004 to 0.487498 (-0.024507, -4.79%); BIOS fell from 2.473605 to 2.306616 (-0.166989, -6.75%). Image/audio hashes, guest clocks and final PC matched in both scenes. The trial was reverted; removing repeated arithmetic did not improve the measured frame.

## Rejected frame-local execution result reuse

Following SS and N64's reusable result objects, a trial passed one frame-local `ExecResult` to a shared instruction body. Public `exec` still allocated a fresh result. Early stops reset both processor-executed flags; zero-line frames, partial clocks and scanline overshoot retained their original behavior. No persistent metadata fields or state-format changes were introduced. All 120 existing execution/state/SPG/ARM-debug/CPG/exception/interrupt scenarios passed. AOT inspection confirmed one allocation before the frame loop and none in `Dc._execute`.

Four alternating Dart 3.13.5 AOT runs per variant on Linux CPU 2, five warmup frames and eight measured frames, changed gameplay median FPS from 0.497956 to 0.525701 (+0.027745, +5.57%) and BIOS from 2.524526 to 2.481576 (-0.042950, -1.70%). A repeat changed gameplay from 0.537966 to 0.544663 (+0.006697, +1.24%) and BIOS from 2.570401 to 2.410370 (-0.160031, -6.23%). Both comparisons matched image/audio hashes, guest clocks and final PC. The small repeated gameplay gain did not justify the repeated BIOS regression, so the trial was reverted.

## Rejected deferred stopped-watchdog phase

A trial accumulated bounded master clocks while watchdog counting was disabled and normalized the phase before FRQCR/WTCSR changes and state output. Large clock values retained the original arithmetic path, counter writes reset both phase components, and loading rebuilt the derived state without changing the save-state schema. A temporary comparison against the original implementation matched 5,000 deterministic operations including resets, frequency/control changes and large clocks. Native results, periods and serialized states matched; JavaScript results, periods, registers and deadlines also matched. All 26 existing CPG/public-state scenarios passed.

Four alternating Dart 3.13.5 AOT runs per variant on Linux CPU 2 used five warmup frames and eight measured frames. Gameplay median process CPU time increased from 1896.875 to 1962.500 ms/frame (+65.625, +3.46%); BIOS increased from 439.375 to 444.375 ms/frame (+5.000, +1.14%). Image/audio hashes, guest clocks and final PC matched. The trial was reverted. Subsequent comparisons use process CPU ms/frame at the user's request, rather than wall-clock FPS.

## CPU profile refresh

After reverting the early-resolution, sample-position, frame-local-result and deferred-watchdog trials, profile the retained implementation through the existing headless frame runner. Use Dart 3.13.5, the diagnostic gameplay checkpoint and the normal-profile no-disc BIOS menu checkpoint separately. Allow 20 seconds of JIT warmup, clear CPU samples, then request 30 seconds of samples at a 250-microsecond period. The VM sample buffer retained 59,361 gameplay samples spanning 22.223 seconds and 59,313 BIOS samples spanning 21.566 seconds. These are JIT hotspot measurements, not AOT timing proportions.

Classify each retained stack once, prioritizing rendering, AICA, SH-4 stepping, board scheduling, core execution and other runtime work. In particular, memory and interrupt-check descendants remain in SH-4; the board group excludes rendering and AICA descendants. This prevents inclusive caller percentages from being added twice.

| Exclusive stack category | Gameplay samples | BIOS samples |
| --- | ---: | ---: |
| SH-4 execution, memory and interrupt checks | 39.80% | 33.08% |
| Board scheduling and other devices | 38.57% | 33.09% |
| AICA | 8.53% | 10.71% |
| Rendering | 7.63% | 18.09% |
| Core wrapper and provisional GPIO wiring | 4.43% | 3.36% |
| Runtime and headless | 1.04% | 1.68% |

The gameplay leaf hotspots include `DcIntc.pending` (3.93%), `DcCache.readLocation` (3.68%), `DcBus._tickMasterClocks` (3.44%), `DcAica.clocksToEvent` (3.37%) and `Sh4._step` (3.32%). Including descendants, `DcBus.cpuRead` accounts for 15.03%, and `DcBus.tickMasterClocks` for 54.44%; these inclusive values overlap the categories above. BIOS rendering is larger, with `_triangle` at 5.48% as a leaf and 15.03% including descendants.

Prioritize instruction execution/memory routing and per-instruction board scheduling before further small renderer changes. Investigate reducing repeated event-deadline work and batching device advancement up to observable events, while preserving DMA preparation, interrupt visibility, CPU/ARM ordering and register-write effects. Measure AOT CPU ms/frame before retaining a change. Do not convert JIT sample percentages into estimated AOT milliseconds. Establish normal-profile gameplay before comparing different cores or timing profiles.

A separate unprofiled native AOT baseline used Linux CPU 2, five warmup frames and eight measured frames, in gameplay/BIOS/BIOS/gameplay order. The headless process CPU measurement sums Linux user and system ticks; sample collection was stopped before these runs.

| Scene | Median CPU ms/frame | Range, two runs |
| --- | ---: | ---: |
| Diagnostic gameplay | 1860.000 | 1768.750–1951.250 |
| Normal-profile BIOS menu | 411.250 | 391.250–431.250 |

Both runs per scene matched image/audio hashes, guest clocks and final PC. These establish the refreshed baseline, not an optimization gain.

## Rejected short-quantum AICA event guard

A trial added `clocksToEventBefore(quantum)` to avoid full event-deadline calculation for quanta of at most eight master clocks when no audio-sample, active DMA or enabled ARM clock edge could occur. It retained the original deadline getter for all other cases. Arithmetic in the shortcut stayed within exact JavaScript integer bounds. A temporary deterministic check compared 160,000 horizon queries with the original getter across ARM reset changes, interrupt enables/acknowledgements and clock advances, with identical results. The existing AICA, interrupt, internal DMA, ARM debug, G2 and public-state suites had 80 passing and two failing cases both before and after. Both failures expected unsupported MMIO accesses that already return successfully in the baseline; failure names and expected/actual diagnostics matched.

Four alternating AOT runs per variant used Dart 3.13.5, Linux CPU 2, five warmup frames and eight measured frames. Gameplay median process CPU time changed from 2261.250 to 2133.750 ms/frame (-127.500, -5.64%), while BIOS changed from 396.875 to 423.125 (+26.250, +6.61%). Image/audio hashes, guest clocks and final PC matched in both scenes. The cross-scene regression did not justify retaining the additional guard, and the trial was reverted.

Inspecting the retained AOT cache path confirmed no ordinary record allocation in `DcCache.readLocation` or the ordinary RAM/BIOS returns of `DcBus._resolve`. The cache reader still invokes external validation before resolving a hit. Investigate an instruction-specific ordinary-memory validation path rather than replacing record syntax or repeating the rejected global dispatch reordering. Preserve address alignment, operand-cache RAM restrictions, translation, cache-fill behavior and exceptions.

## Instruction-specific ordinary-memory reads

Supply an optional instruction-read callback to the cache. For already aligned instruction accesses to direct or translated ordinary RAM/BIOS addresses, the bus resolves the buffer before the device decoder. Keep instruction cache eligibility, tag lookup, fills, no-fill peeks and operand-cache RAM restrictions in the existing cache path. Retain G1 observation on external instruction reads; other addresses use the original external reader or resolver. Data reads and cache fills retain their existing callbacks. No derived fields or state-format changes are introduced.

An initial nullable-record/coalescing implementation introduced `AllocateRecord2` calls in AOT. That obsolete comparison was stopped and is not performance evidence. Explicitly destructure the callback result into buffer/offset values before control-flow joins. The final AOT listing contains no record-allocation calls in `DcCache.readLocation` or `DcBus._readInstructionExternal`. The existing bus/cache/MMU/exception/public-state scenarios pass (106 tests).

Four alternating AOT runs per variant used Dart 3.13.5, Linux CPU 2, five warmup frames and eight measured frames.

| Scene | Baseline CPU ms/frame | Candidate CPU ms/frame | Difference |
| --- | ---: | ---: | ---: |
| Diagnostic gameplay | 1896.875 | 1850.000 | -46.875 (-2.47%) |
| Normal-profile BIOS menu | 393.125 | 358.750 | -34.375 (-8.74%) |

Retain this change: both measured scenes improve and match image/audio hashes, guest clocks and final PC. Individual timings remain variable, so these are observations for the specified scenes and profiles, not a universal speedup. Further CPU scheduling and instruction-path work remains warranted.

## Direct T-flag updates

Update `_sr` bit zero directly from the T setter instead of calling the full SR setter. Like the flag-only operations in the other SH interpreters, this operation cannot change processor privilege or register-bank selection. SR assignment and state loading already mask or validate reserved bits, so the direct bit operation preserves their invariant. Full SR transfers, exception entry/return and their bank-switch behavior retain the original setter.

All 185 existing SH-4 instruction/FPU/divide-MAC/exception/interrupt scenarios pass. The AOT T setter shrinks from 78 to 47 bytes and has no call to `Sh4.sr=`. Four alternating AOT runs per variant use Dart 3.13.5, Linux CPU 2, five warmup frames and eight measured frames, relative to the retained instruction-read optimization.

| Scene | Baseline CPU ms/frame | Direct T CPU ms/frame | Difference |
| --- | ---: | ---: | ---: |
| Diagnostic gameplay | 2151.875 | 1860.000 | -291.875 (-13.56%) |
| Normal-profile BIOS menu | 423.125 | 362.500 | -60.625 (-14.33%) |

Image/audio hashes, guest clocks and final PC match in both scenes. Retain the direct T update. The gameplay baseline has a wide range, including an initial 3381.250 ms/frame run; these medians are scene-specific observations and do not establish a universal percentage gain. Consider direct Q/M/S updates and FPSCR exception-status updates separately, preserving bank-selection invariants and exception priority.

## Direct integer and FPU status updates

Following the direct T update, write `_sr` directly only for Q/M/S changes in DIV1, DIV0S, DIV0U, CLRS and SETS. Their masks cannot change the processor mode or register-bank selection, and SR remains canonical. In `_finishFloat`, write the FPSCR exception cause/sticky flags directly while retaining the writable-bit mask and writing status before any enabled exception is raised. The six result flag bits cannot change FR. Full SR/FPSCR transfers and exception entry/return retain their existing bank-switch setters.

All 185 existing SH-4 instruction/FPU/divide-MAC/exception/interrupt scenarios pass with both changes. AOT removes the remaining two SR setter calls from `_integerOp` and reduces its body from 3185 to 3016 bytes. The FPU status helper shrinks from 258 to 205 bytes and no longer calls `Sh4.fpscr=`. No state-format changes or new unit-test cases are introduced.

Three AOT variants run in A/B/C/C/B/A order twice per scene with Dart 3.13.5, Linux CPU 2, five warmup frames and eight measured frames.

| Scene | A: retained T update CPU ms/frame | B: Q/M/S added | C: Q/M/S and FPU added |
| --- | ---: | ---: | ---: |
| Diagnostic gameplay | 1936.875 | 1929.375 | 1921.875 |
| Normal-profile BIOS menu | 436.875 | 408.750 | 369.375 |

Relative to A, C changes gameplay by -15.000 ms/frame (-0.77%) and BIOS by -67.500 (-15.45%). Relative to B, the FPU change is -7.500 ms/frame (-0.39%) for gameplay and -39.375 (-9.63%) for BIOS. All variants match image/audio hashes, guest clocks and final PC. Retain both direct updates: they remove unnecessary bank-switch setter work without introducing new dispatch branches or derived state, and neither scene regresses in the comparison. Gameplay's sub-one-percent difference should be treated as near-neutral rather than a demonstrated large speedup. Timing remains variable; the BIOS observations also do not establish a universal percentage.

CMP/STR allocates a context, list and closure and invokes `ListBase.any` to test four fixed byte lanes. The explicit-lane trial below did not establish a sufficiently consistent gain. A compact zero-byte arithmetic predicate remains a separate candidate, subject to exact native/Web behavior and AOT frame measurements.

## Rejected explicit CMP/STR lanes and GBR classification

Variant B replaced CMP/STR's list/closure traversal with four short-circuited byte-mask comparisons. The AOT `_integerOp` body shrank from 3016 to 2917 bytes and contained no context/list/closure allocations or `ListBase.any` call. Variant C additionally replaced the GBR-relative load/store high-byte list with a mask predicate. All 65,536 instruction encodings matched the original GBR classification. `_extraMemoryOp` shrank from 1330 to 1224 bytes and contained no list allocations or `contains` call. Both variants passed the same 101 existing integer/divide-MAC/exception scenarios; no unit-test cases were added.

Three AOT variants ran in A/B/C/C/B/A order twice per scene, with Dart 3.13.5, Linux CPU 2, five warmup frames and eight measured frames. The baseline A includes the retained direct T/Q/M/S and FPU status updates.

| Scene | A: baseline CPU ms/frame | B: explicit CMP/STR | C: CMP/STR and GBR mask |
| --- | ---: | ---: | ---: |
| Diagnostic gameplay | 2971.250 | 2996.250 | 3111.875 |
| Normal-profile BIOS menu | 495.000 | 479.375 | 505.000 |

All variants matched image/audio hashes, guest clocks and final PC. B changes gameplay by +25.000 ms/frame (+0.84%) and BIOS by -15.625 (-3.16%). C changes gameplay by +140.625 (+4.73%) and BIOS by +10.000 (+2.02%). The explicit-lane trial offers no consistent cross-scene gain, and the combined GBR change regresses both scenes, so both changes were reverted. Individual gameplay values also drifted during the comparison; do not compare these absolute CPU times with earlier measurement windows or claim allocation removal alone proves a speedup.

## GPIO/TMU source-priority guards and rejected control-only gate

As already done for DMA and serial interrupt sources, compare GPIO/TMU source priority with the selected priority before reading their pure pending-status getters. Retain strict greater-than comparisons, source tie order, NMI handling and all device state. Existing interrupt/exception/GPIO/TMU/public-state scenarios pass (68 tests). AOT `DcIntc.pending` changes from 1965 to 1964 bytes without record allocation.

A separate variant additionally restricted `_controlOp` calls to major opcode groups 0 and 4, without adding the previously rejected FPU classification gate. All 65,536 encodings were checked: all 928 recognized control encodings pass `op & 0xb000 == 0`. All 185 existing SH-4 scenarios pass. AOT emits one `test` and branch before the decoder call.

The first comparison ran A/B/C/C/B/A twice per scene, using Dart 3.13.5, Linux CPU 2, five warmup frames and eight measured frames.

| Scene | A: baseline CPU ms/frame | B: source-priority guards | C: guards plus control gate |
| --- | ---: | ---: | ---: |
| Diagnostic gameplay | 2145.000 | 2211.875 | 2330.625 |
| Normal-profile BIOS menu | 491.250 | 364.375 | 364.375 |

B initially changes gameplay by +66.875 ms/frame (+3.12%) and BIOS by -126.875 (-25.83%). C is slower than B for gameplay and offers no additional BIOS improvement, so the control-only gate was reverted. The large mixed scene results warranted a second comparison of A/B, with the variant order reversed and BIOS measured before gameplay. Each variant again ran four times with five warmup and eight measured frames.

| Scene, reversed comparison | Baseline CPU ms/frame | Source-priority guards CPU ms/frame | Difference |
| --- | ---: | ---: | ---: |
| Diagnostic gameplay | 1849.375 | 1838.750 | -10.625 (-0.57%) |
| Normal-profile BIOS menu | 370.000 | 360.625 | -9.375 (-2.53%) |

All variants and both comparisons matched image/audio hashes, guest clocks and final PC. The first-executed variant was slower at the start of each BIOS comparison, including after reversing the order; the initial 25.83% BIOS reduction overstates the confidence in the effect size. Retain the two source-priority guards: BIOS improves in both windows, while gameplay varies from a small regression to near-neutral improvement. Do not claim an established gameplay gain or a universal percentage. The rejected control gate remains absent. No unit-test cases or serialized state were added.

## Rejected cached AICA clock horizon

A trial cached a conservative lower bound to the next audio sample edge, enabled ARM instruction or active internal DMA word. It included every sample edge even while sound/DSP/external audio was inactive, so direct activity changes could not make a cached bound too late. Master-clock ticks decremented the bound; reset, state restore, ARM reset/control, memory-inhibit changes and DMA start invalidated it. Possible-event quanta retained the original exact getter, and debugger stepping kept its original API. The derived bound was not serialized.

Temporary native and JavaScript comparisons each matched 320,000 deadline queries against the original getter, across both short (0–8 clocks) and larger clock advances, reset/hold/release, interrupt writes, memory inhibition and internal DMA start/completion. The existing AICA/interrupt/DMA/ARM-debug/G2/public-state suites had 80 passing and the same two preexisting failing cases, concerning unsupported MMIO expectations at `aica_test.dart:83` and `g2_test.dart:59`. Their failure names and expected/actual diagnostics matched the prior baseline. No unit cases were added. AOT called the exact getter only when the cached horizon could fall inside the quantum.

Four alternating AOT runs per variant used Dart 3.13.5, Linux CPU 2, five warmup frames and eight measured frames, relative to the retained source-priority guards.

| Scene | Baseline CPU ms/frame | Cached horizon CPU ms/frame | Difference |
| --- | ---: | ---: | ---: |
| Diagnostic gameplay | 1726.250 | 1804.375 | +78.125 (+4.53%) |
| Normal-profile BIOS menu | 365.625 | 338.125 | -27.500 (-7.52%) |

An adaptive variant used the original exact getter for single-clock quanta, allowing the cached counter to remain invalid during sustained single-clock stepping. It used the cached getter only for larger quanta. A second alternating comparison measured BIOS first and reversed the executable order, with the same warmup and frame counts.

| Scene | Baseline CPU ms/frame | Adaptive horizon CPU ms/frame | Difference |
| --- | ---: | ---: | ---: |
| Diagnostic gameplay | 1706.875 | 1766.875 | +60.000 (+3.52%) |
| Normal-profile BIOS menu | 360.000 | 348.750 | -11.250 (-3.13%) |

Both comparisons matched image/audio hashes, guest clocks and final PC. Both cached variants regressed gameplay while improving BIOS, and excluding single-clock quanta did not remove the gameplay regression. Revert the complete cache, invalidation hooks and bus API changes. The added derived state did not establish a sufficiently consistent gain. The existing exact getter remains in use; an approach without per-tick counter stores is a separate candidate, not a retained improvement.

## Scalar instruction-result pairs

Extract the shared execution body to return an immediately destructured `(elapsedClocks, flags)` integer pair. Pack stopped, scanline-rendered, SH-4-executed and ARM-executed status into four named constant bits. Public `exec` and `runFrame` materialize fresh `ExecResult` objects at their boundaries. The frame loop retains elapsed clocks and flags in locals; no persistent metadata fields or reusable mutable result object are introduced. Preserve zero-line frame defaults, early-stop flags, last-step elapsed clocks, partial ARM debugger steps and scanline overshoot. Elapsed time remains the actual step value rather than a difference of accumulated clocks, preserving JavaScript precision behavior.

All 120 existing core/public-state/SPG/ARM-debug/CPG/exception/interrupt scenarios pass. AOT `_execute` and `runFrame` contain neither record allocations nor per-instruction `ExecResult` construction. The public conversion helper constructs the result once at the boundary. This differs from both rejected execution-result trials: no five-field stores on each instruction, and no private mutable metadata state. No serialization format or unit-test cases changed.

Four alternating AOT runs per variant used Dart 3.13.5, Linux CPU 2, five warmup frames and eight measured frames. BIOS ran before gameplay, with the pair variant first in the alternating order. The baseline includes the retained source-priority guards.

| Scene | Baseline CPU ms/frame | Result-pair CPU ms/frame | Difference |
| --- | ---: | ---: | ---: |
| Diagnostic gameplay | 1750.625 | 1712.500 | -38.125 (-2.18%) |
| Normal-profile BIOS menu | 358.750 | 355.000 | -3.750 (-1.05%) |

Image/audio hashes, guest clocks and final PC match in both scenes. Retain this change: it eliminates the confirmed per-instruction native allocation without adding derived state and both measured scenes show small improvements. The timings remain variable; these percentages do not establish a universal gain, nor do native register returns establish allocation behavior for the JavaScript backend.

## Rejected frame-only metadata and progress returns

A first trial added a private frame mode to the scalar execution body. Non-stopped, non-rendering frame steps returned no processor-executed flags; public execution and terminal frame results retained complete metadata. All 120 existing core/public-state/SPG/ARM-debug/CPG/exception/interrupt scenarios passed. AOT retained allocation-free integer-pair returns.

Four alternating runs per variant used Dart 3.13.5, Linux CPU 2, five warmup frames and eight measured frames, with BIOS first and the candidate first in the variant order.

| Scene | Retained pair CPU ms/frame | Frame-only flag suppression CPU ms/frame | Difference |
| --- | ---: | ---: | ---: |
| Diagnostic gameplay | 1756.875 | 1755.625 | -1.250 (-0.07%) |
| Normal-profile BIOS menu | 346.250 | 349.375 | +3.125 (+0.90%) |

A second trial also moved frame-line accounting into the execution body, removing duplicated SPG snapshots from the outer frame loop. Intermediate results encoded remaining frame lines as a negative status; terminal and public results returned the normal nonnegative flags. It preserved fallback line accounting, actual video-line deltas, overshoot, early stops and zero-line defaults without persistent fields or a mutable frame object. The same 120 scenarios passed. AOT `runFrame` shrank from 317 to 161 bytes and neither it nor `_execute` allocated records or intermediate results.

A second alternating comparison used the same SDK, affinity and frame counts.

| Scene | Retained pair CPU ms/frame | Combined frame-progress CPU ms/frame | Difference |
| --- | ---: | ---: | ---: |
| Diagnostic gameplay | 1664.375 | 1775.000 | +110.625 (+6.65%) |
| Normal-profile BIOS menu | 365.625 | 341.875 | -23.750 (-6.50%) |

Both comparisons matched image/audio hashes, guest clocks and final PC. Flag suppression alone was effectively neutral, while the combined progress return regressed gameplay despite improving BIOS. Both trials were reverted to the retained scalar-pair implementation. No unit-test cases were added.

## Current-SDK confirmation

Rebuild three variants with Dart 3.13.7 (Flutter 3.47.9) from isolated package copies using the same locked dependency versions. A restores the saved pre-performance implementations of GPIO, SH-4 decoding/status updates, renderer bounds, bus routing, cache instruction reads, interrupt-source guards and per-instruction execution results. B retains all adopted optimizations except scalar result pairs. C is the current retained implementation including result pairs. The actual worktree remains unchanged during variant builds. All 120 existing execution/state/SPG/ARM-debug/CPG/exception/interrupt scenarios pass under the current SDK. AOT `_execute` and `runFrame` still have no record allocations or per-instruction result construction.

Run A/B/C/C/B/A twice per scene, with Linux CPU 2, five warmup frames and eight measured frames. All variants match image/audio hashes, guest clocks and final PC.

| Scene | A: before performance work CPU ms/frame | B: optimized with object results | C: optimized with scalar pairs |
| --- | ---: | ---: | ---: |
| Diagnostic gameplay | 2921.250 | 1781.250 | 1858.750 |
| Normal-profile BIOS menu | 958.125 | 729.375 | 683.750 |

The cumulative A-to-C change is -1062.500 ms/frame (-36.37%) for gameplay and -274.375 (-28.64%) for BIOS. The isolated B-to-C change is mixed: +77.500 (+4.35%) for gameplay and -45.625 (-6.26%) for BIOS. Individual gameplay runs range up to 5465.000 ms/frame for A, 4727.500 for B and 4420.000 for C. Keep the cumulative evidence separate from the small result-pair effect; the newer-SDK gameplay result does not confirm a result-pair speedup. Further focused measurement remains warranted. Do not compare these absolute times with the previous SDK's different host-load windows.

The current AOT runtime rejects the VM-service flag, so the JIT-service sampler cannot simply be applied to the native snapshot. A disabled own-process Linux software task-clock perf-event probe succeeds; an actual AOT sample collector remains to be implemented. No native sampling results are claimed yet.

## Memory-access review

Reading the supplied measurement checkpoints shows CCR `0x105` in the normal BIOS menu and `0x185` in diagnostic gameplay. Both instruction and operand caches are enabled, while MMU translation is disabled. The general registers and both floating-point register banks use `Uint32List`; special registers use masked/validated Dart integer fields.

The cache reader still resolves an external location before checking a hit, and uncached reads may resolve it again in the external reader. Fills and writeback create temporary byte buffers; scalar stores also construct byte arrays. These are software-path costs, rather than modeled cache-miss wait states. Investigate a guarded ordinary-RAM hit path and fixed-width scalar accessors while preserving dirty/stale data, DMA coherence, cache-control operations and required exceptions. Globally bypassing the enabled cache is not established as safe by these checkpoints.
