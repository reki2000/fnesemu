# DC core implementation plan

The `dc` module is an experimental bring-up core, not a game-compatible DC emulator.
The current milestone runs integer/floating-point diagnostics, exposes functional VRAM/framebuffer readout and software/hardware Maple controller input, and displays the supplied BIOS startup screen through the normal core factory with provisional startup assumptions.
A user-supplied BIOS now draws the startup animation and orange startup logo with the explicit diagnostic assumptions below; controller navigation reaches the main menu, and the supplied game executes through a diagnostic disc handoff; the supplied game now produces recognizable imagery and nonzero audio samples under the diagnostic assumptions below.

## Current implementation priority

Missing audio and rendering behavior takes priority over further boot-path investigation.
The next substantial gaps are AICA DSP floating sound-memory conversion and hardware filter behavior, followed by remaining GPU output and material modes.
SSCTL noise now feeds the existing pitch, envelope, filter and mixing path without reading wave RAM.
Its continuous xorshift sequence and per-slot key-on seed are provisional because the available AICA documentation does not specify the physical noise generator; exact noise spectrum and clocking are not claimed.
Noise history is retained when saving an active voice, including interpolation lookahead and repeated source loops.
MRWINH bit 1 now checks active wave-RAM sources rather than all active voices, so internal noise continues while PCM/ADPCM wave reads remain inhibited.
The public noise/DSP audio state scenario retains this inhibit setting across restore, while the existing inhibit scenario also confirms that a wave-memory voice still stops; no test case was added.
A one-sample loop now interpolates consecutive continuous-noise values even when its wrapped wave index does not change; one-shot endpoints still hold their last value.
An original half-rate noise scene had 1,022 differing samples between loop periods 1 and 128 before this correction and zero differences afterward.
The existing partial-audio state scenario now uses the short half-rate noise loop and no longer fills unused wave RAM; the four public-core state scenarios pass without adding a test case.
The DC test suite was reduced from 98 files to 72 by removing component serialization and standalone disassembler suites; public core state coverage is consolidated into four integration scenarios.
Obsolete assertions for unsupported audio behavior were also removed.
Future tests should protect representative observable behavior and reproducible failures rather than duplicate every internal field or validation branch; see the scoped test AGENTS.md.
Historical verification notes below describe earlier development work, not the retained test inventory.

## BIOS and disc bring-up

The BIOS startup screen and supplied CDI's program already produce image and sound under the diagnostic assumptions below.
Core-owned BIOS metadata now requests the 2 MiB boot ROM and 128 KiB flash image; `setBiosFiles` identifies them by size regardless of selection order.
One-ROM input remains available to low-level diagnostic callers, but the normal BIOS picker requests both files.
Loading flash uses the same core API as the boot ROM, without a probe-only bus mutation.
Strict hardware matching and unrelated peripheral expansion are deferred while blocking startup operations are implemented.
The normal core factory now enables the provisional BIOS startup profile by default; `DC_BOOT_BRINGUP=false` selects strict operation.
Low-level callers can explicitly select `Dc(bootBringUp: true)`; direct `Dc()` construction remains strict unless the build-time define enables the profile.
This profile bundles verification bypass, the provisional GPIO 0/1 shared net, eight master clocks per instruction, whole-program fallback for unsupported AICA DSP instructions, provisional AICA low-pass filtering and the diagnostic byte-addressed short-ADPCM policy inside the core.
The debugger identifies the profile, and its states have a distinct configuration identity.
It enables BIOS bring-up through the ordinary core API without GUI-specific device setup, but does not add an automatic ISO bootstrap fallback or override disc format.
The same profile can be exercised without individual GPIO/timing flags:

```sh
dart run tool/dc_probe.dart --core-bring-up --capture=/tmp/dc-core-boot BOOT_ROM FLASH 80000000
```

The probe can explicitly bypass the unknown HOLLY checksum and drive a provisional shared net for GPIO pins 0/1:

```sh
dart run tool/dc_probe.dart --bypass-bios-verification --gpio-link=3 --clock-scale=32 --capture=/tmp/dc-boot BOOT_ROM FLASH 150000000 DISC_IMAGE
```

The checksum bypass returns a passed status without implementing the algorithm; it is disabled in strict operation and is included in public save-state media/configuration identity.
The GPIO wiring is a diagnostic hypothesis based on the unmodified BIOS's alternating high/low input checks, not a measured physical board claim.
The probe records both assumptions, periodic PCs, actual framebuffer dimensions and nonzero audio sample counts; available output is saved as `frame.png` and `audio.wav`.
Zero initialization writes to undocumented HOLLY/G2 registers and disabled UBC controls are accepted without inventing DMA transfers or completion interrupts.
SH7750 RTC register initialization, HOLLY channel-2/sort/GPU DMA configuration and GPU SDRAM configuration are retained; channel-2 DREQ now transfers actual TA packets and reports completion through both DMAC and HOLLY.
RTC oscillator/interrupt behavior and physical DMA timing remain incomplete; functional Sort-DMA and GPU-DMA now use channel-0 DDT for linked TA parameter and palette/register/VRAM transfers.
TA initialization writes empty OPB terminators, including lists that receive no polygons; No List still permits ISP/TSP parameter conversion.
The provisional No List conversion path retains parameters even outside the global tile clip, so CPU-consumed converted geometry is not discarded with OPB coverage.
This usage extends the manual's restrictions and remains a BIOS bring-up approximation.
The current diagnostic run reaches an enabled 640-by-480 framebuffer containing startup swirl geometry and nonzero audio samples after 80 million instructions with `--clock-scale=32`.
TA software reset now preserves configuration registers rather than clearing list allocation and tile clipping each frame.
TA-generated object pointers are relative to the 1 MiB-aligned parameter segment subsequently added through CORE's `PARAM_BASE`.
At 150 million instructions, the captured display contains the orange swirl and complete startup wordmark after the moving light-point animation.
Non-textured packed vertex color now uses HOLLY2's word-4 layout from System Architecture section 8.6.
Background geometry and colors remain imperfect.
Further execution reaches the date/time dialog; normal controller input now advances its cursor and confirms the settings.
Maple MSB selection now normalizes logical SH4 packet words correctly, allowing the BIOS to identify the controller and request its conditions.
AICA non-bypass filters render dry audio by default so BIOS navigation sounds do not stop execution; an explicitly enabled graph-based approximation is available, while hardware cutoff processing remains unimplemented.
The conflicting FEG rate-49 duration uses a provisional 154 ms interpolation for bring-up.
The BIOS now reaches its animated main menu and CD player through normal controller navigation.
With the supplied single-data-track CDI, the observed BIOS Play path returns to the CD player without reading program sectors.
The core's explicit `Dc.bootUnscrambledDisc` diagnostic reads IP.BIN and its named executable from bounded ISO root extents through its attached `CdromDrive`, without changing the source image; the probe selects it with `--boot-disc-unscrambled`.
It first checks the track's boot area and can explicitly fall back to a root IP.BIN file; this fallback is not standard BIOS auto-boot.
The IP.BIN entry displays the license screen; its native BIOS frame wait now advances through the level-2 VBlank route, while subsequent full-path optical drive startup and game entry remain incomplete.
`--skip-license-screen` enters the original bootstrap at `0x8c00b800`; `--direct-disc-entry` instead enters the loaded executable at `0x8c010000` and skips IP.BIN execution.
`--second-bootstrap` runs the original IP.BIN entry at `0x8c00e000`, including its ROM BIOS initialization calls; this is preferred over direct entry for current game bring-up.
`Dc.startDiscBootstrap` owns the explicit native handoff: it validates the supplied IP.BIN and program bounds, completes a pending delay slot, masks previous HOLLY interrupt enables, resets the cache and transfers execution to the selected bootstrap entry with a privileged startup stack.
The core now owns ISO interpretation and sector loading as well as the native handoff; the tool supplies the filesystem-backed drive and selects diagnostic options.
An execution check of this core-owned handoff loads the supplied CDI's original 2,490,368-byte `1ST_READ.BIN`, enters the program after 5,202 observations and continues for two million observations without a development stop; this short check does not establish fresh game video or audio after the handoff.
That code establishes `VBR=0x8c00f400` and its own startup stack instead of retaining the probe's provisional direct-entry state.
The diagnostic handoff disables the old cache contents, masks the previous BIOS HOLLY interrupts, selects low BIOS exception vectors and establishes an explicit privileged stack.
Direct entry into the supplied 2,490,368-byte 1ST_READ.BIN from LBA 54 executes at least five million guest instructions and reaches the program's memory-clear loop.
Further execution passes initial memory clearing and device setup, including an idempotent Maple trigger write while the previous interface remains enabled.
An earlier direct-entry run hit invalid `0x8c0a` at `0xac000302` while returning to BIOS after disk initialization failed.
Native-bootstrap execution passes that location and accepts zero writes to unused INTC halfwords during ROM BIOS cleanup; meaningful nonzero writes remain unsupported.
The modeled drive now reports the vendor, Rev 6.43 and 990408 identity from an independent drive-information tool's hardware output, rather than the old synthetic PIO version string.
This is a compatibility identity profile, not execution of the original drive firmware.
The explicit BIOS verification bypass also provisionally accepts undocumented packets `0x70/0x71`; packet `0x71` supplies a minimal length-delimited pass record in a 1024-byte data phase, without implementing drive authentication.
Normal CD-ROM reporting still causes the supplied game to return to BIOS after initialization.
The probe can explicitly select `--drive-format=80`; only that diagnostic virtual profile maps the high-density TOC request to the unchanged source data-track TOC.
This virtual mapping is not a claim about physical optical drive geometry or the source CDI's format, and the override must be repeated when resuming a probe state.
With that profile and the original second bootstrap, the game reads actual ISO/filesystem sectors from the CDI and completes a 36 KiB native drive DMA transfer after requesting 28 distinct sectors.
Further execution loads additional game assets, starts the native ARM sound driver and programs the AICA DSP.
The explicit probe option `--bypass-aica-dsp` retains the uploaded DSP program but suppresses its effect output while preserving direct channel mixing; it must be repeated on resume and does not implement DSP execution.
Zero writes to reserved DSP gaps are ignored, and a G2 start write while disabled is inert.
The game requests a 320-by-240 YUV conversion window; the converter provisionally accepts this partial texture height using the manual's linear macroblock layout, although the register table lists power-of-two texture heights.
Subsequent native execution reaches the title, main menu and first stage with game-generated graphics and nonzero PCM output; retained BIOS graphics and trailing navigation audio do not count as game output.
Framebuffer dithering uses a provisional 4-by-4 ordered pattern for 16-bit formats; the physical matrix and rounding remain unverified.
The original ROM, flash and CDI files remain unmodified; bypassed bring-up is not hardware-verified BIOS boot.

## Architecture

The module owns SH-4 execution, address decoding and future DC devices under `src/core/dc/`.
It uses the shared `Core`, `CoreModule`, debug and memory utility interfaces.
Registration is generated by `dart run tool/generate_core_registry.dart` from the core package directory.
The app and GUI require no changes.
The SH-2 components are not an SH-4 implementation and are not imported by this module.
Only extract reusable components when another consumer exists and their hardware contracts agree.

## Milestones and acceptance conditions

| Stage | Work | Acceptance condition | Status |
| --- | --- | --- | --- |
| 1 | Core registration, BIOS validation, little-endian boot ROM and main RAM mapping, direct address aliases | Factory construction and memory boundary tests pass without app changes | Implemented |
| 2 | Initial integer SH-4 interpreter, separately stepped delay slots, explicit development stops, independent diagnostic programs | Synthetic instruction and branch tests pass, including failed accesses without partial effects | Implemented subset |
| 3 | Remaining integer instructions, banked registers, SR/control registers, FPU, exceptions and interrupts | Independent instruction tests cover boundary values, privilege checks and exception state | Integer/transfer subset, DIV1, MAC subset, scalar FPU, functional graphics FPU, synchronous exceptions and encoded IRL implemented; hardware approximation matching and ambiguous saturation cases pending |
| 4 | SH7750 cache/MMU/store queues, timers, interrupt controller, DMA and serial output | Documented register resets and access widths pass device tests; BIOS advances with serial diagnostics | TMU/INTC, caches/MMU, store queues, memory/SCI/SCIF DMA, asynchronous/synchronous SCI and asynchronous multiprocessor communication, asynchronous SCIF, functional CPG/watchdog and light/deep sleep implemented; channel-0 DDT 32-byte requests implemented; accurate timing, remaining serial modes and pin sampling, standby and other external/DDT modes pending |
| 5 | Flash command protocol, system bus and interrupt routing | Flash persistence and interrupt ordering pass component tests | Functional top-boot flash, persistence, HOLLY interrupt controller and G2-DMA register/data path implemented; remaining system-bus registers/DMA, device connections and board variants pending |
| 6 | GPU registers, VRAM addressing, framebuffer scanout and hardware video scheduling | A self-authored framebuffer program produces an expected image through `ImageBuffer` | VRAM/framebuffer readout, per-line capture, functional SPG counters/interrupts, field latching and interlaced presentation implemented; pixel/FIFO timing, external sync and pin-level validation pending |
| 7 | Maple controller/memory card and optical drive commands/DMA via `CdromDrive` | A self-authored disc program reads sectors and responds to input; memory card data persists through `Sram` | Functional software/VBlank Maple DMA with channel-0 DDT and standard controller input implemented; memory card storage/LCD/timer packet subset and slot persistence implemented; optical drive SPI PIO and drive DMA subset implemented; Maple physical arbitration, memory card factory/pin behavior and remaining disc commands/formats pending |
| 8 | AICA registers, ARM7 execution, sound RAM and audio generation | A self-authored audio program produces independently checked samples through `AudioBuffer` | Retail wave RAM, RTC, timers, HOLLY routing, baseline ARM7DI, functional PCM/ADPCM direct audio and amplitude/pitch LFO, ARM FIQ delivery, functional internal DMA, G2-DMA wave transfers, functional MIDI byte FIFOs/interrupts, decoded DSP arithmetic and linear-memory backends, CPU-visible DSP buffers and DSP input/effect mixing implemented; DSP floating sound-memory conversion, hardware envelope/filter and interrupt matching, MIDI pin timing and internal-DMA timing pending |
| 9 | Tile accelerator and GPU rendering | Independent primitive, depth, texture and blending scenes match documented behavior | Functional TA conversion, VRAM display lists, opaque/punch-through and pre-sorted/auto-sorted translucent primitives, RGB/palette/YUV textures, YUV420/422 conversion, square RGB VQ and non-MIP palette VQ, functional MIP selection, trilinear passes and texture supersampling, depth/culling, fog/color clamp, primary/secondary blending, functional bump mapping, intensity/parameter-selection modifier volumes, textured/Gouraud backgrounds with intensity/parameter-selection modifier volumes, framebuffer writes, horizontal 1/2 scaling and functional vertical filtering/scaling and type-B interlaced field output implemented; palette VQ MIP layouts, physical accumulation-buffer initialization, cache behavior, precise rasterization and timing pending |
| 10 | Full BIOS boot and game progression, logical save states, optional JIT | Repeatable boot/input/video/audio regressions pass before performance work | Native logical save/load implemented; default-factory cold BIOS logo and diagnostic BIOS menu, game title/menu and first-stage image/audio reached; strict hardware startup, broader game progression and optional JIT pending |

Implement each device from hardware documentation and independently authored tests.
Do not read, port or adapt other emulators' implementations.
Add small tested increments and update this table when their acceptance conditions are met.
Keep optical drive format support separate from the core: `CdromDrive` currently exposes CD-style TOC/raw-sector access, so high-density sessions and track-sheet image support need an explicit interface review before implementation.

## Validation without physical hardware

Physical DC hardware testing is unavailable for this project and is not a prerequisite for continuing implementation.
Use original hardware documentation, independently authored diagnostic programs and user-supplied BIOS/disc assets as the available evidence.
Do not use other emulators as implementation references or correctness oracles.

- Verify documented instruction and device behavior with independent boundary, interrupt, transfer and timing tests.
- Run functional tests on both the native VM and browser where supported; native save-state tests also check resumed execution and rejected-state atomicity.
- Run the unmodified BIOS with `tool/dc_probe.dart` and retain the instruction count, PC, stop reason and recent instruction trace for each new stop.
- Check disc parsing independently from guest transfers, then compare bytes returned by guest PIO/DMA with the disc adapter's sector data.
- Once boot progresses, retain repeatable input, frame and audio regressions before optimizing execution.

Passing these checks establishes consistency with the tested specification and inputs, not measured physical hardware equivalence.
Keep undocumented behavior, ambiguous specification details and unmeasured timing explicitly identified as uncertainties; do not require the user to obtain hardware to resolve them.
Do not silently report an assumed HOLLY verification result as implemented hardware behavior.
The request at `0x005f74e4` is retained; strict operation stops before an unknown result or dependent optical drive access, while the explicit diagnostic bypass permits further bring-up.
Independent device implementation and testing can continue while that blocker is unresolved.

## Implemented subset

- Boot ROM: exactly 2 MiB, read-only at physical `0x00000000..0x001fffff`.
- System flash: 128 KiB visible upper half of a top-boot MBM29F002TC, with command protocol and `Sram` persistence.
- Texture memory: 8 MiB with shared 32-bit/64-bit apertures, cache/SQ/SH4 DMA transfers and functional framebuffer readout.
- Main RAM: 16 MiB mirrored in physical area 3 (`0x0c000000..0x0fffffff`).
- Direct addressing with translation disabled, including P1/P2 aliases; P0/P3/SQ translation when enabled, with explicit stops for unmapped devices.
- Aligned little-endian byte, word and longword accesses; signed byte/word register loads.
- MOV immediate/register/indirect/predecrement/postincrement, PC-relative word/longword loads, longword displacement loads/stores, MOVA, MOVT and PR register transfers.
- ADD, SUB, NEG, comparisons, DT, TST, AND, OR, XOR, NOT, EXTS and EXTU.
- ADDC, ADDV, SUBC, SUBV, NEGC, CMP/PZ, CMP/PL, CMP/STR, SWAP, XTRCT, fixed/dynamic shifts and rotations, including carry rotations.
- MUL.L, MULS.W, MULU.W, DMULS.L, DMULU.L and MACH/MACL/PR register and stack transfers; 16-bit partial products keep multiplication exact on JavaScript as well as the VM.
- R0-indexed, byte/word displacement and GBR-relative MOV forms, GBR byte logic, TAS.B, CLRMAC, CLRS, SETS, DIV0S, DIV0U and DIV1.
- MAC.W and MAC.L with sequential operand reads, postincrements, aliased operands and wrapping 64-bit accumulation; documented common saturation cases are supported as described below.
- NOP, CLRT, SETT, BRA, BSR, BRAF, BSRF, JMP, JSR, RTS, BT, BF, BT/S and BF/S.
- SR-controlled register banks, GBR/VBR/SSR/SPC/SGR/DBR and opposite-bank LDC/STC transfers, including memory forms where supported.
- TRAPA, RTE, documented undefined instruction `0xfffd`, privilege violations, illegal slots and instruction/data address exceptions.
- MMU registers, 64-entry UTLB, four-entry ITLB, LDTLB, memory-mapped TLB arrays, page permissions, ASIDs and hardware ITLB refill.
- TEA, TRA, EXPEVT and INTEVT with documented exception state and 32-bit P4/area-7 access.
- INTC priority registers, encoded/independent IRL inputs, edge-latched NMI, DMAC and TMU interrupt arbitration, interrupt entry and RTE return; HOLLY system-bus levels 2/4/6 are connected; SPG, Maple and G1/optical drive sources are connected; remaining device sources are pending.
- FR/XF banks, FPSCR and FPUL, raw 32/64-bit FMOV transfers, scalar arithmetic/comparison/conversion, square root and fused FMAC, plus functional FIPR/FTRV/FSCA/FSRRA models.
- Direct-mapped 8 KiB instruction and 16 KiB operand caches, CCR, index/RAM modes, memory-mapped arrays and cache maintenance instructions.
- Two write-only 32-byte store queues, QACR0/1, MMUCR.SQMD protection and direct or translated PREF transfers to implemented external memory.
- Four-channel DMAC auto-request memory transfers, address/count feedback, fixed/round-robin priority, read-before-clear status flags, NMI suspension and SCI/SCIF transmit/receive requests.
- Asynchronous SCIF with transmit/receive FIFOs, framing/status/error flags, interrupts, loopback, CTS/RTS flow control and completed-frame endpoints.
- FRQCR clock dividers, watchdog interval/reset modes, module clock gates and light SLEEP interrupt wakeup.
- Debug register dump, instruction-word inspection and persistent stop diagnostics.

The shared instruction logger refreshes its pending capture when a CPU-only event changes PC without completing an instruction, so the first handler instruction is not recorded under the previous PC.

R0-R7 use bank 1 only when both SR.MD and SR.RB are set; R8-R15 remain shared.
Control transfers enforce privilege rules except for GBR transfers, which are available in user mode.
Undefined reset register values are initialized to zero for repeatability; the defined SR reset bits, PC and VBR follow the SH7750 manual.
Supported synchronous exceptions save SSR, SPC and SGR, select privileged bank 1, set EXPEVT and enter `VBR + 0x100`.
TRAPA records its immediate operand in TRA and saves the next instruction address; reexecution exceptions in delay slots save the preceding branch address and inhibit the call's PR update.
RTE restores SR before executing its separately stepped slot; the slot fetch uses the old privilege mode while data accesses and registers use the restored state.
Address exceptions update TEA and the PTEH virtual page while preserving ASID; guest accesses to privileged regions are rejected in user mode.
A supported general exception with SR.BL set performs a CPU/on-chip manual reset with EXPEVT `0x20`, retaining external RAM and ROM.
Implemented CPU, MMU, cache, TMU, DMAC, SCI, SCIF and INTC registers participate in manual reset; future devices must join the same path.
Manual reset disables the caches while retaining their validity, dirty flags, tags and data; a full reset invalidates their entries.
The CPU exposes `irlPins` as IRL3-IRL0: in encoded mode, `0` requests priority 15, `14` requests priority 1 and `15` deasserts the input.
ICR.IRLM selects independent active-low pins with SH7750 fixed priorities 13, 10, 7 and 4.
An asserted input is accepted at a CPU instruction boundary when its priority exceeds SR.IMASK, SR.BL is clear (or the CPU is sleeping) and no branch delay slot is pending.
Acceptance saves SSR/SPC/SGR, selects privileged bank 1, sets INTEVT to `0x200 + irlPins * 0x20`, and enters `VBR + 0x600` without changing IMASK or EXPEVT.
Interrupt entry is a separate CPU step, reports no completed instruction, and does not execute the interrupted instruction or the first handler instruction.
The input remains asserted until its source clears it; returning through RTE can therefore immediately retrigger the interrupt after the RTE slot.
CPU/manual reset retains external input pins, while a full core reset deasserts them.
Independent tests drive IRL directly and through the HOLLY interrupt controller; SPG, Maple, optical drive/G1 and AICA timer/software sources are connected while remaining devices are pending.
TAS.B performs the documented read/modify/write against the current single-CPU bus; bus-lock timing and contention are not modeled.
An unimplemented opcode, ROM write or unimplemented device access still produces `DcUnsupported`; the core records the reason and returns a stopped `ExecResult` without completing the attempted instruction.
The faulting PC and any pending branch remain available for debugging on development stops.
An unimplemented opcode must not be reclassified as an architectural illegal instruction merely because its implementation is missing.
LDC.L @Rm+,SR completes its source-bank postincrement before changing SR, including when an R0-R7 source changes the active bank.
The ADCS 7182230F architecture manual specifies this update order explicitly; tests cover every low register, both bank directions, entering user mode and a failed source read.
SH4 disassembly decodes integer/control, cache and FPU mnemonics, using raw `.word` output for undefined/context-unrepresentable encodings as described below.
Video exposes functional framebuffer readout, and audio exposes functional AICA source/mixer output through the core audio callback.
Controller input and a subset of optical drive transfers are implemented as described below; commercial disc execution remains unvalidated; native logical save/load is described below.

## Division and accumulation boundaries

DIV1 performs one non-restoring division step and changes only Rn, Q and T, preserving M and capturing an aliased divisor before shifting Rn.
The tests compare all M/Q/T combinations with an independent 33-bit BigInt model, and compare full unsigned 64-by-32 division sequences with mathematical quotients.
DIV1 does not detect division by zero or quotient overflow; division sequences must check their input ranges in guest software.

MAC instructions read Rn before Rm and defer pointer/accumulator updates until both reads succeed.
Aliased operands read consecutive elements and advance the shared pointer twice.
Wrapping sums use two 32-bit limbs, avoiding host integer overflow and JavaScript floating-point precision loss.

Saturation has conflicting documentation: ADE-602-156D preserves MACH's upper 16 bits for MAC.L and specifies setting bit 0 on MAC.W overflow, while ADCS 7182230F writes a sign-extended MAC.L result and replaces MACH with 1 on MAC.W overflow.
Until independent hardware evidence resolves this difference, saturated MAC.L requires a sign-extended 48-bit accumulator and matching MACH results under both descriptions.
Saturated MAC.W supports overflow when MACH is 0 or 1; without overflow it preserves MACH.
Conflicting cases stop with `DcUnsupported` before committing pointers or accumulator changes.
Tests validate the agreed arithmetic and these deliberate stops; they do not establish which conflicting description matches DC hardware.

## Floating-point implementation

Scalar binary32/binary64 arithmetic uses exact BigInt significands and rational rounding, rather than host floating-point results.
RN uses nearest-even and RZ truncates magnitude; the engine tracks inexact, underflow, overflow, divide-by-zero, invalid operation and denormal-input error.
SH-4's signaling-NaN fraction bit is the inverse of modern host IEEE conventions; quiet results use the documented canonical payloads.
Arithmetic refreshes FPSCR causes and preserves sticky flags; enabled exceptions suppress destination updates, including the documented unconditional O/U/I traps for normal arithmetic paths.
SR.FD raises the general or delay-slot FPU-disable event before register or memory effects.
Quadword FMOV preserves SH-4's word order instead of performing host little-endian 64-bit conversion, and validates both words before committing a store.

The graphics instructions currently implement their mathematical functions, special inputs and exception paths.
FIPR/FTRV use exact products and one final rounding instead of reproducing the SH7091's 28/30-bit intermediate reductions.
FSCA uses host sine/cosine rounded to binary32, and FSRRA uses a rounded reciprocal square root; these do not reproduce undocumented hardware lookup tables.
Their functional tests are evidence of instruction dispatch, register layout and mathematical behavior, not hardware-bit agreement or real-game compatibility.
Hardware approximation matching remains an explicit verification item before the core is complete.

## MMU implementation boundary

P0/P3 accesses use the UTLB when MMUCR.AT is set; P1/P2 remain direct, P4 is on-chip control space and enabled operand RAM bypasses translation.
The four page sizes are 1 KiB, 4 KiB, 64 KiB and 1 MiB.
Matching uses VPN, V, ASID, SH and SV, followed by PR and D permission checks.
LDTLB copies PTEH/PTEL/PTEA into the entry selected by URC without advancing URC.
UTLB lookups advance URC with the configured URB boundary.
Instruction misses refill the ITLB from UTLB and update the documented six-bit LRUI state; UTLB replacement alone does not invalidate a stale ITLB entry.
TI invalidates both TLBs and self-clears.
Manual reset disables translation but retains TLB entry validity; full reset invalidates entries.

TLB misses use EXPEVT `0x40`/`0x60` and `VBR+0x400`; protection violations and initial writes use `VBR+0x100`.
Faults preserve the virtual address in TEA/PTEH and save the faulting or preceding branch PC as appropriate.
Multiple matches take the reset path with EXPEVT `0x140` and the virtual address in TEA; hardware-undefined corruption is not simulated.
A synthetic guest handler installs its missing page with LDTLB, returns through RTE and successfully retries the original load.
Debugger translation searches without refilling ITLB or changing replacement state.

PCMCIA assistance attributes are stored but their bus protocol is not implemented.
TLB lookup/refill cycles and the documented pipeline spacing after control-register writes are not modeled.
Functional tests do not establish hardware timing or commercial BIOS compatibility.

## Cache implementation boundary

The SH7750 direct-mapped configuration uses 256 instruction-cache lines and 512 operand-cache lines, each containing 32 bytes.
Instruction fetches use a separate cache from data reads, so self-modifying code must perform the documented data write-back and instruction invalidation.
Cacheable data writes use CCR.CB in P1 and CCR.WT in P0; copy-back misses allocate and fill a line, while write-through misses write external memory without allocating.
Dirty eviction writes back all 32 bytes using the cached physical tag and index.
P2 and store-queue transfers access external memory without snooping either cache.

CCR commands invalidate instruction or operand entries and read back as zero.
OCBI discards a matching operand line, OCBP writes back and invalidates, and OCBWB writes back while retaining validity.
MOVCA.L allocates without reading the incoming block in copy-back mode; other words retain deterministic previous array contents because their hardware values are undefined.
Longword-only cache-array accesses support mirrored indexing and associative tag comparisons without address translation.
The RAM mode exposes the two documented 4 KiB banks through `0x7c000000..0x7fffffff` and shares their storage with the operand data array.
OIX/IIX select cache halves using effective address bit 25.
Debugger reads and disassembly observe existing cache contents without filling or evicting entries.

The model completes fills and write-back synchronously; pipeline overlap, bus contention, cache miss cycles and write-buffer timing remain unimplemented.
Translated accesses use the virtual cache index, physical tag and page C/WT attributes; associative cache-array writes search the appropriate TLB.
Writes targeting the read-only boot ROM remain explicit development stops, including invalid manually fabricated dirty cache entries.
These functional tests do not establish real BIOS/game compatibility or timing accuracy.

## Store queue implementation boundary

Longword and quadword stores to `0xe0000000..0xe3ffffff` select one of two queues using address bit 5 and select a word using bits 4:2.
The remaining address bits do not select queue storage, so aliased writes replace the same words.
PREF transfers all 32 bytes to `(address & 0x03ffffe0) | ((QACR & 0x1c) << 24)` and retains the queue contents.
The external destination is validated before any bytes are written; unimplemented destinations stop explicitly.
Transfers are synchronous and do not model burst latency, bus arbitration or the documented SH7750 pipeline errata.
QACR and undefined queue reset contents use deterministic zero.

When MMUCR.AT is set, queue writes validate UTLB permissions and PREF uses the translated physical destination in place of QACR.
SQ writes test write permissions and D; PREF tests read permissions without requiring D.
SQMD controls user-mode SQ writes and transfers, with write-type and read-type address exceptions respectively.
The user-mode exception for store queues never permits instruction fetches from P4.
Other accessible, cacheable PREF addresses fill an operand-cache line when enabled; inaccessible hints produce no exception and do not fill the cache.
Queue reads and byte/word stores remain unsupported.

## DMA implementation boundary

The SH7750 DMAC exposes four SAR/DAR/DMATCR/CHCR groups and DMAOR as longword registers through P4 and direct area-7 aliases.
Auto-request external-memory transfers support byte, word, longword, quadword and 32-byte units, with independently fixed, increasing or decreasing source and destination addresses.
SAR/DAR describe the current unit and advance after it completes; DMATCR counts units and an initial zero denotes 16,777,216 units.
External accesses ignore the top three address bits and bypass CPU address translation and both caches.
Each transfer validates its source and destination before copying a snapshot of one unit.
Unknown devices remain development stops, while documented alignment and external area-7 violations set AE and suspend all channels.

Completion sets TE without clearing DE and requests the channel-specific DMTE interrupt when IE is set.
AE requests DMAE independently of channel IE.
INTC uses IPRC.DMAC and the documented ordering within the DMA group and against TMU requests.
TE, AE and NMIF cannot be set by software and require a preceding read of one before writing zero to clear them.
Non-mutating register inspection does not satisfy this read requirement.
An NMI input edge sets NMIF and suspends transfers even when SR.BL prevents CPU acceptance of the pending NMI.
Clearing DME or DE suspends progress without setting TE.

The scheduler currently permits one transfer unit per configured bus clock, nominally 100 MHz.
This functional schedule does not reproduce memory wait states, bus arbitration, CPU stalls, or burst/cycle-steal timing.
SCI and SCIF transmit/receive requests and their byte-wide DMA endpoints are connected, independently of the CPU serial interrupt enables.
SCIF DMA accesses automatically update TEND/TDFE/RDF/DR under the documented FIFO count conditions.
Peripheral auto-request transfers can also access these endpoints.
Other peripheral and external request sources remain disconnected; unsupported peripheral endpoints stop explicitly.
Channel-0 DDT 32-byte requests are implemented below; other DTR sizes, counts, modes and queued channels remain pending.
Serial events and peripheral DMA units are interleaved at bus-slot boundaries so batched advancement agrees with individual clocks.
Undefined SAR/DAR/count reset values use deterministic zero.
A synthetic guest DMA handler reads and clears completion, disables its channel, returns through RTE and resumes the interrupted code.
A development stop during a scheduled DMA unit retains the already completed CPU instruction and its elapsed clock in ExecResult.

## Serial implementation boundary

The SH7750 SCIF exposes the documented byte and word registers through P4 and direct area-7 aliases.
Transmit and receive FIFOs each hold 16 bytes; transmission also uses the shift register.
The internal baud generator uses `32 * (SCBRR + 1) * 4^CKS` peripheral clocks per bit, with programmed 7/8-bit data, optional parity and one/two stop bits.
TDFE and RDF follow all four transmit/receive trigger levels, and DR indicates a receive tail after 15 idle bit periods.
Status flags require the documented read-one/write-zero acknowledgement and cannot be set by software.
Input frames can carry parity/framing errors; the FIFO preserves per-byte error flags and error counts, while overrun drops the new frame and blocks further reception until acknowledged.
Detected breaks can be injected as decoded events.
ERI/RXI/BRI/TXI are routed through IPRC.SCIF with their documented group priority.
Equal-priority module requests follow the hardware table order: DMAC precedes TMU, SCI, SCIF and WDT.
CTS controls the start of subsequent frames, RTS reflects receive capacity in modem mode, and internal loopback delivers transmitted frames to the receiver.

Headless diagnostics can attach `core.bus.scif.onTransmit` to receive completed bytes and use `receiveFrame` or `receiveBreak` to inject decoded serial input.
These endpoints model frames rather than decoding or emitting pin-level waveforms.
Register inspection with side effects disabled does not consume input or acknowledge status flags.
A synthetic guest program writes the transmit data register through Core.exec and produces its expected byte without GUI changes.
Tests also exercise DMA streams longer than the FIFO and compare batched bidirectional DMA/loopback against individual clocks.

The existing CPU clock model still uses one placeholder CPU cycle per step; serial bit periods therefore do not establish accurate whole-system timing.
External serial clocks, bit-level sampling, baud-generator settling, premature TE changes and device errata need further hardware validation.
The separate SCI channel implements internal/external-clock asynchronous and synchronous transmission, decoded reception, double buffering, baud/data/parity/stop settings and ERI/RXI/TXI/TEI interrupts through IPRB.SCI.
Its byte-only registers enforce read-one/write-zero status acknowledgement; CPU TDR writes require a separate TDRE clear, while DMA performs automatic acknowledgement.
Receive parity/framing errors transfer the byte without setting RDRF; overrun preserves the unread byte, and all three errors block reception until acknowledged.
SCSPTR.EIO suppresses CPU RXI without suppressing receive DMA or ERI.
Transmission preloads the next byte at the start of the stop bit and otherwise sets TEND/TEI there; completed-frame callbacks occur after the stop bits.
SCI module stop resets all registers except SCSPTR and discards pending transmission; software must reconfigure the channel after restarting it.
Headless users can attach `core.bus.sci.onTransmit` and inject `receiveFrame` events.
Synchronous mode always transfers eight bits, ignores asynchronous parity/stop/length settings, and uses `4 * (SCBRR + 1) * 4^CKS` peripheral clocks per bit.
Its final-data-bit boundary performs transmit preload/TEND arbitration; receive overrun suspends both directions until acknowledged.
`tickExternalClocks` advances SCK input cycles: sixteen per asynchronous bit and one per synchronous bit; peripheral ticks do not advance an externally clocked transmitter.
External clock cycles are explicit test/adapter inputs; they do not decode pin edges, start-bit synchronization or receive samples.
A synthetic bidirectional synchronous DMA stream compares batched master-clock advancement with individual ticks.
Asynchronous multiprocessor reception accepts an explicit `multiprocessorBit` on decoded `receiveFrame` inputs (SH7750 hardware manual sections 15.2.5, 15.2.7 and 15.3.3).
With MPIE set, data frames are discarded without receive requests or framing/overrun errors; an address frame clears MPIE before normal receive and error handling.
MP replaces the parity bit regardless of PE, supports seven/eight data bits and one/two stop bits, and leaves subsequent data frames enabled until software rearms MPIE.
Synchronous and ordinary asynchronous modes ignore the injected MP bit and MPIE filtering.
SCSSR.MPB remains deterministically zero because the manual explicitly identifies its read value as undefined on this LSI; software must not use it to recover the address bit.
MPIE and unread address/data state participate in native save/load without new serialized fields.
Multiprocessor transmission uses the same data double buffer, CPU/DMA requests and stop-bit TEND boundary as ordinary asynchronous transmission.
MPBT is not buffered with TDR: the model samples its current value at the beginning of the MP bit, after the start/data bits and before the stop bits (sections 15.2.7 and 15.3.3).
The sampled value is retained through frame completion and native save/load, including when a TEI handler changes MPBT during the stop bit for the next frame.
`onTransmitFrame(byte, multiprocessorBit)` delivers decoded completed frames with a Boolean MP bit in multiprocessor mode and null in ordinary/synchronous mode; the existing byte-only `onTransmit` callback remains available.
Tests cover all seven/eight-bit, one/two-stop and PE combinations with internal/external clocks, double buffering, MPBT changes before/after sampling, decoded loopback with address filtering, DMA writes, batch equivalence, reset/abort and save/load on both sides of the sampling boundary.
Pin-level changes during an individual bit and physical propagation timing remain unmeasured; software should follow the manual's requirement to wait for TEND before changing MPBT.
Smart-card mode remains unimplemented.
Pin-level serial sampling and undefined multiprocessor receive-bit behavior remain pending hardware validation.

## Timer implementation boundary

TMU channels 0-2 expose byte TOCR/TSTR, longword TCOR/TCNT and word TCR through P4 and direct area-7 aliases.
Internal peripheral-clock divisors, automatic reload, write-zero-clear UNF and level-sensitive underflow requests are implemented from the SH7750 hardware manual, section 12.
Tests cover multiple underflows in one batch, all five divisors, the full 32-bit reload period, reset and invalid access widths.
The model uses a shared free-running prescaler phase; its precise phase relationship to timer start/stop needs hardware validation.
Core execution advances TMU with the configured CPG peripheral clock, nominally 50 MHz, carrying fractional clocks between steps.
This connection uses the existing one-clock-per-step placeholder and does not establish accurate instruction or interrupt latency.
CPG module gates pause TMU advancement; direct device tests can also advance peripheral clocks.
INTC arbitration delivers underflow events `0x400`, `0x420` and `0x440` at instruction boundaries, subject to priority, IMASK, BL and delay-slot rules.
Equal-priority requests follow the documented default order: external IRL precedes TMU0, TMU1 and TMU2.
NMI input transitions latch the edge selected by NMIE, outrank maskable requests and consume the latch on acceptance.
NMIB permits NMI acceptance with BL set and clears on acceptance; MAI masks other requests while the NMI pin is low.
CPU/manual reset retains the external NMI level and clears its pending latch; full core reset holds the unconnected NMI pin high.
RTC/external clocks and input-capture configuration stop explicitly rather than silently counting from an incorrect clock.
TCPR2 currently reads deterministic zero because capture is unavailable.

## Clock and power implementation boundary

FRQCR implements the fifteen documented divider combinations with nominal mode-5 reset ratios of 200/100/50 MHz for CPU, bus and peripheral clocks.
PLL changes suspend CPU, bus and peripheral advancement while the watchdog counter measures stabilization; ordinary divider changes preserve fractional clock progress deterministically.
WTCNT and WTCSR enforce keyed word writes and byte reads.
Interval overflow requests WDT through IPRB; watchdog overflow performs a power-on or manual CPU reset while retaining the clock-control registers and external RAM.
Ordinary manual reset retains STBCR, while watchdog reset clears the standby registers.
STBCR gates implemented DMA, SCIF and TMU clocks, and stopped SCIF rejects decoded receive events.
The RTC gate bit is stored for its future device; PHZ/PPU pin behavior is not modeled.

Light SLEEP halts instruction execution while peripherals continue and resumes at the following instruction after an accepted interrupt.
Sleep wakeup ignores SR.BL while retaining IMASK and interrupt priority checks.
Deep sleep follows SH7750 hardware manual section 9.4: SLEEP with STBY clear and DSLP set retains CPU state, halts instruction execution and DMAC transfer units, and leaves peripheral clocks running.
Entry requires terminated DMA channels and MCR.RFSH/RMODE self-refresh for retail SDRAM; violating these documented software preconditions produces an explicit development stop before changing PC or sleep state.
Interrupt wakeup clears the deep-sleep latch before resumed DMA advancement and retains the ordinary sleep IMASK/BL behavior; NMI and watchdog/manual/full reset also release the latch.
HOLLY, GPU, AICA and host media observations continue on their independent device clocks; deep sleep does not pause the entire console.
The BSC model retains register/counter behavior, while SDRAM refresh pins and actual external-bus quiescence are not modeled at cycle level.
Tests cover peripheral counting, light/deep DMA clock differences, IRL/BL/IMASK, NMI, timer handler return to the following instruction, watchdog resets and CPU reset retention.
The CPG sleep latch and clock fractions participate in native save/load; public loading rejects inconsistent CPU/CPG/self-refresh state before committing live RAM or device state.
Standby still stops explicitly because its stopped-clock, register-initialization and oscillation-restart contracts are not implemented.
The board mode-pin assumption, PLL shutdown and PLL2-only stabilization transitions, prescaler phase after counter writes and subcycle divider changes still need hardware validation.
The allowed stabilization counter result of zero or one is represented deterministically as zero.
These functional clocks do not provide instruction pipeline, memory wait-state or interrupt latency accuracy.

## System flash implementation boundary

The VA0 schematic labels IC502 as a 5 V MBM29F002 and ties its A17 pin high.
The CPU therefore sees the upper 128 KiB of the 256 KiB die at physical `0x00200000..0x0021ffff`.
The top-boot variant matches the independently observed 64/32/8/8/16 KiB partition boundaries; its autoselect IDs are manufacturer `0x04` and device `0xb0`.
Later board variants and their IDs still need separate confirmation.
Unlock commands decode A0–A10; byte programming only clears bits, and attempted zero-to-one programming leaves a DQ5 failure until reset/read.
The model implements DQ7 data polling, DQ6 toggle, DQ3 sector-selection timeout, DQ2 erase suspension, multi-sector selection, chip erase, suspend/resume and programming of a non-suspended sector.
Debugger peeks do not toggle status.
Operation scheduling uses nominal datasheet durations of 8 microseconds for byte programming, 50 microseconds for sector selection and one second for erase, measured on the fixed master timebase.
Suspend latency is represented immediately; voltage effects, endurance, protected-sector response delays and precise failure timing remain unvalidated.

The power-cycle reset clears command state while retaining data.
CPU resets retain command state because the board ties the chip RESET pin high.
A new chip starts erased; no factory serial number, region, checksum or system-setting image is fabricated.
Headless callers can import an authorized 128 KiB image with `core.bus.flash.loadImage` and export it with `exportImage`.
`Core.setSram` attaches the shared persistence interface under `dc/sram/system_flash`; the factory image and later writes use the same storage.
The default model protects the factory sector at offset `0x1a000..0x1bfff`, matching the system specification's 8 KiB protected area and the independently observed factory partition.
Component tests can configure a different protection set for chip-level diagnostics.

Uncached CPU reads and writes support byte/word/longword transfers; the byte-wide G1 device receives wider transfers in address order.
Cached array and status reads retain normal SH-4 cache behavior: a line fill performs device reads, while hits and debugger peeks do not toggle status.
Cached polling can therefore retain stale status until software invalidates the line.
Unspecified autoselect outputs use deterministic ones so an identifier line can be filled without assigning meaning to undefined bytes.
SH4 DMA reads bypass the CPU cache and perform device read cycles after validating the destination.
Cached writes and store-queue transfers to boot ROM/flash remain explicit stops because the system architecture permits only cached reads and excludes those devices from store-queue access.
Flash writes through other bulk masters and G1 arbitration/wait-state timing still need validation.
A self-authored SH-4 diagnostic programs a byte through `Core.exec` and verifies persistence through a second core instance.

## HOLLY interrupt implementation boundary

The system-bus interrupt block exposes longword-only status, level-2/4/6 mask and GPU/G2 DMA-trigger selection registers, including the documented area-0 image alias.
Normal and error sources latch independently and use write-one-clear acknowledgement; external status follows the generating devices and ignores software writes.
ISTNRM bits 30/31 summarize external/error status and cannot be cleared or selected as normal interrupt sources.
Reserved mask bits read back as zero, and the controller supports HOLLY1/HOLLY2 normal-source masks, with HOLLY2 selected by default.
The highest enabled tier drives IRL1/IRL2 with levels 6, 4 and 2; CPU priority, BL, IMASK and delay-slot rules still apply through INTC.
A self-authored SH-4 handler clears the HOLLY source and returns through RTE to the interrupted instruction.
CPU reset retains this external controller; its own reset clears status/masks while preserving external levels unless the whole core is power-cycled.

`raiseNormal`, `raiseError` and `setExternal` provide source endpoints; SPG drives video events, Maple drives its completion, overrun and error events, optical drives external interrupt bit 0 and AICA drives external bit 1.
G2 trigger selection connects normal source pulses and rising external levels to its DMA engine; GPU trigger output remains an unconnected selected-source level.
Register changes and IRQ propagation are functional and immediate; posted writes, clock-domain synchronization and the documented dummy-read pipeline delays remain unmodeled.
The remaining system-bus registers, DMA engines and physical device events are still pending.

## GPU memory and framebuffer boundary

The core stores 8 MiB of VRAM as two contiguous 4 MiB banks in 32-bit aperture order.
The 64-bit aperture alternates longwords between banks A and B, following the system architecture's texture-memory address diagram.
Both apertures and their area-1 images access the same storage; the absent extended memory is represented by an 8 MiB address wrap, which still needs hardware confirmation for every board variant.
External CPU accesses use words, longwords or cache-line bursts; compound SH4 quadwords use two consecutive longwords.
Byte bus accesses stop explicitly, while cached byte stores can reach VRAM through a line write-back and debugger byte peeks remain available.
Cache fills/write-backs, write-through writes, SH4 DMA and store-queue bursts all use the same address conversion.
The cache remains unsnooped across VRAM aperture aliases.

Implemented registers include ID/revision, SOFTRESET, border color, framebuffer read control, both field start addresses, size/modulus, video output control and horizontal/vertical display start positions.
The core identifies the documented HOLLY2 revision `0x11`; other revisions remain a future configuration choice.
Framebuffer readout supports 0555 RGB, RGB565, packed RGB888 and 32-bit RGB0888, including concatenation bits, row modulus, address wrap, blank border color and display doubling metadata.
The DAC output is opaque; K/alpha and chroma signaling do not become image transparency.
Headless tests can capture either live field through `core.bus.gpu.image(field2: ...)`; when internal SPG timing runs, `Core.imageBuffer` returns the last completed field image or rolling interlaced weave.
Strip-buffer drawing and scanout have a functional synchronized path; X clipping in strip mode and external field-selection modes remain explicit unsupported cases.
SOFTRESET holds TA/SDRAM input and CORE rendering in reset and clears the corresponding functional engines; exact reset duration, register retention and physical device sequencing remain unverified.
A device reset retains VRAM and a whole-core power cycle clears undefined RAM deterministically.

Each display row is sampled when the horizontal counter reaches VO_STARTX on the line selected by VO_STARTY.
Already sampled rows retain their pixels, while upcoming rows observe subsequent VRAM, blank-video and color-setting changes.
Field completion publishes the sampled buffer without reading earlier rows again.
Line doubling samples the same source row on successive display lines, so a write between the two reads can produce different output rows.
Interlaced capture uses separate field start positions and half-line counter units before weaving both fields.
Horizontal clipping accounts for line end, programmed blank edges and pixel doubling; clipped or unscanned framebuffer pixels are represented by the border color.
The output covers the framebuffer extent, rather than a full CRT image with outer borders and analog blank levels.
Output buffer geometry and its vertical origin are fixed at the first sampled row of each field; exact timing for size/format changes during an active field still needs hardware validation.
Sampling is row-granular: intra-row writes, FIFO prefetch, exact DAC blank/polarity behavior, sync-pulse shaping and scanout bus contention remain pending.
Live diagnostic capture remains available when internal SPG timing is not running.
A self-authored SH4 program writes red/green pixels through the CPU bus and obtains independently checked RGBA values through `ImageBuffer`, without app changes.

## TA parameter and CORE rendering boundary

`DcTa` consumes 32-byte polygon FIFO bursts from store queues, normal SH4 DMA or completed cache writebacks.
The polygon aperture includes P0/P1/P2 and its documented area-4 image; reads and direct partial bursts stop explicitly.
The existing cache allocation/writeback contract remains in force, and no app or GUI changes are needed.
HOLLY ch2-DDT initiation, sort DMA and physical FIFO backpressure remain pending.
The direct texture path and functional FIFO capacity are described below.

TA list initialization allocates the enabled HOLLY2 list types' initial OPBs in horizontal tile order, latches their allocation settings and initializes current parameter/additional-OPB pointers.
Continuation replaces the initial OPB area while retaining the additional-OPB and ISP/TSP cursors.
Polygon input supports packed, floating and both intensity color modes with optional RGB/palette textures and offset colors; modifier triangle input is described below.
Long intensity/offset headers and floating textured vertices accumulate two 32-byte bursts before conversion, and continuation words are not misinterpreted as new control words.
Full reset discards partial packets, while list initialization during a truncated packet stops explicitly.
Color conversion clamps finite components to [0,1] and truncates after multiplication by 255; exact hardware rounding remains unverified.
The active page-186 tables place packed color and intensity at byte 0x18; the contradictory HOLLY2 change tables on page 189 and their introductory text are struck out in the original PDF and are not applied.
Group controls retain strip lengths of 1, 2, 4 or 6 triangles and disabled/inside/outside user-tile clipping until updated.
Infinite strips are partitioned with shared boundary vertices, alternating winding and per-tile triangle masks.
TA tile inclusion uses truncated vertex coordinates and per-triangle bounding boxes intersected with global/user tile clips, rather than exact pixel coverage.
Fully clipped groups do not consume parameter memory.

The TA writes the documented packed ISP/TSP parameters and object pointers directly into the shared 32-bit VRAM layout.
OPBs reserve a link/end entry and allocate additional blocks in either programmed address direction when full.
Object List Set can register independently supplied VRAM parameters without regenerating them.
End of List writes terminators for every tile of the selected list and raises its corresponding HOLLY completion source.
Disabled/repeated lists and invalid sequences raise the TA parameter error and stop explicitly; parameter/OPB limit failures raise their separate overflow sources without reporting completion.
TA illegal-input recovery, pointer merging/array compaction and TA_OL_POINTERS inspection remain pending.

`DcGpuRender` reads the CPU-authored five- or six-word Region Array, follows object-list links and fetches vertex data from VRAM at each tile deadline.
It does not retain an alternate host primitive list; CPU writes to generated parameters affect subsequent drawing.
The baseline rasterizer supports textured/non-textured triangle strips, flat/Gouraud colors, programmable reciprocal-depth comparisons, Z-write disable, determinant culling and all eight source/destination blend factors.
Opaque, punch-through and pre-sorted/auto-sorted translucent lists use the primary accumulation buffer; functional intensity and parameter-selection modifier volumes are described below.
The background uses the selected parameter tag, functional flat/Gouraud color and optional texture with a separately programmed depth.
Its shadow flag supports intensity and parameter-selection modifier volumes using background-depth evaluation before foreground composition.
Retained consecutive tiles support the Region Array's Z-clear and flush controls.
Framebuffer output applies X/Y write clips, byte stride, all seven documented packing formats, K/alpha threshold and the selected 32/64-bit VRAM mapping.
Horizontal 1/2 framebuffer scaling now averages adjacent accumulation-buffer pixels before packing and applies X clipping in output coordinates.
Vertical scaling now stages rendered tiles to supply neighboring rows for interpolation and three-line reduction filtering before output packing.
The physical dithering matrix and nonzero perpendicular-rejection thresholds remain pending.

Raster math currently uses host doubles, configurable integer/half-pixel sampling, a top-left edge convention and nearest-integer color/blend rounding.
These choices form a functional model, not hardware-validated edge, interpolation or internal color precision.
TA conversion and VRAM stores are synchronous; rendering advances one region per two nominal master clocks solely to expose ordered completion and shared-memory deadlines.
The actual FIFO, tile cache, pipeline, bus contention, reset phases and separate Video/ISP/TSP completion latencies are not modeled; the three render completion bits are raised together after the final committed region.
Cyclic object lists, out-of-range VRAM and unsupported behavior stop without a false render completion.

Independent tests inspect pointer/parameter words, strip masks, OPB links and list continuation, then check primitive colors, depth, culling, blend coefficients, framebuffer formats and ordered tile completion.
A self-authored SH4 ROM configures TA and CORE, sends all five packets through guest PREF/store-queue instructions, starts rendering and produces checked red-triangle/background pixels through ImageBuffer without host device setup.
Native and browser execution are checked independently; full hardware scene comparisons and BIOS/game display lists remain required for stage 9.

### Punch-through and per-pixel translucent sorting

CORE processes opaque results before punch-through, and both contribute depth to translucent drawing, regardless of the lists' input order or pointer order in the Region Array.
Punch-through uses PT_ALPHA_REF, whose default is 255 and whose valid field is the low byte.
The functional model applies the inclusive threshold to the final shaded/filtered pixel alpha, selects the nearest accepted fragment and copies its RGB with opaque output alpha, bypassing accumulation blend factors.
Rejected pixels do not update depth, so farther accepted punch-through or translucent pixels remain visible.
Equal-depth punch-through fragments give later input priority.
The general Z-write-disable control is retained independently of punch-through's fixed comparison.

The fixed punch-through comparison follows section 3.4.3's greater-or-equal reciprocal-depth rule, consistent with its opaque-depth reference, despite the conflicting less-or-equal wording in section 3.7.9.1.
The alpha-test point follows PT_ALPHA_REF's pixel-alpha wording and the texture/shading equations, while some earlier prose refers only to texel alpha.
These source discrepancies, exact tie precision and Z-mask interactions still require physical validation.

Translucent pre-sort draws in input order using the programmed depth function.
Auto-sort ignores that function and uses greater-or-equal, replaying the object list to select each pixel's next farthest eligible fragment before blending it.
A previous (depth, primitive-order) key prevents equal-depth fragments from repeating and ensures that earlier input is farther away at a tie.
Only one candidate and one previous key per pixel are held, so temporary storage does not grow with the number of overlap layers.
Opaque/punch-through depth rejection and programmed Z-write disable remain effective through retained multipass regions.
Type-1 Region Arrays use ISP_FEED_CFG's sort mode, while type-2 arrays select it per region.
Hardware ISP-cache capacities/overflow, discard scheduling, texture-cache phases and sort latency remain unmodeled; functional region timing is still the placeholder described above.

Gouraud RGB and alpha now use reciprocal-depth compensation rather than screen-linear interpolation; flat shading still uses the third defining vertex.
Regressions independently check crossing depth planes, equal-depth order, multiple OPBs, mode selection, perspective RGBA, threshold boundaries, filtered/shaded alpha, dependency order, depth masking and reset recovery after a list fault on native and browser runtimes.

### Sprites, quad planes and independent arrays

The TA accepts Sprite globals with packed flat base/offset colors and 64-byte Sprite vertex parameters, including non-textured and 16-bit-UV textured forms.
The second vertex burst is continuation data regardless of its first word's bit pattern.
The required End Of Strip bit is checked, and prohibited floating/intensity sprite colors, Gouraud input or textured 32-bit UV signal the TA parameter error.
Triangle globals can resume normal parsing after sprite objects.
A sprite stores a Quad Array object pointer and the full four-vertex ISP/TSP record; the fourth vertex contains defined X/Y and deterministic placeholders for its invalid fields.
Its TA bounding box includes all four positions and uses the existing global/user tile clips, OPB allocation and parameter-limit checks.
TA still emits one pointer per sprite rather than compacting adjacent objects into a counted array; hardware pointer merging remains pending.

The CORE reads independent Triangle Array and Quad Array pointers, including their 1–16 contiguous-record counts, in addition to masked triangle strips.
Quad vertices follow the perimeter sequence in figure 3-1, with ABC defining the surface plane and only D.X/D.Y loaded from the fourth record.
The same ABC plane supplies reciprocal depth, perspective UV, flat/Gouraud base and offset colors and MIP derivatives across both raster coverage triangles.
Invalid fourth-vertex Z/UV/color fields are not fetched, including when they contain NaN bit patterns.
Quad culling uses the defining ABC determinant once, and the shared diagonal uses the same top-left coverage convention to avoid double blending.
This is a functional triangulated coverage implementation; exact hardware quad edge precision, plane arithmetic and degenerate-case behavior remain unverified.
Concave/crossed quads stop explicitly pending hardware evidence.

Independent regressions inspect the generated Quad Array format, burst continuation, parameter sizes and D-inclusive tile boxes.
Rendered scenes check flat/textured/offset sprites, derived depth/UV/color in the opposite half, counted CPU arrays, whole-quad culling and single coverage of half-alpha diagonals on native and browser runtimes.

### RGB/palette texture sampling and shading

TA parameters retain 32-bit IEEE UV values or the documented packed upper halves of IEEE UV values; the latter are not IEEE binary16.
Generated object pointers carry the corresponding skip size, and the CORE validates it against the parameter format before reading vertices.
Texture UVs and Gouraud base/offset RGBA are interpolated using reciprocal depth for perspective correction, as required by section 3.1.1.8, independently of the integer/half-pixel position chosen for coverage through HALF_OFFSET.
Zero perspective denominators and nonfinite/overflowing coordinates stop explicitly without a render-completion interrupt.

`DcGpuTexture` reads texture data from the 64-bit VRAM layout and supports uncompressed ARGB1555, RGB565 and ARGB4444; format code 7 uses ARGB1555 as specified.
Twiddled addressing alternates V/U bits starting with V0, placing any remaining rectangular-coordinate bits at the high end.
Twiddled color components extend by repeating their upper bits, while linear components append zeroes except for one-bit alpha.
Linear row-major textures support TEXT_CONTROL stride, and each direction supports repeat, mirror or clamp with clamp taking precedence.
The functional point sampler uses floor(U*width), floor(V*height); the bilinear sampler averages the four neighbors at that position, including wrapped/clamped borders.
Filter weights, texel-origin conventions, coordinate precision and rounding still require physical measurements.
Trilinear pass codes fall back to point sampling when no effective MIP mapping is enabled, as specified.
Functional bump sampling and texture supersampling are described below; alternate texture bank positions remain an explicit development stop.
The MIP flag is ignored for linear textures.

The CORE implements Decal, Modulate, Decal Alpha and Modulate Alpha before accumulation blending, including Ignore Texture Alpha and saturated RGB offset addition.
Base/offset colors follow flat/Gouraud selection, including offset-alpha vertex fog.
Texels are read from current VRAM without a modeled texture cache.
Tests check independent storage patterns, square/rectangular layouts, format expansion, stride, addressing modes, four-texel averages and all four shading equations.
Pipeline diagnostics upload texture data through store queues, inspect generated UV/skip words, and check final pixels from 16/32-bit UVs, long floating/intensity packets, perspective correction and HALF_OFFSET selection on native and browser runtimes.

### RGB VQ texture decoding

Square twiddled ARGB1555/RGB565/ARGB4444 textures support the VQ-compressed flag; pixel format 7 retains its specified RGB1555 interpretation.
The texture address identifies a 256-element codebook of four 16-bit texels per element, followed at byte offset 0800h by the eight-bit index image.
The index image is half the texture width and height, with Morton ordering; the two low texel-coordinate bits select the reverse-N position within the chosen codebook element.
The existing texture addressing, component expansion, shading and filtering paths operate on the decoded texels, including interpolation across different codebook elements.
Reduced-codebook layouts keep the specified fixed 2048-byte index displacement and can select only the entries actually populated, without a separate codebook-size setting.
Functional reads observe current VRAM without a modeled codebook/index cache.

Linear or rectangular non-MIP VQ and big-endian codebook/index wiring remain explicit development stops; §3.6.2.3 only specifies square VQ.
Point/bilinear MIP layouts are described below.
Section 3.6.2.3 describes square RGB VQ in detail, while the later Texture Control Word description explicitly includes larger palette-VQ block geometries.
The functional non-MIP palette VQ path described below uses those geometries and the documented palette twiddle word ordering; palette VQ MIP layouts remain unresolved.
TEXT_CONTROL names separate big-endian selectors but does not establish the byte/word permutation used by the internal 64-bit fetch here, so that permutation is not guessed.
Tests independently check index displacement, block order, all supported color formats, high code indices, addressing boundaries, filtering and final TA/CORE pixels in native and browser runtimes.

### MIP layouts and functional resolution selection

Point, bilinear and functional trilinear sampling support the square twiddled RGB, palette and RGB-VQ MIP layouts in System Architecture section 3.6.2.4.
The MIP flag makes the V size equal the U size; linear textures continue to ignore the flag.
All levels down to 1x1 use the explicit page-148 offset tables, retaining their documented padding instead of assuming tightly packed levels.
RGB offsets are bytes, eight-bit palette offsets are bytes, and four-bit palette offsets are nibbles, including nibble 3 for the smallest four-bit level.
VQ offsets locate index data after the fixed 2048-byte codebook; the smallest 1x1 level uses texel 3 of the selected element.
Each level applies its own dimensions to wrapping, clamping, Morton addressing and filtering.

CORE derives planes for U*Z, V*Z and reciprocal depth and applies the two documented Dcalc numerator formulas before dividing by the squared depth denominator at the current texture-sampling position.
Dcalc=0 uses the screen-origin constants; Dcalc=1 uses the original first vertex of the current triangle.
The larger Euclidean texture-gradient magnitude determines the functional footprint, scaled by the TSP's unsigned quarter-unit D-adjust value; adjustment zero is prohibited.
A power-of-two footprint policy selects a resolution and clamps to the largest/1x1 limits.
This threshold policy is an explicit model inference from the binary texture hierarchy, not a physically measured implementation: page 112 gives full resolution below D=2 and the next resolution for 2<D<3 but does not supply a complete transition table.
Exact threshold encoding, finite internal derivative precision and source-document range ambiguities still need independent hardware observations.
Uniform coordinates retain the largest level in this model.

Effective MIP trilinear Pass A/B use the functional binary-interval model described below; the physical D encoding, fractional weighting and transition precision still require validation.
The documented non-MIP fallback for those filter codes remains point sampling.
Tests inspect independent RGB/palette/VQ level patterns, the special 1x1 texel/nibble positions, D-adjust, level limits and bilinear dimensions.
CORE regressions verify automatic minification in all three storage families and different Dcalc results from the manual's screen-origin/first-vertex formulas on native and browser runtimes.

### Palette RAM and indexed textures

The on-chip palette exposes 1024 longword entries at 005F9000h–005F9FFFh, including the normal CORE register aliases.
PAL_RAM_CTRL selects ARGB1555, RGB565, ARGB4444 or ARGB8888; only the lower 16 written bits are retained in the 16-bit modes.
The palette's 16-bit channels use the documented replicated-bit color expansion for twiddled texture data.
Four-bit textures unpack the low nibble first in Morton order and append all six selector bits to form a 10-bit palette index.
Eight-bit textures append only selector bits 26–25; the other four selector bits are ignored.
Palette-selector bits must not be interpreted as Scan Order or Stride Select; these uncompressed indexed textures always use the square/rectangular twiddled addressing rules.
Filtering resolves all palette indices to RGBA colors before combining neighboring texels.

The functional model stores raw palette words and decodes them using the current control value at fetch time.
CPU writes before a region is processed affect that region's palette lookups without a modeled palette/texture cache.
The specification requires choosing PAL_RAM_CTRL before loading palette data; conversion timing and changes of format after existing writes need physical validation.
TA/CORE soft resets retain palette words and format; full device reset restores the format default while retaining RAM, and a whole-core power cycle clears undefined words deterministically.
Exact physical reset retention, cache synchronization and the additional ARGB8888 filtering cost remain unverified.
CPU access currently uses the register path; HOLLY GPU-DMA palette uploads remain pending.
Tests check all four color formats, full selector ranges, nibble/byte ordering, overlapping control bits, rectangular addressing, color-space filtering, CPU-update visibility, reset behavior and final indexed-texture pixels on native and browser runtimes.

### Direct Texture Path and board FIFO controls

The write-only 11000000h–11FFFFFFh and 13000000h–13FFFFFFh apertures accept aligned 32-byte bursts through store queues, normal SH4 DMA and allocated cache-line writebacks.
SB_LMMODE0 and SB_LMMODE1 independently choose 64-bit interleaved or 32-bit contiguous VRAM layout for the main and image paths; both default to 64-bit layout.
These settings belong to the board interface and survive TA/CORE soft resets; full core reset restores their defaults.
Data is committed to the same retail 8 MiB VRAM buffer used by rendering, with the existing aperture alias behavior and unsnooped SH4 caches.
The path performs no texture decoding or TA parameter conversion and requires neither list initialization nor a polygon header.
Partial external writes and reads stop explicitly; CPU cache-lane stores remain local until a complete line is written back.

SB_TFREM returns eight available 32-byte entries because the current functional TA/direct-texture FIFO drains synchronously.
This reports modeled empty capacity, not a claimed hardware power-on counter value; the specification states that the physical register is not initialized by reset.
Mode/capacity registers use aligned longword accesses and the documented area-0 images.
Transfers issue no separate completion interrupt, and input while TA/SDRAM reset is held stops explicitly.
Actual FIFO occupancy, arbitration/backpressure, reset sequencing and transfer latency remain unverified.
Tests independently check bank contents, both mode registers, the final retail burst and aliases, cache writeback/bypass, normal DMA and reset handling on native and browser runtimes.

## SPG scheduling boundary

The sync generator implements SPG load, control, H/V blanking, H/V interrupt comparison, pulse width, status and external-trigger capture registers.
The source is the board's nominal 27 MHz VGA pixel clock or 13.5 MHz progressive television clock, advanced as an integer ratio against the fixed 200 MHz master timebase.
Fractional progress survives CPU steps and batched advancement without per-line rounding drift.
The interlaced schedule uses half-line counter units to match the official NTSC/PAL presets and field rates; exact odd/even half-line pin phase still needs hardware validation.
HBlank supports a selected line, every positive N lines, or every line; the periodic mode's phase is modeled relative to line zero and remains a hardware verification item.
Blank intervals retain their state across counter wrap until the programmed ending comparator is reached.
Status exposes logical sync-active/blank flags, scanline and field number; physical polarity, composite/equalizing pulses and external synchronization are not reproduced.
External sync selection pauses the internal counters, and unsupported external sync lock stops explicitly.

HBlank, VBlank-in and VBlank-out drive HOLLY normal sources 5, 3 and 4 respectively.
Field completion publishes the collected scanlines, then latches the pending framebuffer start addresses for the next field; FB_C_SOF exposes the active start address.
Interlaced snapshots update alternating rows and retain the other field, starting undefined rows as opaque black.
Video uses its independent clock even while CPG pauses the SH4 during PLL stabilization.
Active SH4 memory/peripheral DMA is interleaved at bus-clock boundaries so batched VRAM transfers cannot skip intervening row captures or field snapshots.
Coincident video and DMA events currently process video first; exact bus arbitration still needs validation.

Core line-completion flags follow actual SPG counter crossings, and its nominal line/field geometry follows the programmed mode.
`runFrame` counts every crossed SPG line, including multiple lines during a single PLL stabilization pause, and carries any unavoidable overshoot.
When internal SPG timing is inactive, the core retains bounded diagnostic execution slices so a program without video setup cannot hang `runFrame`.
Subcycle effects of clock/control changes and the initial comparator phase are deterministic modeling choices, not established hardware behavior.
Tests cover all five official display presets, pending page flips, VBlank interrupt entry, interlaced weaving, PLL pauses and batched-versus-individual DMA/video progression.

## Running diagnostics

A `.dc` file is a local development convention for an unscrambled, flat, little-endian SH-4 program.
It is copied to `0x8c010000`, execution starts there, and R15 starts at `0x8d000000`.
Reset clears RAM and reloads a private copy of the program.
This loader does not parse ELF, scramble/descramble disc executables or implement a BIOS syscall environment.
Generic `.bin` executables are not identified as flat diagnostics.
Disc images are parsed by the generic image package and identified by their contents through `CdromDrive`, independently of filename extensions.
BIOS setup accepts a single 2 MiB image; without a diagnostic program, reset starts at `0xa0000000`.
When a program is loaded, it takes priority over the BIOS, including after resetting or replacing the BIOS.

Execution currently charges one placeholder CPU cycle per CPU step that completes, delivers a supported exception, accepts an interrupt or performs a manual reset.
The scheduler uses a fixed nominal 200 MHz master timebase and converts CPU cycles through the configured CPG divider.
Only completed guest instructions set the instruction-executed flag; interrupt entry and faulting instruction attempts clear it.
Without internal SPG timing, scheduling values of 6350 clocks per slice and 525 slices per frame only bound diagnostic `runFrame`; they do not describe an active display mode.
With internal SPG timing, line completion and field length come from the video counters; instruction execution still uses the placeholder CPU-cycle model.
Do not use them for performance or hardware timing claims.

Run the independent bring-up tests from `packages/fnesemu_core`:

```sh
dart test test/core/dc test/core/core_layers_test.dart
```

## Maple bring-up

The Maple host supports software/VBlank-started descriptor chains on ports A–D, keyed RAM protection, both `SB_MMSEL` byte orders, normal controller packets, NOP delays, timeout markers, padded response blocks, completion/error interrupts and deferred software aborts.
A standard controller is attached to port A by default; the other ports are disconnected and can be populated through the core-owned controller list.
`Core.padDown` and `Core.padUp` address ports with IDs 0–3 and expose the directional pad, A/B/X/Y, Start and digital endpoints for L/R triggers.
The controller also accepts explicit unsigned eight-bit analog values through its headless interface.
A device reset preserves physical input and returns condition reads to discovery standby; a full core reset clears input and retains port attachments.
Device Request enables condition reads; Device Kill acknowledges once and refuses further packets until an electrical reset.
The headless `resetDevice` endpoint, full core reset and host RESET control pattern provide functional electrical reset as described below.
The host samples controller state when it consumes the descriptor.

Device information and get-condition packets use the original controller specification, with mixed-endian power fields following independent Maple packet observations.
The controller document and System Architecture disagree on the function-definition byte order; the controller document's matching tables 3.1 and 4.4 are used (`00 0f 06 fe`).
Extended device information remains an explicit development stop because the controller document's stated 40-byte extent conflicts with its two longer identification strings.
Condition writes receive no response, as specified in System Architecture §5.2.
Malformed packet lengths and unaddressed devices produce a timeout in this functional endpoint model; malformed wire traffic still needs hardware validation.

Serial budgets count nominal data and parity bits at 2 or 1 Mbps, plus the configured no-response timeout; START/END patterns, turnaround, partial receive progress and pin timing are not modeled.
Response bytes become visible at the exchange deadline, in protected 32-byte blocks; padding bytes are deterministically zero and have no specified hardware value.
Transfers bypass CPU caches and MMU translation, and scheduling splits at Maple deadlines and relevant SPG blank edges to preserve event ordering.
VBlank-over notification follows the SPG blank transition independently of programmable video IRQ lines.
Hardware initiation uses the SPG blank-end edge, supports automatic field repetition or single initiation with `SB_MSHTCL` rearming, and ignores software start writes.
`SB_MSYS` selects a delay of 0–10 units of 1.3 ms; `MDST` is busy during the delay while `MST` remains idle until descriptor processing begins.
Disabling DMA during this delay cancels initiation immediately without a completion notification; disabling it during an exchange finishes that exchange before stopping.
Switching the trigger from software to hardware while disabled rearms single initiation, as described in System Architecture §5.1.6.
The blank-end signal association follows the manual's named VBlank Out event; its exact relationship to video output origin, interlace half-lines and physical signal phase still needs hardware validation.
The scheduler processes a Maple completion before a simultaneous SPG edge; pin-level tie ordering remains unverified.
The transport uses SH4 channel-0 DDT for aligned source snapshots and received-data blocks, as described below.
Exact root-bus arbitration, source/serial FIFO pacing, FIFO overflow/parity injection and light-gun wire patterns remain pending; RESET control descriptors are implemented below.
Selecting these unimplemented control modes stops explicitly.
Memory card physical LCD/buzzer behavior, factory media parameters and complete optical drive support remain stage-7 work; the stage's complete disc/input/persistence acceptance conditions are not yet satisfied.

### Memory card bring-up

`DcMapleDevice` separates packet endpoints from the host DMA engine.
The controller owns two expansion slots and advertises connected children in its response AP; child discovery and transfers are routed only through an identified, operating parent.
`Dc.attachMemoryCard` attaches a core-owned memory card to a port/slot and connects persistence regardless of whether `setSram` was called before or after attachment.
No memory card is attached by default while factory initialization and standalone/pin behavior remain incomplete.
The endpoint advertises FT1/FT2/FT3 definitions, ordered by descending function number, and the documented product name.
It supports single-access reads, four ordered 128-byte write phases, `Get_Last_Error`, documented partition/block/phase/length errors, reset and kill.
A complete write group commits after phase 3; an interrupted or invalid group is discarded without changing the block.
The functional packet endpoint applies effects when the host consumes the descriptor, not at individual wire-bit boundaries; flash programming latency, power-loss behavior and physical write failures remain pending.

Raw 128 KiB byte images can be imported/exported without filesystem synthesis.
For a formatted card, `Get_Media_Info` returns ROM-fixed capacity/partition/root values and the remaining metadata from the system block, following FT1.
Unformatted factory media parameters and extended device information remain explicit development stops until their exact memory card definitions are verified.
The original generic FT1 layout and independent memory card root observations name some fields differently; memory card-specific factory responses still need stronger hardware evidence.
LCD packet state supports FT2 media information (48×32 dots, two levels, no contrast adjustment), a single 192-byte horizontal-1 plane, contrast reset/query and documented LCD error bits.
`lcd.exportPixels` returns an independent copy of panel bytes; `lcd.image` produces a 48×32 RGBA image using the row-major, left-MSB arrangement in FT2 figures 2.5/2.9 and memory card peripheral specification figure 4.6.
Attached LCDs appear as core-owned memory card A1–D2 debug layers through the existing video descriptor interface.
Physical mounting orientation, icon segments and display timing still need hardware validation.
Protocol reset clears the LCD to deterministic white; malformed-length writes return an error and retain panel data as a development policy until their partially displayed hardware result is known.

The FT3 calendar uses a nominal 200 MHz master clock, Gregorian month/leap-year rules, little-endian years and hexadecimal fields.
The initial date is deterministically 2000-01-01 00:00:00 until the guest sets it; this is not a claim about factory RTC contents.
Calendar writes validate the whole date without normalization, reset the fractional-second phase and ignore the unavailable weekday field according to the TR/TW command description.
The FT3 manual states year 0–9999 but prints an inconsistent hexadecimal upper bound; the decimal range is used, and overflow beyond 9999 stops explicitly pending hardware evidence.
Protocol/core resets preserve calendar time and fractional phase while clearing alarm settings; buttons remain physical input, with the most recently pressed opposing direction winning.
The timer continues with Maple DMA disabled or its device killed, and descriptor chains sample it at each request boundary.
The one-alarm period/duty registers enforce duty ≤ period and reject the unsupported second alarm; buzzer waveform/audio output and its clock source are pending.
RTC elapsed wall time while detached or between sessions, calendar persistence and standalone memory card CPU/firmware execution are not implemented.

`DcStorageRegion` selects independent keys through the existing `Sram` contract; switching a key invokes the adapter's existing `init` flush/load path.
The console flash keeps `dc/sram/system_flash`; memory cards use `dc/sram/memory_card_<port>_<slot>` with zero-based port/slot numbers.
Each region retains its current buffer when another region is selected, including with a plain in-memory `Sram`.
Tests interleave console flash and two memory cards, then restore all three regions in a fresh core using a keyed storage adapter.
No app/GUI or shared persistence API changes are required.
Next verify the memory card factory media profile and physical LCD/buzzer behavior, then validate physical DDT/Maple timing and complete the optical drive transport.

## Optical drive bring-up

The core connects the existing `CdromDrive` interface to a functional SPI PIO/DMA device.
The task file occupies `0x005f7018` and `0x005f7080..0x005f709c`, including area-0 images and direct SH-4 aliases.
SPI task-file registers use byte accesses and the data FIFO uses word accesses; unsupported wider cycles stop explicitly until their board-level behavior is verified.
Alternate Status and debugger peeks preserve INTRQ and FIFO position; normal Status reads acknowledge INTRQ.
The `nIEN` bit gates the signal while retaining the device's pending request, and HOLLY external interrupt bit 0 is updated without overwriting other external sources.
CPU/on-chip resets retain this external device; a full core reset restores its task-file signature and clears device transfers.
SPI soft reset can interrupt busy/DRQ states, restores the task-file signature, preserves drive select and transfer-mode settings, and reports completion through BSY polling.

Implemented ATA commands include NOP/unknown-command abort, software reset, device diagnostics, packet reception, synthetic device identification and transfer-mode selection.
The identification strings describe the fnesemu bring-up device and are not presented as real drive firmware contents.
Packet handling includes TEST UNIT READY, REQ_STAT, REQ_MODE, SET_MODE, REQ_ERROR, GET_TOC/REQ_SES, manual CD_OPEN, CD_PLAY/CD_SCAN, CD_SEEK, CD_READ/CD_READ2 and GET_SCD subsets described below.
PIO phases obey the host byte-count limit, expose direction/reason and transfer counts, issue data/completion interrupts and pad the unused high byte of an odd final word deterministically with zero.
SET_MODE validates the entire writable parameter range before changing it.
The packet parser clears previous sense information for a new command except REQ_ERROR and reports documented sense/ASC values for supported error conditions.
Media events are checked on device ticks and before emulated I/O, while debugger peeks preserve the device snapshot.
Media changes abort pending data, reset the head position and report unit attention; stale ready/error events for another generation are ignored.
The asynchronous tray-event-to-INTRQ/sense mapping is a functional policy; the exact tray-opening ASC/qualifier and physical notification timing still need hardware validation.

### Manual CD_OPEN

`CD_OPEN` (`16h`) follows the top-loading behavior in SPI Specifications 1.30, sections 6.1.2, 7.4 and the command description on page 59.
It stops audio, invalidates device DMA staging, clears transfer/seek state and waits with BSY set until the attached drive reports an open lid.
It does not eject the host image, synthesize a tray event or finish after a timer; the drive-state/format register reports BUSY with no TOC format while waiting.
An already open lid completes immediately, including when unit attention has not yet been cleared.
Observed opening completes the command with non-data status, IO/CoD set and INTRQ; nIEN still masks delivery until reenabled or acknowledged.
Media unit attention remains pending for subsequent access, and TOC requests cannot return the old disc while the lid is open.
Soft reset cancels the wait; later media changes follow ordinary notification handling rather than completing the canceled command.
Replacing the medium without observing an open final state aborts the wait with media-change attention; the exact handling of rapid physical open/close sequences remains unmeasured.
The waiting operation is represented by its existing packet and unscheduled busy phase, so native save/load retains it without a separate open-request field or replaying a host action.
Device and public core tests resume waits on a new mount generation and deliver saved opening events only on normal execution after restoration.
Functional native/browser tests also cover ready/empty/loading/error starting states, indefinite waits, audio stop, DMA invalidation, already-open completion, reset cancellation and HOLLY interrupt masking/acknowledgment.

### Sector transfer and seek

CD_READ converts binary FAD/MSF to the shared drive's LBA convention, streams one sector at a time and waits when the asynchronous adapter returns null.
The implementation transfers Mode 1 data, header or combined header/data, and raw 2352-byte data including CD-DA sectors.
It checks the requested Mode 1/CD-DA type and media bounds before transferring; invalid requests retain the current head position.
DSC is set when a requested sector arrives.
Mode 2 extraction supports explicitly identified XA/non-XA discs as described below; unknown identity and ambiguous aggregate padding remain explicit development stops.
Raw CD-DA reads remain separate from CD_PLAY playback through the AICA external input, as described below.
A self-authored SH-4 diagnostic issues a packet through MMIO and stores the returned sector word in main RAM.

CD_SEEK accepts binary FAD/MSF targets within the user area and enters pause mode without reading sector data.
It sends the translated LBA to `CdromDrive.seek`, updates REQ_STAT head position and sets DSC on completion.
While the adapter is seeking, the command remains busy and reports seek drive status; adapter completion is sampled on emulated ticks and side-effecting register reads.
Adapter seek failure reports hardware-error sense with ASC 15h, preserves the previous head position and leaves DSC clear.
Reset and media-generation changes cancel the pending operation; debugger peeks do not poll it.
Pause leaves the head position unchanged; invalid targets retain the previous position and report sense information.
Stop/home uses logical FAD 150 through the adapter as described in the later stop/home section; mechanical positioning remains unmodeled.
The SPI manual's English seek-range sentence is inconsistent; the implementation uses the same user-area bounds as CD_READ and rejects lead-out, pending hardware confirmation.

CD_READ2 uses its separate 16-bit sector count and FAD/MSF next-address fields with the same PIO/DMA sector path as CD_READ.
Both requested data and the next address are range-checked before reading, including MSF second/frame bounds.
After buffering the last requested sector, one speculative `CdromDrive.read` starts loading the next address without changing the visible head position or waiting for its result.
A speculative failure is discarded; a later explicit read reports its own result, as required by SPI.
Zero transfer count completes without a data read or speculative read; physical cache depth, read-ahead timing and prefetch efficiency remain unmodeled.

The fixed nominal 80-master-clock command/phase interval is a scheduling placeholder based on the specified 400 ns interface response bound, not a measured drive delay or seek/rotation model.
A pending sector is polled through the existing synchronous-snapshot adapter; polling is not a model of optical read latency.
FIFO contents are buffered independently of host phase boundaries, so pending reads cannot be replaced by a later disc generation.
Timing, hardware FIFO arbitration, reset duration, task-file writes to reserved fields and zero host-byte-count behavior for nonempty transfers still need validation.

The shared TOC optionally exposes explicit session boundaries; existing drive providers do not yet populate them.
XA disc identity is an optional explicit TOC field; current production providers do not supply it.
Density regions remain unavailable; optional explicit subchannel metadata is described below.
Track addresses/data-vs-audio identity and total sectors are used; audio copy/pre-emphasis flags require an explicit subchannel provider.
The frontend must not label a normal `CdromDrive` CD snapshot as a high-density disc or invent sessions.
REQ_SES supports explicitly supplied session metadata as described below; unknown metadata and high-density TOC remain explicit development stops.
DMA writes to the device, remaining Mode 2 aggregate behavior and high-density media formats remain pending and stop explicitly where recognized.
Review the disc/TOC contract before implementing high-density addressing and track-sheet image support; no app/GUI changes are part of this increment.

### G1 DMA and DDT

G1 longword registers implement drive DMA start/length/direction/enable/status, keyed RAM protection and transfer progress.
The default system straps describe a retail Japan/Asia-NTSC unit (`SB_G1SYSM=1`), rather than deriving a region from BIOS bytes.
Read-only/write-only register directions and reserved field masks are enforced; ROM/flash/PIO timing registers are stored, and their CPU wait-state effects remain pending.
`SB_G1GDRC` controls the functional DMA serial budget using the documented word-count formula on the nominal 20 ns clock.
The formula is applied per FIFO fill segment; the physical DACK/DIOR waveforms, continuous-burst overlap and root-bus wait states still require hardware validation.

SPI Features.DMA requests use a separate byte stream and issue only the final optical drive interrupt, with no per-buffer PIO interrupt.
A 32-byte G1 FIFO stages device bytes across sector boundaries before a root-bus write.
RAM writes request SH7750 channel-0 DDT; VRAM and AICA wave-RAM writes use the external root-bus path without requiring SH4 RAM DMA.
The SH7750 DTR subset is ID=00, SZ=100, MD=01, COUNT=1, with memory read/write direction, incrementing address and automatic DE/TE state.
DDT shares normal channel priority and error/NMI/module gates, and never enables DMTE0.
CPU writes to channel-0 registers are prohibited in SH7750 DDT mode; normal-mode channels retain their existing behavior.
Withdrawing a DTR keeps its register contents without reporting normal completion; exact cancellation pin/state timing remains pending.

G1 end-of-DMA is raised only after the destination write succeeds, independently of the SPI device completion interrupt.
Disabling G1 withdraws an uncommitted DDT request; a CPU/on-chip reset clears DDT while retaining external G1 state, which can reissue after software reenables DMAOR.
DME/NMI/address-error gates stall RAM DDT without discarding its staged bytes.
Media generation changes invalidate staged transfers without a false DMA completion; this external-abort mapping is a functional policy pending hardware validation.
G1 access protection reports illegal start, overrun and root-bus ROM/flash/drive access during drive DMA.
CPU cache hits and debugger peeks do not perform a G1 bus access, and DMA writes do not snoop CPU cache contents.

GDSTAR table ranges are used, including the documented 0C/0E RAM banks and VRAM apertures; 0D/0F RAM banks are rejected because the drive register tables mark them unsupported even though a broader interrupt footnote includes them.
Retail AICA wave RAM accepts these transfers; valid but unimplemented AICA register and other G2 destinations stop before a destination write.
Length zero requests 32 MiB; a shorter SPI command cannot falsely complete that host request.
Non-32-byte lengths use a padded final root-bus block, with deterministic zero in undefined padding and a rounded block counter.
Odd byte counts and partial-block source consumption are functional policies and need board-level validation.
The debug address retains the last committed block address, following the register's stated last-address behavior; its sub-cycle hardware observation points remain pending.

The scheduler samples asynchronous sector availability before selecting a time slice and splits at serial, SPI and root-bus deadlines.
Root writes occur after the corresponding serial data arrive and respect DDT arbitration; batched advancement is tested against individual master clocks.
A synthetic guest SH4 program starts drive DMA, polls its completion register and reads the transferred sector from RAM.
Remaining work includes other DTR formats, Maple source/FIFO pacing, G1 pin/wait-state arbitration, reverse drive DMA, and full session/density-aware disc commands.

### G2 DMA

The four G2 channels expose longword start addresses, length, direction, trigger, enable, start/status, suspend and debug counters at `005F7800h–005F78FFh`, with documented area-0 images.
G2 version reads 12h, timeout fields retain their documented defaults and masks, and prohibited modem settings stop explicitly.
Address/length/direction/trigger registers retain software-visible values while enabled; internal programmed values update while disabled and remain separate from runtime counters.
Undefined initial register values use deterministic zero for diagnostics.
Length zero means 32 MiB, and the remaining-length debug counter returns to the programmed value on completion.
G2 and root debug address counters advance independently when their respective port completes a block; remaining length tracks destination commits, and exact intra-cycle observation timing still needs hardware validation.
Length bit 31 chooses automatic enable clearing or retention for later restart triggers.
Writing enable zero aborts and withdraws queued DDT without fabricating normal completion; already committed G2 words remain visible.
The detailed register description prohibits start-register writes of zero and start while disabled, so these stop explicitly despite the overview's abbreviated STOP label.

System-memory blocks use the shared SH7750 channel-0 32-byte DDT request interface; VRAM blocks use the aperture-aware root-bus path without SH4 DMA enable.
Independent 32-byte staging buffers separate root transfers from G2 data cycles, and G2 channels arbitrate complete bursts in round-robin order.
The functional timing charges two 25 MHz data cycles per longword on the 16-bit G2 bus, with eight longwords per burst.
Address phases, device response waits, CPU/DMA alternation, root-controller priority registers and actual FIFO occupancy remain unmodeled.
Root reads are staged before G2 writes; G2 reads fill a block before a root write, and end interrupts occur only after the destination transfer completes.
DDT gates/NMI stall root requests without losing a staged block; CPU-only reset retains the external engine and allows a lost request to be reissued after DMAOR is configured again.
DMA bypasses SH4 caches; normal end uses HOLLY bits 15–18, illegal addresses use error bits 15–18 and protection/range overruns use error bits 19–22.

The keyed 4659h protection window applies to RAM accesses in 1 MiB units and is checked per block.
The wave-transfer chapter explicitly includes `0C000000h–0FFFFFFFh`, while the later root-address table lists only the first 16 MiB; this functional model accepts the documented RAM mirrors and records that discrepancy for hardware validation.
The listed 64-bit VRAM range includes its latter half; the 32-bit range is limited to `05000000h–057FFFFFh` as in the detailed register table.
Channel 0 accepts the documented AICA ranges and images; channels 1–3 accept the listed external-device ranges, but the core has no external-device implementations yet.
Implemented AICA registers use their real longword handlers, and retail wave RAM is connected in both directions.
An unimplemented endpoint stops at the current word with a positive retry deadline, instead of pretending that a device completed or timed out.
DS/TR timeout fields are stored; electrical response/timeout generation and CPU FIFO status remain pending.

CPU initiation, interrupt initiation, transfer-request pin gating and suspend requests are connected.
Normal source pulses can initiate another transfer even while the status bit remains latched; external levels initiate on rising assertions.
Selecting an already pending source or enabling a channel while its selected source is pending can initiate a transfer in this functional model; exact trigger synchronization still needs board validation.
SPG deadlines split host batches at the next selected programmable H/V interrupt, including compare-line, periodic-line and every-line modes.
Root eligibility and G2 timer identity are sampled before advancing other devices, so a newly generated trigger cannot consume bus cycles from before its assertion.
Suspend and request-pin deassertion stop new blocks while allowing a staged block to complete; the exact hardware suspend granularity and partial-cycle timing remain pending.
The current synchronous AICA endpoint keeps its functional empty-FIFO request asserted; independent tests can drive request pins explicitly, but real occupancy feedback is not implemented yet.

Tests cover bidirectional RAM/AICA transfers, VRAM apertures, protection overruns, forced stop, suspend/resume, pin gating, repeated interrupts, enabled-register latches, CPU reset, NMI and zero-length requests.
A self-authored SH4 program starts DMA, polls completion and reads the resulting wave-memory data.
Another regression chains optical drive sectors through G1 RAM writes into interrupt-initiated G2 wave-memory writes, exercising both controllers' use of DDT.
Audio/DMA and SPG-triggered batches are compared with individual master clocks; synthetic external endpoints exercise all four channel arbitration paths without claiming real device presence.

### AICA bring-up

The retail AICA wave-memory aperture exposes 2 MiB at G2 addresses `00800000h–009FFFFFh`, including area-0 images and P1/P2 aliases.
The unpopulated 8 MiB development-memory range is not silently mirrored.
SH4 accesses use longword cycles; FPU pairs, cache lines, store queues and 32-byte DMA blocks are composed of longwords.
Narrow and unaligned SH4 accesses stop explicitly, and external writes do not snoop the SH4 cache.
Self-authored guest instructions, normal SH4 DMA and drive DMA exercise the same physical buffer.
G2 CPU-write FIFO capacity/status, CPU/DMA arbitration and wait states remain pending; the DMA data path is described above.

Common-register support covers ARM reset hold, VREG video-mode bits, three timers, SCIEB/SCIPD/SCIRE/SCILV and MCIEB/MCIPD/MCIRE.
Only software-request bit 5 can be set through pending-register writes; clear registers acknowledge selected requests independently on the sound and system sides.
The system request drives HOLLY external bit 1 without replacing other external device sources.
The original documents describe both a one-MCCK pulse and an asynchronous level input; the functional connection holds the enabled pending level until acknowledgement, pending board-level validation.
Enabled sound requests use the programmable SCILV bits to select a three-bit number, latch it in the ARM-only L register and assert ARM FIQ.
Sources 7–10 share SCILV group 7, and code zero suppresses delivery.
The functional encoder selects the highest nonzero code when idle and retains that number until the ARM writes M bit 0, even if the original pending source is cleared or disabled.
Acknowledgement deasserts FIQ and defers pending-source resampling to the next ARM dispatch boundary; the ARM F mask independently controls exception acceptance.
This is a single held-number model with coalesced pending bits, not a hardware-validated priority queue.
The independent Yamato hardware reference describes FIQ handlers and M acknowledgement but explicitly identifies its queue-depth explanation as uncertain; queue capacity, preemption, arbitration and crossing latency remain unresolved.
Self-authored ARM handlers read L, acknowledge the source and M, return from FIQ and reload timers while SH4 requests remain independently pending.
Clearing ARMRST starts execution from wave-memory address zero; asserting it resets the ARM without clearing wave RAM, timers or RTC.
The later System Architecture specifies ARMRST=1 for reset, while the older standalone AICA specification prints the opposite polarity; the later document is followed pending hardware confirmation.
Unsupported channel behavior and DSP memory-instruction execution remain explicit development stops; functional MIDI byte registers are described below.

Timers advance at 44.1 kHz with per-timer divisors of 1–128 samples and latch requests on 8-bit counter wrap.
Sample-interval requests latch each sample independently of timer wraps and ARM reset hold.
Clock fractions are retained across batches, and the scheduler splits at enabled, unlatched request deadlines without polling every sample while idle.
Timer writes currently clear their prescaler phase; exact write synchronization, power-on timer values and clock-domain crossings need hardware confirmation.
Timer controls and counts are write-only in the original register descriptions, so undocumented CPU readback stops explicitly; tests inspect counters directly.

The separately powered RTC has a wrapping 32-bit seconds counter, split 16-bit fields and a write-only enable latch.
Writing the low half clears the subsecond fraction; writing the high half restores write protection without clearing that fraction.
RTC register accesses are longword-only and use the lower 16 bits.
Full core reset clears wave RAM and functional audio-register state while retaining RTC seconds/fraction; CPU-only reset retains the external AICA state.
A new instance starts at synthetic counter zero, with no wall-clock seeding, battery-backed persistence or detached-time advancement yet.
RTC and audio clocks use rational advancement against the fixed nominal master clock and do not depend on SH4 peripheral module gates.
Hardware-matched envelopes, filters/LFO/noise, ADPCM long-stream timing, DSP processing, MIDI hardware matching, internal-DMA arbitration, G2 FIFO/pin timing and real BIOS sound-driver validation remain required for stage 8.

### AICA memory controls and ARM register lanes

ARM register byte accesses select either of the two implemented low word lanes; upper lanes read zero and ignore writes.
Command writes affect only the selected lane, so a low-byte M acknowledgement preserves the neighboring RP bit and high-byte writes do not acknowledge M.
Reading the low byte of the channel monitor does not clear its high-byte loop flag.
This byte-access behavior follows Lars Olsson's independent hardware notes; the original SH4 longword restriction remains in force.
The ARM cannot access SH4 reset/VREG controls, and SH4 cannot access ARM-only L/M.

MRWINH stores the four requester inhibition bits; only SH4 can change the ARM-memory inhibition bit.
ARM-memory inhibition pauses functional instruction dispatch without accumulating instructions to execute after release; timers and RTC continue advancing.
System inhibition blocks actual SH4/G2 wave-memory reads and writes, and ARM-only RP additionally blocks system reads while permitting writes.
Cache hits and side-effect-free debugger inspection do not issue these external bus cycles; fills, writebacks and DMA use the protected physical path.
Inhibited system cycles and active sound-source reads currently stop explicitly instead of modeling physical bus waits or lockup.
The DSP-inhibit bit is retained for DSP wave-memory requests, whose execution remains unimplemented; it does not block CPU access to DSP registers or the register-only mixer path.
Internal DMA uses its own requester path independently of SH4 read protection.
The later System Architecture's write-only RP description takes precedence over the older AICA specification's conflicting read-only label.
Full core reset clears these controls; SH4-only and ARM-only resets retain them.
Tests cover byte lanes, all eight SCILV codes, actual FIQ debugger traces, timer-handler batch equivalence, cache behavior and normal/G2 DMA protection with recovery.

### AICA internal DMA

The internal engine transfers in increasing address order between retail wave RAM and implemented AICA registers, in either direction.
DGATE clears the destination without reading the source; it can therefore clear wave memory even when the selected register source is write-only.
The later System Architecture's DMEA[22:2], DRGA[14:2] and DLG[14:2] layout takes precedence over the older standalone specification's bit-1 layout.
The functional interpretation uses longword-aligned byte addresses and a byte span in DLG, advancing both addresses by four per register access; the count-unit wording in both documents still needs hardware confirmation.
Each register access uses its implemented lower 16-bit payload in a longword location.
Readable DGATE, DDIR and DEXE bits are exposed without inventing readback for write-only address/count fields.
ARM byte writes preserve the other descriptor lanes.

DEXE starts an asynchronous transfer and clears only after the final destination commit.
Completion independently latches sound/system pending bit 4 and uses the existing FIQ and HOLLY routes.
ARM reset does not stop internal DMA; full AICA reset discards it without reporting completion.
Changing the descriptor while active stops explicitly, while DEXE=0 with the same descriptor cannot abort it.
Other MRWINH bits may be changed without replacing the active DMEA high bits.
Transfers exceeding retail wave RAM or the documented register aperture, touching the descriptor itself, or using an unresolved zero length stop explicitly.
Unimplemented register behavior retains the failing word and a positive retry deadline without a false completion.

The functional engine issues one longword per nominal AICA clock and splits bus batches at each issue deadline.
This rate is an explicit scheduling approximation, not a documented bandwidth or physical DMA latency.
Actual memory/register arbitration, access-inhibit interactions, address/count feedback and DMA clock phases remain unverified.
The engine bypasses SH4 caches and does not share G2's external staging FIFO.
Tests check both directions, source-free zero clear, partial progress, protection boundaries, completion routing, ARM byte configuration, guest ARM start/poll instructions and batched-versus-individual advancement.

### AICA direct audio

The functional 64-slot source/mixer accepts channel registers, global key execution, PCM8/PCM16 and AICA ADPCM sources, signed octave/FNS pitch, total/send/master level and stereo pan.
Signed PCM samples and little-endian word order are tested through `Core.onAudio` using 44.1 kHz stereo `AudioBuffer` packets of 256 frames.
Packets own their buffers; full core reset discards partial output while retaining the callback.
Sources continue advancing without a callback, and registered callbacks receive silence when no slots are active.
Key execution validates all slots that would start before changing playback state; unsupported sources cannot partially start other slots.
Already running slots and naturally exhausted one-shots do not restart on unrelated global key execution; explicit key-off arms the slot again, and a new key-on can restart a releasing slot.

Pitch uses an exact 18-bit fraction for all documented OCT/FNS combinations, with functional linear interpolation between decoded source samples.
PCM16 alignment and complete source ranges are checked against the installed 2 MiB wave RAM.
ADPCM reads the low nibble first, starts with predictor zero and quantization width 127, and applies the published factors with integer truncation and saturation.
Decoded samples are cached per voice to replay normal ADPCM loops; changing active ADPCM source parameters stops explicitly.
Long-stream format uses a separate sequential decoder with continuing history, as described below.
Predictor saturation, exact decode/interpolation rounding and extreme-pitch behavior still need independent hardware validation.

The loop model emits the LEA sample, then returns to LSA+1 while retaining the pitch fraction, following the sequence and equal-endpoint waveform diagram in the original manual.
The manual's printed LSA example disagrees with its diagram and sequence; exact loop-boundary addresses and timing remain a documented uncertainty requiring hardware tests.
Short-loop overshoot uses modular wrapping as a functional policy; the manual warns that such settings can misbehave on hardware.
CA, SGC, AEG and loop-end monitoring are exposed for the selected slot; reading LP clears only that slot's latch, while debugger reads preserve it.
FEG monitoring exposes a separate 13-bit functional cutoff envelope and state, as described below; active filtering remains an explicit development stop.

The envelope model applies the published key-scaling formula and attack/decay/release end-to-end times using a linear-dB approximation between attenuation codes.
It supports decay-level transitions and loop-start linking, but does not claim hardware envelope curves or internal code timing.
The standalone AICA specification gives decay rate 31 as 790 ms, resolving the apparent 90 ms typo in System Architecture.
Direct gain and pan use the documented dB values; mono disables slot pan, and the mixed output clips at the selected 16/18-bit DAC range.
The floating-point mixer does not yet reproduce internal fixed-point quantization or DAC pin timing.
Only the documented Q=4, FLV=1FF8h filter-bypass configuration is supported; active filter processing and source-noise generation stop explicitly instead of being ignored.
Functional amplitude/pitch LFO is described below.
DSP input sends and register-defined effect mixing are described below.
Channel setup values and monitor selection are retained; the currently unverified chip revision reads as synthetic version zero.

The scheduler clips at sample edges for active sources and interleaves SH4 memory DMA with wave-memory reads.
Independent tests compare batched audio against individual master clocks while DMA changes the waveform.
A standalone self-authored SH4 diagnostic initializes its waveform and all required channel settings through guest instructions, starts playback through channel MMIO and produces independently checked PCM samples through the core audio callback without host register setup.
These tests establish the functional data path; commercial sound drivers, audio captures and physical timing validation remain pending.

### ARM7DI execution

The AICA interpreter is derived from ARM7DI Data Sheet DDI 0027D rather than the GBA module's ARM7TDMI implementation.
It implements the ARM7DI 32-bit modes without Thumb, ARMv4 halfword/signed transfers, long multiplies or System mode.
The separate implementation avoids importing another core module and preserves the ARM7DI multiply restrictions, PSR encodings and block-transfer behavior.
The baseline instruction path includes all condition codes and data-processing operations, immediate/register shifts, MRS/MSR, MUL/MLA, B/BL, byte/word transfers, SWP/SWPB and block transfers.
User/FIQ/IRQ/Supervisor/Abort/Undefined register banks and saved status are maintained across mode changes.
SWI, unaccepted coprocessor operations and the defined undefined-transfer encoding enter their documented vectors; IRQ/FIQ inputs support banked exception entry and SPSR returns.
Legacy TEQP follows the original manual's defined behavior in 32-bit modes, although that manual discourages its use.
Prohibited register combinations, reserved instruction encodings and unsupported memory accesses stop explicitly at the current instruction rather than inventing a successful result.
Data/prefetch abort inputs, 26-bit compatibility modes, debug pins and exact pipeline/bus behavior remain pending.

PC operands use the documented prefetch offsets, word loads rotate unaligned data and word stores retain their unrotated data on aligned bus cycles.
STM stores the old base when it is first in the list and the updated base when it appears later; LDM loads override base writeback.
User-bank block transfers and LDM exception returns preserve the bank-switch ordering.
Multiplication computes the low 32 bits exactly on JavaScript as well as native Dart.
The undefined multiply carry result is retained deterministically, while N/Z and the unchanged V follow the specification.
Architecturally undefined general register contents after reset are initialized to zero for reproducible diagnostics.

The ARM sees retail wave RAM at `00000000h–001FFFFFh` and implemented AICA registers at their internal `00800000h` base.
ARM accesses to SH4-only reset/VREG and RTC controls are rejected.
The scheduler uses the 22.5792 MHz internal CPU clock stated in the Hardware Specification Outline and retains rational clock fractions against the master clock.
Instruction costs sum the original S/N/I cycle counts with one clock per cycle; memory wait states, pipeline prefetch, clock pin phases and contention still need hardware validation.
Instruction effects occur at dispatch boundaries, and the cycle counter records issued instruction costs; individual pipeline and memory-cycle effects are not serialized yet.
The bus splits at ARM instruction deadlines, so batched and individual master-clock advancement agree for shared-memory diagnostics.
CPU-only SH4 reset retains the running ARM; full core reset holds it in reset.
Self-authored programs verify SH4 reset release, ARM stores visible to SH4 and ARM software requests visible through HOLLY.
The core advertises ARM7DI as CPU 1 through the existing debugger contract, with its own PC, stack, memory address space and register/banked-state trace snapshots.
ARM instruction inspection currently formats 32-bit words; ARM mnemonic decoding remains pending.
SH4 inspection now supplies contextual mnemonics for its 16-bit instructions.
Side-effect-free ARM inspection neither advances device clocks nor acknowledges requests.
Execution flags distinguish retired instructions, synchronous traps, interrupt entry and reset; the debugger waits for the selected CPU and refreshes a pending trace on exception entry.
Debug execution splits divided-clock and PLL-pause intervals at ARM observation deadlines, carrying the remaining SH4 interval without issuing another SH4 instruction early.
Normal and debug slices are checked against the same CPU timeline, including PLL stabilization with the ARM still running.
Hardware interrupt queue/priority validation and full sound-driver execution remain pending.

## Hardware references

- [SH-4 Programming Manual, Rev. 5.0, ADE-602-156D](https://0x04.net/~mwk/doc/sh/e602156_sh4.pdf): instruction encodings and semantics, including sections 9.56–9.59 for data transfer and the prohibition on PC-relative loads in delay slots.
- [ARM7DI Data Sheet, DDI 0027D](https://documentation-service.arm.com/static/5ed11a2dca06a95ce53f8f99): 32-bit programmer's model, instruction encodings, shifts, banked registers, PSR transfer, multiply restrictions, transfer ordering, exceptions and S/N/I cycle counts.
- Yamato, AICA Sound System Hardware Reference v0.8: independent FIQ-handler and interrupt-end observations only; guessed queue behavior and other uncertain fields are not treated as established hardware behavior.
- Lars Olsson, AICA Sound Chip, 2001: independent observation of ARM byte register accesses; its uncertain clock estimate is not used.
- AICA Specification: source formats, loop diagrams, ADPCM quantization factors, envelope timing and mixer gains; the later System Architecture takes precedence for reset polarity.
- [SH7750 Series Hardware Manual, Rev. 6.0, ADE-602-124E](https://docs.rs-online.com/ba59/0900766b80c2b5e1.pdf): section 2 register reset state, section 3 memory regions and section 5 reset/exception handling, section 4 caches/store queues, sections 9–10 power-down, CPG and watchdog, section 12 TMU, section 14 DMAC, section 15 SCI, section 16 SCIF and section 19 INTC.
- SH-4 CPU Core Architecture, ADCS 7182230F: LDC.L SR update order (page 347), MAC read/commit ordering and saturation (pages 365–368).
- Dev.Box System Architecture, 1999-09-03: sections 2.1/2.6/2.7, 3.5, 4.1.2–4.1.3, 4.2.2–4.2.3, 8.4.1.1–8.4.2 and 8.4.5 for memory-bank layout, framebuffer formats, access restrictions, flash protection, HOLLY interrupts and AICA memory/RTC/timers.
- Optical drive protocol SPI Specifications, Rev. 1.31: task-file reset, PIO phases, packet formats, mode/status/sense data, TOC and sector reads.
- Memory card peripheral hardware specifications, Rev. 1.00: storage capacity, transfer phases, LCD and clock formats.
- FT2 B/W LCD Function Specifications, Rev. 0.81: panel/plane data, media information, contrast and LCD errors.
- FT3 Timer Function Specifications, Rev. 0.80: calendar, setting buttons, alarm registers and command errors.
- FT1 Storage Function Specifications, Rev. 0.80: ordered write groups, errors and `Get_Last_Error`.
- Maple Bus 1.0 Standard Specification, Rev. 0.82: device discovery, electrical/software resets and Device Kill semantics.
- Controller Peripheral Hardware Specifications, Rev. 1.00: digital/analog input, fixed device information and identification strings.
- Marcus Comstedt's independent memory card flash observations: raw capacity, system-block location, format marker and filesystem byte order.
- [Marcus Comstedt's independent Maple packet observations](https://mc.pp.se/dc/maplebus.html): packet headers, endpoint addresses, response codes and mixed-endian device information.
- Hardware Specification Outline, table 2-1: nominal 200 MHz CPU, 100 MHz external bus and 50 MHz peripheral clocks; section 4.2 describes the 22.5792 MHz ARM/sound clock, and section 6 describes the 54 MHz multiplexed video transport and 27 MHz VGA pixel clock.
- [MBM29F002TC/BC datasheet, DS05-20868-3E](https://pe2bz.philpem.me.uk/pdf%20on%20typenumber/M-N/MBM29F002BC.pdf): sector organization, command sequences, status flags and nominal operation durations.
- VA0 board ROM/flash/I/O schematic: IC502 part, 5 V supply, A17 and RESET straps.
- [Marcus Comstedt's independent system-flash observations](https://mc.pp.se/dc/flashmem.html): visible capacity and partition boundaries.
- [Marcus Comstedt's independent DC memory-map documentation](https://mc.pp.se/dc/memory.html): physical boot ROM and main RAM regions and capacities.

Unimplemented device behavior must remain explicit until supported by hardware documentation or an independent test.
The VA0 schematic resolves the visible-capacity difference through its A17 strap; later board part variants and protection configuration still need hardware evidence.

The next concrete tasks are AICA interrupt hardware validation and the remaining sound pipeline, remaining GPU texture formats, volume processing, sort/cache and raster validation, Maple/DDT timing validation, memory card factory and physical LCD/buzzer behavior, optical drive session metadata providers and density interfaces, pixel/FIFO scanout and remaining video timing validation, remaining system-bus registers/DMA, G1/G2 arbitration and flash timing validation, remaining serial modes, remaining external/peripheral/DDT DMA requests, graphics-FPU hardware validation, and hardware validation of conflicting MAC saturation cases before full BIOS and game progression tests.

## YUV texture input and conversion

`DcGpuYuv` accepts 32-byte bursts through the YUV aperture and its area-4 image from store queues, normal SH4 DMA and cache writebacks.
The converter implements the YUV420 and YUV422 macroblock input orders in System Architecture §3.8.1 and writes non-twiddled YUV422 into the 64-bit VRAM address space.
The top eight rows commit after 256 input bytes; the bottom eight rows commit after 384 bytes for YUV420 or 512 bytes for YUV422.
Combined images arrange macroblocks horizontally and then vertically, while separate textures place each 512-byte macroblock consecutively.
The configured final block raises HOLLY normal interrupt 6 and restarts the next frame at the programmed base.
Writing the base discards partial input and resets the block counter.
The completed count remains visible until the next frame's first burst; this counter reset phase is a functional policy because the manual specifies address restart without specifying the counter phase.
Each half validates its complete destination before writing, and an invalid destination stops without a completion interrupt.
Physical FIFO latency, bus contention, reset retention and register changes during active conversion still need hardware validation.

The texture sampler decodes horizontal YUV422 pairs in linear and twiddled layouts, including linear stride and the RGB565 smallest MIP level exception.
RGB conversion uses the rational matrix in §3.6.1.2 with saturated channels and alpha 255.
Conversion precedes the functional RGBA bilinear filter; conversion rounding and filtering order still require hardware measurements.
VQ-compressed YUV remains an explicit development stop.
Normal DMA targeting the YUV aperture advances at individual DMA boundaries so completion-triggered devices cannot receive elapsed clocks from before their request.

## Fog and color clamp

`DcGpuFog` owns the two independent RGB fog colors, signed-exponent density scale, ARGB clamp bounds and 128 packed table entries described in System Architecture §§3.4.8, 3.7.9.2 and 8.4.2.
The CORE applies optional per-channel clamp after texture/shading and before fog; alpha is clamped along with RGB.
Depth fog scales the interpolated reciprocal depth, clamps it to the documented 1.0–255.9999 interval and uses three exponent bits plus four mantissa bits to select a table entry.
Each entry supplies its own upper-byte and lower-byte interpolation endpoints; the following table word is not fetched for the second endpoint.
The density representation reproduces the manual's 0xFF07 = 255.0 example and supports signed negative exponents.
Vertex fog uses flat or perspective-correct Gouraud offset alpha and its separate fog color; an object without offset data receives no vertex fog.
Normal fog changes RGB while preserving the shaded alpha, and Mode 2 replaces RGB and alpha with the table fog color and coefficient before blending.
The Mode 2 implementation follows the explicit assignments in §3.4.8.1; the abbreviated wording in §3.7.9.2 is ambiguous about the substitution direction.
Flat untextured backgrounds use the same clamp/fog stage with the programmed background depth.
Table interpolation and RGB mixing use host double arithmetic with nearest integer color rounding; physical internal precision, coefficient quantization and rounding remain unverified.
Table power-on contents are unspecified and initialized to zero for deterministic execution; physical table retention through pipeline resets is unverified.
Reversed clamp bounds stop explicitly because their hardware behavior is not documented.

## Secondary accumulation buffer

The CORE implements the ARGB32 secondary accumulation buffer in System Architecture §§3.4.6.1 and 3.7.9.2.
TSP DST Select chooses the secondary buffer for both destination blend operands and writeback, while SRC Select uses its stored RGBA as the source.
Both selectors may be enabled together for operations within the secondary buffer.
The same eight blend factors and depth tests apply to normal primary and secondary draws, including Z-write disable.
A Flush polygon supplies geometry and blend instructions while bypassing its base/offset color, UV, texture lookup, shading, clamp and fog stages; its own Use Alpha bit cannot replace the stored source alpha.
Only the primary buffer is packed into the framebuffer.
Opaque, pre-sorted translucent and auto-sorted translucent lists share this path.
Auto-sorted source selection occurs when each selected layer is composited, after farther layers have updated the secondary buffer; candidate collection does not snapshot a premature source color.
Retained consecutive regions preserve secondary colors and their initialization validity.

The manual requires writing secondary pixels before extracting them and does not define their initial contents.
The functional implementation tracks initialization per pixel and stops on an uninitialized source or a destination-dependent blend that reads an uninitialized secondary destination.
An independent overwrite does not require a previous destination value.
A fresh background/tile invalidates secondary pixels rather than exposing stale host storage; exact hardware retention when clearing or switching tiles remains unverified.
Punch-through secondary routing and secondary-buffer background loading remain explicit development stops pending authoritative behavior or independent hardware tests.
Functional trilinear and bump/textured multi-pass scenes use this buffer as described below.

## Functional trilinear passes

System Architecture §3.4.7.2.3 describes two separately submitted polygons for opaque trilinear rendering and three polygons for translucent rendering.
Pass A bilinearly samples the higher-resolution MIP level; Pass B bilinearly samples the next lower-resolution level, with its own coordinate dimensions and addressing.
The trilinear multiplier scales all shaded RGBA channels after color clamp/fog and before alpha blending, following the pipeline diagram in §3.4.6.
An opaque scene writes Pass A to the primary buffer and adds Pass B from the translucent list.
A translucent scene overwrites and then adds in the secondary buffer before a Flush polygon composites its stored RGBA into the primary buffer.
Pre-sorted and auto-sorted translucent scenes use the same path.
Non-MIP pass codes retain the documented point-sampling fallback, including linear textures that ignore the MIP flag.
HOLLY2 punch-through polygons with effective trilinear filtering stop explicitly because the manual prohibits this combination.

The existing functional level model uses binary footprint intervals, while the manual describes the weight as the fractional part of D without resolving how its level-range prose relates to the derivative magnitude.
Within an interval, this implementation infers a linear normalized-mantissa fraction from the adjusted footprint, assigns complementary A/B weights and clamps magnification and the smallest level to a full A contribution.
This maintains continuity of the combined color at every modeled level transition and keeps D-adjust consistent between level selection and weights.
It is an explicit functional inference, not evidence that the hardware uses this D encoding or these precise weights.
Internal derivative/LOD encoding, weight quantization, multiplier rounding, saturation boundaries and physical pass timing remain unverified and require independent hardware observations.
Tests use analytically chosen footprints and self-authored TA scenes to check both MIP sampling and pass accumulation for RGB, palette, VQ and YUV data; they do not constitute hardware measurements.

## Functional intensity modifier volumes

TA accepts the 32-byte modifier global and 64-byte independent-triangle vertex formats in System Architecture §§3.7.5.2–3.
The two vertex bursts stage together before allocation; only the nine XYZ coordinates are decoded, and the trailing padding and irrelevant color/texture fields are ignored.
The PCW last-volume flag must agree with the ISP Volume Instruction, and the reserved modifier Shadow flag is rejected.
Both modifier lists retain the existing tile clipping, OPB allocation, parameter bounds, End Of List and HOLLY transfer-interrupt contracts.
Normal polygon Shadow bits propagate to object-pointer bit 24 independently of vertex skip.

`DcGpuModifier` evaluates per-pixel parity against visible reciprocal depth and combines completed inclusion volumes by union.
Outside Last removes the parity interior from the accumulated area, matching the exclusion semantics in §3.4.5 and the instruction name in §3.7.9.1.
The abbreviated Boolean table in §3.4.5.1 calls its operand an inside flag while also describing an outside mask; this implementation explicitly interprets the exclusion operand as the complement of inside parity.
Triangle and quad arrays support counted records and OPB links, with cycle detection; quad D obtains its depth from the ABC plane and shared edges toggle once.
The functional parameter representation follows the generic three-word ISP/TSP header in §3.7.9 with XYZ-only vertices and skip zero; physical modifier packing still requires independent hardware confirmation.
In-front tests use GEq as a functional coplanar policy; exact equality, raster precision and internal flag transitions remain unverified.
A volume without a last polygon stops rather than emitting an incomplete area.
Per-tile last-polygon propagation when the final face is clipped from a tile remains pending; such a tile can currently stop as an unfinished volume.

FPU_SHAD_SCALE exposes the documented intensity enable bit and unsigned factor divided by 256.
Area-one pixels on Shadow-enabled objects scale interpolated base and offset channels before texture/shading, clamp, fog and blending.
The model applies the literal color multiplier to ARGB, then applies Use Alpha normally; the physical alpha/offset-alpha gating and multiplier rounding still require hardware observations.
Opaque/punch-through depths are resolved before area evaluation, after which the tile is replayed from saved color, depth and secondary-buffer state to avoid duplicate blending.
A failed depth/area prepass restores those buffers as well, allowing repaired VRAM data to be retried on a retained tile without applying the failed prepass twice.
Auto-sorted translucent modifiers evaluate against each selected layer's fragment depths before that layer is shaded and composited.
Opaque and translucent area masks are independent; pre-sorted translucent modifiers stop because §3.4.5.3 permits only auto-sort.
Replay is a functional implementation strategy and does not model the hardware ISP/TSP phases or render duration.
Modifier-enabled backgrounds and punch-through intensity shadows with Use Alpha remain explicit development stops; two-volume parameter selection is described below.
Tests use analytical planes, closed slabs, inclusion/exclusion combinations and self-authored TA scenes, including secondary writes and per-layer translucent blending; they are not physical hardware measurements.

## Two-volume parameter selection

TA implements the Packed Color and Intensity A/B two-volume formats in System Architecture §§3.7.5–6 and the expanded input tables on pages 397–399.
Both PCW Shadow and Volume must be set; the reserved floating-color combination and two-volume Sprite format report a parameter error.
Intensity A globals and textured vertices stage 64 bytes even when offsets are not enabled; packed globals, Intensity B globals and non-textured vertices use 32 bytes.
The two Intensity A face-color sets are independent and Intensity B retains both; each set supplies both its base and offset intensity conversion as specified for Polygon Type 4.
Mixed single/two-volume face-register aliasing still needs hardware confirmation.
Non-textured inputs force the stored ISP Offset flag to zero.

The functional VRAM representation stores ISP, TSP0, TCW0, TSP1, TCW1 followed by each vertex's shared XYZ, attributes 0 and attributes 1.
The object-pointer skip remains the number of attribute words for one material, so CORE uses the documented skip-times-two-plus-three rule in parameter-selection mode.
Five header words preserve all independently supplied global controls; the schematic on page 202 omits the second TSP/TCW pair, so this precise physical header interpretation remains unverified and requires independent hardware confirmation.
Parameter bounds and counted-array advancement include the expanded header and both attribute sets.
CORE chooses complete material 0 outside and material 1 inside the modifier area, including UV, colors, TSP controls and texture control word.
Each material computes interpolation and MIP derivatives from its own attributes while sharing geometry, depth, culling and primitive identity.
Both material walks retain one primitive order for translucent sorting, and the area filter is restored even when material decoding stops.
Slot-selected secondary sources bypass that material's shader data and use the stored secondary RGBA normally.

The path supports opaque/punch-through area replay and per-layer auto-sorted translucency, including strips and CPU-authored counted triangle/quad arrays.
Quad D's undefined shading data remains ignored for both materials; ABC defines their respective planes.
Punch-through tests use matching alpha behavior in both parameter sets as required by §3.4.5.3; differing coverage/alpha is not claimed to reproduce the hardware's inconsistent result.
The physical header arrangement, internal area transitions, raster precision and render timing remain unmeasured.
The functional tests check independent material pixels, packed/16-bit UV, both intensity sets, offsets, fog, blending, MIP selection, secondary sources, expanded bounds and fault/retry state without relying on another emulator.

## Functional bump mapping

Twiddled Bump Map format 4 stores unsigned S in bits 15–8 and R in bits 7–0, following System Architecture §§3.4.7.3 and 3.6.1.3.
The sampler evaluates the documented K1 + K2*sin(S) + K3*cos(S)*cos(R-Q) expression, returns white RGB and clamps the computed brightness to the texture alpha range.
K coefficients use byte values 0–255 for 0–1, S spans the hemisphere's elevation, and R/Q span azimuth; the documented angle endpoint 255 is treated as 256.
K1/K2/K3/Q come from the packed Offset Color field of the provoking third vertex, including later triangles in a strip and ABC's plane for a quad.
Those bytes replace Offset Color and are not added to RGB as ordinary offsets.
The resulting texel flows through the existing four shading modes, Ignore Texture Alpha, fog/clamp, optional trilinear multiplier and alpha blending.

Packed and floating-color TA input preserve the light parameters; intensity conversion is rejected as prohibited by §3.7.4.3, including a bump texture in the second volume's control word.
CORE requires Offset enabled and Flat Shading as stated in §3.7.9.1.
The Gouraud illustration in §3.4.7.3 conflicts with that Flat Shading requirement; Gouraud bump behavior remains an explicit development stop pending independent hardware clarification.
Non-twiddled bump maps stop because erratum 26 documents a hardware hang, and VQ bump maps remain rejected because VQ is specified for RGB formats only.

The functional sampler evaluates brightness per texel before applying its existing bilinear RGBA filter.
This ordering avoids interpolating azimuth byte endpoints across the opposite hemisphere, but the hardware's exact filtering order has not been established here.
MIP bump data uses the generic padded 16-bit level offsets and the existing functional level/pass model; physical bump-specific MIP behavior remains unverified.
Host double trigonometry and nearest integer alpha rounding implement the formula, without claiming agreement with the hardware's lookup precision or rounding.
Vertex-fog interpretation of the replaced offset alpha and intensity-shadow scaling of K/Q still require physical measurements; the latter is already documented as unsuitable for bump mapping in §3.4.5.2.

Self-authored TA scenes exercise standalone Decal Alpha bump shading, Method A/B bump-plus-texture combinations, three-pass secondary-buffer translucency, two-volume light-vector selection, strips, sprites, punch-through alpha and functional trilinear combination.
Analytical axis, oblique, saturation and endpoint cases check the equation independently of the rendering path; these tests do not replace hardware measurements.

## DSP data and mixer boundary

`DcAicaDsp` implements the CPU-visible COEF, MADRS, MPRO, TEMP, MEMS, MIXS, EFREG and EXTS storage described in System Architecture §8.4.5 and AICA Specification pages 8–9 and 19.
The map retains 128 coefficient entries with three reserved low bits, 64 addresses, four 16-bit words for each of 128 microsteps, 128 24-bit TEMP entries, 32 24-bit MEMS entries, 16 20-bit MIXS entries, 16 signed effect outputs and two external input latches.
TEMP/MEMS low-byte and high-halfword positions and MIXS low-nibble/high-halfword positions follow the original register table.
A MEMS low-byte write remains staged until MEMS bits 23–16 are written; ARM byte writes to the middle byte alone do not commit it.
CPU writes to MIXS require the unimplemented IC-test mode and stop explicitly; EXTS remains read-only and may be supplied by the device's external-input endpoint.
Ring control stores the documented RBL/RBP fields and rejects IC-test mode; ring-control readback is a functional convenience rather than established behavior for the documented write-only port.
Power-on contents of DSP storage and exact CPU/DSP arbitration remain unverified; full reset initializes the model's buffers and staged bytes deterministically to zero.

The 16 MIXS inputs sum source data after the existing envelope/total-level processing and before direct-send attenuation and pan.
The later System Architecture table takes precedence over the earlier standalone AICA map: IMXL is bits 7–4 and ISEL is bits 3–0 at slot offset 0x20.
The current mixer converts each completed generation to signed 20-bit data using nearest-integer quantization and wrapping without saturation.
The manual requires input sums below 0 dB and states there is no overflow protection; the exact physical overflow and quantization are not established by the functional wrap policy.
CPU reads expose the most recently completed input generation, and an additional sample clears it after the final source stops even when no audio callback is installed.
Sub-sample generation selection and the higher precision associated with SDIR are not implemented.

Eighteen EFSDL/EFPAN controls mix EFREG 0–15 and external inputs 0–1 into stereo output using the published send/pan levels, master volume, mono and DAC clipping.
Effects do not make a sound-source wave-memory access, so MRWINH sound-source read inhibition does not block register-only effect output.
Nonzero audible effect data schedules sample edges even without active source voices; muted/zero effect data does not add idle polling.
The mixer uses the existing floating-point arithmetic and does not claim physical DSP arithmetic or DAC quantization.
CPU-defined EFREG output latches are retained until rewritten or reset in the zero-program model; physical output latch timing still needs measurements.

The primary AICA manual describes the 55 control bits and DSP datapath; a functional arithmetic MPRO decoder now uses field order recovered from original FX Program Editor 1.10 data and register packing inferred from original compiled FPB data.
No microinstruction encoding or execution logic is taken from another emulator.
The original tool's STRS resource contains the control-bit names, referenced by a 64-entry table at DATA offset 0x10ea; original compiled register images establish candidate padding positions while the manual supplies field widths and arithmetic semantics.
This is an independently derived functional layout, not a hardware-verified assignment.
Across 45 original Collection 1 FPB programs, all 5,760 candidate instructions have zero reserved-bit violations and valid input selectors; all 1,022 memory-request steps are odd as required by the AICA manual.
Those structural checks do not validate execution of the compiled effects.

Each supported sample executes 128 arithmetic steps after the current MIXS input is latched and before EFREG mixing.
COEF addresses follow the step number; TEMP read/write addresses rotate with the sample decrement counter, and the existing arithmetic stage supplies accumulator, shifter and latch behavior.
EWT writes EFREG values that feed the ordinary AudioBuffer path; unwritten output latches retain their existing contents.
MPRO writes and state restoration invalidate the derived preflight cache.
Reserved fields, unsupported memory request combinations and NOFL=0 memory instructions stop before source advancement or external-input consumption.
IWT/MRD/MWT now have a functional NOFL=1 pipeline; floating sound-memory conversion, physical latency/arbitration and microprogram start/update behavior remain unfinished.
The normal experimental boot profile executes supported DSP programs and bypasses a whole program only when static validation finds an unsupported instruction; the supplied program still requires unsupported floating memory conversion.
Multiply/accumulate precision, pipeline hazards, physical ring/TEMP behavior and memory arbitration still need hardware validation.
The retained DSP/storage cases and four public-core state cases pass without adding a scenario; the partial-audio state case now runs noise through an arithmetic MPRO program rather than bypassing DSP execution.
An original two-step multiply/output program runs with bypass disabled and produces 256 stereo frames at exactly 0.25, using EFREG0=8192 and a rotating TEMP write.

| Register word | Functional fields |
|---|---|
| 0 | TRA 15:9, TWT 8, TWA 7:1; bit 0 reserved |
| 1 | XSEL 15, YSEL 14:13, IRA 12:7, IWT 6, IWA 5:1; bit 0 reserved |
| 2 | TABLE 15, MWT 14, MRD 13, EWT 12, EWA 11:8, ADRL 7, FRCL 6, SHFT 5:4, YRL 3, NEGB 2, ZERO 1, BSEL 0 |
| 3 | NOFL 15, MASA 13:8, ADREB 7, NXADR 6; bit 14 and bits 5:0 reserved |

The original data sources are the original sound tool distribution and DSP Collection 1.
Their SHA-256 values are `bcd84060f76f2fea868e3b6c481a0fc8b0f2ef39dc1b1c2650e121118fa3bed4` and `4991c69a6e6abf1f10c0f9dcf5499b63a2eaa4dbb55a0035810473d2d3aace79`, respectively.
These archives and their executable/resource payloads are not copied into the repository.

## Functional slot LFO

`DcAicaLfo` implements the per-slot amplitude and pitch modulation controls in System Architecture §8.1.1.5 and Table 8-8/8-9.
Slot offset 0x1C retains LFORE, LFOF, PLFOWS/PLFOS and ALFOWS/ALFOS in their documented bit positions.
The model uses the published 32 rounded frequency values as integer centihertz and advances an eight-bit waveform phase with rational sample-domain timing.
Elapsed time is reduced modulo the phase denominator before multiplication so long inactive spans remain exact on browser runtimes.
The actual hardware divider frequencies, waveform phase origin and edge quantization are still unmeasured.

Saw, square and triangle shapes provide unsigned amplitude codes and signed pitch codes matching the plotted polarities and ranges.
Amplitude modulation applies the published attenuation depth to the source after its existing envelope/total-level processing, before both direct send and DSP input send.
The current gain model linearly maps code 0–255 to the selected dB range, while actual EG-code mixing and gain rounding still require hardware observations.
Pitch modulation adjusts the F-number before octave scaling: for nonzero depth, the base number 1024+FNS is incremented by floor(base*PLFO / 2^(17-depth)).
This functional arithmetic reproduces all seven pairs of rounded cent extrema in Table 8-9 at FNS=0, including their asymmetry, without introducing host floating-point source-position drift.
The intermediate arithmetic and quantization placement remain an inference from those endpoints, not a physical trace.
A zero modulation depth preserves the original pitch/gain paths, and source interpolation, loops and ADPCM decoding consume the resulting pitch step normally.
The AEG monitor continues to expose the envelope's own attenuation rather than an invented combined LFO monitor value.

Periodic LFO phase is free-running in the model even for inactive voices or disabled modulation; updates are lazy and add no idle sample interrupts or polling.
Live frequency/control writes synchronize the old settings first and retain phase unless LFORE requests reset.
The functional LFORE policy holds periodic phase at zero while the bit remains set and starts it on release; key-on restarts the source/envelope without implicitly resetting the independent LFO.
These reset, key-on and inactive-clock phase choices remain unverified and can be replaced when hardware observations establish their behavior.
Noise LFO uses a deterministic per-slot counter-based generator, with shared unsigned/signed interpretations for amplitude and pitch.
Its polynomial, cadence and phase relationships are not claimed to reproduce the hardware; the model ignores frequency and periodic reset for this noise waveform.
The manual's parenthetical noise exceptions do not establish the full distinction between source noise and LFO noise here, so those control semantics also require clarification.
SSCTL source noise has a provisional generator; arithmetic MPRO programs now execute, while DSP floating sound-memory conversion remains an explicit development stop and the filter approximation does not replace DSP effects.
Tests cover published pitch extrema, waveform landmarks, long-time arithmetic, PCM/ADPCM audio, DSP sends, ARM byte control writes, key/reset behavior, per-slot isolation, deterministic replay and equivalent clock chunking.


## Functional FEG and remaining active filtering

FEG state is implemented independently from AEG state: FLV0 initializes attack, FLV1 ends attack, FLV2 ends decay 1, FLV3 initializes key-off release, and FLV4 ends release, according to System Architecture §8.4.5 (pages 378–379).
The selected FEG monitor tracks attack, decay 1, decay 2 and release with its own 13-bit value, independently from the AEG attenuation and its 10-bit monitor value.
The manual leaves the loop flag undefined during FEG monitoring; this model returns zero for that bit and preserves the existing read-to-clear side effect on the underlying loop latch.
The currently supported pass-through configuration holds all five levels at 0x1FF8, so the connected FEG completes attack and decay 1 on successive sample edges and remains in decay 2 until key-off.
Key-off loads FLV3 once and enters release; repeated key-off commands do not reload it, and a retrigger loads FLV0 and restarts attack.
These edge, key-off and equality policies are functional interpretations of Figure 8-14, not measured chip behavior.
Direct strict construction renders non-pass-through settings dry unless the provisional filter policy is selected; the normal boot bring-up profile enables that policy, which does not establish the hardware filter implementation.

The timing references conflict: System Architecture §8.1.1.7, Table 8-14 (page 270), gives 472800 ms at effective rate 2 and 2760 ms at rate 32, while the standalone AICA manual's FEG table (page 31) gives 118200 ms and 690 ms respectively.
Many corresponding entries differ by approximately four, but the later table's rate 49 entry is 34 ms between rate 48 at 172 ms and rate 50 at 136 ms.
The functional envelope uses the later table, except that effective rate 49 provisionally uses a 154 ms interpolation between its neighbors.
Equal targets complete without consulting the ambiguous timing entry.
The implementation uses linear changes across the full-range duration, clamps at each target and permits both increasing and decreasing target values.
KRS=15 disables key scaling as in the existing AEG model; other settings include signed octave and FNS bit 9, with the effective rate clamped to 0–63.
These policies do not establish the hardware curve, rounding or divider behavior.
The later table defines a full-range transition from 0x0008 to 0x1FF8; partial-range timing, integer stepping and rate changes need separate validation.

For the hardware filter implementation, derive the cutoff mapping from the original cutoff-frequency graph and the resonance definition from the original Q graph, rather than substituting an unrelated generic low-pass filter.
Q is specified as 0.75 times the register value minus 3 dB; the register is not directly a dimensionless biquad Q parameter.
The documented pass-through setting remains Q=4 and FLV=0x1FF8.
Use independent constant, impulse, step and swept-frequency inputs to check pass-through, DC gain, cutoff movement, resonance and state continuity; distinguish functional approximations from measured fixed-point coefficients and clipping.
Existing FEG tests cover full-range timing, zero-rate holds, stages, transitions, key scaling, live changes, monitor selection, key-on/key-off and reset; strict-policy assertions for the old rate-49 and active-filter stops are pending update while boot bring-up takes priority.
Further exercise source formats, DSP sends, ARM byte access and batched scheduling when implementing the filter signal path.


## Functional ADPCM long streams

PCMS=3 uses the AICA ADPCM recurrence documented in System Architecture §8.1.1.2, with predictor and adaptive quantization retained across forward loops as required by §8.1.1.1's long-stream notes.
SA is four-byte aligned, and the low two bits of LSA and LEA must be zero; invalid configurations stop before key-on.
The existing functional loop convention emits LEA and resumes at LSA+1, treating the LSA sample as the duplicated boundary sample; the printed-example uncertainty discussed above also applies here.
Nonlooping long streams stop at LEA as other source formats do.

A bounded sequential decoder retains only the predictor, quantization and last two decoded samples needed by interpolation, rather than allocating a decoded buffer for every pass.
A monotonically increasing stream position distinguishes successive visits to the same wave-memory address.
Every intervening nibble is decoded when pitch skips samples or crosses multiple loops; source position continues to expose the wrapped 16-bit relative address.
Wave-memory bytes are reread on each pass, permitting software to refill encoded stream storage while playback continues.
The functional decoder reads one sample ahead for interpolation; physical wave-memory prefetch, refill deadlines, arbitration and MRWINH timing still require hardware validation.
Source address, format and loop-boundary changes remain prohibited during ADPCM playback, while pitch and gain controls retain their existing live-write behavior.
Key-off/retrigger initializes a new stream predictor and quantizer, and full reset discards stream state.

Tests cover the published initial nibble sequence, predictor and adaptive-step continuity across wraps, refilled bytes, signed saturation, interpolation, multiple loop crossings, current-address and loop monitoring, nonlooping completion, retrigger, alignment/live-write rejection, ordinary ADPCM preservation and identical chunked/batched output.
Commercial streaming drivers and hardware audio captures have not been validated.


## Functional MIDI byte interface

AICA MIBUF at 0x2808 exposes a four-byte input FIFO and the documented MIEMP, MIFUL, MIOVF, MOEMP and MOFUL status bits from System Architecture §8.4.5 (pages 381–385).
The status describes the FIFO before the data read; ARM reads of the high status byte and debugger peeks preserve the data and overflow latch, while a data read consumes one byte.
The functional overflow policy drops the newest input byte, preserves the queued bytes and clears the overflow latch on a consuming register read.
Empty reads retain the last consumed byte, initially zero.
Overflow clear timing, dropped-byte selection and empty-read data are model policies requiring hardware validation.

MOBUF at 0x280C queues every written low byte, including zero, while the high byte selects MSLC/AFSEL.
An ARM high-byte write changes only MSLC/AFSEL, and a low-byte write changes only MOBUF; a system longword write performs both functions.
The output FIFO uses a provisional four-byte capacity because the available original descriptions specify the input capacity without establishing the output depth.
MOFUL reports that functional capacity; further writes while full are dropped, preserving the queued bytes.

The core-owned receiveMidiByte endpoint injects a completely received byte, and takeMidiOutput completes transmission of one queued output byte.
These endpoints do not implement serial framing, electrical pins, baud timing, MIDI message parsing or an app-level MIDI connection.
No sample clock or idle polling is introduced for externally completed byte events.
Input requests update both SCIPD and MCIPD bit 3 while data remains available and clear when the FIFO is drained; clearing a pending bit alone does not consume input.
Completing the last queued output byte sets bit 9 independently on both interrupt sides, and writing output clears both output requests.
Explicit interrupt acknowledgements can independently clear the output request; initial empty/reset state does not synthesize a transmission-completion event.
The existing ARM interrupt-number/end handshake and HOLLY external interrupt routing apply normally.
ARM-only reset retains the FIFOs, while full AICA reset clears their data, status and pending requests.

Tests cover FIFO order/fullness, pre-read flags, overflow/empty policies, shared ARM/SH4 consumption, byte lanes and peeks, zero-byte transmission, TX completion/acknowledgement, monitor isolation, reset, idle deadlines and an original guest ARM byte-instruction echo program.
MIDI pin timing, output depth, overflow behavior and reset/interrupt edge timing remain unverified on hardware.


## Explicit CD session metadata and REQ_SES

CdromToc now optionally accepts a list of CdromSession boundaries, each carrying a contiguous session number starting at one, its first track number and its starting LBA without the two-second lead-in.
Null means unknown metadata, rather than an implied single session.
This is a core-owned disc contract and does not introduce a dependency on image formats or the GUI.
Current production drive adapters do not supply this optional metadata; format parsing and adapter propagation remain required before those discs can answer nonempty session queries.
The test drive accepts explicitly authored boundaries so the SPI behavior can be checked independently of an image parser.

REQ_SES (15h) follows SPI Specifications §8.2's session command description (pages 57–58).
Session zero returns the session count and whole-disc lead-out FAD; a specified session returns its first track and starting FAD.
The six-byte response carries the current low-nibble drive status, a reserved zero byte and big-endian 24-bit FAD, converted from LBA by adding 150.
A zero allocation length completes without transferring data or requiring unknown metadata; other allocations transfer at most the six response bytes, including odd lengths through the existing PIO phase mechanism.
Normal media-ready and unit-attention checks still apply.
An absent session or a session number above 99 returns illegal-request/invalid-parameter sense.
Missing or inconsistent host metadata stops explicitly instead of fabricating boundaries.
Validation checks the 1–99 count, contiguous session numbering, increasing first-track numbers and starting LBAs, backing TOC tracks, disc bounds and the 24-bit lead-out limit.
Media changes invalidate partially transferred responses through the existing optical drive command reset path.

Tests cover single/multiple sessions, count/lead-out and per-session responses, allocation limits, odd/bounded PIO phases, unknown metadata, zero allocation, invalid numbers, inconsistent boundaries and disc removal during transfer.
This does not establish high-density regions, session parsing from media, physical drive timing or commercial BIOS compatibility.


## Functional Mode 2 sector extraction

CD_READ and CD_READ2 now share Mode 2 extraction based on SPI Specifications §8.2 (pages 66–71) and the sector layouts in [ECMA-168, Annex C.2.1](https://ecma-international.org/wp-content/uploads/ECMA-168_2nd_edition_december_1994.pdf).
The XA form is read from submode bit 5, consistent with the original CXD1199AQ data sheet's SHDR description (page 30; [public transcription](https://dtsheet.com/model/1330684)).
The core TOC has optional isXa identity; null means unknown and does not authorize guessing from sector mode or matching subheader bytes.
Original SPI rules distinguish disc identity from sector form, so the functional path requires explicit identity for Mode 2/non-XA requests.
Current production providers do not populate that identity; image/drive adapter propagation remains required.

Expected Form 1 transfers 2048 user bytes at raw offsets 24–2071, and expected Form 2 transfers 2324 bytes at offsets 24–2347.
Continuous selections may include the four-byte header and/or eight-byte subheader; a header-plus-data selection that omits the intervening subheader reports invalid-parameter sense.
The Other selection returns all 2352 bytes without reconstructing check bytes, and normal CD-DA/Mode 1 paths retain their existing behavior.
Any-type requests on known XA discs select the current sector's form for user-data extraction, allowing successive Form 1 and Form 2 sectors in a read; this automatic selection policy still needs drive validation.
Form mismatches, an XA request against an explicitly non-XA disc, and non-XA requests against an XA disc report invalid-parameter sense.
Mode 2 non-XA returns the raw 2336 bytes after the header without a sector-form check, as SPI specifies.
Structured XA extraction rejects inconsistent duplicate subheaders instead of choosing an unverified corrected copy; physical EDC/ECC correction, retry and error-pointer behavior are not implemented.

Generic expected Mode 2 Form 1 with selected data remains a development stop: SPI prints 28 Form 1 dummy bytes, inconsistent with its 2336-byte description and the physical sector layout.
Generic Mode 2 Form 2 transfers the subheader automatically with selected data and appends four dummy bytes, producing 2336 bytes plus an optional four-byte header.
Dummy contents are deterministically zero in this model; physical dummy values are unverified.
Header/subheader-only and complete raw transfers do not require inventing the Form 1 padding and are supported.
This restriction is distinct from explicit Form 1/Form 2 user-data extraction.
Tests cover form sizes and byte ranges, continuous field selections, raw transfers, mixed forms, identity/form/selection errors, non-XA no-form-check behavior, ambiguous padding, contradictory subheaders, CD_READ2 prefetch, Form 1 G1 DMA and complete generic Form 2 G1 DMA.
G1 DMA retains its nominal serial/FIFO schedule; the new DMA test waits for the existing transfer deadline rather than assuming instantaneous completion.


## Functional non-MIP palette VQ

Square non-MIP 4bpp and 8bpp VQ textures are decoded using System Architecture §3.7.9.3's stated 4×4 and 2×4 codebook blocks and §3.6.2.1's 64-bit palette-texel ordering.
The texture address points at 256 eight-byte codebook elements; the index stream follows the 2048-byte book as in the existing RGB VQ path.
The functional address model partitions the texture's Morton texel index into a code index and an in-book index: low four bits for 4bpp and low three bits for 8bpp.
This preserves the documented V0,U0,V1,U1 order for 4×4 elements and V0,U0,V1 for 2×4 elements.
In particular, the remaining 8bpp index stream starts with U1, then V2; it is not independently retwiddled as if each code represented a 2×2 RGB block.
This bit-partition model and the shared index-stream base remain inferred from the documented word ordering and codebook description rather than hardware captures.

Decompressed indices select the existing 1024-entry palette using all six selector bits for 4bpp and the upper two for 8bpp.
All four palette color formats, alpha, point/bilinear filtering, repeat/mirror/clamp, normal shading and framebuffer output use the existing paths.
CPU writes to codebook and palette storage are immediately visible in this functional sampler; physical texture-cache invalidation is still unmodeled.
Palette VQ MIP textures remain an explicit development stop because small-level code index offsets and in-book positions are not established by the available diagrams.
Rectangular/linear VQ, YUV/bump VQ and non-default codebook/index endian wiring retain their existing stops.

Tests check every texel of one 4×4/2×4 codebook element, adjacent block ordering, the fixed index offset and high codes, palette bank limits, all palette color formats, bilinear boundaries, address modes and live writes.
Original TA scenes render RGB, 4bpp and 8bpp VQ through normal polygon control words and verify framebuffer colors and list interrupts.
These tests establish the implemented mapping, not physical cache behavior, hardware VQ index wiring or commercial title compatibility.


## Decoded DSP arithmetic backend

DcAicaDspAlu implements the arithmetic selectors, accumulator, shifter and interpolation latches described in the original AICA manual's DSP diagram and control tables (pages 34–37).
It takes decoded controls; it does not assign unverified MPRO bit positions.
X selects signed 24-bit TEMP or INPUTS, and Y selects signed FRC, signed 13-bit COEF, Y_REG bits 23–11 or unsigned Y_REG bits 15–4.
B selects signed TEMP or the prior 26-bit accumulator, with independent zero and negate controls.
The functional multiplier treats the coefficient as signed 1.12 fixed point, floors the product after division by 4096 and wraps the sum to 26 bits.
The product remains below the exact-integer limit of a JavaScript double; arithmetic division avoids JavaScript's 32-bit bit-shift truncation.
Binary-point placement, product truncation and accumulator pipeline timing still require hardware or original assembly-test validation.

The shifter consumes the prior accumulator in the functional pipeline and supports ×1/×2 with 24-bit saturation or wrap according to the documented four modes.
YRL latches INPUTS bits 23–4 for the next step.
FRCL and ADRL follow the manual's interpolation/non-interpolation bit-selection tables, with unsigned 12-bit interpolation fraction/address and signed high-bit selection in the other modes.
All operand and latch reads precede writes within the decoded step.

DcAicaDsp.executeArithmetic connects this backend to existing buffers with explicitly supplied physical TEMP, coefficient and input addresses.
MEMS supplies signed 24-bit data, MIXS is shifted from signed 20-bit to 24-bit, and EXTS from signed 16-bit to 24-bit.
Reserved input addresses and invalid physical buffer addresses are rejected before committing state.
The returned shifter output may write TEMP and its high 16 bits may write EFREG; EFREG then feeds the existing effect mixer normally.
Full DSP reset clears the arithmetic latches alongside CPU-visible storage.
This method is an internal execution backend for a future verified decoder, not a substitute host API for guest effects.

Tests cover selector behavior, signed coefficients and negative fractional products, saturating/wrapping boundaries, read-before-write latches, all interpolation bit selections and 2048 multiply/add cases checked against an independent BigInt oracle.
Buffer tests check signed MEMS/MIXS/EXTS alignment, aliased TEMP reads/writes, pipelined EFREG output into stereo AudioBuffer, error atomicity and reset.
The audio test explicitly invokes decoded backend steps; it does not execute a guest MPRO program.
Nonzero MPRO still stops at the sample boundary before source/output/interrupt advancement.
MPRO decoding, rotating TEMP addresses, wave-memory pipeline scheduling/floating conversion, remaining address validation and full 128-step sample execution remain required before this becomes a working guest DSP executor.


## Decoded DSP ring/table and linear-memory backend

The decoded DSP backend now adds MADRS, an enabled positive ADRS_REG offset, NXADR and the sample decrement counter, following the address description in [AICA User Manual pages 36 and 39](https://manuals.plus/m/d260f79355dbff7664bdab58c9b8c9bc4b04fa272fdfc7c933ea28a47a167836.pdf) and System Architecture §8.1.1.8.
Ring accesses mask relative word addresses to the selected 8K/16K/32K/64K-word length; TABLE accesses omit the counter and use a 16-bit word address without the ring-length mask.
ADRS_REG values with bit 11 set stop when enabled because extending that 12-bit value into the 16-bit address adder has not been established here.
Disabled address-latch values do not affect accesses.

The counter starts at zero, decrements modulo the ring length for every completed audio sample and is immediately masked if RBL shrinks; these phase/reset/resize choices remain functional policies.
Idle sound batches update it in constant time, and ordinary mixer frames update it before delivering audio callbacks.
A nonzero unverified MPRO program still stops before sample/counter advancement.

Linear NOFL=1 backend reads sign-align a 16-bit little-endian wave value to 24 bits and can commit it to MEMS; writes store the high sixteen bits of a 24-bit value.
This fixed-point alignment is a functional conversion policy requiring hardware validation.
A DSP write to MEMS does not destroy a separately staged CPU low-byte write.
The backend accepts an explicit inhibit condition and rejects inhibited or out-of-range accesses before touching data; a future executor must pass MRWINH bit 0 and schedule the request/return pipeline.
These transactions are synchronous internal helpers, not timed MRD/MWT guest instructions.

Absolute byte addresses retain the existing ringBaseBytes policy: low twelve RBP bits shifted left eleven, plus twice the relative word address.
The available descriptions conflict on RBP width/boundary units: the System Architecture diagram labels RBP[19:11], other register descriptions use [22:11], and the accompanying text uses differing word-boundary sizes.
The current byte-base policy is not claimed to resolve those differences or reproduce memory aliases; accesses beyond the supplied retail wave RAM stop.
Floating memory conversion, physical DRAM arbitration, read/write latency and verified MPRO decode remain unimplemented.

Fourteen tests cover all ring lengths, large exact batch counts, TABLE gating, MADRS/ADRS/NXADR sums and wrapping, resize, signed linear samples, base/word offsets, CPU staging, error atomicity, memory-to-ALU/effect data flow, idle/mixer integration and equivalent master-clock chunking.
These tests validate the functional backend and its deliberate stops, not hardware memory timing or a running guest DSP effect program.


## Functional texture supersampling

TSP Super-Sample now requests the four screen positions documented in System Architecture §3.4.7.2.4: (x,y), (x+0.5,y), (x,y+0.5) and (x+0.5,y+0.5).
CORE recomputes the perspective-correct UV from the polygon's shading plane at every position, preserving the selected texture half-offset origin.
It does not approximate the positions by adding a constant texture-space offset.
The additional samples use the same material plane as the existing triangle, quad or sprite path and do not change primitive coverage or depth testing.

Each position uses the selected point/bilinear filter, existing address modes and texture decoding before the four ARGB colors are averaged.
The functional average uses equal weights and nearest-integer channel rounding; physical filter arithmetic and accumulation precision remain unverified.
Palette lookup and bump brightness occur before this average, and the averaged texel then enters the existing shading, fog, trilinear pass-weight and blend paths once per covered pixel.
Direct sampler calls must supply the other three perspective UVs; missing/incomplete coordinates stop instead of silently treating screen offsets as UV offsets.

For MIP textures, each pass selects the next higher-resolution level as required by the Super-Sample description in §3.7.9.2 (page 209), clamped to the largest level.
Trilinear passes retain their complementary existing weights; both selected levels move up independently, including the case where both reach the largest level.
All four subpoints share the anchor pixel's functional LOD/weight calculation.
Per-subpoint hardware LOD evaluation, internal rounding and the exact interaction with Dcalc still require hardware measurements.
Non-MIP filter modes 2/3 retain their documented point-sample fallback at each position.

Eleven tests cover point/bilinear averaging, palette alpha, VQ expansion, bump alpha, independent address clamping, MIP limits and both trilinear levels, invalid UV lists, TA framebuffer output, unchanged coverage and analytical perspective coordinates with both texture-origin settings.
The existing nominal tile completion schedule remains a functional placeholder; hardware's documented three-to-fourfold drawing cost is not modeled by that schedule.
Supersampling support does not establish physical antialiasing, cache/FIFO behavior or commercial image matching.


## Functional textured and Gouraud backgrounds

Background ISP/TSP parameters now use the existing vertex decoder, texture sampler and pixel-shading path, following System Architecture §3.4.1 and ISP_BACKGND_T (pages 102 and 348).
The tag selects three consecutive strip vertices and the expected skip-plus-three stride; TCW remains present even for an untextured background.
Textured backgrounds accept UV32 or the documented packed UV16 format, optional offset color, palette/VQ formats and the existing point/bilinear, MIP and supersampling paths where those formats are supported.
Untextured Gouraud backgrounds interpolate color from the same three-vertex surface.
The flat untextured fast path remains available and does not require unused XYZ values to form a shading plane.

The three vertex Z values control perspective color/UV interpolation and MIP derivatives independently of ISP_BACKGND_D.
The latter initializes the tile's depth surface and controls subsequent polygon depth tests; a zero background depth does not imply a zero shading denominator.
A synthetic covering primitive evaluates the parameter plane across the tile, including the part outside the original parameter triangle, without applying ordinary polygon culling or depth testing to background initialization.
The generated color initializes the primary accumulation buffer directly, preserving the existing background policy rather than blending against an invented previous pixel.
Fog uses the programmed background depth in this functional model.
Exact hardware interpolation, extrapolation, fog depth selection and initialization ordering still require image/hardware measurements.

The background path resets object-shadow selection and secondary validity before processing display-list objects.
Background modifiers/parameter-selection volumes and secondary-buffer routing remain development stops.
Trilinear background pass accumulation also stops because the single background material's relationship to the two-pass protocol has not been established here.
Unsupported bump combinations retain the existing requirement for offset parameters and flat shading.
Invalid skip values, nonfinite depth and degenerate nonflat shading planes stop explicitly.

Twelve tests cover complete-tile texturing, UV16, strip offsets, ordinary and perspective Gouraud color, direct initialization, offset color, foreground occlusion using the separate depth plane, supersampling, MIP derivatives and retained stops for unresolved background modes.
These tests use original CPU-authored parameter blocks and independently selected expected pixels; they do not establish commercial background compatibility or physical parameter-cache behavior.


## Maple RESET control descriptors

DMA command pattern 011 now emits a functional electrical reset on the selected port, based on System Architecture §§5.1.1/5.1.3 and the original Maple Standard §§2.2/3.5.
Unlike a normal data command, this descriptor consumes only its instruction word; the transfer-length field is ignored and there is no response address or data frame.
The End Flag terminates the command table normally, and a descriptor without End Flag chains immediately to the next instruction after the reset interval.
No receive-buffer write or timeout is fabricated for RESET, including an empty port.

The original standard defines detection by fourteen SDCKB falling edges and requires resetting every device and expansion device on the selected port, without a reply.
The transport uses a nominal 28 bit-period interval: 2800 master clocks in its 2 MHz mode and 5600 in its 1 MHz mode.
That interval is inferred from alternating serial-line transitions; it does not model physical setup/hold, connector delay or exact reset-completion timing.
The existing controller resetDevice operation commits at the end of the interval, recovers Device Kill and clears discovery for the main device and attached children.
Held host input and persistent expansion storage retain their existing reset semantics.
Other ports keep running and are not reset.

Disabling DMA during the interval completes the in-flight reset and then stops without a DMA-end interrupt, matching the transport's existing forced-termination policy.
Transport failures, a new transfer and full reset clear a pending reset-port selection.
Light-gun occupy/release patterns remain explicit development stops; the DDT transport below connects RESET descriptor fetches to channel zero but does not establish pin/arbitration timing.

Eight additional tests cover delayed commit/recovery, input retention, port/expansion isolation, descriptor chaining and length-field omission, empty ports, DMA disable, both serial rates and single-clock completion.
The complete Maple suite also retains software/VBlank triggers, byte-order handling, protection and discovery tests.


## Maple channel-zero DDT transport

Maple command and packet reads now use the shared SH7750 channel-zero 32-byte DDT interface used by G1/G2, rather than reading the command table directly during start.
The transport waits when DMAOR.DDT/DME or error/NMI gates prohibit requests, and respects the existing DMAC module-stop gate.
It never enables DDT on the guest's behalf.
The external endpoint callback accesses physical RAM after a granted root transfer, bypassing CPU cache/MMU as before, with channel-zero registers and transfer completion updated by DcDmac.
Other DDT owners can hold the shared request slot; Maple retries without consuming a packet or fabricating completion.

Source reads capture aligned 32-byte snapshots before the descriptor is interpreted.
A data descriptor fetches all required packet bytes before invoking the device; it does not yet pace those source reads against the physical serial FIFO.
Snapshots are retired as the command cursor passes their blocks, retaining unused bytes of the current aligned block for following descriptors.
The largest supported 1024-byte packet spans 33 source blocks including its descriptor and receive pointer.
Protection is checked before source requests and again at callback commit; invalid decoded commands are detected only after their source data reaches the controller.
An unsupported device command keeps its descriptor replayable rather than advancing to a different command during a development stop.

After the functional serial interval, responses wait for individual 32-byte DDT writes.
Each block becomes visible at its own root-bus boundary, and Maple DMA-end follows the final committed block.
VBlank Over reflects active serial transmission/reception, excluding source-fetch and response-write DDT waits.
Existing wire-byte-order conversion and deterministic invalid padding apply to each block.
A timeout response uses a 32-byte write with a four-byte all-ones sentinel and deterministic zero padding; the invalid padding values remain a model policy.
If DMAC reset removes a queued request, the retained source/response state can reissue it after software restores DMAOR.
A NMI pauses a queued response without replaying its peripheral exchange.

Source-fetch cancellation before serial transmission performs no exchange; disabling Maple during an exchange or response drain completes that exchange's writes and stops without a DMA-end interrupt.
Full Maple reset and transport errors withdraw owned requests and discard source snapshots.
Hardware VBlank startup/delay boundaries and serial completion queue new requests only at the current bus time, so earlier clocks are not credited to a newly ready transfer.
NOP and RESET instructions also require their source DDT fetch; the nominal RESET interval itself is unchanged.
Existing Maple/memory card tests now initialize DMAOR explicitly, and their precise deadlines include source and response root transfers.

Fourteen added tests cover disabled DDT, root-unit timing, partial receive visibility, serial-only VBlank-over notification, NMI/DMAC-reset recovery, module stop, cancellation/reset, source snapshot retention, maximum packet size, an occupied DDT slot, replayable development stops and concurrent G1/Maple transfers.
The original Maple/memory card suite continues to exercise hardware triggers, software aborts, protection, serial byte order, input and persistence with the DDT path enabled.
The current request preparation order is functional scheduling, not a measured HOLLY root-bus priority model.
Physical arbitration, continuous serial FIFO streaming/backpressure and other DTR formats remain validation/implementation work.


## SH4 instruction inspection

The core debugger now formats SH4 mnemonics using the instruction tables in the SH7750 Hardware Manual §7.5 and the SH-4 Programming Manual, together with fnesemu's own execution decoder.
The pure decoder receives only the opcode, instruction address and FPSCR; it never fetches a literal, dereferences a register or executes an instruction.
The existing instruction peek still observes cached instructions without allocating/evicting cache lines or consuming MMIO data.
The address/code columns and two-byte instruction length are unchanged.

The decoder covers integer ALU/multiply/divide, shifts/rotates, memory addressing modes, PC/GBR-relative transfers, branches, traps, control/system/banked registers, cache/store-queue instructions and the implemented scalar/vector FPU families.
PC-relative comments show the computed literal address, including longword alignment and 32-bit wrapping, without reading its value.
Branch targets use PC+4 and the appropriately sign-extended displacement.
Signed MOV/ADD/CMP immediates and scaled unsigned memory displacements retain their distinct interpretations.

FPU arithmetic names use FR or even DR registers according to FPSCR.PR.
FMOV uses FPSCR.SZ independently and identifies odd encoded pairs as XD registers in the alternate bank.
The current active FR bank remains implicit in the architectural names, as it does for guest assembly.
Undefined words and modes that cannot name an architectural operand retain complete hexadecimal .word output instead of inventing a mnemonic.
This inspection does not classify exception acceptance, emulate delay slots or establish hardware timing/graphics-FPU accuracy.
ARM7DI mnemonics are provided by the independent decoder described below.

Fourteen tests cover operand order, signed immediates, access-size scaling, control/bank names, branch/literal alignment and wrap, single/double arithmetic, FMOV pairs, vector instructions, reserved fallbacks and Core FPSCR inspection without CPU advancement.
All 65536 instruction words are also inspected for bounded, single-line output without operand-index errors.
The existing cached-instruction debugger test now checks the NOP mnemonic while retaining its cache-state assertions.


## CD audio playback through AICA

CD_PLAY (20h) accepts FAD or binary MSF ranges, finite repeat counts and endless repeat, and parameter type 7 resumes a saved play range.
CD_SEEK pause retains the next stereo frame; ordinary seeks, data reads, reset and media changes discard the saved range.
The drive reports PLAY while active and SEEK during the initial asynchronous adapter seek; an initial seek failure reports the existing hardware-error sense.
Each 44.1 kHz AICA sample consumes one signed stereo frame from a raw CD-DA sector, with 588 frames per 2352-byte sector, and latches EXTS left/right before the output mixer runs.
System Architecture describes the physical optical drive digital audio connection to the AICA; the existing EXTS send and pan controls determine whether this input reaches the DAC output.
Data-track playback advances silently, as specified by SPI; it does not decode sector headers as sound.
The raw adapter byte order follows fnesemu's existing little-endian CD audio convention.
A host sector-cache miss emits silence while preserving the next unconsumed source frame; malformed raw audio sectors remain explicit development stops.
The unsupported guest DSP program check runs before consuming an external frame.
End addresses are treated as exclusive, pause resumes at the exact next frame, and repeat restarts request an adapter seek; these boundary and latency policies require hardware validation.
An end of zero or an address beyond physical lead-out clamps to lead-out, and reaching lead-out terminates even an endless repeat, as required by SPI.
Playback across unrepresented intermediate session lead-in/out gaps, physical seek/audio latency remain unfinished; functional scan is described below.
The synthetic packet regression verifies CD_PLAY through stereo AICA output, pause silence, resume and reset without using commercial media.


## Explicit optical drive subchannel data and audio status

The optional `CdromSubcodeDrive` capability supplies subchannels by LBA without changing ordinary 2352-byte drive implementations.
`CdromSubcode.raw` carries the 96 packed P-W symbols without the two synchronization symbols, and `CdromSubcodePosition` carries a provider-validated ADR=1 Q position with binary track/index numbers, control flags and track-relative frames.
Unknown metadata is represented separately from a pending fetch or an unreadable sector; the core does not reconstruct Q indexes, copy flags or pre-emphasis from a track's audio/data identity.
AsyncCdromDrive now supplies retained CHD RW_RAW subchannels through this capability; ordinary images and unavailable subchannel records remain explicitly unknown.

CD_SCD (40h) formats 0 and 1 return the SPI 100-byte raw response or 14-byte Q position response, truncated by allocation length and the existing bounded PIO phases.
The response length fields retain the full record length after truncation.
The SPI Q response translates the supplied position to control/ADR, binary track/index and 24-bit relative/absolute FAD fields; explicit decoded positions must be provider-validated; raw-only providers use the shared Q decoder described below.
The original SPI format table lists 12 Q transfer bytes while its detailed response layout explicitly specifies 14 bytes; this implementation follows the detailed layout and needs hardware confirmation.
Zero allocation completes without metadata access; allocations of four bytes or less return only the independently known header.
A pending subchannel read holds BSY and retains the requested head position until the provider returns a result.
Unreadable subchannels report medium-error sense with ASC 11h; absent capabilities, malformed metadata and unavailable raw/Q fields remain explicit development stops.
Reset and media changes cancel pending subchannel reads.
Reserved formats are rejected as illegal parameters; explicit catalog and ISRC metadata are handled as described below.

Audio status reports 11h while playing, 12h while paused, 13h after normal completion, 14h after a playback seek failure and 15h after reset/read/ordinary seek or after an end result has been reported once.
An end result is consumed when a valid subchannel response containing its status byte is queued; zero-byte and one-byte allocations leave that result pending.
The exact consumption point if a queued response is abandoned, the subcode sampling phase relative to audio and optical subcode update latency remain unverified functional policies.
Tests cover explicit control/index preservation, raw symbols across odd PIO phases, bounded/zero/header-only allocation, pending fetches, media cancellation, read errors, unavailable metadata, playback status and one-shot completion.


### Catalog and recording identifiers

CD_SCD formats 2 and 3 return the specified 24-byte media catalog number (MCN) and track recording identifier (ISRC) records, including format, validity and binary Aframe fields.
`CdromSubcodeIdentifier` supplies the provider-validated value and the frame number from the identifier's own Q record, rather than inferring the frame from the current head position.
MCN accepts thirteen ASCII digits; ISRC accepts two uppercase country letters, three uppercase alphanumeric registrant characters, and seven recording-year/serial digits without separators.
An empty identifier explicitly means that the provider did not detect a code; a null identifier remains unavailable metadata and stops explicitly.
Undetected identifiers clear MCVal/TCVal and fill the character field with ASCII zeroes as a functional policy; an all-zero MCN also clears MCVal as specified by SPI.
Malformed characters, lengths or frame values stop before queuing a response or consuming one-shot audio status.
Header-only and zero allocations do not require identifier metadata, and other allocations use the existing truncation and bounded PIO path.

The detailed SPI ISRC byte table places twelve characters at bytes 9..20, zero at byte 21, binary Aframe at byte 22 and zero at byte 23.
The prose instead describes three trailing ASCII zeroes; this implementation follows the detailed table and retains the discrepancy as an unresolved hardware-validation item.
The code does not synthesize MCN/ISRC from track names, filenames or other TOC fields.
The CHD adapter can supply CRC-validated ADR=2 catalog and ADR=3 ISRC records; cross-record identifier discovery still requires further provider work.
Tests check exact ASCII payloads, both validity flags, retained record frame numbers, empty versus unknown values, allocation/PIO boundaries, header-only operation and malformed provider data.


### Raw Q decoding

`CdromSubcode.fromRaw` decodes packed P-W symbols using [ECMA-130 section 22](https://ecma-international.org/wp-content/uploads/ECMA-130_2nd_edition_june_1996.pdf).
It extracts Q from bit 6, checks the inverted CRC-16 parity, validates BCD fields and reserved zeroes, and decodes ADR=1 positions, ADR=2 catalog numbers and ADR=3 ISRC identifiers.
Position records retain their actual absolute frame count, including the disc lead-in, in `discFrames`; older explicit providers may omit it and retain the requested-position fallback.
Pause countdown values and lead-out track AA are preserved; lead-in TOC and non-ISRC CD-R identifier records remain undecoded.
Raw symbols are copied and retained even when Q cannot be validated, so format-0 reads remain available without inventing a valid position.
Optical drive raw-only providers now use this decoder for Q and MCN responses, while explicit cached metadata takes precedence.
Tests use independent polynomial long division, all 96 single-bit Q errors, malformed BCD and reserved fields, 1,024 randomized positions, and packet-level raw-only responses.
CHD RW_RAW extraction and asynchronous adapter caching are connected as described below; CUE/ISO/BIN and processed R-W-only images do not acquire synthetic P-Q data.


### Stop/home and repeat reporting

CD_SEEK parameter type 3 now stops playback, discards the saved resume range and returns to the home FAD 150 specified by the SPI REQ_STAT table (page 44).
The operation uses the existing asynchronous `CdromDrive.seek(0)` contract and reports SEEK until the adapter completes, then STANDBY with DSC and the normal command-completion interrupt.
An adapter error reports the existing hardware-error/ASC 15h sense, retains the previous head position and does not enter standby.
The adapter seek represents logical home positioning and host cache preparation, not mechanical pickup or spindle timing.
Reset, media changes and command cancellation clear a pending home request; side-effect-free debugger reads do not complete it.
Pause, ordinary seek, nonempty data reads and a new play request leave standby; a stopped range cannot be resumed by CD_PLAY type 7.
Physical spindle behavior remains unfinished; the SET_MODE pause-to-standby timeout is described below.

REQ_STAT byte 1 now combines the existing disc-format nibble with the saved remaining repeat count, including Fh for endless repeat.
Pause retains that count, a finite loop decrements it, and completed, stopped or reset ranges report zero remaining cycles.
The exact terminal count after an endless request reaches physical lead-out still needs hardware confirmation.
Tests cover synchronous/asynchronous home completion, reserved seek-address bytes, seek errors, debugger reads, reset/media cancellation, standby exit and finite/endless repeat reporting.


### Automatic standby timeout

SET_MODE bytes 4..5 now control the pause-to-standby interval in seconds, following SPI page 47: zero disables automatic standby, 1..FFFFh select an unsigned period, and reset restores B4h (180 seconds).
The timer uses 200 MHz master-clock arithmetic and contributes a deadline to the shared bus scheduler; maximum periods remain exact on the browser backend.
Completed pause intervals enter STANDBY, report home FAD 150 and invalidate any saved audio resume range without changing ATA response buffers, completion flags or interrupt state.
Normal status/mode PIO responses remain readable across the deadline.
Playback, a pending seek, an active sector-read command through its final PIO/DMA drain, pending subchannel fetches and the ATA soft-reset interval inhibit counting.
An ordinary seek or new read/play operation interrupts the old pause interval, and a completed seek or sector drain starts a fresh one.
Changing the timeout value restarts counting; invalid mode writes preserve the configured value and elapsed interval.
Media changes restart counting while retaining mode settings, and reset restores the default period.

The implementation treats standby as a logical drive transition without issuing a host sector read or cache seek, and does not model mechanical pickup/spindle latency.
Counting through unrelated status/mode transfers, restarting on changed mode values, and inhibiting during pending host subchannel fetches are functional policies that still need hardware timing validation.
Tests cover exact default/one-second/maximum deadlines, disabled timeout, shared-bus scheduling, active playback and reads, pending seeks, retained PIO responses, invalid/reprogrammed mode values and reset/media ownership.


### Functional CD scan transport

CD_SCAN (22h) implements SPI page 65's forward/reverse direction and speed ranges: parameters 0..2 select 2x, 3..5 select 5x, 6..9 select 9x and 10..255 select 16x.
It requires an active or paused saved CD_PLAY range; ordinary seeks, reset and stop do not create a resumable play range.
The drive reports SCAN (5), exposes its advancing FAD through REQ_STAT and retains the saved play range and repeat count while scanning.
A new scan command can change speed/direction; pause, normal resume, a fresh play request, read, ordinary seek, stop, reset and media changes leave scan mode.
Scan is clocked through the same 44.1 kHz AICA external-input path as normal playback and inhibits the pause-to-standby timer while active.

The functional audio monitor selects source frames at the nominal signed scan rate; it does not reproduce an optical drive's scan-window/mute cadence or physical seek latency.
It traverses raw sectors in either direction, holds position across pending host cache reads and advances silently across data tracks.
The currently exposed user area is bounded by FAD 150 and physical lead-out; reaching either boundary clamps the position and enters a resumable pause without consuming repeats.
Scanning backward from lead-out starts at the final available source frame.
The exact lower boundary when a provider exposes initial pregap/lead-in data remains unverified and requires a richer disc interface.
A normal resume preserves the current source position and returns to unit rate; if that position has already reached/passed the saved play end, this functional policy completes the range immediately rather than reading beyond its bounds.
Physical boundary/resume behavior still requires hardware validation.

Tests cover all 256 speed parameters, signed stereo samples, forward/reverse sector traversal, direction changes, endpoint pauses, saved ranges, host cache misses, data-track silence, command-state rejection, REQ_STAT/subchannel status, standby inhibition, command/reset ownership and scan PCM through the AICA output mixer.


### CHD subchannels through the generic image/drive boundary

The optional image-owned `DiscSubcodeImage` interface returns copied 96-byte raw P-W symbols without importing core contracts.
CHD RW_RAW tracks and stored pregaps expose their actual symbols; NONE, processed R-W-only tracks and synthetic gaps return unavailable metadata rather than fabricated P-Q bits.
The CHD reader now preserves the separate subchannel stream for CD Deflate/LZMA/FLAC/Zstandard hunks, leaving 2352-byte sector reads and CD audio byte order unchanged.
Nonzero raw symbols are checked against original synthetic images created by chdman 0.242 in each of cdzl/cdlz/cdfl, alongside uncompressed layout, track padding, stored pregaps and copy ownership tests.
The existing Zstandard fixture exercises its zero-filled subchannel stream; an independently authored nonzero cdzs fixture remains a verification item because the installed authoring tool predates that codec.
The original fixture generator and source-byte formulas are included in the image package; no external emulator implementation code was consulted.

AsyncCdromDrive implements the generic optional subchannel capability without core-specific imports or GUI changes.
It fetches and decodes Q asynchronously, coalesces duplicate requests, caches successful/unavailable/error results for the existing cache lifetime and includes pending subchannel work in host waiting/settle behavior.
Subchannel errors remain separate from sector seek status, and media generations prevent a late result from overwriting replacement-disc metadata.
Actual raw Q records provide control, index and recorded absolute position through the shared CRC decoder; unsupported/invalid records remain raw-only and do not acquire invented decoded fields.
A public-Core-API regression executes an original SH-4 diagnostic that issues REQ_ERROR and CD_SCD through guest MMIO and copies the CHD-derived Q response into RAM.
This proves the image/adapter/guest command path for the synthetic fixture, not commercial BIOS or game progression.


### Raw ISRC records

Raw ADR=3 decoding follows [IEC 60908:1999 section 17.5.3](https://audio-union.com/wp-content/uploads/2023/02/Red-Book-Audio-Recording-Compact-Disc-Digital-Audio-System-IEC-60908-Second-Edition-1999-02-ISBN-2-8318-4638-2.pdf).
Five six-bit character cells and seven BCD digits become the twelve-character ISRC; the decoder checks the country-letter profile, reserved bits and recorded AFRAME after CRC validation.
Invalid codes remain raw-only.

[ECMA-394 section 5.6.3.2](https://www.ecma-international.org/wp-content/uploads/ECMA-394_1st_edition_december_2010.pdf) distinguishes ISRC from recorder and reserved records using two selector bits.
Only selector 00 becomes an ISRC; an all-zero ISRC body explicitly supplies a not-detected result.
Other selectors do not acquire recording metadata.

Raw-only optical drive providers now return decoded ISRC in CD_SCD format 3, retaining the existing SPI byte-layout policy.
Explicit cached identifiers still take precedence.
Tests cover the character table, malformed fields, every single-bit CRC error, 1,024 randomized codes, selector distinctions, SPI responses and an original CHD-to-adapter-to-guest diagnostic.
Finding an identifier in other sectors and associating cached records across track changes remain unfinished.


## Initial execution of user-supplied boot assets

This section records early bring-up results; the current BIOS and game status is described in Boot-first bring-up above.

The supplied 2 MiB boot ROM and 128 KiB system flash are loaded only from external paths by `dart run tool/dc_probe.dart BOOT_ROM FLASH [INSTRUCTIONS [DISC_IMAGE]]`.
The probe does not copy those assets into the repository or write back flash changes; it records executed instruction count, clocks, a bounded recent-instruction trace and the first explicit stop.
The initial probe stopped after 19 instructions at the BCR2 halfword write at PC A0000026.

DcBsc now implements SH7750 hardware-manual section 13.2's BCR1/BCR2, WCR1/2/3, MCR/PCR, keyed refresh control/counters and address-encoded SDRAM mode writes.
Register widths, reserved masks, read-only endian/area-0 mode-pin fields, power-on versus manual reset and refresh write keys are checked independently.
The external bus clock from CPG drives the functional RTCNT divider, compare/clear behavior, RFCR count and CMF/OVF write-zero-to-clear flags.
Zero RTCOR uses the eight-bit wrap interval, and 512/1024 refresh count limits and divider-change phase resets are functional policies requiring hardware timing checks.
SDRAM byte accesses distinguish MCR precharge from mode-register setting and use SH-4 A2 or A3 for 32-bit or 64-bit SDRAM respectively.
The area-0 width strap is configurable; its board-specific default remains unverified.
Refresh compare-match (RCMI, INTEVT 0x580) and overflow (ROVI, INTEVT 0x5a0) requests use IPRB bits 11:8 and remain pending until their enabled status flags are cleared. RCMI takes precedence over ROVI. External wait-state waveforms, SDRAM pin timing and memory refresh contention are not modeled; physical timing remains unverified.

The supplied BIOS then reached its G1 system-ROM timing setup after 2,239 instructions.
G1 accepts aligned low-halfword writes for the timing registers and IORDY control, whose defined fields fit in the low 16 bits; DMA and keyed protection registers retain their existing longword access requirement.
The firmware exercises this partial-write path, but physical HOLLY byte-enable behavior still needs independent hardware validation.
With these changes, the BIOS executes 2,311 instructions before writing 001FFFFF to the unimplemented G1 address 005F74E4 from PC 8C0000E4.
That address is absent from the current original System Architecture register table; the independent KallistiOS hardware SDK documentation identifies it as the HOLLY BIOS-content protection trigger and 005F74EC as its status register.
The SDK documents in-progress, failed and passed states, but does not establish the hardware verification algorithm or timing, so this remains an explicit stop rather than an assumed success.
This progress does not establish a boot screen, disc boot or game compatibility.


The supplied CDI has also been inspected read-only with the independent [CDIrip utility](https://github.com/jozip/cdirip), used only as an opaque metadata tool rather than as implementation reference code.
It reports a v3.5 image containing one session and one Mode1/2048 track at LBA 0 with 358,613 sectors.
Independent reads confirm an ISO 9660 primary volume descriptor with volume identifier SC5R, 2048-byte logical blocks and the matching volume-sector count; its root directory includes 1ST_READ.BIN.
This metadata inspection does not establish self-bootability or game compatibility, and native CDI parsing/attachment is still required.
No BIOS, flash or game payload has been added to repository fixtures.


### Read-only validation of the supplied CDI sector path

The independent CDIrip conversion produced a single 734,439,424-byte Mode1/2048 ISO for the supplied one-session CDI.
Every output byte was compared against the corresponding original CDI sector stream following its 150-sector stored prefix, with no difference.
The converted data and cached source remain in temporary storage outside the repository; this is a diagnostic conversion path, not native CDI format support.

The BIOS probe now accepts a parsed disc image and waits for pending host reads without changing emulated device completion rules.
With the converted image attached it reports one track and 358,613 sectors, but the BIOS still stops after 2,311 instructions at the HOLLY protection trigger.
No boot or protection checks are bypassed.

`dart run tool/dc_disc_probe.dart DISC_IMAGE [LBA]` runs an original SH-4 device diagnostic that issues REQ_ERROR followed by CD_READ through guest MMIO, drains 2,048 data bytes into RAM and compares them with the adapter sector.
Using LBA 16 of the supplied image, the diagnostic completes after 5,508 instructions and every returned byte matches the ISO primary volume descriptor.
This establishes actual image-to-adapter-to-optical drive-to-SH-4 sector transfer for the provided disc, independently of BIOS or game boot.
The same diagnostic also reads the final LBA 358,612 successfully with an exact 2,048-byte match, exercising full three-byte FAD encoding and the end-of-image boundary.
The tool also runs against repository-owned synthetic CUE/ISO fixtures without commercial assets.
Native CDI parsing and session propagation are described below; full BIOS/game progression remains required.

## SH7750 GPIO ports

`DcGpio` implements hardware manual sections 18.2.1–18.2.5: PCTRA/PDTRA, PCTRB/PDTRB and GPIOIC, including access widths and reserved fields.
Input samples update on external bus-clock edges; output reads use the retained data latch.
External driver masks override input pull-ups, and floating inputs with pull-up disabled resolve low as a deterministic model policy.
Initial sampled inputs are high and initial undefined data latches are zero; subsequent power-on resets retain the latches, while manual resets also retain control registers.
PORTEN gates active-low GPIO interrupt requests, with input direction and GPIOIC selecting the pins.
GPIOI uses INTEVT 0x620 and IPRC bits 15:12, ahead of DMAC at equal internal priority and behind equal-priority external IRL requests.
DC board-specific connections, analog floating-pin behavior and data-bus multiplexing while PORTEN is clear are not established by this implementation.
These register and interrupt tests do not establish BIOS or game boot compatibility.

## ARM7DI instruction inspection

The AICA debugger and trace formatter use `dcArm7diDisasm`, based on ARM7DI Data Sheet DDI 0027D chapter 4 and this core's independent ARM7DI interpreter.
It covers integer data processing, immediate/register shifters, branches, multiply/accumulate, swap, PSR transfers, single/block transfers and software interrupts.
Branch targets use PC+8 with signed word offsets and 32-bit wrapping; operand immediates retain the ARM rotated-eight-bit encoding.
Addressing displays pre/post indexing, writeback, byte/translated transfers and block transfer user-bank/PSR suffixes.
ARMv4 extensions, absent external coprocessors and unrecognized encodings retain complete raw words.
Inspection reads existing side-effect-free AICA memory and does not advance either CPU or acknowledge device requests.
Tests cover instruction families, shift-zero semantics, branch wrap, reserved fallbacks, random full-word inspection and the public core debugger boundary.

## Disc platform identification

The DC module exposes its disc capability to the existing factory; no application or GUI changes are required.
Identification checks the 32-byte hardware/maker identity at the start of the first or last data track's user data, as described in the independent [IP.BIN](https://mc.pp.se/dc/ip.bin.html) and [IP0000.BIN](https://mc.pp.se/dc/ip0000.bin.html) documentation.
Mode 1 and Mode 2 Form 1 raw sectors require the sync pattern and the latter's duplicated subheader; audio and Form 2 sectors are excluded.
If the boot area has no identity, a bounded ISO 9660 root-directory lookup checks `IP.BIN;1` and `IP0000.BIN;1` file metadata using [ECMA-119, second edition](https://ecma-international.org/wp-content/uploads/ECMA-119_2nd_edition_december_1987.pdf), sections 7–9.
This lookup supports 2,048-byte blocks, single-volume non-interleaved extents without extended attributes, consistent both-endian numbers and volume-relative block addresses within the candidate data track.
It examines at most 32 volume-descriptor sectors and 128 root-directory blocks per candidate track; these are identification resource limits, not filesystem limits.
Malformed records, out-of-range extents, oversized directories and unsupported layouts do not identify the disc through this fallback.
Identification retries pending host reads, cancels on media-generation changes and neither seeks the guest drive nor consumes its media events.

The filename alone does not select DC, and identification does not verify license code, executable scrambling, regional compatibility or BIOS bootability.
BIOS metadata remains optional for flat development diagnostics; actual disc execution requires a supplied boot ROM and still encounters the documented HOLLY verification stop.
The supplied CDI has zeroes in its first sector and a 32 KiB root `IP.BIN` file at LBA 65,482.
It is now identified as `dc` through the public factory using that file's metadata; this does not establish that the disc is self-booting.
The updated `dc_disc_probe.dart` reports the identified system as well as its guest sector-read comparison.
For the supplied image's LBA 16, identification returns `dc` and the independent SH-4 PIO diagnostic still completes in 5,508 instructions with all 2,048 bytes matching the adapter.
Independent fixtures cover track selection, raw sector framing, exact identities, deferred reads, media replacement, ISO offsets/records/extents and both factory and module entry points on native/browser runtimes.

## Native CDI media and session propagation

The generic disc-image package now parses the verified CDI v3.5 descriptor layouts directly, including explicit session starts, mixed audio/data tracks, stored pregaps and 2048/2336/2352-byte sector encodings.
Independently authored multi-session fixtures were checked using only the standalone CDIrip metadata/extraction CLI; no converter or emulator implementation was consulted.
The app and headless drive adapters pass the optional generic image session list to `CdromToc.sessions` without core-specific production branches.
The provided external CDI can now be opened directly by `dc_disc_probe.dart`; no conversion or payload copy into the repository is needed.
The guest optical drive PIO diagnostic completes at LBA 16 and final LBA 358,612, with all 2,048 returned payload bytes matching the image adapter.
Separate direct image reads at LBA 0, 16, 1,000, 179,306 and 358,612 match all payload bytes of the earlier independently extracted ISO, checking the parser separately from the guest transport.
Descriptor variants and encoding limitations are documented in the disc-image package; unsupported inputs fail explicitly.
This media path does not resolve the separate HOLLY BIOS-content verification stop or establish game boot.

## Logical save-state component work

The public DC core implements native logical save/load for the current functional machine model.
The AICA CPU/DSP component serializers cover `DcArm7di`, `DcAicaDsp` and `DcAicaDspAlu` using the shared tagged `StateWriter`/`StateReader` format.
ARM state includes all active and hidden banks, CPSR/SPSRs, elapsed cycles, interrupt input levels and instruction-completion observation state.
Restoration updates existing register buffers directly and preserves the new instance's bus callbacks; memory belongs to the owning AICA component.
DSP state includes COEF, MADRS, MPRO, TEMP, MEMS, separately staged CPU MEMS low bytes, MIXS, EFREG, EXTS, ring configuration/phase and arithmetic latches.
Program-presence and mixer-presence caches are reconstructed from logical storage, and the existing ALU object is retained.
Each loader reads and validates its component before modifying live state, including field widths, array lengths and control values.
Tests resume ARM programs saved after IRQ/FIQ entry, compare subsequent bus writes and bank transitions, preserve clocks above 32 bits, and compare continued decoded DSP arithmetic/memory operations and staged writes.
Truncated and invalid component sections are rejected without partially replacing that component.
These tests validate the functional implementations; they do not establish guest MPRO execution or hardware DSP accuracy.
The shared state utility currently requires native 64-bit integer support, so these component round trips are native tests.

The complete core format integrates SH-4, on-chip devices, HOLLY/GPU/Maple/memory card/optical drive/flash state, shared memory, media identity and core timing.
Wave RAM is included by the AICA controller section described below; callbacks, already delivered host audio packets and asynchronous drive caches are excluded.
Core-level continuation, media rejection and frame/input/video/audio comparisons are covered by the native tests described below.

The MPRO documentation search additionally inspected the original SDK R10.1 DSP effect descriptions and the FX Program Editor 1.10 documentation/configuration resources.
They provide original effect and module metadata, but no verified microinstruction bit map was established from those materials.
The editor's executable code was not used as an implementation reference, and the nonzero-MPRO development stop remains in place.

## Voice and mixer save-state components

`DcAicaSound` now saves all 64 voice register sets, fractional source positions, amplitude/filter envelope stages and levels, loop flags, LFO phase/absolute clocks/seeds, ADPCM decoder histories and effect routing.
Normal ADPCM retains its decoded sample history because the current model can continue using previously decoded samples after wave RAM changes; rebuilding that history from current RAM would alter continuation.
Long-stream ADPCM retains its monotonic decode position, prior/current interpolation samples and quantization step, and restores into a new history object bound to the owning AICA instance's existing wave RAM.
LFO and ADPCM counters above 32 bits are covered by the native component tests.
The MIDI component preserves both FIFO orders, overflow and the retained empty-read byte without consuming input or generating interrupt callbacks during restoration.
The owning AICA interrupt controller is included by the controller section described below.

The mixer retains master controls, monitor selection, the absolute sample clock and the partially accumulated stereo packet.
Active-voice and enabled-effect counts are rebuilt from logical state; per-sample DSP mix scratch is cleared before its next normal use.
The output callback and wave RAM binding remain those of the destination instance, and loading does not deliver an audio packet.
A pending packet prefix is restored so that the first subsequently delivered packet contains the same samples as uninterrupted execution.
Already delivered packets and host audio queue state are excluded.
Component loaders validate complete voice/mixer sections before committing, including decoder ranges, slot identity, active source binding and wave-memory bounds.

Tests compare subsequent PCM16, PCM8, normal ADPCM and long-stream ADPCM packets through loops, live wave writes, LFO updates, release and re-key.
A mixed 64-voice case checks slot identities, monitor positions and continued output, and an effect-only case checks scheduling-presence reconstruction.
Separate component tests cover fractional FEG continuation, all LFO waveforms including the functional noise policy, MIDI full/empty/overflow behavior, ADPCM lookahead and invalid/truncated states.
These serializers are included in public native save/load; the nonzero-MPRO execution stop remains, while non-bypass filtering currently uses the dry-audio approximation described above.

## Complete AICA component state

`DcAica` now owns the complete AICA component snapshot: 2 MiB wave RAM, all three timer registers and divider phases, interrupt enables/pending bits/level maps, reset and memory controls, RTC value/fraction/write-enable, ARM instruction deadline/fraction, internal DMA descriptor/cursors/remaining bytes/fraction, external-input latch and executed-instruction count.
The existing ARM, DSP, MIDI and sound serializers form its tagged sub-sections.
This component section is included in the complete native DC state format.

Loading validates on an isolated AICA instance first, including active DMA extent/cursor consistency and untruncated timer values.
It then copies wave RAM into the existing destination buffer and restores the existing ARM, DSP, MIDI and sound objects through their logical state interfaces.
The validated component sections are replayed for this commit; wave RAM is not serialized a second time.
Audio, external-input and interrupt callbacks remain destination-owned.
After commit, the system interrupt callback receives the restored level once; loading does not capture a new ARM interrupt number, acknowledge a request, consume MIDI or deliver/sample audio.
A latched external-input state requires a destination provider, whose source device state must be restored separately by the machine owner.

Continuation tests combine a running ARM memory-write loop, an in-flight internal DMA, prescaled timers and a partial audio packet with uneven master-clock batches.
They compare subsequent RAM, register/control state, deadlines, interrupt callbacks and stereo sample packets.
All DMA directions and clear modes resume partway through a transfer with independently checked destination values.
Other tests cover RTC wrap/fraction and an unfinished RTC write, interrupt-end rearm and read protection, MIDI completion levels, external-input stop flushing, the longest ARM instruction deadline, timer-width rejection and late/truncated-state atomicity.
These tests validate component continuation without adding hardware timing claims; MPRO execution and the actual filter signal path remain incomplete.

## SH-4 CPU component state

`Sh4` now saves active/inactive integer banks, both raw floating-point banks, PC/PR and control/MAC registers, FPUL/FPSCR, SR, the external IRL input, sleep and instruction-completion flags, and pending delay-slot metadata.
Loading restores register buffers in place and assigns SR/FPSCR directly, so their normal bank-swapping setters do not swap an already restored layout.
Floating registers retain raw 32-bit words, including NaN payloads, instead of being converted through host floating-point values.
The externally driven IRL input is stored separately from the HOLLY interrupt controller's combined pin level.
A pending branch retains its target and pre-link PR; RTE additionally retains the old privilege used only for fetching its slot instruction.
Positive odd PC/target values are retained because they can represent an upcoming guest address exception, rather than being normalized during loading.

Continuation tests cover BSR/RTS slots, slot address faults and PR rollback, RTE kernel-slot fetch with restored user data permissions, single/double FPU arithmetic, SLEEP interrupt entry, raw bank switching and a pending odd-PC fault.
Invalid and truncated CPU sections leave registers and bus state untouched.
This CPU section does not reset or serialize the bus, MMU, caches, timers, DMA or interrupt controllers; their component sections and remaining bus state must be integrated by the machine owner.
Public native Core save/load is implemented; full BIOS/game progression remains unfinished.

## SH-4 cache and MMU component state

`DcCache` saves all operand/instruction bytes, both complete tag arrays and CCR, including dirty lines, stale instruction data, invalid-line contents and operand-cache RAM.
Restoration bypasses normal CCR and cache-array writes, so it neither invalidates nor fills nor writes back a line and never invokes external memory callbacks.
Subsequent evictions use the destination cache's existing external memory binding.

`DcMmu` saves PTEH/PTEL/PTEA/TTB, MMUCR including URC/URB/LRUI, all 64 UTLB entries and all four ITLB entries with their assistance attributes.
The two TLB groups are restored independently, retaining ITLB translations made stale by a later UTLB replacement.
Loading does not perform translation, advance counters, select a replacement or pulse TLB invalidation.
Both component loaders validate complete layouts and field widths before modifying live state.

Tests cover dirty eviction through a new memory owner, stale instruction bytes, operand-cache RAM and a CPU continuation that simultaneously depends on an old ITLB mapping and old instruction-cache contents.
Further tests continue replacement/counter updates, touch the last UTLB entry, reproduce write-protection and miss exceptions, and reject invalid/truncated component sections without callbacks or partial updates.
These component sections are integrated into the complete native DC save/load path described below.

## SH-4 clock, timer and interrupt component state

`DcTmu` saves all three reload/counter/control sets, the start/output controls and the shared prescaler phase, including phases accumulated while channels are stopped and latched underflow flags.
`DcIntc` saves ICR/IPRA/IPRB/IPRC, the sampled NMI level and its pending edge without invoking the destination's NMI callback or acknowledging the request.
`DcCpg` saves FRQCR, standby controls, watchdog counter/control and fractional phase, bus/peripheral fractions, remaining PLL stabilization passes and preset, and an unconsumed power/manual watchdog reset request.
Loading bypasses register-write actions and reset consumption, so it neither starts a new stabilization delay nor clears standby or interrupt state.
Destination callbacks remain connected for subsequent real edges.

Continuation tests cover every supported TMU divider, all channels, stopped-phase activation, NMI low/pending states, the second PLL stabilization pass, both watchdog reset types and a composed SH-4/CPG/TMU/INTC interrupt boundary.
The composed case restores one master clock before simultaneous TMU/watchdog requests and retains the watchdog's higher programmed priority.
Invalid and truncated sections are checked before any live component state is replaced.

## SH-4 BSC and GPIO component state

`DcBsc` saves its bus configuration and keyed refresh registers, refresh divider phase, SDRAM mode values and precharge observations; the area-0 width strap must match the destination configuration.
The loader does not issue precharges, mode writes or refresh acknowledgments.
`DcGpio` saves both control/latch/sample sets, GPIOIC, the port-enable gate and current external driver masks/values.
Sampled inputs remain separate from newly changed driver values until the next bus-clock edge, preserving level-triggered interrupt behavior.
Tests resume refresh compare/overflow requests and write-zero-to-clear handling, retain SDRAM observations and GPIO latch/reset behavior, check destination strap mismatch rejection and preserve the pre-edge GPIO interrupt until the next actual sample.

These component sections are integrated into the complete native DC save/load path described below.
The changes preserve the current functional timing policies and do not establish hardware timing or BIOS/game progression.

## SH-4 serial component state

`DcSci` saves mode/baud/control/data/status/port registers, status-read history, active/preloaded transmit bytes, remaining frame and stop intervals, module-clock state and external input levels.
`DcScif` additionally saves both FIFOs, per-received-frame parity/framing metadata, read-before-clear overrun history, CTS/RTS inputs, queued/preloaded transmit state, receive timeout progress and the data-written/status handshake.
The absolute receive-idle counter is retained above 32 bits by the native state format.

Loading assigns sampled inputs and clock gates directly instead of using setters that can start transmission or reset a stopped module.
It neither emits output nor pops a FIFO, samples flow control, acknowledges errors or starts a new frame; destination transmit callbacks remain connected.
FIFO capacities, error masks, register fields, nullable shifter bytes and timing counters are validated before live state is replaced.

Continuation tests cover SCI synchronous/asynchronous and internal/external clocks at a preloaded stop bit, observed/unobserved error acknowledgment and module stop.
SCIF cases cover an active/preloaded/FIFO transmit chain, a clock-gated frame, CTS backpressure, a one-clock receive timeout boundary, long idle counts, per-frame errors and observed/unobserved overruns.
Truncated sections retain the entire prior device state without transmitting a character.
These component serializers preserve the current decoded-frame model and are integrated with native core save/load; pin-level framing remains separate work.

## SH-4 DMA component state

`DcDmac` saves all four channel register sets, DMAOR, transfer-end/error read history, the arbitration cursor and the pending DDT direction.
Pending external DDT requests require a stable device ID when saved and an explicit destination-owned endpoint resolver when loaded.
The resolver receives the raw saved address and direction; loading neither performs a transfer nor issues a replacement request.
Missing owner mappings, malformed descriptors and truncated sections fail before live DMA state is replaced.
Paused requests retain their owner while address errors or NMI inhibit scheduling.

Continuation tests cover all arbitration modes, transfer-end/error acknowledgment, both DDT directions, paused requests, owner resolution failures and SCIF loopback DMA on a fresh destination bus.
These component sections are integrated into the complete native DC save/load path described below.

## G2 DMA component state

`DcG2` saves programmed and latched channel registers, each 32-byte staging FIFO, partial longword position, transfer cursors, debug cursors, request/suspend flags, protection and timeout controls, arbitration cursors and the active serial deadline/ticket.
Loading validates temporary channel data before copying into the existing channel objects and does not access either bus or emit interrupts.
G2 provides stable `g2.0` through `g2.3` owner IDs for the SH-4 DMA registry and resolves only a queued request with a matching raw root address and direction.
The machine owner must restore G2 before resolving pending SH-4 DDT endpoints.

Tests resume both RAM/AICA directions at seven boundaries, including a queued DDT request, partial FIFO serialization and the second block, and check actual destination bytes and completion interrupts.
Additional tests retain suspension, reject mismatched endpoint bindings and preserve existing component state after a truncated section.
These component sections are integrated into the complete native DC save/load path described below.

## G1 DMA component state

`DcG1` saves its 32-byte FIFO, timing/protection registers, programmed controls, active and debug cursors, requested/transferred lengths, partial FIFO fill and fetch counts, serial deadline, optical drive stream epoch and pending root/DDT flags.
The board system mode is checked as configuration identity.
Loading validates all temporary fields before replacing the live controller and performs no device reads, root writes or interrupt callbacks.
G1 exposes the stable `g1` DDT owner ID and resolves only a pending write at the saved raw root address.
A restored request still checks the destination optical drive stream epoch before committing data, retaining cancellation when the stream changes.

Continuation tests use an independent chunked DMA input stream restored separately from G1 and cover RAM/DDT and direct VRAM destinations, partial FIFO fills and deadlines, non-block final padding, destination callback ownership, changed-stream cancellation and truncated-section atomicity.
These tests establish G1 continuation, not optical drive command/media restoration.
These component sections are integrated into the complete native DC save/load path described below.

## Optical drive and CD-DA component state

`DcOpticalDrive` saves the task file, command packet/sense/mode buffers, current transfer buffer and PIO positions, pending action/deadline, packet and mode-output cursors, read/seek/subcode cursors, media observations, interrupt/attention flags, standby counter and DMA stream generation.
`DcOpticalAudio` saves play/pause/repeat/scan state, the exact next stereo-frame position, one-shot terminal status and the retained current raw audio sector.
The retained sector is logical in-progress transport data, so restoring it does not depend on the destination adapter's sector-cache contents.

Loading validates temporary data and audio state before committing into the existing device and audio objects.
It does not poll or clear host events, issue seeks, read sectors, acknowledge interrupts or emit callbacks.
The machine owner remains responsible for media identity, external drive state and restoring system-bus interrupt observations; asynchronous seek completion still follows the attached drive.
Pending sector requests retry against the destination drive when normal preparation resumes.

Tests resume buffered PIO reads, partial command packets, partial SET_MODE output, command and soft-reset deadlines, pending sector/seek completion and standby counters above 32 bits.
Real `DcOpticalDrive`/G1/DMAC continuation tests restore all three components into new instances at five transfer boundaries and verify all 2048 destination bytes.
CD-DA tests cover a cached partial sector across pause/repeat, both scan directions and one-shot completion status; a late truncated audio section leaves the complete optical drive component unchanged.
These component sections are integrated into the complete native DC save/load path described below.

## Memory card component state

`DcMemoryCard` saves the visible 128 KiB image, the pending 512-byte write group, ordered-write phase and error history, protocol discovery/kill state, LCD pixels and timer state.
The timer includes the calendar, fractional master clocks, held buttons and alarm configuration.
Loading validates isolated LCD/timer data and storage/protocol fields before committing and preserves the destination LCD/timer objects, storage binding and key.
The attached storage is the authoritative visible image when present; restoring uses its existing `write8` path so region activation and host dirty tracking remain active without protocol resets.

Continuation tests cover both memory card unit addresses at every incomplete write phase, LCD output, a fractional leap-day boundary, held inputs, alarms, error recovery, killed-device clock progression, externally changed storage bytes and late-state rejection.
These peripheral sections participate in the Maple host DMA and complete native core snapshots.

## Maple controller component state

`DcMapleController` saves held digital/analog inputs, discovery/kill flags and both expansion slots, including complete memory card component sections.
Expansion presence and memory card unit numbers must match the destination configuration; unknown peripheral types fail explicitly rather than losing their state.
Loading validates all children in isolation and preflights every destination storage binding before committing any parent or child state.
Existing controller, memory card, LCD, timer and storage objects remain attached, and no reset or protocol exchange is performed during loading.

Tests cover ports A/D, held inputs across electrical reset, both memory card slots continuing partially completed writes, parent discovery/kill gates independent of child state, child object/storage ownership, late child truncation and configuration/binding mismatch atomicity.
The controller sections participate in the Maple DMA and complete native core snapshots.

## Maple DMA component state

`DcMaple` saves programmed controls/protection, descriptor and receive cursors, serial/reset/VBlank deadlines, hardware one-shot arming, abort and transport flags, source-block snapshots, the retained response and all configured controller/memory card sections.
The pending DDT address is now explicit logical state rather than only a captured callback variable.
The stable `maple` endpoint resolves only a pending request with the matching raw address and transfer direction.
Loading retains the destination RAM, controller and peripheral objects, stages every port before committing and performs no exchange, reset, RAM transfer or interrupt callback.
RAM contents remain the machine owner's responsibility.
Unregistered controller subclasses fail explicitly because their additional protocol state has no registered serializer.

Continuation tests cover both byte orders at seven transfer boundaries, independently visible receive blocks, cached source data after guest RAM changes, a partially received memory card write, VBlank delay/one-shot behavior, NMI-held DDT, software abort, no-response padding, completed transfers and the electrical reset deadline.
Late truncated port state leaves the active destination unchanged.
These component sections are integrated into the complete native DC save/load path described below.

## HOLLY interrupt, flash and SPG component state

`DcSystemBus` saves the HOLLY variant, normal/external/error sources, all priority masks and GPU/G2 trigger selections.
Loading assigns pending levels directly without producing a new G2 edge or losing the destination callback.
Tests restore all three interrupt tiers, clear them independently, retain external level ownership and verify that subsequent trigger edges reach the destination.

`DcFlash` saves the visible image, protected-sector configuration, command-unlock sequence, pending program address/value/deadline, erase selection and execution deadlines, selected sectors, polling toggle phase and autoselect/suspend/chip-erase/failure flags.
The existing destination storage binding and key remain in place; loading restores bytes through `write8` without issuing flash commands or resetting the operation.
Tests resume every command-input sequence, program and erase boundaries, selection-window extension, erase-suspended programming, failure polling, autoselect and unsuspendable chip erase.

`DcSpg` saves timing registers, external-trigger position, display position, horizontal/vertical counters, fractional pixel clocks, blank/field latches, per-line sampling state and completed-line/field counters above 32 bits.
Loading does not sample a line or emit blank, field or interrupt callbacks.
Continuation tests cover both clock rates and progressive/interlaced modes, uneven clock batches, a previously sampled pixel, stopped/restarted output and unchanged next-event predictions.
Late truncated sections and board/protection mismatches leave existing component state unchanged.
These component sections are integrated into the complete native DC save/load path described below.

## GPU palette, YUV and fog component state

`DcGpuPalette` saves all 1024 raw words and the active format without truncating previously written ARGB8888 entries when restoring a 16-bit format.
Loading retains the existing palette word buffer and object for destination texture consumers.
`DcGpuFog` saves the full interpolation table, table/vertex colors, density and color-clamp bounds.
Inverted clamp bounds remain stored register state and retain their existing development stop when rendering uses them.

`DcGpuYuv` saves its full 512-byte staging buffer, partial input position, output base/control, completed-block count and completed-frame latch, with destination VRAM size checked as configuration identity.
Loading performs no half-block commit, memory write or completion interrupt and keeps the existing destination VRAM/callback bindings.
VRAM bytes remain the owning GPU component's responsibility.
The completed count can belong to the previous frame after dimensions change; it is retained until the next accepted burst resets the count.

Tests cover all palette formats with retained raw high bits, fog/clamp output, YUV420/422 in combined/separate layouts at five input boundaries, independent expected output bytes, completed-frame dimension changes, replayable output-boundary failures and late-section rejection.
These component sections are integrated into the complete native DC save/load path described below.

## Tile accelerator component state

`DcTa` saves programmed/active allocation and clipping registers, parameter/object cursors, selected/ended lists, current material words, strip grouping/winding progress, sprite/modifier flags, retained face colors, half-received packets, converted vertices and per-tile object-block cursors.
Coordinates and pending packet words remain raw 32-bit data; retained normalized face colors use the shared floating-point state format.
The descending allocator's next cursor may be negative after a successful final allocation and is retained until a later access reports overflow.

Loading validates temporary data, including VRAM layout, list/vertex shapes and block extents, before replacing private collections and scalar state.
It does not initialize lists, emit parameters, write VRAM or invoke interrupts; the destination VRAM and callbacks remain attached.
VRAM bytes must be restored by the GPU owner separately.

Continuation tests resume a strip at five vertex boundaries, long intensity headers, retained face/offset colors, two-volume intensity, half-received sprites/modifiers, ascending/descending block chains and ended-list history.
They compare complete independent fixture VRAM, parameter sizes, object pointers and expected color words with uninterrupted execution.
A late truncated block table retains existing partial vertices and permits their original completion afterward.
These component sections are integrated into the complete native DC save/load path described below.

## GPU CORE rendering component state

`DcGpuRender` saves its register map, region cursor, retained tile coordinates, remaining functional tile deadline, sort/material state, primary/secondary color buffers, secondary-valid bits, depth buffer, shadow mask, depth-peeling history, fragment candidates and fog component.
The negative-infinity depth-peeling sentinel is retained without conversion to a finite depth.
Destination VRAM, palette and completion callbacks stay attached; their owning components restore VRAM bytes and palette state separately.
The modifier evaluator has only scratch data and destination-owned callbacks, so it requires no independent persistent section.

Loading validates temporary register, buffer, fragment and fog data before replacing live state.
It does not restart rendering, read display lists, write a framebuffer or emit completion.
The register mask helper is shared with normal writes so saved register validation follows the same implemented fields.

Tests resume at four deadline boundaries, preserve a retained background after its VRAM source changes, cover all seven framebuffer formats, retain depth rejection and secondary-buffer reads and continue both sorted and pre-sorted translucent output.
Expected framebuffer words are checked independently alongside uninterrupted VRAM/state comparisons.
Additional tests resume a repaired display-list stop, avoid repeating a completed render and retain all live state when the final fog section is truncated.
These component sections are integrated into the complete native DC save/load path described below.

## Complete GPU component state

`DcGpu` owns the complete current GPU snapshot: 8 MiB VRAM, direct-texture aperture modes, framebuffer/scanout/reset controls, active and programmed field addresses, scan-start position, presented and partially scanned images with display metadata, SPG, palette, YUV input, TA and CORE rendering state.
Already sampled pixels are retained separately from framebuffer bytes, so a later guest framebuffer write does not redraw the past portion of a restored field.

Loading validates the entire device graph on an isolated GPU instance before copying validated state into existing destination devices and VRAM.
It retains the destination SPG/TA/YUV/renderer/palette/fog identities and callbacks, without ticking clocks, emitting interrupts, exchanging input or rendering pixels.
The internal field-end/scan-position callbacks continue to reference the destination GPU owner.
Previously returned presented images remain immutable when later fields are published.

Tests resume progressive/interlaced scanout at five boundaries, preserve sampled pixels after framebuffer mutation, retain field-latched page flips and repeated-pixel/line metadata and restore simultaneous TA/YUV/CORE work.
They check explicit output colors and parameter pointers, compare full VRAM and logical snapshots and prove that a truncated final CORE section leaves existing live state unchanged.
These component sections are integrated into the complete native DC save/load path described below.

## Complete bus component state

`DcBus` saves main RAM, both store queues/QACR registers, exception/event registers and all implemented device sections.
The bus owns a combined stable endpoint registry for pending G1, G2 and Maple DDT requests.
Device ownership is restored before DMAC resolves its saved endpoint.

Loading preflights destination storage/topology, validates the complete graph on an isolated bus configured with matching controller/memory card slots, then restores existing destination buffers and device instances.
G2 edge delivery is suppressed while device interrupt levels are restored, and saved HOLLY observations are loaded last; loading must not turn an AICA IRQ update into a fresh DMA grant.
The destination G2 trigger callback is restored after loading.
The attached disc-drive objects, BIOS bytes, persistent-storage bindings and callback wiring remain destination-owned.
Flash and memory card restoration uses normal storage writes so switching cached persistent regions cannot reload stale pre-state bytes; plain SRAM backing lists remain in place while region adapters retain their normal activation behavior.
BIOS/media identity, CPU/core scheduling and external drive seek/generation restoration remain the core owner's responsibility.

Tests restore dirty cache writeback and store queues through destination RAM, preserve flash/memory card storage identities, continue all G1/G2/Maple DDT directions used by the current model and compare complete bus snapshots after uneven clock batches.
They also preserve a pending sector read on the destination drive, suppress IRQ-induced G2 edges during loading and retain live state after topology/binding mismatch or a truncated final interrupt section.
These component sections are integrated into the complete native DC save/load path described below.

## External drive observations for state restoration

Optical drive state now retains queued drive notifications without delivering them during saving, the captured host mount generation and seek readiness/error observations.
Saving moves notifications into a core-owned backlog; the next normal preparation still processes them at the original guest-visible boundary.
Isolated validation instances retain the saved observation instead of replacing it with their empty drive's generation.

After validating media identity, the owning core can explicitly rebind the saved observations to its destination drive.
Current and stale notification generations remain distinct, including when a stale source generation numerically matches the destination's current generation.
Unobserved media changes still invalidate the stream on normal preparation, while destination mount notifications do not invalidate an otherwise matching restored stream.
Pending seeks restart on the destination; already completed seek results are retained for one later protocol completion, including when the state is saved again before polling.
A pending media-change notification suppresses restarting an old seek.

Tests cover buffered reads on a new mount generation, deferred ready/tray notifications, stale generation collisions, unobserved generation changes, pending seek restart and success/failure completion across repeated restoration.
Rebinding is an explicit owner operation and is not called by the component/bus loader before media verification.
These component sections are integrated into the complete native DC save/load path described below.

## Public native core save/load

`Dc.saveState()` and `loadState()` now exchange the complete logical state of the current functional interpreter machine through the shared tagged format, version 4.
Version 2 added the sampled SCI transmit multiprocessor bit; version 3 adds the CPG deep-sleep latch.
Version 4 includes the retained G1 verification request, SH7750 RTC initialization registers, HOLLY setup registers and GPU SDRAM controls.
Earlier states are rejected rather than misreading subsequent device sections.
The core owns SH-4 state, master-clock count, the remaining CPU observation slice and the persistent development-stop reason; the bus owns memory and device sections.
Loading validates the header, CPU, complete bus graph, pending drive operations and the end of the file before committing any live CPU or RAM state.
Existing CPU, memory, device, storage and callback objects remain destination-owned.
After commit, the core rebinds drive generations and resumes valid pending seeks without delivering notifications early.
A completed CD-DA seek failure that has not reached the next sample is retained across restoration.

Identity includes BIOS bytes/presence, the complete loaded diagnostic program, drive state, all track/session fields, XA identity and subcode-provider capability.
Host mount-generation numbers and sector-cache contents are excluded.
The drive interface does not expose a whole-disc hash: matching TOCs do not prove identical disc contents, and callers must attach the same disc.
Different asynchronous drive/cache readiness can change timing after restoration, while already buffered sector/audio data remains part of logical state.
The shared format requires native 64-bit integer support; these state round trips are VM tests rather than dart2js state serialization.

Public API tests resume delay slots, partial CPU clock slices during ARM stepping, CPU execution with concurrent G2/Maple work, partial audio packets, presented video, controller input and memory card ownership.
They reject program/BIOS/TOC/session/XA/subcode mismatches, unloaded operation, trailing/truncated data and invalid resumed seeks without partially restoring live state.
The unmodified supplied BIOS was also saved at its existing stop after 2,311 successful execution observations and restored on a new core with matching PC, clocks and stop reason.
It still stops at PC `8c0000e4` on the unimplemented G1 verification write; save/load does not establish full BIOS boot, game compatibility or missing hardware behavior.

The 320-by-240 YUV window change allows the supplied game program to produce recognizable game imagery.
A further 10 million instructions complete without an unsupported-operation stop and emit 53,815 nonzero samples out of 141,312 captured audio samples.
The capture has visible border artifacts; audio quality, continuous playback and default-profile boot remain unverified.

An additional 30 million instructions after the first recognizable game capture complete without a development stop, request 192 further disc sectors and produce 423,406 nonzero audio samples.
This establishes continued program execution and asset reads, not completion of the opening movie or playable game progression.

Sending normal Maple Start input during the opening and executing another 30 million instructions reaches the title screen with its PRESS START BUTTON prompt.
That interval requests 1,198 further CDI sectors and emits 326,322 nonzero audio samples.
The title screen is generated by the unmodified game executable; no host replacement image or sound is used.

A second normal Start input reaches the main game menu with NEW GAME, LOAD, CONTINUE, TUTORIAL and OPTIONS after another 10 million instructions.
This interval reads 98 additional sectors and emits 140,800 nonzero samples.

Selecting NEW GAME reaches a sound-driver reset that clears/reuses ADPCM channels while the master volume is zero.
Bring-up provisionally retires a channel decoder when its source registers change under master mute or after key-off, allowing subsequent key-on to initialize a fresh decoder.
This is not a measured claim about live source-register latching; audible ADPCM source changes still stop explicitly.

After the muted-channel change, NEW GAME completes sound-driver reset and another 30 million instructions without an unsupported-operation stop.
The latter 20 million instructions request 1,078 sectors, including a native 1,554,432-byte drive DMA transfer, and restart the ARM driver with an uploaded DSP program.
The screen remains black during this resource-loading interval; playable stage rendering is not yet established.

A further 30 million instructions pass without a development stop and display the opening story caption AD 2489, with 293,971 nonzero audio samples and 192 additional sectors read.
This confirms story-entry output after NEW GAME, while gameplay remains unverified.

Skipping the next introductory movie reaches the animated NOW LOADING screen and reads 4,304 additional sectors in 20 million instructions.
The preceding interval displays changing movie scenes and continues producing nonzero audio.

After another 30 million instructions, the supplied game displays the player character in the first stage with HUD text.
The interval completes without a development stop, reads another 226 sectors and emits 88,174 nonzero audio samples.
This is the actual program's stage output under the explicit diagnostic profile; timing, audio effects, default-profile boot and broader compatibility remain incomplete.

The core-owned boot profile reaches the orange startup swirl and complete wordmark after 80 million instructions from cold BIOS/flash input, without separate GPIO-link, checksum-bypass or peripheral clock-scale arguments.
That no-disc run completes without a development stop and produces a 640-by-480 display; it emits no nonzero audio during the captured interval.

The public `CoreFactory.of('dc')` path with `DC_BOOT_BRINGUP=true` also loads boot/flash files in reverse selection order and advances the captured BIOS display through `runFrame(3)` without stopping.
This exercises the ordinary core interface; no GUI device setup or module-specific GUI branch is required.
After enabling the provisional profile by default in the factory, a separate cold run through `CoreFactory.of('dc')`, with neither a build define nor a loaded state, executes 80 million observations and reaches the complete startup logo at 640 by 480 without a development stop.
That run loads only the supplied boot ROM and flash, in reverse selection order, and reports 2,560,000,000 master clocks.
The lower part of the capture still contains visible rendering artifacts; this result establishes the default startup path, not strict hardware matching or complete BIOS navigation.
A further 50 million observations of the no-disc core-profile run retain the logo and repeatedly sample VSYNC at `0xa05f810c` from `0x8c00cb2e`; progression to the date dialog or main menu on this particular path remains unresolved.
Tracing that checkpoint shows that the 32-clock approximation lets interrupt service consume the VSYNC pulse before the foreground wait observes it: pulses occur, but the wait never returns during one million observations.
The core-owned profile now uses eight master clocks per instruction instead.
At the same checkpoint, the original BIOS returns through `0x8c00cb3a`, continues display initialization and executes five million additional observations without a development stop; this provisional timing adjustment is not a cycle-accurate SH-4 model.
The earlier 32-clock cold-boot captures above describe the previous profile revision.
Another 20 million observations with the eight-clock profile complete without a development stop and fade the logo to a plain background while native BIOS service processing continues; the date dialog and main menu are not yet established on this no-disc path.
Further execution leaves that service loop, clears the entire VRAM through the original BIOS stores and initializes the next display's data while video output is disabled.
The next 30-million and 40-million observation intervals both finish without a development stop; a disabled display during this initialization is not evidence of a rendered menu.
The following 20 million observations enable the 640-by-480 display, draw the animated blue BIOS background and reach the complete Set Date/Time dialog with its controller instructions and date fields.
This establishes post-logo BIOS UI rendering on the no-disc core-owned eight-clock profile without additional GPIO or clock arguments.
Five normal Maple Right presses select the date dialog's confirmation control, and A accepts it; the subsequent 16-million-observation interval completes without a development stop, removes the dialog text and emits 51,850 nonzero PCM samples.
The following 20 million observations complete without a development stop and continue the screen transition into another native memory-clear loop with output disabled; the main menu is still pending on this particular no-disc run.
Subsequent native execution completes that initialization and draws the main menu's Play, File, Music and Settings labels and animated 3D icons over the blue background.
This no-disc path uses only the core-owned boot profile and normal Maple input to advance from the earlier logo checkpoint through the date dialog to the main menu; the checkpoint originated under the preceding 32-clock profile, so it is not a complete cold-run claim for the revised eight-clock timing.
Menu rendering retains visible color and raster artifacts, and the current profile still bypasses BIOS verification and AICA DSP effects.

The supplied game also continues for another 100 million instructions from the later first-stage checkpoint without a development stop, reading 544 additional CDI sectors.
Captured frames advance through the stage sequence with changing characters and HUD values; this establishes ongoing game logic rather than a frozen retained frame.
That interval emits 16.004 seconds of stereo 44.1 kHz PCM with 1,355,634 nonzero samples, RMS amplitude approximately 4,668 and no samples at either signed 16-bit clipping endpoint.
These waveform measurements do not establish audible accuracy, DSP effect execution or completion of the stage; the run retains the explicit 32-clock diagnostic game profile and other documented bypasses.
A further 50 million instructions continue the stage sequence without a development stop, read another 300 sectors and emit 705,464 nonzero samples out of 705,536 samples.
An additional 30 million game instructions after the first-stage capture complete without a development stop and emit 422,866 nonzero audio samples.

## GPU interface DMA

GPU-DMA now transfers 32-byte bursts between system RAM and GPU registers or either VRAM aperture through the existing SH7750 channel-0 DDT arbiter.
Software and masked normal/external interrupt triggers honor enable/start state, retain active address/direction/length latches across setup writes, and abort when disabled.
Successful completion clears start and raises HOLLY normal interrupt bit 11 while retaining enable.
Keyed `SB_PDAPRO` protection and invalid start addresses report HOLLY error bits 7 and 6; debug counters expose current transfer positions.
A temporary independent execution of the original manual's palette-transfer sequence copies 64 bytes into ARGB8888 palette RAM and reads them back through reverse DMA with matching first/last words, completion set and no errors.
The supplied game also continues image/audio output after integrating this path; that game run does not establish that it exercises GPU-DMA itself.
Physical GPU bus latency and simultaneous root-bus engine timing remain functional approximations.
The unpublished state reader accepts earlier inactive eight-word register snapshots and includes current transfer latches and DDT ownership in new snapshots.

The same temporary DMA execution also transfers into the 64-bit VRAM aperture on a normal-interrupt trigger, confirms that disabled starts remain inactive, and reports error bit 7 for a transfer crossing its protected RAM window.
No new test suite was added during boot-first work; full device regressions remain deferred.

After GPU-DMA integration, a fresh 80-million-instruction BIOS run under the core-owned bring-up profile again displays the complete orange startup logo without a development stop.
The active game checkpoint also advances two further million instructions with image/audio output after loading both earlier and newly written inactive GPU-DMA register layouts.

## Sort-DMA

Sort-DMA now follows the original System Architecture section 2.6.5.3 start-link table and per-global parameter links through channel-0 DDT arbitration.
It supports 16-bit and 32-bit start entries, raw or 32-times-scaled relative links, per-block current-data sizes including zero as 8192 bytes, End Of List and End Of DMA markers, table-address advancement and the division counter.
The stream is passed unchanged to the existing TA input path; CPU-created links determine transfer order.
Normal completion raises HOLLY normal interrupt bit 20.
A stop request remains visible until the next scheduled DMA boundary and completes without a normal-end interrupt.
Failure to find a global parameter within 128 bytes terminates the transfer with HOLLY error bit 28, following the interrupt register table rather than the conflicting ISTNRM wording in section 2.6.5.3.
Active setup writes and prohibited link/size encodings remain explicit development stops.
An independent temporary execution transfers triangle data into the TA in all four width/shift combinations, advances the parameter buffer by 60 bytes and completes with no error.
The same execution exercises missing-global and stop-request paths.
Each start-link entry currently fetches an aligned 32-byte DDT burst; table prefetch occupancy and precise bus timing remain unverified.
After integration, the supplied game completes another 15 million instructions with image/audio output; those runs do not establish that this game exercises Sort-DMA itself.

## Horizontal framebuffer scaler

The SCALER_CTL horizontal-enable bit now performs the fixed 0.5/0.5 filter described in System Architecture section 3.4.11.1 before pixel-format packing.
Two source accumulation pixels produce one destination pixel, including across adjacent tile output ranges, and framebuffer X clipping uses destination coordinates.
A temporary two-tile Gouraud scene produces the exact per-channel average of its unscaled adjacent pixels with no mismatches, including a restricted output clip rectangle and untouched row padding.
Half-integer channel averages currently truncate; physical rounding remains unverified.
Vertical scaling and type-B flicker-free interlace output are described below.
SCALER_CTL Field Select is now retained without rejecting progressive rendering when type-B interlace is disabled, because the documented field selection applies only to that interlace mode.
An original Gouraud scene with Field Select set completes ordinary and half-width output, preserves clipping and padding, and raises the normal completion interrupt with no pixel differences from the existing progressive results.
The supplied game completes a further 100 million instructions without a development stop, emits 1,411,506 nonzero audio samples and reads 392 additional sectors under its diagnostic startup profile.
This game interval establishes continued stage output, not use of the new horizontal scaler.

## Independent raster and shading sample positions

HALF_OFFSET now independently selects the ISP coverage/depth sample position and the TSP color/offset/perspective sample position.
The existing separate texel sampling position remains independent of both.
Depth comparison and transparent ordering retain ISP samples, while Gouraud/perspective shading uses the TSP pixel samples.
A temporary triangle scene changes 91 coverage pixels when only the ISP offset changes, with identical colors on common covered pixels; changing only the TSP offset changes colors without changing coverage.
An overlapping depth plane also retains its ISP-selected occlusion when the TSP offset changes.
Identical default sample positions retain the existing arithmetic path.

## One-shot key execution during game progression

The supplied game stopped while clearing slot 48 from ADPCM control 0x410f to zero with full master volume; the model had restarted that voice at phase zero.
Global key execution now uses the key-off/release state to arm a source instead of restarting every inactive voice whose KYONB bit remains set after natural sample exhaustion.
Explicit key-off also arms an already exhausted voice, permitting the following key-on to restart it normally.
This functional latch policy follows the documented key-on/off strobe interface and the observed driver sequence; exact hardware gate timing remains unmeasured.
A temporary one-shot sequence retains its ended address after another slot is keyed on and returns to address zero after explicit key-off/key-on.
Re-executing the supplied game completes 50 million instructions, passes the prior ADPCM stop, displays stage characters and HUD icons and emits 705,330 nonzero audio samples.
Audible live ADPCM source changes that are not covered by this correction still stop explicitly; the earlier master-mute reconfiguration approximation remains separate.

A further 15 million instructions with direction/A/B input complete without a development stop after the one-shot correction, retain stage rendering and emit 211,956 nonzero audio samples.

## ADPCM address and loop reconfiguration during stage progression

The game requests a short-ADPCM voice at byte address 0x382c2, which is not four-byte aligned.
System Architecture section 8.4.5 requires four-byte alignment for ADPCM, whereas the original AICA sound-block manual describes byte-addressed SA and explicitly constrains only PCM16 alignment.
The strict default retains the System Architecture alignment check.
The explicit probe option `--byte-address-adpcm`, also included in the core-owned boot bring-up profile, permits byte-addressed format-2 ADPCM without rounding its source address or changing the source data.
PCM16 and long-stream alignment rules remain unchanged.
The policy belongs to the running configuration and must be repeated on probe resume; isolated chip validation preserves the destination policy.
A temporary sound execution decodes the expected first samples 47 and 94 from the specified byte address, retains strict alignment rejection by default and still rejects odd PCM16 sources.
The game next clears LPCTL during a releasing short-ADPCM voice, from control 0x306 to 0x106.
LPCTL is now treated as loop policy rather than an ADPCM source replacement, retaining decoder history until the unchanged end address is reached.
The same temporary execution ends the voice at its end address after loop-off rather than restarting its decoder.

The releasing voice then changes its source address immediately after loop-off.
Bring-up now retires its old decoder when source registers are reused after key-off, instead of applying new sample data to the old ADPCM history.
This can truncate the remaining release tail; precise release-source latching remains unfinished, and source replacement for held ADPCM voices remains prohibited.
With the explicit byte-address policy and release reuse handling, the game passes both stops and executes a further 10 million instructions, reads another 48 sectors and emits 141,312 nonzero audio samples while retaining the stage scene.
The nonzero perpendicular-triangle comparison setting remains unsupported because the available register description does not establish its comparison equation.

## Background modifier volumes

ISP_BACKGND_T.shadow now participates in both FPU_SHAD_SCALE modes.
Intensity mode scales the background base/offset shading colors before texture shading and fog, preserving the unmodified area outside the volume.
Parameter-selection mode reads the two TSP/texture words and doubled per-vertex attribute stride from the common ISP/TSP layout, selecting material zero or one by modifier area.
Flat color, Gouraud color and textured backgrounds share the existing primitive shader and sampling controls.
Background modifier masks are evaluated at the background depth separately from visible foreground depth, so a blended foreground still reveals the correctly shaded background.
A temporary rendering sequence produces the expected half-intensity flat/Gouraud/texture colors, independent red/green material selection in all three cases, and the expected blend over a shadowed background.
The supplied game separately completes 50 million further instructions with stage image/audio output; another six million instructions after the background changes also complete without a development stop.
Those game runs do not establish that the supplied game uses background modifier volumes.
The physical initial contents of untouched accumulation pixels and exact hardware modifier/raster timing remain unfinished.
Background trilinear materials now use the shared MIP derivative, bilinear sampling and per-pass weighting path, including both filter modes 2 and 3.
Each background initializes one weighted pass; software must supply any further polygon pass required to accumulate another level.
The shared normalized-mantissa MIP fraction and channel rounding remain functional approximations, not measured hardware behavior.
The existing background MIP scenario covers both weighted levels without adding another unit-test case; the obsolete unsupported-mode case was removed.
Its foreground setup also uses the current relative TA parameter segment and word-4 packed color layout.

## Vertical framebuffer scaler

SCALER_CTL now applies its 6.10 fixed-point vertical factor through row interpolation, with output height truncated to the documented inverse scale.
Reduction first applies the three-line Y_COEFF filter, using the outer byte for both neighboring rows and the center byte for the current row, divided by 256 and saturated per channel.
The first and last source lines repeat at filter boundaries as shown in System Architecture sections 3.4.11.2 and 3.4.12.1.
Enlargement interpolates unfiltered source rows; horizontal averaging and framebuffer packing follow vertical processing.
Output X/Y clips remain destination-coordinate limits and do not remove filter neighbors.
The renderer retains source-color tiles until render completion for scaled output so filtering and interpolation can cross both tile axes; unity-scale output retains its immediate tile path.
This functional staging does not reproduce the physical three-line buffer latency, and filtering/interpolation currently truncate fractional channel values without claiming measured rounding behavior.
Missing source tiles inside a required scaling rectangle stop explicitly rather than inventing neighboring pixels.
Type-B interlace uses factor 0x0800 and selects filtered even or odd source rows according to Field Select, writing a half-height frame through the programmed framebuffer output path.
Field Select remains inactive when type-B interlace is disabled; other interlaced scale factors stop explicitly because the documented mode requires 1/2 reduction.

Pending scaler tiles are device state, recorded only when present, and older eight-field inactive renderer layouts remain readable.
Original gradient scenes spanning four tiles exercise factors 0x0200, 0x0300, 0x0401, 0x0600 and 0x0800, including filter boundaries, horizontal half-width composition, output clipping and continuation after the first tile.
Their computed pixels match the specified functional formulas, with no differences after the pending-tile continuation.
The supplied game resumes its preceding state and executes another million instructions without stopping after integration, preserving 640-by-480 output and emitting 13,824 nonzero audio samples; this does not establish that this game interval uses vertical scaling.

## Type-B interlaced framebuffer output

The vertical scaler now supports System Architecture section 3.4.12.2 and SCALER_CTL bits 17/18: factor 0x0800, three-line filtering, and even/odd source-line selection for field one/two.
Output line y takes filtered source line 2*y or 2*y+1; the software-programmed framebuffer address and stride continue to control storage.
This produces 240 stored lines from 480 drawn lines without requiring the display reader to skip alternate stored lines.
Physical field synchronization and line-buffer latency remain outside this functional whole-render staging model.
Original gradient scenes check both fields, including clipping, horizontal 1/2 scaling and continuation with pending source tiles.
The same path also exercises a 480-line source to check the documented 240-line layout and the final source line of each field.

## Provisional AICA low-pass model

The normal core-owned boot bring-up profile enables `DcAicaSound.diagnosticFilterApproximation`; direct strict construction leaves it disabled.
The probe selects the model through `--core-bring-up` or, for individually configured diagnostic runs, `--approximate-aica-filter`.
This is an experimental signal path, not an implementation of the undocumented fixed-point AICA filter.
The standalone AICA manual's page-13 approximate graph supplies rough frequency anchors, interpolated logarithmically; the unplotted low range holds the first anchor rather than claiming a decoded coefficient.
The model uses the independent [W3C Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/) low-pass equations, provisionally converting the documented resonance dB setting to a biquad parameter.
The exact hardware interpretation of the resonance peak, coefficient mapping, rounding and saturation remain unresolved; this model must not be treated as hardware validation.
Documented maximum-cutoff/Q=4 pass-through returns unchanged samples, and reserved FLV values below 8 retain the earlier dry bring-up behavior.
Each voice filters the interpolated source before envelope/level/send mixing and resets its delay history at key-on.
Nonfinite filter output stops explicitly.

Nonzero delay histories extend the voice's existing six-field layout through an optional marker and two floating values; older dry voice layouts remain readable.
The flag is host configuration rather than serialized hardware state; individually configured diagnostic runs must repeat it when resuming a corresponding probe state.
Original sinusoidal checks with the approximate 1 kHz cutoff and minimum resonance retain approximately 0.707 RMS at 100 Hz, yield 0.501 RMS at 1 kHz and reduce 8 kHz to 0.00877 RMS; increasing resonance raises the response, documented through settings are unchanged, and cutoff sweeps across all resonance codes remain finite.
These checks establish properties of the approximation, not measured AICA transfer functions.
The supplied game runs five million instructions with the model, emits 70,656 nonzero samples without clipping and saves a voice with nonzero filter history; this does not establish audible correctness or DSP execution.

## Core-owned diagnostic disc loading

`Dc.bootUnscrambledDisc` loads through the core's attached `CdromDrive` and then invokes the existing native bootstrap handoff, returning the selected file metadata.
The ISO parser lives in `disc_bootstrap.dart` under the DC module and imports neither filesystem APIs nor disc-image formats.
The old tool helper is a thin adapter for callers that still use its import path.
Asynchronous sector reads use the drive contract's null/pending result and yield to the event loop; an optional wait callback permits a host adapter to settle its existing requests directly.
Data-track bounds, raw-sector sync and form, dual-endian ISO extents, IP.BIN identity and program-size bounds are checked before guest memory is replaced.
The caller must pause guest execution during loading.
Reset, state replacement, drive reattachment or CPU execution invalidates a pending request; invalidation is checked while reading and immediately before the handoff.
These host request generations are not guest save-state data.
The default entry remains the original IP.BIN bootstrap 2 at 0x8c00e000; loading is explicit and does not make a non-self-bootable CDI into a BIOS-authenticated disc.

The supplied CDI loads its original 2,490,368-byte program through the generic asynchronous path, enters that program after 5,202 observations and executes two million observations without a development stop.
This handoff check is not evidence of fresh game image/audio output after re-entry.
An original delayed-drive exercise invalidates requests through reset, CPU execution and drive replacement without writing the bootstrap/program area.

## Original license-entry frame service

The explicit first IP.BIN entry now enables normal VBlank-in at HOLLY interrupt level 2 after masking the old UI sources and selecting the low BIOS vector base.
The supplied BIOS's low interrupt table registers its generic HOLLY dispatcher at INTEVT 0x3a0, whereas the level-6 slot used by the former UI has no corresponding low-vector handler.
Clearing every mask blocked the frame service at 0x8c000776, and enabling the UI's level-6 mask alone did not fix that dependency.
Routing actual SPG events to the registered level-2 dispatcher lets the unmodified BIOS increment its frame counter at GBR+0x28; the counter is not patched and no interrupt completion is synthesized.
The observed counter advances from 11 to 12 and the license path leaves its wait, reaches native BIOS cleanup and proceeds into optical drive service processing.
This correction applies only to entry 0x8c008300; the established explicit bootstrap-2 path retains its preceding interrupt policy.
A following ten-million-instruction interval completes without a development stop, but does not yet reach the actual program entry; the full license-to-game path remains in progress.

## Executable entry observations

The probe now compares the candidate entry's instruction bytes against the original ISO executable's first 64 bytes before reporting `enteredDiscProgram`.
The shared physical address 0x0c010000 alone is insufficient because the BIOS UI can execute from that address after reloading its own program.
Reference-file reads are recorded separately and excluded from subsequent guest sector-read counts.
Replaying the full license path reaches that address after 1,764,864 observations but its prefix does not match, and subsequent execution initializes the BIOS UI rather than demonstrating game startup.
The established bootstrap-2 path reaches the same address after 5,202 observations with a matching prefix and continues the original game's BSS initialization.
The full-license path therefore remains incomplete, and the core API's default remains bootstrap 2 rather than promoting the failed path to the default.
The supplied IP.BIN advertises JUE and contains all three predefined region strings; these metadata alone do not prove the BIOS's later boot checks pass.

## Background MIP pass continuation

Background trilinear materials no longer stop before reaching the shared texture pipeline.
The retained background suite has 11 scenarios and checks both half-weighted MIP levels within its existing MIP scenario.
After this change, a one-million-instruction continuation of the supplied game from the existing stage state finishes without a core stop, captures a 640-by-480 stage frame and emits 14,328 nonzero samples out of 14,336.
This run retains the explicit diagnostic GPIO/timing, verification bypass, byte-addressed ADPCM and DSP bypass assumptions; it does not prove that the game exercised background trilinear materials or that DSP effects are implemented.

## Punch-through secondary accumulation routing

Punch-through objects can select secondary accumulation pixels as their source and write accepted pixels to either accumulation buffer.
Source selection occurs before PT_ALPHA_REF comparison, so the stored secondary alpha controls rejection instead of an unused vertex or texture alpha.
System Architecture sections 3.4.3 and 3.7.9.2 define the alpha comparison, opaque accepted output and source/destination selectors.
Accepted punch-through pixels retain their source RGB and write alpha 255 to the selected destination; they do not perform translucent blending.
An independent punch-through write initializes a secondary pixel without reading its old contents; an uninitialized secondary source remains an explicit unsupported operation.
The existing secondary-routing scenario now checks threshold rejection, acceptance and a punch-through secondary write consumed by a subsequent translucent flush.
No unit-test file or scenario was added; all 19 retained secondary-buffer scenarios pass.
The test fixture now uses the current TA relative parameter segment and word-4 untextured packed color layout.
This is a functional tile implementation; physical ISP cache grouping and timing remain incomplete.

## Functional framebuffer dithering

FB_W_CTRL bit 3 now enables ordered RGB dithering for 0555, RGB565, ARGB4444 and ARGB1555 framebuffer writes.
The provisional 4-by-4 Bayer ranks add a format-dependent sub-quantization offset before packing, saturating RGB at 255.
Alpha thresholding, stored alpha and K bits do not receive a dither offset; 24-bit and 32-bit formats remain unaffected.
The pattern uses framebuffer output coordinates after X/Y scaling, so clipping and tile boundaries do not restart its phase.
System Architecture's FB_W_CTRL description specifies the formats and enable bit but not the matrix; this pattern is a functional approximation, not a hardware match.
The existing background initialization scenario covers disabled/enabled RGB565 output without adding a test case; the retained 11 background scenarios pass.

An additional DSP source audit inspected AICA-related patent search results, the independent yamato AICA Hardware Reference v0.8 and the file listing of the original sound tool distribution.
No verified MPRO field-position specification was recovered; the original distribution lists FX Program Editor 1.10 but no separate instruction-format document.
Full guest DSP execution remains unfinished; the arithmetic-only executor described above does not substitute replacement effect algorithms for unsupported memory instructions.

## Background secondary destination

Background materials now honor DST Select when initializing accumulation pixels, including flat, Gouraud, textured, trilinear and modifier-selected paths.
A background can initialize secondary color and validity for later ordinary, translucent or punch-through objects to consume through SRC Select.
Background initialization still writes its shaded result directly instead of applying ordinary polygon source/destination blend factors.
A background SRC Select request remains unsupported because the secondary pixels have not yet been initialized for the tile.
Primary pixels left untouched by a secondary-only background provisionally start at transparent black; this is a functional initialization policy, not measured physical contents.
The existing background initialization scenario covers a flat secondary background, a textured secondary background and geometry-limited reads into the primary buffer.
The scenario count remains 11, with no additional unit-test file or test case.

## Synchronized strip buffers

FB_R_CTRL can enable strip buffers with a nonzero even strip-size field, decoded in 32-line units.
The functional CORE path writes consecutive horizontal region rows alternately into FB_W_SOF1 and FB_W_SOF2, wrapping the memory row within each strip.
Only two strips may be outstanding; the producer waits until scanout has consumed a buffer before overwriting it.
Raster capture reads those same buffers at each SPG scan position and retains the complete presented image even after a strip has been reused.
The bus scheduler bounds strip-mode time slices at scan positions so a batched tick cannot overwrite lines before they have been captured.
If the strip needed by scanout is incomplete, rendering is halted and HOLLY error bit 1 is raised, without a render-completion interrupt.
The implementation uses System Architecture section 3.4.13, the FB_R_CTRL/FB_W_SOF register descriptions and the RENDER hazard interrupt definition.
Functional tile latency remains two master clocks; this does not model physical render throughput or the documented first-frame spurious-hazard erratum.
X-clipped strip rendering remains unsupported; a following strip frame can wait for preceding scanout to finish, and ordinary framebuffer rendering is unchanged.
The available register description does not establish the 1024-line encoding, so a zero strip-size field remains unsupported.
Strip sizes, producer/consumer progress and waiting state are serialized with an optional renderer-header extension; older ordinary framebuffer and scaler states remain readable.
An original temporary 32-by-128 gradient scene compares the raster-captured strip image with ordinary framebuffer output, with zero pixel differences for 32-line and 64-line strips, a waiting-state continuation and the 64-bit VRAM aperture.
A deliberately late producer raises hazard bit 1, halts rendering and leaves render completion clear.
No repository unit-test case was added; the 34 retained background, secondary-buffer and public-core-state scenarios pass.

## Strip output scaling

Horizontal 1/2 scaling now computes the source region width from the output clip width before validating horizontal strip traversal.
The existing adjacent-pixel average then packs each output pixel at its scaled X coordinate within the selected strip buffer.
Vertical scaling and Type B field selection reuse the shared filter/interpolation path, with incremental source-row staging for strip output.
Scaled output is drained in complete tile rows, suspending before either unconsumed strip would be overwritten and resuming after scanout releases it.
Only a completed output strip becomes visible to the readiness check; completing source geometry alone does not mark the strip ready.
The staged source tiles and next output tile-row cursor survive state restore, including a wait for buffer reuse.
An interrupted render discards pending scaler output and still reports only the strip hazard interrupt.
Strip output retains the source rows needed for pending output and interpolation; physical line-buffer capacity, arithmetic precision and timing remain unmeasured.
Original temporary gradient scenes produce zero differences against ordinary framebuffer output for combined horizontal 1/2 scaling and vertical factors 0x200, 0x300, 0x401, 0x600 and 0x800, including Type B field-2 selection, 32/64-line strips, the 64-bit aperture and a suspended-drain continuation.
No repository unit-test case was added.

## Queued strip-frame continuation

After strip rendering completes, STARTRENDER can queue one following frame while the previous frame is still being scanned out.
The pending request retains both displayed strip buffers until the previous frame's final visible source row has been captured, then starts rendering from the programmed region base.
Releasing an earlier strip does not wake a pending next frame; only completion of the preceding scanout does so.
Render configuration is validated when the command is accepted, and further configuration writes remain blocked while the pending command is busy.
The current model requires the previous strip addresses, write stride and display strip configuration to remain unchanged until scanout completes.
This conservative whole-frame handoff does not model physical overlap of two frames through independently released strips.
The queue flag is retained in the existing optional strip-state flags, and hazard/reset discard pending work.
An original temporary two-frame scene changes the input colors after the first render completes, submits the next command during scanout and compares each presented frame with ordinary framebuffer output.
Both frame comparisons have zero differences, including a continuation restored while the command is queued; no repository unit-test case was added.

## Filter integration in the normal core profile

The ordinary DC module factory now uses the provisional low-pass model as part of its existing experimental boot bring-up profile.
Filter-envelope changes therefore affect interpolated source audio before envelope gain, direct mixing and DSP sends without requiring a tool-only register mutation.
The profile retains the policy across reset; direct strict construction retains its earlier dry policy.
The probe's core-profile option no longer overwrites that policy with a false default and reports the selected approximation in its JSON output.
An original 8 kHz PCM tone through the ordinary module factory produces RMS 0.00321 with the approximate 1 kHz filter setting, compared with 0.25895 on the dry path; the documented through setting has zero sample differences from the dry path.
These results prove that the functional filter reaches factory-created audio output, not the accuracy of its undocumented AICA coefficients or DSP execution.
No unit-test case was added.

## Incremental strip scaling

Scaled strip rendering now drains completed horizontal source rows before the entire scene has been rendered.
A destination tile row is emitted only when its complete visible output, interpolation neighbor and three-line filter neighbors are available.
A partial source batch never uses the current batch edge as the final image edge; edge repetition is reserved for completed source geometry.
After output advances, source tiles whose rows precede all future filter/interpolation reads are discarded.
When both destination buffers are occupied, the drain suspends without fetching another source tile and resumes before source rendering continues.
The final clipped output strip becomes ready when all its visible rows are committed, even if the source scene contains additional padding rows.
The source/drain phase and cursor are serialized in a new optional renderer header; the older whole-source drain header remains readable.
An original 16-tile source scene emits its first strip while rendering remains busy and retains two source tiles after that output; the blocked drain retains six tiles rather than the complete scene.
Existing temporary gradient comparisons retain zero differences for the previously covered scale factors, banked output and suspended-state continuations; ordinary framebuffer scaling and queued next-frame presentation also retain zero differences.
No repository unit-test case was added.
DSP instruction execution remains unfinished: the additional original SDK CustomDSP sample documents FPB loading but supplies no verified microinstruction field layout.

## Functional linear DSP memory instructions

NOFL=1 MRD and MWT now execute through the MPRO path, with MADRS, TABLE, NXADR, ADREB and ring-base addressing shared with the existing decoded backend.
Address generation captures the old address latch before the same step's ADRL update.
The original AICA manual's page-38 example places a step-1 read request on the step-2 memory cycle, enables IWT at step 3 and allows IRA to observe the new MEMS at step 4.
The functional executor implements that ordering: input reads precede IWT writes, a read result arrives two steps after its request, and a write commits on the following step.
Requests issued at step 127 continue into the following sample instead of being dropped or forced to complete early.
The pending physical addresses, write value, returned-read stage and available input latch are serialized through an optional DSP-state extension; older states retain the empty-pipeline interpretation.
IWT preserves the separate CPU-staged MEMS low-byte latch.
MRWINH bit 0 prevents actual DSP wave-memory cycles while leaving register-only arithmetic/effect output available; the model reports an unsupported inhibited access rather than reproducing a bus lockup.
NOFL=0 conversion and simultaneous read/write requests remain unsupported; dynamic address errors are checked when an instruction issues its transaction.
The 12-bit address-latch input is provisionally zero-extended into the address sum; signed extension has not been established on hardware.
The memory cycles execute within the existing sample callback and do not model independent CPU/DSP arbitration between microsteps.
An original MPRO sequence reads a RAM sample, writes half of it back, produces PCM through EFREG, observes old MEMS during same-step IWT and consumes a step-127 read in the next sample.
It produces effect 8192 from input 16384 and effect 4096 after input changes to 8192, with the same values written into wave memory.
The existing public partial-audio state case now includes a pending DSP memory read, preserving noise, arithmetic, memory and packet continuation together; all 44 retained public-state and DSP/register/memory scenarios pass without adding a test case.

## Upper address-latch range

The functional address generator now accepts all 12 ADRS_REG bits instead of rejecting values with bit 11 set.
The AICA register table and DSP gate diagram specify a 12-bit input; this model provisionally adds that unsigned field before the existing table/ring wrap.
The absence or presence of sign extension into the wider address adder remains unverified, so this does not establish hardware behavior for negative address offsets.
An original MPRO sequence loads ADRS_REG=0xfff through the shifter/ADRL path, reads word 4095 through ADREB and produces EFREG=2330 and 256 stereo PCM frames from the test sample.
The obsolete standalone rejection case was removed, and high-field wrap is covered inside the existing MADRS/NXADR case; the retained 13 DSP-memory scenarios pass.
An additional source audit checked the original SCSP User's Manual, the later Japanese SCSP DSP chapter and the original dAsms manual, without recovering an AICA floating-memory bit assignment.
An emulator-derived search excerpt was excluded from implementation evidence, and no floating converter was added from it.

## DSP execution in the ordinary boot profile

The normal module factory now executes supported arithmetic and NOFL=1 programs instead of unconditionally bypassing every nonzero MPRO image.
Static preflight failures are cached until MPRO changes or state is restored.
The bring-up profile bypasses the entire unsupported program and mutes its EFREG sends; it does not execute a supported prefix or replace missing instructions with invented effects.
Direct strict construction still stops on an unsupported program.
A previously issued memory request is retired before an unsupported replacement program is bypassed; memory inhibit still applies to that outstanding request.
The explicit `--bypass-aica-dsp` option retains full bypass, while `--fallback-aica-dsp` or `--core-bring-up` selects supported execution with whole-program fallback.
Probe JSON reports the fallback policy, actual bypass status and unsupported reason; APU inspection also reports the current DSP execution policy/status.
An original factory-created PCM scene confirms supported MPRO output, silence when a floating-memory request is introduced, renewed output after rewriting it to supported arithmetic and the retained explicit full-bypass behavior.
The supplied game continues one million instructions without stopping, produces a 640-by-480 image and 14,328 nonzero audio samples, while reporting unsupported floating conversion at step 3 as the fallback reason.
This does not establish execution of that game's DSP effect program or hardware accuracy; partial program-upload/start timing also remains unverified.
No unit-test case was added, and the retained 30 DSP/public-state scenarios pass.
