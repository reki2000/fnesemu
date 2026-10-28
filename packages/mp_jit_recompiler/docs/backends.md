# Backends

`JitRuntime.native` selects the backend for the host. `JitRuntime.interpreter` is the reference executor and runs on every platform. All of them implement the same IR; see [IR](ir.md).

| Backend | Hosts | Block storage |
| --- | --- | --- |
| x86-64 | Linux, Android and Windows x64 | 64MiB code region, 2^19 link slots |
| ARM64 | macOS, Linux, Windows and Android ARM64 | The same native runtime as x86-64 |
| Wasm | Web (dart2js and dart2wasm) | One small module per block |
| Reference | Every platform | Interpreted IR |

## x86-64

- Immediate arithmetic and shifts are used, and constants are rematerialized.
- Block-local values are assigned to seven general-purpose registers (R8-R11, RBP, RSI, RDI) with a linear scan. Both widths use the same allocator and eight-byte spill slots. Values spanning possible helper calls remain in stack slots, and side exits retain values at their branch point. No register state is shared across block boundaries.
- The frame reserves 4,096 value slots, which bounds the block length.

## ARM64

The ARM64 backend supports the complete integer IR, both memory byte orders, callbacks, guards, side-exit snapshots and block linking. It runs integer blocks of PS1, N64 and SH-2 on all its hosts. Guest instructions outside a frontend's coverage still use its CPU interpreter.

- X19-X23 hold the context, read and write page tables, link slots and dynamic table. The trampoline saves the callee-saved registers it uses and LR, keeps SP aligned to 16 bytes and probes its stack frame in 4KiB steps. X18 stays reserved for the platform.
- SSA values use eight-byte stack slots and constants are materialized at use sites. The backend does not yet allocate SSA values to host registers.
- Floating-point add, subtract and multiply use the caller-saved V0/V1 registers. Binary32 operands widen to binary64 before evaluation and narrow afterward to match the reference executor.

### Checks

Run `dart test` in this package and the CPU and frontend tests in `fnesemu_core`. Run the same suites on native ARM64 CI hosts to exercise their OS memory APIs.

A Linux x64 cross-build was run under QEMU AArch64 user mode with an ARM64 libc sysroot. A temporary in-process driver invoked the existing test registration functions, avoiding subprocess emulation. Native and reference-IR paths both ran, covering randomized mixed-width operations, callbacks, code guards, shared-memory views, load delays, device boundaries, randomized finite floating-point bit patterns, signed zero, subnormals and overflow.

QEMU validates instruction encodings and Linux ARM64 execution semantics. It does not establish real ARM64 throughput, hardware cache coherence, or macOS, Windows and Android memory-policy behavior. An Android ARM64 NDK build of the C helper links, and a Flutter release APK for android-arm64 builds with the native asset. Record native OS CI and device results separately from these checks.

## Wasm

- The backend emits one small module per block and uses a common function table and a Wasm dispatcher loop to chain them without Dart calls or a growing stack.
- All Wasm runtimes allocate registers, page tables, links and guest buffers from one fixed 64MiB linear memory, so a runtime can map another runtime's guest buffer. Memory does not grow, so existing Dart views remain valid.
- `dispose` returns a runtime's allocations, and a finalizer returns those of a runtime dropped without `dispose`. Allocations beyond the free capacity throw. Dispose runtimes explicitly, since finalization timing is not guaranteed.
- The code cache clears at 4,096 installed blocks and recompiles on demand. It does not reclaim guest allocations.
- i64 values use Wasm i64 locals. Big-endian accesses and guards reverse bytes around little-endian linear-memory operations. Floating-point operations reinterpret the bit patterns as f32 and f64.

## Code publication

A build hook compiles the small C memory helper and packages it as a native asset. It keeps OS memory permissions and instruction-cache synchronization outside the emitter.

| Host | Code publication |
| --- | --- |
| Linux / Android | Anonymous allocation, RW-to-RX `mprotect`, and `__builtin___clear_cache` |
| Windows | `VirtualAlloc`, `VirtualProtect`, and `FlushInstructionCache` |
| macOS | One `MAP_JIT` arena, per-thread JIT write protection, and `sys_icache_invalidate` |

On macOS the arena provides up to 32 concurrent 64MiB runtime slots. The 2GiB reservation is virtual address space. Pages are populated on demand, and released slots are advised unused and reused. Keeping one arena accommodates the hardened runtime's single-region limit. The write-protection transition, byte copy and cache synchronization complete in one native call before returning to Dart. The release app includes the JIT entitlement. The optional JIT callback allowlist entitlement is not implemented.

OS allocation and protection use the host page size rather than assuming 4KiB, including on hosts with 16KiB pages. Guest page-table granularity is independent. Publication and buffer sharing do not support concurrent execution of the same runtime from multiple threads.

The relevant platform contracts are documented in [AAPCS64](https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst), [JIT memory publication on macOS](https://developer.apple.com/documentation/apple-silicon/porting-just-in-time-compilers-to-apple-silicon) and [instruction-cache synchronization on Windows](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-flushinstructioncache).
