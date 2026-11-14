# Compute GS checks

Tools that check the compute GS of the PS2 core (`packages/fnesemu_core/lib/src/core/ps2/gs/gs_compute.dart`) and the compute CORE of the DC core (`packages/fnesemu_core/lib/src/core/dc/dc_compute.dart`) on the GPU through `packages/mp_compute`.

- `bin/frame_check.dart`: replays a GS frame trace through the core's software raster and through the compute GS, and compares the local memory and the displayed buffer.
- `bin/core_check.dart`: runs the whole core from a state twice, with the software renderer and with the compute program attached as the app attaches it, and compares the pictures of each frame. `--core` selects `ps2` (the default) or `dc`.
- `test/dc_render_test.dart`: runs the DC renderer tests of `packages/fnesemu_core/test/core/dc/gpu_*_test.dart` with the compute program attached to each renderer. It is skipped when there is no adapter.
- `bin/trace_stats.dart`: counts the primitives, states and transfers of a trace.
- `bin/dc_capture.dart`: runs the DC core from a state and writes the inputs of renders (registers, palette and VRAM) to capture files.
- `bin/dc_replay.dart`: replays captures on the CPU and on the compute program, and prints the differing pixels and the fastest of 10 renders of each.
- `web/dc_render_check.dart`: replays captures in a browser on WebGPU, as `dc_replay` does, and posts the result to `/report`.

Traces come from `packages/fnesemu_core/tool/gs_trace_record.dart`.

## Run

```
dart run bin/frame_check.dart TRACE_DIR [--adapter NAME] [--rounds N] [--chunk STEPS] [--dump N]
dart run bin/core_check.dart STATE FRAMES OUT BIOS DISC [--core ps2|dc] [--bios DIR] [--jit] [--adapter NAME] [--max-over8 N]
dart test test/dc_render_test.dart
dart run bin/trace_stats.dart TRACE_DIR
dart run bin/dc_capture.dart STATE FRAMES OUT BOOT DISC [--bios FILE] [--jit on|off] [--count N]
dart run bin/dc_replay.dart CAPTURE... [--adapter NAME]
dart compile wasm -O2 web/dc_render_check.dart -o OUT/check.wasm
```

`dc_render_check` needs a page that loads `check.mjs` and `check.wasm`, and a server that takes the report as a POST to `/report`. It takes the capture URLs as `?c=NAME&c=NAME`.

`--adapter` takes a part of an adapter description, as `ComputeDevice.adapterList` of `mp_compute` lists them. Without it, the first discrete GPU is used, else the first adapter. In WSL, the Vulkan driver is dozen, which reports itself as not conformant; `mp_compute` enables such adapters.

For timing, build with `dart build cli --target bin/frame_check.dart`. `MPC_PROFILE=1` writes GPU timestamps around each dispatch and prints the time per entry point and the longest dispatches. `MPC_SKIP` lists entry point indices (digits) that are not dispatched, to measure the rest. `frame_check --dump N` prints the first N differing words of the local memory.

## Differences from the software raster

- Triangles of 2048 pixels or more and AA1 are not drawn.
- Texture and colour interpolation use 32-bit floats where the core uses doubles, so a few pixels differ by a step. Depth is exact.
- A draw that reads its own target pages reads them as they were before its batch, while the core reads the pixels it already wrote.
- The local memory is read back at each vblank and before each local to host transfer, which waits for the GPU.

## Differences of the DC compute CORE

- Edge, depth, texture and colour planes use 32-bit floats on the GPU. Shared edges are flipped to one direction before their coefficients are rounded, so neighbouring triangles neither crack nor overlap.
- The software renderer steps perspective rows linearly between exact span ends. The GPU evaluates each pixel exactly, so textured pixels can differ by several steps per channel, and `core_check --core dc` can exceed the default limit on scenes with large textured triangles.
- A check that the software renderer throws at a pixel is reported by the GPU as an error code, and the core throws it when it reaches that region entry.
- Only the VRAM pages inside the texture spans of a render that were written since they were last copied are uploaded.
- The tiles of a render are written to VRAM only when a CPU or DMA access, the scanout, the next render or a saved state needs them, so the CPU, the DMA and the display see the same bytes as without the wait. The render tests read VRAM directly, so `dc_render_test` turns this off with `deferTiles`.

## Notes on speed

- The bilinear and mipmap texel reads are the main cost of the raster step. The texels are read in loops so that the texel read, with its layout and CLUT lookup, is compiled once.
- The GS submits a run without waiting every `chunkSteps` steps (64; `frame_check --chunk`), so the GPU works while the core issues the rest of the frame. The buffers are written in queue order, so each run reuses them from the start.
- The CLUT loads of the core come one entry at a time, so `loadClut` of the GS must not allocate.
