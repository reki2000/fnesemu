# mp_jit_recompiler

A block recompiler for emulator cores. A core translates guest code to `IrBlock`s, and `JitRuntime` runs them as host native code.

- `IrBlock` is straight-line SSA code over 32-bit values with side exits and one terminator: a static jump, a branch, a dynamic jump or an exit to the host. Blocks are keyed by (pc, tag); the tag carries guest state that the code depends on, such as a load in its delay slot.
- The context is an array of 32-bit words shared with the host. The first words hold the exit reason, pc and tag, the clock budget and a stop word; the rest belong to the guest.
- Guest memory is mapped in 4KiB pages to buffers from `JitRuntime.alloc`, separately for reads and writes. Unmapped accesses call the host read and write functions. Guards compare code words at block entry to detect modified code.
- `IrBuilder.guardMapped` exits before an access to an unmapped read or write page without calling the host. A core can then synchronize clocks and CPU state and execute the instruction in its interpreter. Removing write mappings for translated code pages also makes stores to upcoming instructions leave the block before changing them; the core must protect every writable alias of those pages.
- A run continues from block to block through link slots and a dynamic jump table, and returns to the host only when a block exits, a target is missing, the budget runs out or the stop word is set.

`JitRuntime.native` returns the x86-64 backend on Linux, Android and Windows hosts, or null elsewhere. Linux and Windows x64 CI exercise the native backend. `JitRuntime.interpreter` interprets the IR on every platform and is the reference for the backends. Allocation and code-protection failures throw; construction releases partially allocated resources, and a runtime whose code-protection update fails cannot run again. Shared guest buffers remain valid until the owner calls `dispose`.
