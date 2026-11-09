# mp_gpu

Offscreen drawing on the GPU of the platform. `GpuDevice.create()` picks the API and returns null when none is available:

| Platform | API |
|---|---|
| Native platforms | Flutter GPU, which needs Impeller and its enable setting |
| Web (Wasm) | WebGPU through `dart:js_interop` |
| Others | none |

## Model

- `GpuDevice.program` loads a program from a `GpuProgramSource`, which names the shader bundle for Flutter GPU, the WGSL source for WebGPU, the vertex attributes and the bindings. The WGSL source has the entry points `vertex_main` and `fragment_main` and all bindings in group 0; the sampler of a texture takes the binding after the texture.
- `GpuDevice.texture` uploads an RGBA texture, and `GpuDevice.target` creates a color target with a depth and stencil buffer.
- `GpuDevice.pass` starts a pass over one or more vertex arrays. Uniforms, textures, the draw state (`GpuState`) and the stencil reference are set per draw, as in Flutter GPU. The WebGPU backend keeps a pipeline for each state and a bind group for each set of textures, and writes the uniforms of a pass into one buffer with dynamic offsets.
- `GpuDevice.settle` waits until the passes ended so far can be read, and `GpuDevice.read` returns the RGBA bytes of a target.

## Backend behavior

- Flutter GPU: `settle` waits for a frame of the engine and then reuses the oldest of four blocks of uniforms; `read` reads the target twice, because the GLES backend often showed a texture as it was at the read before. A read after a pass that uploaded many textures still came back as before now and then.
- WebGPU: `settle` waits for the submitted work, and `read` copies the target into a buffer and maps it. The headless Chrome of the tests runs WebGPU on SwiftShader with `--enable-unsafe-webgpu`.

## Probe

`example/` is a probe app that measures, for each way to wait, how often a read returns an older frame and how long it takes. `.github/workflows/mp-gpu-probe.yaml` runs it on each platform; see `example/README.md`.
