# ARM64 backend

The shared backend runs PS1, N64 and SH-2 integer blocks on macOS, Linux, Windows and Android ARM64. It supports i32/i64 values, both memory byte orders, static/dynamic links, guards, precise side-exit snapshots and the existing three-i32 helper ABI. Guest instructions outside a frontend's coverage still use its CPU interpreter.

## ABI and memory publication

X19-X23 hold the context, read/write page tables, link slots and dynamic table. The trampoline saves the callee-saved registers it uses and LR, keeps SP aligned to 16 bytes and probes its stack frame in 4KiB steps. X18 remains reserved for the platform. SSA values use eight-byte stack slots and constants are materialized at use sites; host register allocation remains future work.

A build hook compiles the small C memory helper and packages it as a native asset. It keeps OS memory permissions and instruction-cache synchronization outside the emitter:

| Host | Code publication |
| --- | --- |
| Linux / Android | Anonymous allocation, RW-to-RX `mprotect`, and `__builtin___clear_cache` |
| Windows | `VirtualAlloc`, `VirtualProtect`, and `FlushInstructionCache` |
| macOS | One `MAP_JIT` arena, per-thread JIT write protection, and `sys_icache_invalidate` |

On macOS the arena provides up to 32 concurrent 64MiB runtime slots. The 2GiB reservation is virtual address space; pages are populated on demand, and released slots are advised unused and reused. Keeping one arena accommodates the hardened runtime's single-region limit. The write-protection transition, byte copy and cache synchronization complete in one native call before returning to Dart. The release app includes the JIT entitlement. This does not implement the optional JIT callback allowlist entitlement.

OS allocation/protection uses the host page size rather than assuming 4KiB, including on hosts with 16KiB pages. Guest page-table granularity remains independent. Native buffers can be explicitly shared by sequential CPU runtimes; the allocating owner must outlive all borrowers. Publication and buffer sharing do not support concurrent execution of the same runtime from multiple threads.

The relevant platform contracts are documented in [AAPCS64](https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst), [JIT memory publication on macOS](https://developer.apple.com/documentation/apple-silicon/porting-just-in-time-compilers-to-apple-silicon), and [instruction-cache synchronization on Windows](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-flushinstructioncache).

## Checks

Development checks use `dart test` in this package and CPU/frontend tests in `fnesemu_core`. Run the same suites on native ARM64 CI hosts to exercise their OS memory APIs. The host toolchain must contain a C compiler. Standalone tools require `dart build cli` so the native asset accompanies the executable; see the README.

A Linux x64 cross-build with Dart 3.13.5 was run under QEMU AArch64 user mode 6.2 with an ARM64 libc sysroot. A temporary in-process test driver invoked the existing test registration functions and `test_api` live tests, avoiding subprocess emulation requirements. It passed 298 runtime/PS1/N64/SH-2 checks, including randomized mixed-width operations, callbacks, code guards, shared-memory views, load delays and device boundaries. Native and reference-IR paths both ran.

QEMU validates instruction encodings and Linux ARM64 execution semantics. It does not establish real ARM64 throughput, real hardware cache-coherence behavior, or macOS/Windows/Android memory-policy behavior. The final SH-2 subset also passed 65 checks after the chaining/alignment and reset-mapping changes. An Android ARM64 NDK build of the C helper links successfully, and a Flutter release APK targeting android-arm64 built with the native asset included. Record native OS CI and device results separately from these checks.

## Limited floating-point emission

ADD/SUB/MUL on binary32/binary64 bit patterns use caller-saved V0/V1. Binary32 operands widen to binary64 before evaluation and narrow afterward to match the reference executor. Linux ARM64 AOT under QEMU passed 92 floating-point/N64 checks, including randomized finite bit patterns, signed zero, subnormals, overflow/underflow, shared register layouts and CPU fallbacks. QEMU was used for correctness only; the throughput measurements use native x64 execution.
