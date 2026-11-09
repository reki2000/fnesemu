# Drawing the renders of a core on the host GPU

This note collects what a developer needs to know to let another core, such as N64 or PS2, draw its 3D renders on the host GPU in the way that DC does. It describes the parts that exist, the contract between a core and the host, what is specific to DC, and what each core will need.

## Layers

| Layer | Package | Role |
|---|---|---|
| GPU device | `mp_gpu` | Offscreen drawing on Flutter GPU or WebGPU: programs, textures, targets, passes with per-draw state, `settle` and `read`. It knows nothing of cores. |
| Renderer and sink | `render_frame_gpu` | `FrameRenderer` draws one `RenderFrame` with its shaders; `GpuFrameSink` queues frames, draws them, reads them back and returns the pixels. |
| Frame and contract | `fnesemu_core` | `RenderFrame`, `RenderBatch`, `RenderTexture`, `RenderFrameSink`, `Core.rendersFrames` and `Core.renderFrameSink`. No Flutter imports. |
| App | root | Creates the sink at start, offers GPU or Software in the setup menu, and sets `CoreController.renderFrameSink`. |

The dependency directions follow `ARCHITECTURE.md`: the core never imports the renderer or `mp_gpu`, and `mp_gpu` never imports the core. A new core only adds code to `fnesemu_core` (its frame builder) and to `render_frame_gpu` (its renderer and shaders); the app does not change.

## The contract of a host render

The DC core uses these rules, and a new core should keep them:

1. When a render starts, the core builds a frame of everything the render needs: the vertices in pixels with y down and the depth as the reciprocal of w, the batches in drawing order with a packed state each, the textures as decoded RGBA texels with a sampler, and the per-render constants.
2. The core sets `onDrawn` and passes the frame to the sink. It does not wait. The sink calls `onDrawn` later with RGBA bytes, row by row, and the core converts them to its framebuffer format and writes them to emulated memory.
3. The emulated timing does not depend on the host. The core keeps the same render deadline and the same interrupts as with its own renderer. The pixels arrive one or more host frames later.
4. A counter of the core drops pixels that come back after a reset or a state load.
5. A render that the host cannot draw right stays with the core's own renderer. DC keeps the renders through the strip buffer and the scaler. A core decides this per render, not per game.
6. A texture that did not change keeps the same texel list (`Uint8List`), and the renderer uploads a list only once. DC keys its decoded texels by the texture cache and its count of changes with an `Expando`.

### What the late pixels mean

The sink returns the pixels after the device settles, so the emulated framebuffer holds the new render only some time after the core finished it. This is fine when the render goes to the display. It is wrong when the emulated program reads the render back soon after: as a texture of a later render, by the CPU, or by a copy engine. A core must find these cases and either keep them with its own renderer or wait for the pixels before the read. Find the cases from the hardware model (which units can read the target address, and when), not from a list of games.

## The sink

- `GpuFrameSink.create()` returns null when there is no GPU. The app falls back to the core's renderer.
- The frames that come while others are drawn wait, and are drawn together, each into a target of its own, and read back after one `settle`. When more than eight wait, the oldest are dropped, so a slow GPU loses renders instead of falling behind.
- A new target is checked with a white textured triangle until the white comes back. This also shows whether the GPU works at all.

## The read-back wait of mp_gpu

How soon a target can be read after its passes differs by backend and driver. `GpuDevice.create` checks it in at most two seconds and keeps the shortest wait that reads every frame right; `GpuDevice.readBack` names it. When the check cannot tell, it uses the completion of the passes. Measured with the probe in `packages/mp_gpu/example`:

| Backend | Wait |
|---|---|
| Vulkan on an Android phone, Metal on macOS, the Windows backend | The completion of the passes |
| GLES on Linux with Mesa | The completion, a frame of the engine and a second read; even then a frame with large uploads now and then shows the frame before |
| WebGPU | None besides the mapping of the read buffer |

So a core must not assume that the pixels come back within a fixed time, and the GLES backend may now and then return the frame before. Run the probe after a Flutter upgrade or on a new kind of device. Emulators and simulators do not show the behavior of real drivers.

## What is specific to DC

`RenderFrame` was made for the DC renderer and holds these DC concepts:

- Six passes in a fixed order: opaque, punch-through, volume, inside opaque, inside punch-through and translucent.
- Modifier volumes drawn into the stencil with layers and groups.
- A base and an offset color per vertex, four texture shading modes, and a punch-through alpha reference.
- A fog table of 128 entries with a scale, vertex fog, and table fog as alpha.
- Translucent triangles sorted by the core per triangle.

The shaders (`frame.vert`, `frame.frag`, `frame.wgsl`) and `FrameRenderer` follow these fields one to one. A new core should not force its pipeline into them.

## Adding another core

The recommended way:

1. Give the core its own frame type in `fnesemu_core` beside `RenderFrame`, with its own vertex layout, state packing and constants. Keep the shared parts the same: width and height, the vertex convention, decoded RGBA textures with the sampler bits of `RenderTexture`, `onDrawn`, `reference` and an `encode`/`decode` pair for captures.
2. Widen `RenderFrameSink` so that a sink takes the frames of every core, for example with a common base class of the frame types, and let `GpuFrameSink` pass each frame to the renderer of its type. Each renderer has its own `GpuProgram`, shaders and draw loop on the same `GpuDevice`.
3. Write the shaders in GLSL for `impellerc` and in WGSL, keep them in step, add them to the bundle with a build script like `tool/build_shaders.sh`, and check the bundle in. The WGSL source has the entry points `vertex_main` and `fragment_main` and all bindings in group 0, and the sampler of a texture takes the binding after it. Sample with `textureSampleLevel` where control flow is not uniform.
4. Set `rendersFrames` and `renderFrameSink` in the core, and build the frame at the point where the render starts.
5. Capture frames with `core_headless run --render-frames` and compare the GPU result with `reference`, the colors of the core's renderer, in the replay app. Count the pixels that differ by more than a small threshold, and look at the images. Check the Web build in headless Chrome with `--enable-unsafe-webgpu`.

### What mp_gpu offers and lacks

`mp_gpu` covers what the DC renderer needs. A new core will likely need more, and each addition must work on both backends:

| Feature | mp_gpu now | Flutter GPU | WebGPU |
|---|---|---|---|
| Blend factors on color and alpha together | yes | yes | yes |
| Blend operation other than add (subtract, reverse subtract) | no | yes | yes |
| Constant blend color | no | yes | yes |
| Separate factors for alpha | no | yes | yes |
| Color write mask | no | yes | yes |
| Depth compare, depth write, stencil compare, keep/zero/replace/invert, masks | yes | yes | yes |
| Back-face culling | no, all faces are drawn | yes | yes |
| Scissor | no | yes | yes |
| Load the old contents of a target instead of clearing | no | yes | yes |
| Sample a target in a later pass | no | yes, with shader read usage | yes |
| Mipmaps | no | yes | yes |
| Color formats other than RGBA8 | no | yes | yes |
| Read back the depth | no | not checked | yes |

The Flutter GPU column is from the API of the SDK; check each one on a real backend before relying on it.

## Notes for N64

- The core runs the display lists in `n64/graphics.dart` and rasterizes there (`triangle`, `textureRect`, `_combine`, `_put`). A frame would be built from the triangles and rectangles of a task, with the combiner and blender state of each.
- The color combiner and the blender have two cycles with many inputs. Write them as shader code from packed state, not as fixed blend factors. The blender mixes with the framebuffer color, which a fixed blend unit can express only in some modes; the other modes need the old target contents in the shader, or stay with the core.
- The framebuffer and the depth buffer live in RDRAM in 16-bit or 32-bit formats. Programs often read the framebuffer back, use it as a texture, or clear it by drawing into it as a framebuffer of another format. These are the late-pixel cases above. The depth buffer is also memory that a program may read.
- The renders keep the old framebuffer contents, so a pass must load them first: upload the RDRAM image as a texture and draw it, or add loading targets to `mp_gpu`.
- Coverage, dither and the depth modes for decals and interpenetration have no direct GPU counterpart. Start with the common modes and leave the others to the core.

## Notes for PS2

- The GS in `ps2/gs` takes primitives one by one through `writeRegister`, and `gs_raster.dart` draws them into the local memory at once. There is no render start. A frame would gather the primitives between points where the program can observe the result: a transfer from local memory to the host, a texture or CLUT that reads a target address, a change of the display, or a finish event.
- The blend formula takes any of the source color, the destination color and zero as its three color terms and any of three alphas or a fixed value as its factor, and subtracts. Plain blend factors cover only some combinations; the rest needs a blend operation, a constant color, or the old target contents in the shader.
- Render to texture is common: a target is read as a texture by the next primitives. Keeping such targets on the GPU needs targets that a later pass can sample, and a map from local memory addresses to targets. Without it every such read is a late-pixel case.
- The local memory holds the pixels in swizzled pages in several formats, and the frame and depth masks, the destination alpha test and 16-bit and 24-bit formats change how pixels are written. The read-back path must write the pixels in the right format and page layout, and keep the masked bits.
- CLUT textures, region repeat and mipmaps must be decoded by the core into RGBA, as DC does, or added to the shaders.
