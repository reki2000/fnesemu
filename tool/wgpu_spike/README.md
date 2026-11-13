# Compute GS on wgpu-native

A prototype of a GPU layer of our own for the PS2 GS: the 4 MiB local memory is a storage buffer, and compute shaders draw into it with the pixel pipeline of the core's software raster (`GsRaster`). Dart drives it through `dart:ffi` and a thin C shim over [wgpu-native](https://github.com/gfx-rs/wgpu-native).

- `native/gsgpu.c`: the shim. It runs a list of steps (setup, raster, CLUT, upload, copy, snapshot) in one compute pass.
- `gs.wgsl`: the steps. The raster step owns one 16x16 tile per workgroup and draws the primitives of a batch in order.
- `lib/compute_gs.dart`: a `GsResidentSink` with the `gsPrimitiveHook` of the core. It orders the work into steps by the pages each one reads and writes.
- `bin/frame_check.dart`: replays a GS frame trace through the core and through the compute GS, and compares the local memory and the displayed buffer.
- `bin/trace_stats.dart`: counts the primitives, states and transfers of a trace.

Traces come from `packages/fnesemu_core/tool/gs_trace_record.dart`.

## Build and run

```
WGPU_NATIVE=/path/to/wgpu-linux-x86_64-release ./build.sh
dart run bin/frame_check.dart TRACE_DIR --adapter NVIDIA
```

`WGPU_NATIVE` is an unpacked wgpu-native release. In WSL, the Vulkan driver is dozen, which reports itself as not conformant; the shim enables such adapters.

For timing, build with `dart build cli --target bin/frame_check.dart` and set `GSGPU_LIB` and `GSGPU_WGSL` to `build/libgsgpu.so` and `gs.wgsl`.

`GSGPU_PROFILE=1` writes GPU timestamps around each step and prints the time per step kind and the longest steps. `GSGPU_SKIP` lists step kinds (digits) that the shim does not dispatch, to measure the rest. `frame_check --dump N` prints the primitives of step N.

## Notes on speed

- The bilinear and mipmap texel reads are the main cost of the raster step. The texels are read in loops so that the texel read, with its layout and CLUT lookup, is compiled once; this cut the raster time to about a fifth.

## Not done

- Triangles of 2048 pixels or more, AA1.
- Texture and colour interpolation use 32-bit floats where the core uses doubles, so a few pixels differ by a step. Depth is exact.
- A draw that reads its own target pages reads them as they were before its batch, while the core reads the pixels it already wrote.
- Local to host transfers read the whole memory back synchronously.
- Display: the test reads the display buffer from the memory; there is no scanout step yet.
