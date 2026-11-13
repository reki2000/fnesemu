# mp_compute

Compute programs on the platform GPU through [wgpu-native](https://github.com/gfx-rs/wgpu-native) and `dart:ffi`.

A `ComputeDevice` compiles a WGSL module into a `ComputeProgram`: several entry points that share the buffers of bind group 0. Each binding is a read-write storage buffer, a read-only storage buffer, or a parameter block (at most one per program): a uniform buffer with one block per dispatch, bound with a dynamic offset, so that each dispatch of a run sees its own parameters. Dart writes and reads the buffers and runs lists of dispatches in order in one compute pass. A run can be submitted without waiting; writes are in queue order, so the next run may reuse the buffers at once.

## Build

`hook/build.dart` downloads a pinned wgpu-native release for the target, checks its SHA-256, and links its static library into the shim `src/mp_compute.c`. The archive is kept in the shared output directory of the hook, so a build needs the network only the first time. The release archives cover these targets:

| OS | Architectures | Backend |
|---|---|---|
| Linux | x64, arm64 | Vulkan |
| Windows (MSVC) | x64, arm64 | Direct3D 12, Vulkan |
| macOS | arm64, x64 | Metal |
| iOS | arm64 device, arm64 and x64 simulators | Metal |
| Android | arm64, arm, x64, ia32 | Vulkan |

Other targets, such as the web, get no shim, and `ComputeDevice.open` returns null. Each archive is extracted to its own directory. The shim links the static library of the release: on Windows with the DLL C runtime (`/MD`) and the system libraries of Direct3D 12 and Vulkan, on Apple targets with the Metal frameworks, and on Android with `liblog` and `libandroid`. Only the `mpc_` functions are exported. The shim also exports its allocator, so Dart does not look up the C library by name.

To update wgpu-native, change `_version` and the SHA-256 in `hook/build.dart`, and check the shim against the headers of the release.

## Adapters

`ComputeDevice.open` chooses the first adapter whose description contains the given name, or the first discrete GPU (else the first adapter) when no name is given, on Vulkan, Metal or Direct3D 12 (`ComputeDevice.nativeBackends`) by default. On Windows a GPU can appear once per backend; the first match wins. It enables adapters that report themselves as not conformant, such as dozen (Vulkan over Direct3D 12) in WSL. `ComputeDevice.adapterList` returns the descriptions of the adapters, such as `name (Vulkan, discrete)`, without opening a device, and `open` takes one of them as its adapter name.

The shim keeps one WebGPU instance per backend mask for the life of the process. Releasing an instance lets the Vulkan loader unload drivers whose threads still run, and the process then crashes at exit.

## Diagnostics

- `MPC_PROFILE=1` writes GPU timestamps around each dispatch, when the adapter supports timestamps inside passes, and prints the time per entry point and the longest dispatches of each run.
- `MPC_SKIP` lists entry point indices (digits) that runs leave out.

## Tests

```
dart test
```

The test skips when no adapter is available.
