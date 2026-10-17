# mp_jit_recompiler

A block recompiler for emulator cores. A core translates guest code to `IrBlock`s, and `JitRuntime` runs them as x86-64 or WebAssembly code.

- `IrBlock` is straight-line SSA code over explicit `i32` and `i64` values with side exits and one terminator: a static jump, a branch, a dynamic jump or an exit to the host. Blocks are keyed by (pc, tag); the tag carries guest state that the code depends on, such as a load in its delay slot.
- The context is an array of 32-bit words shared with the host. The first words hold the exit reason, pc and tag, the clock budget and a stop word; the rest belong to the guest.
- Guest memory is mapped in 4KiB pages to buffers from `JitRuntime.alloc`, separately for reads and writes. Unmapped accesses call the host read and write functions. Guards compare code words at block entry to detect modified code.
- `IrBuilder.guardMapped` exits before an access to an unmapped read or write page without calling the host. A core can then synchronize clocks and CPU state and execute the instruction in its interpreter. Removing write mappings for translated code pages also makes stores to upcoming instructions leave the block before changing them; the core must protect every writable alias of those pages.
- A run continues from block to block through link slots and a dynamic jump table, and returns to the host only when a block exits, a target is missing, the budget runs out or the stop word is set.

`JitRuntime.native` returns the x86-64 backend on Linux, Android and Windows x64 hosts, or the Wasm backend on the Web. The Web backend works with both dart2js and dart2wasm. Unsupported hosts and policies that prohibit compiling Wasm return null. `JitRuntime.interpreter` interprets the IR on every platform and is the reference for the backends.

The Wasm backend emits one small module per block and uses a common function table and a Wasm dispatcher loop to chain them without Dart calls or growing the stack. Registers, page tables, links and guest buffers occupy the same fixed 64MiB linear memory. Memory does not grow, so existing Dart views remain valid. Guest allocations beyond that capacity throw. The code cache clears at 4,096 installed blocks and recompiles on demand; it does not reclaim guest allocations.

Allocation and x86-64 code-protection failures throw; construction releases partially allocated native resources, and a runtime whose code-protection update fails cannot run again. Shared guest buffers remain valid until the owner calls `dispose`.

Run `dart test` for the host backend, `dart test -p chrome --compiler dart2wasm` for the browser backend, or `dart test -p node --compiler dart2wasm` for Wasm without a browser. `web_runtime_test.dart` requires an active compiled backend so browser CI cannot silently skip Wasm coverage.

## N64 preparation

The reference executor supports both value widths and both memory byte orders, using `BigInt` for exact i64 semantics on every Dart compiler. Compiled x86-64 and Wasm execution currently supports i32 little-endian blocks only. `supportsBlock` lets a future translator select an executor; installing unsupported IR throws before publishing or replacing code. This preparation does not enable an N64 recompiler.

- Arithmetic wraps at its declared width. Comparisons return i32; shift counts, conditions, guest addresses, block PCs and tags remain i32 independently of register width.
- `sext32`, `zext32` and `trunc32` make word-to-register conversions explicit. For example, an N64 word result can use `b.sext32(b.add(b.trunc32(register), b.c32(1)))` before storing to an i64 register.
- Context indices count 32-bit words. An i64 load/store occupies two consecutive words, low word first, independently of guest memory byte order. Runtime installation checks the whole access against the context size.
- `c64(BigInt)` and `c64Parts(low, high)` preserve exact constants without converting a 64-bit value through a JavaScript number.
- Memory accesses specify `IrEndian.little` or `IrEndian.big` and may transfer up to the value width, including 8 bytes for i64. The default remains i32 little-endian for PS1. A sign-extended big-endian word load can use `b.load(4, address, type: IrType.i64, signed: true, endian: IrEndian.big)`. Frontends handle guest alignment faults and split accesses that cross page mappings.
- Instruction guards also take an explicit byte order through `b.guard(address, instruction, endian: IrEndian.big)`, so a future N64 translator can compare decoded 32-bit instructions with big-endian code bytes.
- Unmapped read/write callbacks exchange raw little-endian packed bytes; IR applies the access byte order. The reference executor splits an 8-byte callback access into two 4-byte calls in address order. A future N64 bus adapter must honor this contract or exit to the CPU interpreter for device accesses.
- Helpers still use the existing three-i32-argument/i32-result ABI. The verifier rejects i64 helper arguments; a typed 64-bit helper ABI, native/Wasm i64 emission, floating-point lowering and TLB-aware fast paths remain future work.
