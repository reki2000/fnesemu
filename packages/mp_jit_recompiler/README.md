# mp_jit_recompiler

A block recompiler for emulator cores. A core translates guest code to `IrBlock`s, and `JitRuntime` runs them as x86-64, ARM64 or WebAssembly code.

- `IrBlock` is straight-line SSA code over explicit `i32` and `i64` values with side exits and one terminator: a static jump, a branch, a dynamic jump or an exit to the host. Blocks are keyed by (pc, tag); the tag carries guest state that the code depends on, such as a load in its delay slot.
- The context is an array of 32-bit words shared with the host. The first words hold the exit reason, pc and tag, the clock budget, a stop word and a fault address; the rest belong to the guest.
- Guest memory is mapped in pages to buffers from `JitRuntime.alloc`. Unmapped accesses call host functions or leave the block, and guards detect modified code.
- `JitDriver` runs the dispatch loop for an adapter. `JitDiagnostics` collects optional statistics.

`JitRuntime.native` returns the x86-64 backend on Linux, Android and Windows x64 hosts, the ARM64 backend on macOS, Linux, Windows and Android ARM64 hosts, or the Wasm backend on the Web. The Web backend works with both dart2js and dart2wasm. Unsupported hosts and policies that prohibit compiling Wasm return null. `JitRuntime.interpreter` interprets the IR on every platform and is the reference for the backends.

Every backend provides the same IR and runtime features on every platform: both value widths, both memory byte orders, floating-point operations, buffer sharing, entry counters and diagnostics. Frontends and cores therefore emit one lowering and do not query backend capabilities. A new IR feature is complete only when the reference executor and all compiled backends implement it. Block profiling is the one compiled-only diagnostic.

## Documentation

The documents are grouped by purpose.

| Purpose | Document | Contents |
| --- | --- | --- |
| Use the runtime | [Runtime](docs/runtime.md) | Memory mappings, code protection, linking and dispatch, `JitDriver`, buffer sharing, error handling |
| Use the runtime | [IR](docs/ir.md) | Value widths, byte order, floating-point operations, optimizer |
| Understand a backend | [Backends](docs/backends.md) | x86-64, ARM64, Wasm and the reference executor, host requirements, code publication |
| Write a frontend | [Frontend guide](docs/frontends.md) | State and clock contracts, register allocation, guarded specialization, validation |
| Check what a core does | [Core adapters](docs/cores.md) | Current defaults and options of PS1, N64, SS and 32X, with their frontend policies |
| Measure | [Diagnostics](docs/diagnostics.md) | Execution, compilation and native-return statistics and the interval metrics |
| Improve performance | [Performance guide](docs/performance.md) | Improvement cycle, measurement and acceptance protocol, synthetic x64 results |
| Plan | [Roadmap](docs/roadmap.md) | Pending proposals |

Component responsibilities and the core state/timing boundaries are defined in the [architecture](../../ARCHITECTURE.md). The command-line options of the benchmark tools are in the [core tools](../fnesemu_core/tool/README.md).

## Build and test

The package builds a small C memory-publication helper through `hook/build.dart`; a C toolchain is required. OS publication, cache synchronization and macOS entitlement rules are in [Backends](docs/backends.md#code-publication).

Use `dart run` or `dart test` for development. For a standalone AOT tool, use `dart build cli -t tool/example.dart -o /tmp/example` and run `/tmp/example/bundle/bin/example`. Preserve its `bundle/lib` directory when copying the executable. Bare `dart compile exe` and `aot-snapshot` do not package the native asset. Flutter builds package the helper automatically. Web builds do not compile it.

Run `dart test` for the host backend, `dart test -p chrome --compiler dart2wasm` for the browser backend, or `dart test -p node --compiler dart2wasm` for Wasm without a browser. `web_runtime_test.dart` requires an active compiled backend so browser CI cannot silently skip Wasm coverage.
