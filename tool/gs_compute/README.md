# Compute GS checks

Tools that check the compute GS of the PS2 core (`packages/fnesemu_core/lib/src/core/ps2/gs/gs_compute.dart`) on the GPU through `packages/mp_compute`.

- `bin/frame_check.dart`: replays a GS frame trace through the core's software raster and through the compute GS, and compares the local memory and the displayed buffer.
- `bin/core_check.dart`: runs the whole core from a state twice, with the software GS and with the compute GS attached as the app attaches it, and compares the pictures of each frame.
- `bin/trace_stats.dart`: counts the primitives, states and transfers of a trace.

Traces come from `packages/fnesemu_core/tool/gs_trace_record.dart`.

## Run

```
dart run bin/frame_check.dart TRACE_DIR [--adapter NAME] [--rounds N] [--chunk STEPS] [--dump N]
dart run bin/core_check.dart STATE FRAMES OUT BIOS DISC [--adapter NAME] [--max-over8 N]
dart run bin/trace_stats.dart TRACE_DIR
```

`--adapter` takes a part of an adapter description, as `ComputeDevice.adapterList` of `mp_compute` lists them. Without it, the first discrete GPU is used, else the first adapter. In WSL, the Vulkan driver is dozen, which reports itself as not conformant; `mp_compute` enables such adapters.

For timing, build with `dart build cli --target bin/frame_check.dart`. `MPC_PROFILE=1` writes GPU timestamps around each dispatch and prints the time per entry point and the longest dispatches. `MPC_SKIP` lists entry point indices (digits) that are not dispatched, to measure the rest. `frame_check --dump N` prints the first N differing words of the local memory.

## Differences from the software raster

- Triangles of 2048 pixels or more and AA1 are not drawn.
- Texture and colour interpolation use 32-bit floats where the core uses doubles, so a few pixels differ by a step. Depth is exact.
- A draw that reads its own target pages reads them as they were before its batch, while the core reads the pixels it already wrote.
- The local memory is read back at each vblank and before each local to host transfer, which waits for the GPU.

## Notes on speed

- The bilinear and mipmap texel reads are the main cost of the raster step. The texels are read in loops so that the texel read, with its layout and CLUT lookup, is compiled once.
- The GS submits a run without waiting every `chunkSteps` steps (64; `frame_check --chunk`), so the GPU works while the core issues the rest of the frame. The buffers are written in queue order, so each run reuses them from the start.
- The CLUT loads of the core come one entry at a time, so `loadClut` of the GS must not allocate.
