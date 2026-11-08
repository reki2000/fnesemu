# render_frame_gpu

An experimental renderer that draws a core's `RenderFrame`s with Flutter GPU.

## Use in the app

`GpuFrameSink.create()` returns a `RenderFrameSink`, or null when Flutter GPU is not available. The app sets it as `CoreController.renderFrameSink` when the GPU setting selects it. A core that supports it then submits each 3D render as a `RenderFrame` and goes on without waiting. The sink draws the frame, reads the pixels back and passes them to `RenderFrame.onDrawn`, and the core writes them to its video memory. The pixels arrive about two frames later than with the core's renderer. The frames submitted while others are drawn wait and are then drawn together, each into a target of its own, and read back after one frame of the engine. When more than eight frames wait, the oldest ones are dropped.

A core passes the same texel list for a texture that has not changed, and the renderer uploads a texel list only once.

Flutter GPU needs the engine switches `enable-impeller` and `enable-flutter-gpu`. The Linux runner sets them through `FLUTTER_ENGINE_SWITCHES`, which only debug and profile engines read, so release builds on Linux draw in software. On the Web, the library exports a stub whose `create()` returns null.

## Shaders

Run `tool/build_shaders.sh` to compile `shaders/frame.vert` and `shaders/frame.frag` into `shaders/frame.shaderbundle` with the `impellerc` of the Flutter SDK. The bundle is checked in. Rebuild it after a Flutter upgrade; a bundle from another `impellerc` fails to load, and the sink is then not available.

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

## Known limits

- Modifier volumes, the secondary accumulation buffer, bump maps and mipmaps are not drawn.
- Automatic sorting of translucent triangles is approximated by the mean depth of each triangle.
- Renders through the strip buffer or the scaler stay with the core's renderer.

## Behavior of the Linux GLES backend

- A read of a texture often showed it as it was at the read before. The sink reads the pixels twice after the next frame of the engine. About one frame in a few hundred still came back as the frame before; it is drawn into video memory as it is.
- A pass that draws nothing was not run. The sink checks a new target with a white textured triangle, which also tells whether Flutter GPU works.
- The completion callback of a command buffer was not a reliable sign that the GPU had finished.
