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

- Flutter GPU: how long a read must wait after the passes differs by backend and driver. `GpuDevice.create` checks it: it draws numbered frames with large texture uploads into two targets, reads them back, and keeps the first of these waits that reads every frame right: the completion of the passes; the completion and a second read; the completion, a frame of the engine and a second read; the completion, two frames and a second read. The check takes at most two seconds. When it cannot tell, because its shaders do not load or no frame comes while the app is hidden, it uses the completion alone; when every wait reads wrong, the longest. `GpuDevice.readBack` names the chosen wait. `settle` waits for the completions and the chosen frames and then reuses the oldest of four blocks of uniforms.
- Measured with the probe: Vulkan on an Android phone, Metal on macOS and the backend on Windows were right with the completion alone; the GLES backend on Linux, with Mesa, needed a frame and a second read, and still showed the frame before now and then with large uploads.
- Flutter GPU cannot list or choose the GPUs of a machine; the engine uses the one that the platform gives the app, such as the GPU that the graphics settings of Windows choose.
- WebGPU: `settle` waits for the submitted work, and `read` copies the target into a buffer and maps it. The headless Chrome of the tests runs WebGPU on SwiftShader with `--enable-unsafe-webgpu`.

## Shaders

`shaders/check.vert` and `shaders/check.frag` are the shaders of the check. Run `tool/build_shaders.sh` to compile them into `shaders/check.shaderbundle` with the `impellerc` of the Flutter SDK; rebuild it after a Flutter upgrade. A bundle that does not load makes the check fall back to the completion.

## Probe

`example/` is a probe app that measures, for each way to wait, how often a read returns an older frame and how long it takes. `.github/workflows/mp-gpu-probe.yaml` runs it on each platform; see `example/README.md`.
