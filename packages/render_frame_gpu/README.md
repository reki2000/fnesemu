# render_frame_gpu

An experimental renderer that draws a core's `RenderFrame`s on the GPU of the platform through `mp_gpu`: Flutter GPU on native platforms and WebGPU on the Web.

## Use in the app

`GpuFrameSink.create()` returns a `RenderFrameSink`, or null when `mp_gpu` has no GPU on the platform; `GpuFrameSink.name` names the API. The app sets it as `CoreController.renderFrameSink` when the GPU setting selects it. A core that supports it then submits each 3D render as a `RenderFrame` and goes on without waiting. The sink draws the frame, reads the pixels back and passes them to `RenderFrame.onDrawn`, and the core writes them to its video memory. The pixels arrive about two frames later than with the core's renderer. The sink leaves the queueing, the targets and the check of the reads to the `GpuQueue` of `mp_gpu`: the frames submitted while others are drawn wait and are then drawn together, and when more than eight frames wait, the oldest ones are dropped. A frame that cannot be read back right is dropped too, and `onDrawn` is not called for it.

A core passes the same texel list for a texture that has not changed, and the renderer uploads a texel list only once.

Flutter GPU needs Impeller and its own enable setting, which works in release builds too:

| Platform | Setting |
|---|---|
| Linux | `fl_dart_project_set_enable_flutter_gpu` in `linux/runner/my_application.cc` |
| Windows | `DartProject::set_enable_flutter_gpu` in `windows/runner/main.cpp` |
| macOS, iOS | `FLTEnableFlutterGPU` in `Info.plist` |
| Android | the `io.flutter.embedding.android.EnableFlutterGPU` meta-data in `AndroidManifest.xml` |

Impeller is the default renderer on all of them; the Linux runner also enables it explicitly. On the Web, `mp_gpu` uses WebGPU where the browser has an adapter.

## Shaders

`shaders/frame.wgsl` holds the same shaders in WGSL for WebGPU; keep it in step with the GLSL sources. Run `tool/build_shaders.sh` to compile `shaders/frame.vert` and `shaders/frame.frag` into `shaders/frame.shaderbundle` with the `impellerc` of the Flutter SDK. In the bundle format `impellerc` writes the shaders of every backend, Metal, Vulkan and OpenGL ES, so one bundle serves all platforms. The bundle is checked in. Rebuild it after a Flutter upgrade; a bundle from another `impellerc` fails to load, and the sink is then not available.

## Capturing a frame

`core_headless run` writes the renders of the second to last frame with `--render-frames PREFIX`. Each render goes to `PREFIX_N.rframe` together with the colors of the core's own renderer.

## Replay app

`example/` draws one `.rframe` file, times it and compares the result with the colors of the core's renderer. It also sends frames through `GpuFrameSink`, every other one without triangles, and checks that the pixels come back for the right frame.

```
cd example
flutter build linux --profile
FLUTTER_ENGINE_SWITCHES=2 FLUTTER_ENGINE_SWITCH_1=enable-impeller FLUTTER_ENGINE_SWITCH_2=enable-flutter-gpu \
  build/linux/x64/profile/bundle/render_frame_gpu_example <file.rframe> [draws] [out dir] [--exit]
```

## Drawing

- A textured or Gouraud background is drawn as a plane over the whole frame. Where its colors leave the range, the frame is cut so that the clamped colors interpolate like the plane.
- The triangles of an object list are clipped to the tiles that refer to the list, so that a list used by only some tiles stays inside them.
- Volumes are drawn into the stencil. Each volume of a group inverts the stencil bit of its layer where its triangles are at or in front of the stored depth, and at the end of the group the layers are folded into bit 7, which marks the pixels inside. The inside batches are then drawn where bit 7 is set and their depth equals the stored depth. Volumes whose bounds do not overlap share a layer, so most groups take few draws.

## Known limits

- Volumes that apply to translucent triangles or to the background, the secondary accumulation buffer, bump maps and mipmaps are not drawn.
- Without a stencil in the depth format, volume and inside batches are skipped.
- Automatic sorting of translucent triangles is done per triangle, not per pixel. The core orders them by mean depth and compares each large triangle with the triangles it overlaps inside the overlap, so that a small triangle just behind a large tilted one is drawn first. Triangles that cut through each other cannot be ordered right. The sorted triangles blend over every opaque depth they are not behind and write no depth, so that layers at the same depth all blend.
- Renders through the strip buffer or the scaler stay with the core's renderer.

## Behavior of the Linux GLES backend

- A read of a texture often showed it as it was at the read before. The check of `mp_gpu` at start chooses a wait that reads right, a frame of the engine and a second read on this backend; see the README of `mp_gpu`. Now and then, mostly after a frame that uploaded many textures, a read still comes back as the frame before. The number that `GpuQueue` draws below each frame shows this, and the frame is dropped.
- A pass that draws nothing was not run. Every pass of a `GpuQueue` job draws its number, and a new target is drawn with its number until it comes back, which also tells whether the GPU works.
- The completion callback of a command buffer alone was not a sign that a read would show the result.

## Other cores

`CORES.md` describes how another core can draw its renders on the host GPU, and what N64 and PS2 will need.
